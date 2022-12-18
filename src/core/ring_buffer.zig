const std = @import("std");

////////////////////////////////////////////////////////////////////////////////
// RingBuffer Memory Implementations
////////////////////////////////////////////////////////////////////////////////

const CopiedMemoryImpl = struct {
    allocator: std.mem.Allocator,
    buf: []u8,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !CopiedMemoryImpl {
        var buf = try allocator.alloc(u8, capacity * 2);

        // Zero initialize buffer
        for (buf) |*e| e.* = 0;

        return .{
            .allocator = allocator,
            .buf = buf,
        };
    }

    pub fn deinit(self: *CopiedMemoryImpl) void {
        self.allocator.free(self.buf);
    }

    pub fn alias(self: *CopiedMemoryImpl, dest: usize, src: usize, count: usize) void {
        std.mem.copy(u8, self.buf[dest .. dest + count], self.buf[src .. src + count]);
    }
};

const MappedMemoryImpl = struct {
    fd: std.os.fd_t,
    buf: []align(std.mem.page_size) u8,

    const MappingError = error{
        MappingNotAdjacent,
    };

    pub fn init(_: std.mem.Allocator, capacity: usize) !MappedMemoryImpl {
        // Create memfd
        const fd = try std.os.memfd_create("ring_buffer_mem", 0);
        errdefer std.os.close(fd);

        // Size memory
        try std.os.ftruncate(fd, capacity);

        // Map the file with two regions of capacity
        const mapping1 = try std.os.mmap(null, 2 * capacity, std.os.PROT.READ | std.os.PROT.WRITE, std.os.MAP.SHARED, fd, 0);
        errdefer std.os.munmap(mapping1);

        // Remap second region to first
        const mapping2 = try std.os.mmap(@alignCast(std.mem.page_size, mapping1.ptr + capacity), capacity, std.os.PROT.READ | std.os.PROT.WRITE, std.os.MAP.SHARED | std.os.MAP.FIXED, fd, 0);
        errdefer std.os.munmap(mapping2);

        // Validate mapping is adjacent
        if (@ptrToInt(mapping2.ptr) < @ptrToInt(mapping1.ptr) or @ptrToInt(mapping2.ptr) - @ptrToInt(mapping1.ptr) != capacity) {
            return MappingError.MappingNotAdjacent;
        }

        return .{ .fd = fd, .buf = mapping1.ptr[0 .. capacity * 2] };
    }

    pub fn deinit(self: *MappedMemoryImpl) void {
        std.os.munmap(self.buf);
        std.os.close(self.fd);
    }

    pub fn alias(_: *MappedMemoryImpl, _: usize, _: usize, _: usize) void {
        // No-op
    }
};

const DefaultMemoryImpl = if (builtin.os.tag == .linux) MappedMemoryImpl else CopiedMemoryImpl;

////////////////////////////////////////////////////////////////////////////////
// RingBuffer Implementation
////////////////////////////////////////////////////////////////////////////////

// RingBuffer is a ring buffer implemented with an adjacent, aliased memory
// region to allow for contiguous reads and writes at all times.
//
//     R points to unread data
//     W points to unwritten data
//     E points to end of virtual buffer
//    2E points to end of real buffer
//
// It exists in two basic states:
//
// R <= W
//
//   |-----------|xxxxxxxxxxx|-------| |-------------------------------|
//   0           R           W       E E                               2E
//
//      Write Available = E - W + R - 1
//       Read Available = W - R
//
// R > W
//
//   |xxx|----------------|xxxxxxxxxx| |xxx|----------------|xxxxxxxxxx|
//   0   W                R          E E                               2E
//
//      Write Available = R - W - 1
//       Read Available = E - R + W
//
// Empty and Full States:
//
// Empty (R == W, case R <= W)
//
//   |-----------------------|-------| |-------------------------------|
//   0                       R       E E                               2E
//                           W
//
//      Write Available = E - W + R - 1 = E - 1
//       Read Available = W - R = 0
//
// Full (W = R - 1, case R > W)
//
//   |xxxxxxxxxxxxxxxxxxxxxx||xxxxxxx| |xxxxxxxxxxxxxxxxxxxxxxxxxxxxx|-|
//   0                      WR       E E                               2E
//
//
//      Write Available = R - W - 1 = R - R + 1 - 1 = 0
//       Read Available = E - R + W = E - R + R - 1 = E - 1
//

