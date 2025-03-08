const std = @import("std");

const Block = @import("../../radio.zig").Block;
const SampleMux = @import("../../core/sample_mux.zig").SampleMux;

////////////////////////////////////////////////////////////////////////////////
// Application Source
////////////////////////////////////////////////////////////////////////////////

pub fn ApplicationSource(comptime T: type) type {
    return struct {
        const Self = @This();

        block: Block,
        rate: f64,
        sample_mux: SampleMux = undefined,

        pub fn init(rate: f64) Self {
            return .{ .block = Block.initRaw(@This(), &[0]type{}, &[1]type{T}), .rate = rate };
        }

        pub fn setRate(self: *Self, _: f64) !f64 {
            return self.rate;
        }

        pub fn start(self: *Self, sample_mux: SampleMux) !void {
            self.sample_mux = sample_mux;
        }

        pub fn stop(self: *Self) void {
            self.setEOS();
        }

        ////////////////////////////////////////////////////////////////////////////
        // API
        ////////////////////////////////////////////////////////////////////////////

        pub fn wait(self: *Self, min_count: usize, timeout_ns: ?u64) error{ BrokenStream, Timeout }!void {
            return self.sample_mux.vtable.waitOutputAvailable(self.sample_mux.ptr, 0, min_count * @sizeOf(T), timeout_ns);
        }

        pub fn available(self: *Self) error{BrokenStream}!usize {
            return try self.sample_mux.vtable.getOutputAvailable(self.sample_mux.ptr, 0) / @sizeOf(T);
        }

        pub fn get(self: *Self) []T {
            const buffer = self.sample_mux.vtable.getOutputBuffer(self.sample_mux.ptr, 0);
            return @alignCast(std.mem.bytesAsSlice(T, buffer[0..std.mem.alignBackward(usize, buffer.len, @sizeOf(T))]));
        }

        pub fn update(self: *Self, count: usize) void {
            return self.sample_mux.vtable.updateOutputBuffer(self.sample_mux.ptr, 0, count * @sizeOf(T));
        }

        pub fn write(self: *Self, samples: []const T) usize {
            const buf: []T = self.get();
            const count = @min(buf.len, samples.len);

            @memcpy(buf[0..count], samples[0..count]);
            self.update(count);

            return count;
        }

        pub fn setEOS(self: *Self) void {
            return self.sample_mux.vtable.setEOS(self.sample_mux.ptr);
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const builtin = @import("builtin");

const ThreadSafeRingBuffer = @import("../../core/ring_buffer.zig").ThreadSafeRingBuffer;
const ThreadSafeRingBufferSampleMux = @import("../../core/sample_mux.zig").ThreadSafeRingBufferSampleMux;

test "ApplicationSource rate" {
    // Create application source block
    var application_source = ApplicationSource(u32).init(8000);

    try application_source.block.setRate(0);
    try std.testing.expectEqual(8000, application_source.block.getRate(usize));
}

test "ApplicationSource available, get, update, write, setEOS" {
    // Create ring buffers
    var input_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.pageSize());
    defer input_ring_buffer.deinit();
    var output_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.pageSize());
    defer output_ring_buffer.deinit();

    // Get output reader
    var output_reader = output_ring_buffer.reader();

    // Create ring buffer sample mux
    var ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux.init(std.testing.allocator, &[_]*ThreadSafeRingBuffer{&input_ring_buffer}, &[1]*ThreadSafeRingBuffer{&output_ring_buffer});
    defer ring_buffer_sample_mux.deinit();

    // Create application source block
    var application_source = ApplicationSource(u32).init(8000);
    try application_source.start(ring_buffer_sample_mux.sampleMux());

    // Wait should not block
    try std.testing.expectEqual(void{}, application_source.wait(1, std.time.ns_per_ms));

    // Available should be ring buffer size - 1
    try std.testing.expectEqual((std.heap.pageSize() / @sizeOf(u32)) - 1, application_source.available());

    // Get buffer
    var buf = application_source.get();
    try std.testing.expectEqual((std.heap.pageSize() / @sizeOf(u32)) - 1, buf.len);

    // Write two samples
    buf[0] = 1;
    buf[1] = 2;
    application_source.update(2);

    // Available should be ring buffer size - 3
    try std.testing.expectEqual((std.heap.pageSize() / @sizeOf(u32)) - 3, application_source.available());

    // Reader should have two samples
    try std.testing.expectEqual(2 * @sizeOf(u32), try output_reader.getAvailable());
    try std.testing.expectEqual(1, std.mem.readInt(u32, output_reader.getBuffer()[0..4], builtin.target.cpu.arch.endian()));
    try std.testing.expectEqual(2, std.mem.readInt(u32, output_reader.getBuffer()[4..8], builtin.target.cpu.arch.endian()));
    output_reader.update(2 * @sizeOf(u32));

    // Available should be ring buffer size - 1
    try std.testing.expectEqual((std.heap.pageSize() / @sizeOf(u32)) - 1, application_source.available());

    // Write three samples
    try std.testing.expectEqual(3, application_source.write(&[3]u32{ 5, 6, 7 }));

    // Reader should have three samples
    try std.testing.expectEqual(3 * @sizeOf(u32), try output_reader.getAvailable());
    try std.testing.expectEqual(5, std.mem.readInt(u32, output_reader.getBuffer()[0..4], builtin.target.cpu.arch.endian()));
    try std.testing.expectEqual(6, std.mem.readInt(u32, output_reader.getBuffer()[4..8], builtin.target.cpu.arch.endian()));
    try std.testing.expectEqual(7, std.mem.readInt(u32, output_reader.getBuffer()[8..12], builtin.target.cpu.arch.endian()));
    output_reader.update(3 * @sizeOf(u32));

    // Write two samples and set EOS
    try std.testing.expectEqual(2, application_source.write(&[2]u32{ 8, 9 }));
    application_source.setEOS();

    // Reader should have two samples
    try std.testing.expectEqual(2 * @sizeOf(u32), try output_reader.getAvailable());
    output_reader.update(2 * @sizeOf(u32));

    // Reader should have EOS
    try std.testing.expectError(error.EndOfStream, output_reader.getAvailable());
}

test "ApplicationSource blocking wait" {
    // Create ring buffers
    var input_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.pageSize());
    defer input_ring_buffer.deinit();
    var output_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.pageSize());
    defer output_ring_buffer.deinit();

    // Get output reader
    var output_reader = output_ring_buffer.reader();

    // Create ring buffer sample mux
    var ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux.init(std.testing.allocator, &[_]*ThreadSafeRingBuffer{&input_ring_buffer}, &[1]*ThreadSafeRingBuffer{&output_ring_buffer});
    defer ring_buffer_sample_mux.deinit();

    // Create application source block
    var application_source = ApplicationSource(u32).init(8000);
    try application_source.start(ring_buffer_sample_mux.sampleMux());

    // Saturate application source
    try std.testing.expectEqual((std.heap.pageSize() / @sizeOf(u32)) - 1, application_source.available());
    application_source.update((std.heap.pageSize() / @sizeOf(u32)) - 1);
    try std.testing.expectEqual(0, application_source.available());

    // Write should write nothing
    try std.testing.expectEqual(0, application_source.write(&[1]u32{123}));

    // Consume one sample
    output_reader.update(@sizeOf(u32));

    // Check reader available
    try std.testing.expectEqual(std.heap.pageSize() - 2 * @sizeOf(u32), try output_reader.getAvailable());

    // Application source wait should timeout for more than 1 sample
    try std.testing.expectEqual(void{}, application_source.wait(1, std.time.ns_per_ms));
    try std.testing.expectError(error.Timeout, application_source.wait(2, std.time.ns_per_ms));
    try std.testing.expectError(error.Timeout, application_source.wait(2, std.time.ns_per_ms));

    const BufferWaiter = struct {
        fn run(source: *ApplicationSource(u32), done: *std.Thread.ResetEvent) !void {
            // Wait for two samples availability
            try source.wait(2, null);
            // Signal done
            done.set();
        }
    };

    // Spawn a thread that blocks until two samples are available
    var done_event = std.Thread.ResetEvent{};
    var thread = try std.Thread.spawn(.{}, BufferWaiter.run, .{ &application_source, &done_event });

    // Check thread is blocking
    try std.testing.expectError(error.Timeout, done_event.timedWait(std.time.ns_per_ms));

    // Consume 1 sample from output ring buffer
    output_reader.update(@sizeOf(u32));

    // Check buffer waiter completed
    try done_event.timedWait(std.time.ns_per_ms);
    try std.testing.expectEqual(true, done_event.isSet());
    thread.join();
}
