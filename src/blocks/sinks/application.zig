// @block ApplicationSink
// @description Sink a signal to a host application.
//
// Provides an interface for applications to consume samples from the flowgraph.
// @category Sinks
// @ctparam T type Complex(f32), f32, u1, etc.
// @signature in:T >
// @usage
// var snk = radio.blocks.ApplicationSink(std.math.Complex(f32)).init();
// try top.connect(&src.block, &snk.block);
// ...
// const sample = snk.pop();

const std = @import("std");

const Block = @import("../../radio.zig").Block;
const SampleMux = @import("../../core/sample_mux.zig").SampleMux;

////////////////////////////////////////////////////////////////////////////////
// Application Sink
////////////////////////////////////////////////////////////////////////////////

pub fn ApplicationSink(comptime T: type) type {
    return struct {
        const Self = @This();

        block: Block,
        sample_mux: SampleMux = undefined,

        pub fn init() Self {
            return .{ .block = Block.initRaw(@This(), &[1]type{T}, &[0]type{}) };
        }

        pub fn start(self: *Self, sample_mux: SampleMux) !void {
            self.sample_mux = sample_mux;
        }

        ////////////////////////////////////////////////////////////////////////////
        // API
        ////////////////////////////////////////////////////////////////////////////

        pub fn wait(self: *Self, min_count: usize, timeout_ns: ?u64) error{ EndOfStream, Timeout }!void {
            return self.sample_mux.vtable.waitInputAvailable(self.sample_mux.ptr, 0, min_count * @sizeOf(T), timeout_ns);
        }

        pub fn available(self: *Self) error{EndOfStream}!usize {
            return try self.sample_mux.vtable.getInputAvailable(self.sample_mux.ptr, 0) / @sizeOf(T);
        }

        pub fn get(self: *Self) []const T {
            const buffer = self.sample_mux.vtable.getInputBuffer(self.sample_mux.ptr, 0);
            return @alignCast(std.mem.bytesAsSlice(T, buffer[0..std.mem.alignBackward(usize, buffer.len, @sizeOf(T))]));
        }

        pub fn update(self: *Self, count: usize) void {
            return self.sample_mux.vtable.updateInputBuffer(self.sample_mux.ptr, 0, count * @sizeOf(T));
        }

        pub fn discard(self: *Self) !void {
            self.update(try self.available());
        }

        pub fn read(self: *Self, samples: []T) usize {
            const buf: []const T = self.get();
            const count = @min(buf.len, samples.len);

            @memcpy(samples[0..count], buf[0..count]);
            self.update(count);

            return count;
        }

        pub fn pop(self: *Self) ?T {
            const buf: []const T = self.get();
            if (buf.len == 0) return null;

            const value = buf[0];
            self.update(1);
            return value;
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const ThreadSafeRingBuffer = @import("../../core/ring_buffer.zig").ThreadSafeRingBuffer;
const ThreadSafeRingBufferSampleMux = @import("../../core/sample_mux.zig").ThreadSafeRingBufferSampleMux;

test "ApplicationSink wait, available, get, update, read, pop, discard, eos" {
    // Create ring buffers
    var input_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.pageSize());
    defer input_ring_buffer.deinit();
    var output_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.pageSize());
    defer output_ring_buffer.deinit();

    // Get input writer
    var input_writer = input_ring_buffer.writer();

    // Create ring buffer sample mux
    var ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux.init(std.testing.allocator, &[_]*ThreadSafeRingBuffer{&input_ring_buffer}, &[1]*ThreadSafeRingBuffer{&output_ring_buffer});
    defer ring_buffer_sample_mux.deinit();

    // Create application sink block
    var application_sink = ApplicationSink(u32).init();
    try application_sink.start(ring_buffer_sample_mux.sampleMux());

    // Wait should block
    try std.testing.expectError(error.Timeout, application_sink.wait(1, std.time.ns_per_ms));

    // Available should be zero
    try std.testing.expectEqual(0, try application_sink.available());
    // Buffer should be empty
    try std.testing.expectEqual(0, application_sink.get().len);

    // Write two samples
    input_writer.write(std.mem.sliceAsBytes(&[2]u32{ 1, 2 }));

    // Available should be two
    try std.testing.expectEqual(2, try application_sink.available());

    // Get buffer
    const buf1 = application_sink.get();
    try std.testing.expectEqual(2, buf1.len);
    try std.testing.expectEqual(1, buf1[0]);
    try std.testing.expectEqual(2, buf1[1]);

    // Update sink
    application_sink.update(2);

    // AVailable should be zero
    try std.testing.expectEqual(0, try application_sink.available());

    // Write three samples
    input_writer.write(std.mem.sliceAsBytes(&[3]u32{ 5, 6, 7 }));

    // Available should be three
    try std.testing.expectEqual(3, try application_sink.available());

    // Read three samples
    var buf2: [5]u32 = undefined;
    try std.testing.expectEqual(3, application_sink.read(&buf2));
    try std.testing.expectEqual(5, buf2[0]);
    try std.testing.expectEqual(6, buf2[1]);
    try std.testing.expectEqual(7, buf2[2]);

    // Available should be zero
    try std.testing.expectEqual(0, try application_sink.available());

    // Write four samples
    input_writer.write(std.mem.sliceAsBytes(&[4]u32{ 8, 9, 10, 11 }));

    // Available should be two
    try std.testing.expectEqual(4, application_sink.available());

    // Pop two samples
    try std.testing.expectEqual(8, application_sink.pop());
    try std.testing.expectEqual(9, application_sink.pop());

    // Discard remaining samples
    try application_sink.discard();

    // Available should be zero
    try std.testing.expectEqual(0, application_sink.available());

    // Pop should return null
    try std.testing.expectEqual(null, application_sink.pop());

    // Write two samples and set EOS
    input_writer.write(std.mem.sliceAsBytes(&[2]u32{ 10, 11 }));
    input_writer.setEOS();

    // Available should be two
    try std.testing.expectEqual(2, application_sink.available());

    // Consume two samples
    application_sink.update(2);

    // Available should return EOS
    try std.testing.expectError(error.EndOfStream, application_sink.available());

    // Wait should return EOS
    try std.testing.expectError(error.EndOfStream, application_sink.wait(1, std.time.ns_per_ms));
}

test "ApplicationSink blocking read" {
    // Create ring buffers
    var input_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.pageSize());
    defer input_ring_buffer.deinit();
    var output_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.pageSize());
    defer output_ring_buffer.deinit();

    // Get input writer
    var input_writer = input_ring_buffer.writer();

    // Create ring buffer sample mux
    var ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux.init(std.testing.allocator, &[_]*ThreadSafeRingBuffer{&input_ring_buffer}, &[1]*ThreadSafeRingBuffer{&output_ring_buffer});
    defer ring_buffer_sample_mux.deinit();

    // Create application sink block
    var application_sink = ApplicationSink(u32).init();
    try application_sink.start(ring_buffer_sample_mux.sampleMux());

    // Wait should block
    try std.testing.expectError(error.Timeout, application_sink.wait(1, std.time.ns_per_ms));

    const BufferWaiter = struct {
        fn run(sink: *ApplicationSink(u32), done: *std.Thread.ResetEvent) !void {
            // Wait for two samples availability
            try sink.wait(2, null);
            // Signal done
            done.set();
        }
    };

    // Spawn a thread that blocks until two samples are available
    var done_event = std.Thread.ResetEvent{};
    var thread = try std.Thread.spawn(.{}, BufferWaiter.run, .{ &application_sink, &done_event });

    // Check thread is blocking
    try std.testing.expectError(error.Timeout, done_event.timedWait(std.time.ns_per_ms));

    // Write one sample
    input_writer.write(std.mem.sliceAsBytes(&[1]u32{123}));

    // Check thread is still blocking
    try std.testing.expectError(error.Timeout, done_event.timedWait(std.time.ns_per_ms));

    // Write one sample
    input_writer.write(std.mem.sliceAsBytes(&[1]u32{456}));

    // Check buffer waiter completed
    try done_event.timedWait(std.time.ns_per_ms);
    try std.testing.expectEqual(true, done_event.isSet());
    thread.join();
}