fn RingBuffer(comptime MemoryImpl: type) type {
    return struct {
        const Self = @This();

        // Max number of readers supported
        pub const MAX_NUM_READERS = 8;

        // Memory and Configuration
        memory: MemoryImpl,
        capacity: usize,
        num_readers: usize = 0,

        // Accounting State
        read_index: [MAX_NUM_READERS]usize = [_]usize{0} ** MAX_NUM_READERS,
        write_index: usize = 0,
        eof: bool = false,

        ////////////////////////////////////////////////////////////////////////
        // Constructor and Destructor
        ////////////////////////////////////////////////////////////////////////

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            return .{
                .memory = try MemoryImpl.init(allocator, capacity),
                .capacity = capacity,
            };
        }

        pub fn deinit(self: *Self) void {
            self.memory.deinit();
        }

        ////////////////////////////////////////////////////////////////////////
        // Internal Helper
        ////////////////////////////////////////////////////////////////////////

        pub fn _minReadIndex(self: *Self) usize {
            // Optimize for single reader
            if (self.num_readers == 1) {
                return self.read_index[0];
            }

            // Find lagging reader index
            var min_weight: usize = std.math.maxInt(usize);
            var min_index: usize = 0;

            for (self.read_index[0..self.num_readers]) |read_index, i| {
                const weight = if (read_index <= self.write_index) read_index + self.capacity else read_index;
                if (weight < min_weight) {
                    min_weight = weight;
                    min_index = i;
                }
            }

            return self.read_index[min_index];
        }

        ////////////////////////////////////////////////////////////////////////
        // Write API
        ////////////////////////////////////////////////////////////////////////

        pub fn getWriteAvailable(self: *Self) usize {
            const min_read_index = self._minReadIndex();
            return if (min_read_index <= self.write_index) self.capacity - self.write_index + min_read_index - 1 else min_read_index - self.write_index - 1;
        }

        pub fn getWriteBuffer(self: *Self, count: usize) []u8 {
            return self.memory.buf[self.write_index .. self.write_index + count];
        }

        pub fn updateWriteIndex(self: *Self, count: usize) void {
            // Copy over wrapped bytes to adjacent region if write index is wrapped
            if (self.write_index + count > self.capacity) {
                self.memory.alias(0, self.capacity, self.write_index + count - self.capacity);
            } else if (self.write_index < self._minReadIndex()) {
                self.memory.alias(self.capacity + self.write_index, self.write_index, count);
            }

            self.write_index = (self.write_index + count) % self.capacity;
        }

        pub fn setEOF(self: *Self) void {
            self.eof = true;
        }

        ////////////////////////////////////////////////////////////////////////
        // Read API
        ////////////////////////////////////////////////////////////////////////

        pub fn getReadAvailable(self: *Self, index: usize) usize {
            return if (self.read_index[index] <= self.write_index) self.write_index - self.read_index[index] else self.capacity - self.read_index[index] + self.write_index;
        }

        pub fn getEOF(self: *Self) bool {
            return self.eof;
        }

        pub fn getReadBuffer(self: *Self, index: usize, count: usize) []const u8 {
            return self.memory.buf[self.read_index[index] .. self.read_index[index] + count];
        }

        pub fn updateReadIndex(self: *Self, index: usize, count: usize) void {
            self.read_index[index] = (self.read_index[index] + count) % self.capacity;
        }

        pub fn addReader(self: *Self) usize {
            std.debug.assert(self.num_readers < MAX_NUM_READERS);

            const index = self.num_readers;
            self.num_readers += 1;

            return index;
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// ThreadSafeRingBuffer
////////////////////////////////////////////////////////////////////////////////

fn _ThreadSafeRingBuffer(comptime RingBufferImpl: type) type {
    return struct {
        const Self = @This();

        // Ring Buffer Implementation
        impl: RingBufferImpl,

        // Lock and Condition Variables
        mutex: std.Thread.Mutex = .{},
        cond_read_available: std.Thread.Condition = .{},
        cond_write_available: std.Thread.Condition = .{},

        ////////////////////////////////////////////////////////////////////////
        // Constructor and Destructor
        ////////////////////////////////////////////////////////////////////////

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            return .{ .impl = try RingBufferImpl.init(allocator, capacity) };
        }

        pub fn deinit(self: *Self) void {
            self.impl.deinit();
        }

        ////////////////////////////////////////////////////////////////////////
        // Writer and Reader Implementations
        ////////////////////////////////////////////////////////////////////////

        pub const Writer = struct {
            ring_buffer: *Self,

            pub fn getAvailable(self: *const @This()) usize {
                self.ring_buffer.mutex.lock();
                defer self.ring_buffer.mutex.unlock();

                return self.ring_buffer.impl.getWriteAvailable();
            }

            pub fn getBuffer(self: *@This(), count: usize) []u8 {
                self.ring_buffer.mutex.lock();
                defer self.ring_buffer.mutex.unlock();

                return self.ring_buffer.impl.getWriteBuffer(count);
            }

            pub fn update(self: *@This(), count: usize) void {
                self.ring_buffer.mutex.lock();
                defer self.ring_buffer.mutex.unlock();

                self.ring_buffer.impl.updateWriteIndex(count);

                self.ring_buffer.cond_read_available.signal();
            }

            pub fn setEOF(self: *@This()) void {
                self.ring_buffer.mutex.lock();
                defer self.ring_buffer.mutex.unlock();

                self.ring_buffer.impl.setEOF();
            }

            pub fn wait(self: *@This(), min_count: usize) void {
                self.ring_buffer.mutex.lock();
                defer self.ring_buffer.mutex.unlock();

                while (self.ring_buffer.impl.getWriteAvailable() < min_count) {
                    self.ring_buffer.cond_write_available.wait(&self.ring_buffer.mutex);
                }
            }

            pub fn write(self: *@This(), data: []const u8) void {
                std.debug.assert(self.getAvailable() >= data.len);
                std.mem.copy(u8, self.getBuffer(data.len), data);
                self.update(data.len);
            }
        };

        pub const Reader = struct {
            ring_buffer: *Self,
            index: usize,

            pub fn getAvailable(self: *const @This()) error{EndOfFile}!usize {
                self.ring_buffer.mutex.lock();
                defer self.ring_buffer.mutex.unlock();

                const available = self.ring_buffer.impl.getReadAvailable(self.index);
                if (available == 0 and self.ring_buffer.impl.getEOF()) {
                    return error.EndOfFile;
                }

                return available;
            }

            pub fn getBuffer(self: *@This(), count: usize) []const u8 {
                self.ring_buffer.mutex.lock();
                defer self.ring_buffer.mutex.unlock();

                return self.ring_buffer.impl.getReadBuffer(self.index, count);
            }

            pub fn update(self: *@This(), count: usize) void {
                self.ring_buffer.mutex.lock();
                defer self.ring_buffer.mutex.unlock();

                self.ring_buffer.impl.updateReadIndex(self.index, count);

                self.ring_buffer.cond_write_available.signal();
            }

            pub fn wait(self: *@This(), min_count: usize) void {
                self.ring_buffer.mutex.lock();
                defer self.ring_buffer.mutex.unlock();

                while (self.ring_buffer.impl.getReadAvailable(self.index) < min_count) {
                    self.ring_buffer.cond_read_available.wait(&self.ring_buffer.mutex);
                }
            }

            pub fn read(self: *@This(), data: []u8) []u8 {
                std.debug.assert(self.getAvailable() catch unreachable >= data.len);
                std.mem.copy(u8, data, self.getBuffer(data.len));
                self.update(data.len);
                return data;
            }
        };

        ////////////////////////////////////////////////////////////////////////
        // Writer and Reader Factory
        ////////////////////////////////////////////////////////////////////////

        pub fn writer(self: *Self) Writer {
            return Writer{ .ring_buffer = self };
        }

        pub fn reader(self: *Self) Reader {
            return Reader{ .ring_buffer = self, .index = self.impl.addReader() };
        }
    };
}

pub const ThreadSafeRingBuffer = _ThreadSafeRingBuffer(RingBuffer(DefaultMemoryImpl));

////////////////////////////////////////////////////////////////////////////////
// RingBuffer Tests
////////////////////////////////////////////////////////////////////////////////

const builtin = @import("builtin");

test "RingBuffer single writer, single reader" {
    inline for ([_]type{CopiedMemoryImpl}) |MemoryImpl| {
        var ring_buffer = try RingBuffer(MemoryImpl).init(std.testing.allocator, 8);
        defer ring_buffer.deinit();

        _ = ring_buffer.addReader();

        std.mem.copy(u8, ring_buffer.memory.buf, &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 });

        // Initial state
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.write_index);
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.read_index[0]);
        try std.testing.expectEqual(@as(usize, 7), ring_buffer.getWriteAvailable());
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.getReadAvailable(0));
        try std.testing.expectEqual(@as([]u8, ring_buffer.memory.buf[0..7]), ring_buffer.getWriteBuffer(ring_buffer.getWriteAvailable()));
        try std.testing.expectEqual(@as([]const u8, ring_buffer.memory.buf[0..0]), ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));
        try std.testing.expectEqualSlices(u8, &[_]u8{}, ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));

        // Write 3
        ring_buffer.updateWriteIndex(3);
        try std.testing.expectEqual(@as(usize, 3), ring_buffer.write_index);
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.read_index[0]);
        try std.testing.expectEqual(@as(usize, 4), ring_buffer.getWriteAvailable());
        try std.testing.expectEqual(@as(usize, 3), ring_buffer.getReadAvailable(0));
        try std.testing.expectEqual(@as([]u8, ring_buffer.memory.buf[3..7]), ring_buffer.getWriteBuffer(ring_buffer.getWriteAvailable()));
        try std.testing.expectEqual(@as([]const u8, ring_buffer.memory.buf[0..3]), ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03 }, ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));

        // Write 4
        ring_buffer.updateWriteIndex(4);
        try std.testing.expectEqual(@as(usize, 7), ring_buffer.write_index);
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.read_index[0]);
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.getWriteAvailable());
        try std.testing.expectEqual(@as(usize, 7), ring_buffer.getReadAvailable(0));
        try std.testing.expectEqual(@as([]u8, ring_buffer.memory.buf[7..7]), ring_buffer.getWriteBuffer(ring_buffer.getWriteAvailable()));
        try std.testing.expectEqual(@as([]const u8, ring_buffer.memory.buf[0..7]), ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07 }, ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));

        // Read 5
        ring_buffer.updateReadIndex(0, 5);
        try std.testing.expectEqual(@as(usize, 7), ring_buffer.write_index);
        try std.testing.expectEqual(@as(usize, 5), ring_buffer.read_index[0]);
        try std.testing.expectEqual(@as(usize, 5), ring_buffer.getWriteAvailable());
        try std.testing.expectEqual(@as(usize, 2), ring_buffer.getReadAvailable(0));
        try std.testing.expectEqual(@as([]u8, ring_buffer.memory.buf[7..12]), ring_buffer.getWriteBuffer(ring_buffer.getWriteAvailable()));
        try std.testing.expectEqual(@as([]const u8, ring_buffer.memory.buf[5..7]), ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x06, 0x07 }, ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));

        // Write 3
        std.mem.copy(u8, ring_buffer.getWriteBuffer(3), &[_]u8{ 0xa8, 0xa9, 0xaa });
        ring_buffer.updateWriteIndex(3);
        try std.testing.expectEqual(@as(usize, 2), ring_buffer.write_index);
        try std.testing.expectEqual(@as(usize, 5), ring_buffer.read_index[0]);
        try std.testing.expectEqual(@as(usize, 2), ring_buffer.getWriteAvailable());
        try std.testing.expectEqual(@as(usize, 5), ring_buffer.getReadAvailable(0));
        try std.testing.expectEqual(@as([]u8, ring_buffer.memory.buf[2..4]), ring_buffer.getWriteBuffer(ring_buffer.getWriteAvailable()));
        try std.testing.expectEqual(@as([]const u8, ring_buffer.memory.buf[5..10]), ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x06, 0x07, 0xa8, 0xa9, 0xaa }, ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));

        // Check wrapped bytes
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0xa8, 0xa9, 0xaa }, ring_buffer.memory.buf[7..10]);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0xa9, 0xaa, 0x03 }, ring_buffer.memory.buf[0..3]);

        // Write 2
        std.mem.copy(u8, ring_buffer.getWriteBuffer(2), &[_]u8{ 0xb1, 0xb2 });
        ring_buffer.updateWriteIndex(2);
        try std.testing.expectEqual(@as(usize, 4), ring_buffer.write_index);
        try std.testing.expectEqual(@as(usize, 5), ring_buffer.read_index[0]);
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.getWriteAvailable());
        try std.testing.expectEqual(@as(usize, 7), ring_buffer.getReadAvailable(0));
        try std.testing.expectEqual(@as([]u8, ring_buffer.memory.buf[4..4]), ring_buffer.getWriteBuffer(ring_buffer.getWriteAvailable()));
        try std.testing.expectEqual(@as([]const u8, ring_buffer.memory.buf[5..12]), ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x06, 0x07, 0xa8, 0xa9, 0xaa, 0xb1, 0xb2 }, ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));

        // Check wrapped bytes
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0xb1, 0xb2 }, ring_buffer.memory.buf[10..12]);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0xa9, 0xaa, 0xb1, 0xb2, 0x05 }, ring_buffer.memory.buf[0..5]);

        // Read 5
        ring_buffer.updateReadIndex(0, 5);
        try std.testing.expectEqual(@as(usize, 4), ring_buffer.write_index);
        try std.testing.expectEqual(@as(usize, 2), ring_buffer.read_index[0]);
        try std.testing.expectEqual(@as(usize, 5), ring_buffer.getWriteAvailable());
        try std.testing.expectEqual(@as(usize, 2), ring_buffer.getReadAvailable(0));
        try std.testing.expectEqual(@as([]u8, ring_buffer.memory.buf[4..9]), ring_buffer.getWriteBuffer(ring_buffer.getWriteAvailable()));
        try std.testing.expectEqual(@as([]const u8, ring_buffer.memory.buf[2..4]), ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0xb1, 0xb2 }, ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));

        // Write 5
        std.mem.copy(u8, ring_buffer.getWriteBuffer(5), &[_]u8{ 0xc1, 0xc2, 0xc3, 0xc4, 0xc5 });
        ring_buffer.updateWriteIndex(5);
        try std.testing.expectEqual(@as(usize, 1), ring_buffer.write_index);
        try std.testing.expectEqual(@as(usize, 2), ring_buffer.read_index[0]);
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.getWriteAvailable());
        try std.testing.expectEqual(@as(usize, 7), ring_buffer.getReadAvailable(0));
        try std.testing.expectEqual(@as([]u8, ring_buffer.memory.buf[1..1]), ring_buffer.getWriteBuffer(ring_buffer.getWriteAvailable()));
        try std.testing.expectEqual(@as([]const u8, ring_buffer.memory.buf[2..9]), ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0xb1, 0xb2, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5 }, ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));

        // Read 7
        ring_buffer.updateReadIndex(0, 7);
        try std.testing.expectEqual(@as(usize, 1), ring_buffer.write_index);
        try std.testing.expectEqual(@as(usize, 1), ring_buffer.read_index[0]);
        try std.testing.expectEqual(@as(usize, 7), ring_buffer.getWriteAvailable());
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.getReadAvailable(0));
        try std.testing.expectEqual(@as([]u8, ring_buffer.memory.buf[1..8]), ring_buffer.getWriteBuffer(ring_buffer.getWriteAvailable()));
        try std.testing.expectEqual(@as([]const u8, ring_buffer.memory.buf[1..1]), ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));
        try std.testing.expectEqualSlices(u8, &[_]u8{}, ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));
    }
}

