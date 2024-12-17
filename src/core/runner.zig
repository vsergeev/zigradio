const std = @import("std");

const Block = @import("block.zig").Block;
const SampleMux = @import("sample_mux.zig").SampleMux;

////////////////////////////////////////////////////////////////////////////////
// ThreadedBlockRunner
////////////////////////////////////////////////////////////////////////////////

pub const ThreadedBlockRunner = struct {
    instance: *Block,
    sample_mux: SampleMux,
    running: bool = false,
    thread: std.Thread = undefined,
    stop_event: std.Thread.ResetEvent = .{},

    pub fn init(instance: *Block, sample_mux: SampleMux) ThreadedBlockRunner {
        return .{
            .instance = instance,
            .sample_mux = sample_mux,
        };
    }

    pub fn deinit(self: *ThreadedBlockRunner) void {
        if (self.running) {
            self.stop();
            self.join();
        }
    }

    pub fn spawn(self: *ThreadedBlockRunner) !void {
        const Runner = struct {
            fn run(block: *Block, sample_mux: *SampleMux, stop_event: *std.Thread.ResetEvent) !void {
                while (true) {
                    if (stop_event.isSet()) {
                        sample_mux.setEOF();
                        break;
                    }

                    const process_result = try block.process(sample_mux);
                    if (process_result.eof) {
                        break;
                    }
                }
            }
        };

        self.thread = try std.Thread.spawn(.{}, Runner.run, .{ self.instance, &self.sample_mux, &self.stop_event });
        self.running = true;
    }

    pub fn stop(self: *ThreadedBlockRunner) void {
        self.stop_event.set();
    }

    pub fn join(self: *ThreadedBlockRunner) void {
        self.thread.join();
        self.running = false;
    }
};

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const builtin = @import("builtin");

const ProcessResult = @import("block.zig").ProcessResult;
const RuntimeDataType = @import("type_signature.zig").RuntimeDataType;

const ThreadSafeRingBuffer = @import("ring_buffer.zig").ThreadSafeRingBuffer;
const ThreadSafeRingBufferSampleMux = @import("sample_mux.zig").ThreadSafeRingBufferSampleMux;

const TestSource = struct {
    block: Block,
    count: usize = 0,

    pub fn init() TestSource {
        return .{ .block = Block.init(@This()) };
    }

    pub fn setRate(_: *TestSource, _: f64) !f64 {
        return 8000;
    }

    pub fn process(self: *TestSource, z: []u16) !ProcessResult {
        if (self.count == 100) {
            return ProcessResult.eof();
        }

        z[0] = @as(u16, @intCast(self.count));
        self.count += 1;

        return ProcessResult.init(&[0]usize{}, &[1]usize{1});
    }
};

const TestBlock = struct {
    block: Block,

    pub fn init() TestBlock {
        return .{ .block = Block.init(@This()) };
    }

    pub fn process(_: *TestBlock, x: []const u16, z: []u16) !ProcessResult {
        for (x, 0..) |_, i| {
            z[i] = x[i] * 2;
        }

        return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
    }
};

const TestSink = struct {
    block: Block,
    buf: [200]u16 = undefined,
    count: usize = 0,

    pub fn init() TestSink {
        return .{ .block = Block.init(@This()) };
    }

    pub fn process(self: *TestSink, x: []const u16) !ProcessResult {
        @memcpy(self.buf[self.count .. self.count + x.len], x);
        self.count += x.len;

        return ProcessResult.init(&[1]usize{x.len}, &[0]usize{});
    }
};

const TestSource2 = struct {
    block: Block,

    pub fn init() TestSource2 {
        return .{ .block = Block.init(@This()) };
    }

    pub fn setRate(_: *TestSource2, _: f64) !f64 {
        return 8000;
    }

    pub fn process(_: *TestSource2, z: []u16) !ProcessResult {
        for (z, 0..) |*e, i| {
            e.* = @as(u16, @truncate(i));
        }
        return ProcessResult.init(&[0]usize{}, &[1]usize{z.len});
    }
};

const TestSink2 = struct {
    block: Block,
    count: usize = 0,

    pub fn init() TestSink2 {
        return .{ .block = Block.init(@This()) };
    }

    pub fn process(self: *TestSink2, x: []const u16) !ProcessResult {
        self.count += x.len;
        return ProcessResult.init(&[1]usize{x.len}, &[0]usize{});
    }
};