test "RingBuffer single writer, multiple readers" {
    inline for ([_]type{CopiedMemoryImpl}) |MemoryImpl| {
        var ring_buffer = try RingBuffer(MemoryImpl).init(std.testing.allocator, 8);
        defer ring_buffer.deinit();

        _ = ring_buffer.addReader();
        _ = ring_buffer.addReader();
        _ = ring_buffer.addReader();

        std.mem.copy(u8, ring_buffer.memory.buf, &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 });

        // Initial state
        try std.testing.expectEqual(@as(usize, 7), ring_buffer.getWriteAvailable());
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.getReadAvailable(0));
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.getReadAvailable(1));
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.getReadAvailable(2));
        try std.testing.expectEqualSlices(u8, &[_]u8{}, ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));
        try std.testing.expectEqualSlices(u8, &[_]u8{}, ring_buffer.getReadBuffer(1, ring_buffer.getReadAvailable(1)));
        try std.testing.expectEqualSlices(u8, &[_]u8{}, ring_buffer.getReadBuffer(2, ring_buffer.getReadAvailable(2)));

        // Write 3
        ring_buffer.updateWriteIndex(3);
        try std.testing.expectEqual(@as(usize, 4), ring_buffer.getWriteAvailable());
        try std.testing.expectEqual(@as(usize, 3), ring_buffer.getReadAvailable(0));
        try std.testing.expectEqual(@as(usize, 3), ring_buffer.getReadAvailable(1));
        try std.testing.expectEqual(@as(usize, 3), ring_buffer.getReadAvailable(2));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03 }, ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03 }, ring_buffer.getReadBuffer(1, ring_buffer.getReadAvailable(1)));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03 }, ring_buffer.getReadBuffer(2, ring_buffer.getReadAvailable(2)));

        // Reader 1 read 3
        ring_buffer.updateReadIndex(0, 3);
        try std.testing.expectEqual(@as(usize, 4), ring_buffer.getWriteAvailable());
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.getReadAvailable(0));
        try std.testing.expectEqual(@as(usize, 3), ring_buffer.getReadAvailable(1));
        try std.testing.expectEqual(@as(usize, 3), ring_buffer.getReadAvailable(2));
        try std.testing.expectEqualSlices(u8, &[_]u8{}, ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03 }, ring_buffer.getReadBuffer(1, ring_buffer.getReadAvailable(1)));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03 }, ring_buffer.getReadBuffer(2, ring_buffer.getReadAvailable(2)));

        // Reader 2 read 2
        ring_buffer.updateReadIndex(1, 2);
        try std.testing.expectEqual(@as(usize, 4), ring_buffer.getWriteAvailable());
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.getReadAvailable(0));
        try std.testing.expectEqual(@as(usize, 1), ring_buffer.getReadAvailable(1));
        try std.testing.expectEqual(@as(usize, 3), ring_buffer.getReadAvailable(2));
        try std.testing.expectEqualSlices(u8, &[_]u8{}, ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));
        try std.testing.expectEqualSlices(u8, &[_]u8{0x03}, ring_buffer.getReadBuffer(1, ring_buffer.getReadAvailable(1)));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03 }, ring_buffer.getReadBuffer(2, ring_buffer.getReadAvailable(2)));

        // Reader 3 read 1
        ring_buffer.updateReadIndex(2, 1);
        try std.testing.expectEqual(@as(usize, 5), ring_buffer.getWriteAvailable());
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.getReadAvailable(0));
        try std.testing.expectEqual(@as(usize, 1), ring_buffer.getReadAvailable(1));
        try std.testing.expectEqual(@as(usize, 2), ring_buffer.getReadAvailable(2));
        try std.testing.expectEqualSlices(u8, &[_]u8{}, ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));
        try std.testing.expectEqualSlices(u8, &[_]u8{0x03}, ring_buffer.getReadBuffer(1, ring_buffer.getReadAvailable(1)));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0x03 }, ring_buffer.getReadBuffer(2, ring_buffer.getReadAvailable(2)));

        // Write 5
        ring_buffer.updateWriteIndex(5);
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.getWriteAvailable());
        try std.testing.expectEqual(@as(usize, 5), ring_buffer.getReadAvailable(0));
        try std.testing.expectEqual(@as(usize, 6), ring_buffer.getReadAvailable(1));
        try std.testing.expectEqual(@as(usize, 7), ring_buffer.getReadAvailable(2));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x04, 0x05, 0x06, 0x07, 0x08 }, ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 }, ring_buffer.getReadBuffer(1, ring_buffer.getReadAvailable(1)));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 }, ring_buffer.getReadBuffer(2, ring_buffer.getReadAvailable(2)));

        // Check indices
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.write_index);
        try std.testing.expectEqual(@as(usize, 3), ring_buffer.read_index[0]);
        try std.testing.expectEqual(@as(usize, 2), ring_buffer.read_index[1]);
        try std.testing.expectEqual(@as(usize, 1), ring_buffer.read_index[2]);

        // Reader 3 read 7
        ring_buffer.updateReadIndex(2, 7);
        try std.testing.expectEqual(@as(usize, 1), ring_buffer.getWriteAvailable());
        try std.testing.expectEqual(@as(usize, 5), ring_buffer.getReadAvailable(0));
        try std.testing.expectEqual(@as(usize, 6), ring_buffer.getReadAvailable(1));
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.getReadAvailable(2));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x04, 0x05, 0x06, 0x07, 0x08 }, ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 }, ring_buffer.getReadBuffer(1, ring_buffer.getReadAvailable(1)));
        try std.testing.expectEqualSlices(u8, &[_]u8{}, ring_buffer.getReadBuffer(2, ring_buffer.getReadAvailable(2)));

        // Check indices
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.write_index);
        try std.testing.expectEqual(@as(usize, 3), ring_buffer.read_index[0]);
        try std.testing.expectEqual(@as(usize, 2), ring_buffer.read_index[1]);
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.read_index[2]);

        // Reader 2 read 6
        ring_buffer.updateReadIndex(1, 6);
        try std.testing.expectEqual(@as(usize, 2), ring_buffer.getWriteAvailable());
        try std.testing.expectEqual(@as(usize, 5), ring_buffer.getReadAvailable(0));
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.getReadAvailable(1));
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.getReadAvailable(2));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x04, 0x05, 0x06, 0x07, 0x08 }, ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));
        try std.testing.expectEqualSlices(u8, &[_]u8{}, ring_buffer.getReadBuffer(1, ring_buffer.getReadAvailable(1)));
        try std.testing.expectEqualSlices(u8, &[_]u8{}, ring_buffer.getReadBuffer(2, ring_buffer.getReadAvailable(2)));

        // Check indices
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.write_index);
        try std.testing.expectEqual(@as(usize, 3), ring_buffer.read_index[0]);
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.read_index[1]);
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.read_index[2]);

        // Write 2
        ring_buffer.updateWriteIndex(2);
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.getWriteAvailable());
        try std.testing.expectEqual(@as(usize, 7), ring_buffer.getReadAvailable(0));
        try std.testing.expectEqual(@as(usize, 2), ring_buffer.getReadAvailable(1));
        try std.testing.expectEqual(@as(usize, 2), ring_buffer.getReadAvailable(2));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x04, 0x05, 0x06, 0x07, 0x08, 0x01, 0x02 }, ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02 }, ring_buffer.getReadBuffer(1, ring_buffer.getReadAvailable(1)));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02 }, ring_buffer.getReadBuffer(2, ring_buffer.getReadAvailable(2)));
    }
}

test "RingBuffer eof" {
    inline for ([_]type{CopiedMemoryImpl}) |MemoryImpl| {
        var ring_buffer = try RingBuffer(MemoryImpl).init(std.testing.allocator, 8);
        defer ring_buffer.deinit();

        _ = ring_buffer.addReader();
        _ = ring_buffer.addReader();

        std.mem.copy(u8, ring_buffer.memory.buf, &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 });

        // Initial state
        try std.testing.expectEqual(@as(usize, 7), ring_buffer.getWriteAvailable());
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.getReadAvailable(0));
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.getReadAvailable(1));
        try std.testing.expectEqualSlices(u8, &[_]u8{}, ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));
        try std.testing.expectEqualSlices(u8, &[_]u8{}, ring_buffer.getReadBuffer(1, ring_buffer.getReadAvailable(1)));

        // Write 5
        ring_buffer.updateWriteIndex(5);
        try std.testing.expectEqual(@as(usize, 2), ring_buffer.getWriteAvailable());
        try std.testing.expectEqual(@as(usize, 5), ring_buffer.getReadAvailable(0));
        try std.testing.expectEqual(@as(usize, 5), ring_buffer.getReadAvailable(1));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05 }, ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05 }, ring_buffer.getReadBuffer(1, ring_buffer.getReadAvailable(1)));

        // Reader 1 read 3
        ring_buffer.updateReadIndex(0, 3);
        try std.testing.expectEqual(@as(usize, 2), ring_buffer.getWriteAvailable());
        try std.testing.expectEqual(@as(usize, 2), ring_buffer.getReadAvailable(0));
        try std.testing.expectEqual(@as(usize, 5), ring_buffer.getReadAvailable(1));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x04, 0x05 }, ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05 }, ring_buffer.getReadBuffer(1, ring_buffer.getReadAvailable(1)));

        // Reader 2 read 2
        ring_buffer.updateReadIndex(1, 2);
        try std.testing.expectEqual(@as(usize, 4), ring_buffer.getWriteAvailable());
        try std.testing.expectEqual(@as(usize, 2), ring_buffer.getReadAvailable(0));
        try std.testing.expectEqual(@as(usize, 3), ring_buffer.getReadAvailable(1));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x04, 0x05 }, ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x03, 0x04, 0x05 }, ring_buffer.getReadBuffer(1, ring_buffer.getReadAvailable(1)));

        // Writer set EOF
        ring_buffer.setEOF();

        // Reader 1 read 1
        ring_buffer.updateReadIndex(0, 1);
        try std.testing.expectEqual(@as(usize, 4), ring_buffer.getWriteAvailable());
        try std.testing.expectEqual(@as(usize, 1), ring_buffer.getReadAvailable(0));
        try std.testing.expectEqual(@as(usize, 3), ring_buffer.getReadAvailable(1));
        try std.testing.expectEqualSlices(u8, &[_]u8{0x05}, ring_buffer.getReadBuffer(0, ring_buffer.getReadAvailable(0)));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x03, 0x04, 0x05 }, ring_buffer.getReadBuffer(1, ring_buffer.getReadAvailable(1)));

        // Reader 1 read 1
        ring_buffer.updateReadIndex(0, 1);
        try std.testing.expectEqual(@as(usize, 4), ring_buffer.getWriteAvailable());
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.getReadAvailable(0));
        try std.testing.expectEqual(@as(usize, 3), ring_buffer.getReadAvailable(1));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x03, 0x04, 0x05 }, ring_buffer.getReadBuffer(1, ring_buffer.getReadAvailable(1)));

        // Reader 2 read 2
        ring_buffer.updateReadIndex(1, 2);
        try std.testing.expectEqual(@as(usize, 6), ring_buffer.getWriteAvailable());
        try std.testing.expectEqual(@as(usize, 1), ring_buffer.getReadAvailable(1));
        try std.testing.expectEqualSlices(u8, &[_]u8{0x05}, ring_buffer.getReadBuffer(1, ring_buffer.getReadAvailable(1)));

        // Reader 2 read 1, should get EOF next
        ring_buffer.updateReadIndex(1, 1);
        try std.testing.expectEqual(@as(usize, 7), ring_buffer.getWriteAvailable());
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.getReadAvailable(0));
        try std.testing.expectEqual(@as(usize, 0), ring_buffer.getReadAvailable(1));
        try std.testing.expectEqual(true, ring_buffer.getEOF());
    }
}