test "ThreadedBlockRunner finite run" {
    // This test requires spawning threads
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    // Create blocks
    var test_source = TestSource.init();
    var test_block = TestBlock.init();
    var test_sink = TestSink.init();

    // Create ring buffers
    var ring_buffer1 = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer ring_buffer1.deinit();
    var ring_buffer2 = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer ring_buffer2.deinit();

    // Create ring buffer sample muxes
    var test_source_ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux(ThreadSafeRingBuffer).init(std.testing.allocator, &[0]*ThreadSafeRingBuffer{}, &[1]*ThreadSafeRingBuffer{&ring_buffer1});
    defer test_source_ring_buffer_sample_mux.deinit();
    var test_block_ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux(ThreadSafeRingBuffer).init(std.testing.allocator, &[1]*ThreadSafeRingBuffer{&ring_buffer1}, &[1]*ThreadSafeRingBuffer{&ring_buffer2});
    defer test_block_ring_buffer_sample_mux.deinit();
    var test_sink_ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux(ThreadSafeRingBuffer).init(std.testing.allocator, &[1]*ThreadSafeRingBuffer{&ring_buffer2}, &[0]*ThreadSafeRingBuffer{});
    defer test_sink_ring_buffer_sample_mux.deinit();

    // Differentiate blocks
    try test_source.block.differentiate(&[0]RuntimeDataType{}, 8000);
    try test_block.block.differentiate(&[1]RuntimeDataType{RuntimeDataType.Unsigned16}, 8000);
    try test_sink.block.differentiate(&[1]RuntimeDataType{RuntimeDataType.Unsigned16}, 8000);

    // Create block runners
    var test_source_runner = ThreadedBlockRunner.init(&test_source.block, test_source_ring_buffer_sample_mux.sampleMux());
    var test_block_runner = ThreadedBlockRunner.init(&test_block.block, test_block_ring_buffer_sample_mux.sampleMux());
    var test_sink_runner = ThreadedBlockRunner.init(&test_sink.block, test_sink_ring_buffer_sample_mux.sampleMux());

    // Spawn block runners
    try test_source_runner.spawn();
    try test_block_runner.spawn();
    try test_sink_runner.spawn();

    // Join block runners
    test_source_runner.join();
    test_block_runner.join();
    test_sink_runner.join();

    // Check results in test sink
    try std.testing.expectEqual(@as(usize, 100), test_sink.count);
    for (test_sink.buf[0..100], 0..) |e, i| {
        try std.testing.expectEqual(i * 2, e);
    }
}

test "ThreadedBlockRunner infinite run" {
    // This test requires spawning threads
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    // Create blocks
    var test_source = TestSource2.init();
    var test_sink = TestSink2.init();

    // Create ring buffer
    var ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer ring_buffer.deinit();

    // Create ring buffer sample muxes
    var test_source_ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux(ThreadSafeRingBuffer).init(std.testing.allocator, &[0]*ThreadSafeRingBuffer{}, &[1]*ThreadSafeRingBuffer{&ring_buffer});
    defer test_source_ring_buffer_sample_mux.deinit();
    var test_sink_ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux(ThreadSafeRingBuffer).init(std.testing.allocator, &[1]*ThreadSafeRingBuffer{&ring_buffer}, &[0]*ThreadSafeRingBuffer{});
    defer test_sink_ring_buffer_sample_mux.deinit();

    // Differentiate blocks
    try test_source.block.differentiate(&[0]RuntimeDataType{}, 8000);
    try test_sink.block.differentiate(&[1]RuntimeDataType{RuntimeDataType.Unsigned16}, 8000);

    // Create block runners
    var test_source_runner = ThreadedBlockRunner.init(&test_source.block, test_source_ring_buffer_sample_mux.sampleMux());
    var test_sink_runner = ThreadedBlockRunner.init(&test_sink.block, test_sink_ring_buffer_sample_mux.sampleMux());

    // Spawn block runners
    try test_source_runner.spawn();
    try test_sink_runner.spawn();

    // Run for 1ms
    std.time.sleep(std.time.ns_per_ms);

    // Stop source runner
    test_source_runner.stop();

    // Join block runners
    test_source_runner.join();
    test_sink_runner.join();

    // Check results in test sink
    try std.testing.expect(test_sink.count > 0);
}