////////////////////////////////////////////////////////////////////////////////
// ThreadSafeRingBuffer Tests
////////////////////////////////////////////////////////////////////////////////

test "RingBuffer write wait" {
    // This test requires spawning threads
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    inline for ([_]type{CopiedMemoryImpl}) |MemoryImpl| {
        const RingBufferType = comptime _ThreadSafeRingBuffer(RingBuffer(MemoryImpl));

        var ring_buffer = try RingBufferType.init(std.testing.allocator, 8);
        defer ring_buffer.deinit();

        var writer = ring_buffer.writer();
        var reader1 = ring_buffer.reader();
        var reader2 = ring_buffer.reader();
        var reader3 = ring_buffer.reader();

        // Write 5
        writer.update(5);
        // Reader 1 read 4
        reader1.update(4);
        // Reader 2 read 3
        reader2.update(3);
        // Reader 3 read 2
        reader3.update(2);

        // Validate available counts
        try std.testing.expectEqual(@as(usize, 4), writer.getAvailable());
        try std.testing.expectEqual(@as(usize, 1), try reader1.getAvailable());
        try std.testing.expectEqual(@as(usize, 2), try reader2.getAvailable());
        try std.testing.expectEqual(@as(usize, 3), try reader3.getAvailable());

        const WriteWaiter = struct {
            fn run(wr: *RingBufferType.Writer, done: *std.Thread.ResetEvent) !void {
                // Wait for 7
                wr.wait(7);
                // Signal done
                done.set();
            }
        };

        // Spawn a thread that waits until writer has 7 available
        var done_event = std.Thread.ResetEvent{};
        var thread = try std.Thread.spawn(.{}, WriteWaiter.run, .{ &writer, &done_event });

        // Reader 1 read 1
        reader1.update(1);
        try std.testing.expectError(error.Timeout, done_event.timedWait(std.time.ns_per_ms));
        // Reader 2 read 2
        reader2.update(2);
        try std.testing.expectError(error.Timeout, done_event.timedWait(std.time.ns_per_ms));
        // Reader 3 read 3
        reader3.update(3);

        // Check write waiter completed
        try done_event.timedWait(std.time.ns_per_ms);
        try std.testing.expectEqual(true, done_event.isSet());
        thread.join();
    }
}

test "RingBuffer read wait" {
    // This test requires spawning threads
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    inline for ([_]type{CopiedMemoryImpl}) |MemoryImpl| {
        const RingBufferType = comptime _ThreadSafeRingBuffer(RingBuffer(MemoryImpl));

        var ring_buffer = try RingBufferType.init(std.testing.allocator, 8);
        defer ring_buffer.deinit();

        var writer = ring_buffer.writer();
        var reader1 = ring_buffer.reader();
        var reader2 = ring_buffer.reader();

        // Write 5
        writer.update(7);
        // Reader 1 read 7
        reader1.update(7);

        // Validate available counts
        try std.testing.expectEqual(@as(usize, 0), writer.getAvailable());
        try std.testing.expectEqual(@as(usize, 0), try reader1.getAvailable());
        try std.testing.expectEqual(@as(usize, 7), try reader2.getAvailable());

        const ReadWaiter = struct {
            fn run(rd: *RingBufferType.Reader, done: *std.Thread.ResetEvent) !void {
                // Wait for 5
                rd.wait(5);
                // Signal done
                done.set();
            }
        };

        // Spawn a thread that waits until reader has 7 available
        var done_event = std.Thread.ResetEvent{};
        var thread = try std.Thread.spawn(.{}, ReadWaiter.run, .{ &reader1, &done_event });

        // Reader 2 read 2
        reader2.update(2);
        try std.testing.expectError(error.Timeout, done_event.timedWait(std.time.ns_per_ms));
        // Reader 2 read 2
        reader2.update(2);
        try std.testing.expectError(error.Timeout, done_event.timedWait(std.time.ns_per_ms));
        // Writer write 2
        writer.update(2);
        try std.testing.expectError(error.Timeout, done_event.timedWait(std.time.ns_per_ms));
        // Writer write 2
        writer.update(2);
        try std.testing.expectError(error.Timeout, done_event.timedWait(std.time.ns_per_ms));

        // Validate available counts
        try std.testing.expectEqual(@as(usize, 0), writer.getAvailable());
        try std.testing.expectEqual(@as(usize, 4), try reader1.getAvailable());
        try std.testing.expectEqual(@as(usize, 7), try reader2.getAvailable());

        // Reader 2 read 1
        reader2.update(1);
        try std.testing.expectError(error.Timeout, done_event.timedWait(std.time.ns_per_ms));
        // Writer write 1
        writer.update(1);

        // Check write waiter completed
        try done_event.timedWait(std.time.ns_per_ms);
        try std.testing.expectEqual(true, done_event.isSet());
        thread.join();
    }
}

////////////////////////////////////////////////////////////////////////////////
// MappedMemoryImpl test
////////////////////////////////////////////////////////////////////////////////

test "MappedMemoryImpl" {
    // This test requires linux
    if (builtin.os.tag != .linux) {
        return error.SkipZigTest;
    }

    const capacity = std.mem.page_size * 8;

    // Create three mappings
    var memory1 = try MappedMemoryImpl.init(std.testing.allocator, capacity);
    defer memory1.deinit();
    var memory2 = try MappedMemoryImpl.init(std.testing.allocator, capacity);
    defer memory2.deinit();
    var memory3 = try MappedMemoryImpl.init(std.testing.allocator, capacity);
    defer memory3.deinit();

    // Validate buffer sizes
    try std.testing.expectEqual(@as(usize, capacity * 2), memory1.buf.len);
    try std.testing.expectEqual(@as(usize, capacity * 2), memory2.buf.len);
    try std.testing.expectEqual(@as(usize, capacity * 2), memory3.buf.len);

    // Create three random buffers
    var buf1: [capacity]u8 = undefined;
    var buf2: [capacity]u8 = undefined;
    var buf3: [capacity]u8 = undefined;
    var prng = std.rand.DefaultPrng.init(123);
    prng.fill(&buf1);
    prng.fill(&buf2);
    prng.fill(&buf3);

    // Fill upper region
    std.mem.copy(u8, memory1.buf[capacity..], &buf1);
    std.mem.copy(u8, memory2.buf[capacity..], &buf2);
    std.mem.copy(u8, memory3.buf[capacity..], &buf3);

    // Validate lower
    try std.testing.expectEqualSlices(u8, memory1.buf[0..capacity], &buf1);
    try std.testing.expectEqualSlices(u8, memory2.buf[0..capacity], &buf2);
    try std.testing.expectEqualSlices(u8, memory3.buf[0..capacity], &buf3);

    // Fill lower region
    std.mem.copy(u8, memory1.buf[0..capacity], &buf3);
    std.mem.copy(u8, memory2.buf[0..capacity], &buf1);
    std.mem.copy(u8, memory3.buf[0..capacity], &buf2);

    // Validate upper
    try std.testing.expectEqualSlices(u8, memory1.buf[capacity..], &buf3);
    try std.testing.expectEqualSlices(u8, memory2.buf[capacity..], &buf1);
    try std.testing.expectEqualSlices(u8, memory3.buf[capacity..], &buf2);
}
