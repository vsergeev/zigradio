const std = @import("std");

const Block = @import("block.zig").Block;
const SampleMux = @import("sample_mux.zig").SampleMux;

////////////////////////////////////////////////////////////////////////////////
// RawBlockRunner
////////////////////////////////////////////////////////////////////////////////

pub const RawBlockRunner = struct {
    block: *Block,
    sample_mux: SampleMux,

    running: bool = false,

    pub fn init(_: std.mem.Allocator, block: *Block, sample_mux: SampleMux) !RawBlockRunner {
        return .{
            .block = block,
            .sample_mux = sample_mux,
        };
    }

    pub fn deinit(self: *RawBlockRunner) void {
        if (self.running) {
            self.stop();
            self.join();
        }
    }

    pub fn spawn(self: *RawBlockRunner) !void {
        try self.block.start(self.sample_mux);
        self.running = true;
    }

    pub fn call(self: *RawBlockRunner, comptime function: anytype, args: anytype) @typeInfo(@TypeOf(function)).Fn.return_type.? {
        const block = @as(@typeInfo(@TypeOf(function)).Fn.params[0].type.?, @fieldParentPtr("block", self.block));
        return @call(.auto, function, .{block} ++ args);
    }

    pub fn stop(self: *RawBlockRunner) void {
        self.block.stop();
    }

    pub fn join(self: *RawBlockRunner) void {
        self.running = false;
    }

    pub fn getError(_: *const RawBlockRunner) ?anyerror {
        return null;
    }
};

////////////////////////////////////////////////////////////////////////////////
// ThreadedBlockRunner
////////////////////////////////////////////////////////////////////////////////

pub const ThreadedBlockRunner = struct {
    block: *Block,
    sample_mux: SampleMux,

    running: bool = false,
    process_error: ?anyerror = null,

    thread: std.Thread = undefined,
    mutex: std.Thread.Mutex = .{},
    call_event: std.Thread.ResetEvent = .{},
    stop_event: std.Thread.ResetEvent = .{},

    pub fn init(_: std.mem.Allocator, block: *Block, sample_mux: SampleMux) !ThreadedBlockRunner {
        return .{
            .block = block,
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
            fn run(runner: *ThreadedBlockRunner) !void {
                while (true) {
                    if (runner.stop_event.isSet()) {
                        break;
                    } else if (runner.call_event.isSet()) {
                        // Give calling thread a chance to lock the mutex
                        std.time.sleep(std.time.ns_per_us);
                    }

                    runner.mutex.lock();
                    defer runner.mutex.unlock();

                    const process_result = runner.block.process(runner.sample_mux) catch |err| switch (err) {
                        error.EndOfStream => break,
                        else => {
                            runner.process_error = err;
                            break;
                        },
                    };
                    if (process_result.eos) {
                        break;
                    }
                }

                runner.sample_mux.setEOS();
            }
        };

        self.thread = try std.Thread.spawn(.{}, Runner.run, .{self});
        self.running = true;
    }

    pub fn call(self: *ThreadedBlockRunner, comptime function: anytype, args: anytype) @typeInfo(@TypeOf(function)).Fn.return_type.? {
        self.call_event.set();
        self.mutex.lock();
        defer self.mutex.unlock();
        defer self.call_event.reset();

        const block = @as(@typeInfo(@TypeOf(function)).Fn.params[0].type.?, @fieldParentPtr("block", self.block));
        return @call(.auto, function, .{block} ++ args);
    }

    pub fn stop(self: *ThreadedBlockRunner) void {
        self.stop_event.set();
    }

    pub fn join(self: *ThreadedBlockRunner) void {
        self.thread.join();
        self.running = false;
    }

    pub fn getError(self: *const ThreadedBlockRunner) ?anyerror {
        return self.process_error;
    }
};

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const builtin = @import("builtin");

const ProcessResult = @import("block.zig").ProcessResult;
const RuntimeDataType = @import("types.zig").RuntimeDataType;

const ThreadSafeRingBuffer = @import("ring_buffer.zig").ThreadSafeRingBuffer;
const ThreadSafeRingBufferSampleMux = @import("sample_mux.zig").ThreadSafeRingBufferSampleMux;

const TestRawBlock = struct {
    block: Block,

    started: bool = false,
    stopped: bool = false,

    pub fn init() TestRawBlock {
        return .{ .block = Block.initRaw(@This(), &[1]type{f32}, &[1]type{f32}) };
    }

    pub fn start(self: *TestRawBlock, _: SampleMux) !void {
        self.started = true;
    }

    pub fn stop(self: *TestRawBlock) void {
        self.stopped = true;
    }
};

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
            return ProcessResult.eos();
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

const TestErrorSink = struct {
    block: Block,
    count: usize = 0,

    pub fn init() TestErrorSink {
        return .{ .block = Block.init(@This()) };
    }

    pub fn process(self: *TestErrorSink, x: []const u16) !ProcessResult {
        if (self.count == 25) {
            return error.Unexpected;
        }

        self.count += 1;

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

const TestSource3 = struct {
    block: Block,

    pub fn init() TestSource3 {
        return .{ .block = Block.init(@This()) };
    }

    pub fn setRate(_: *TestSource3, _: f64) !f64 {
        return 8000;
    }

    pub fn process(_: *TestSource3, z: []f32) !ProcessResult {
        return ProcessResult.init(&[0]usize{}, &[1]usize{@min(1024, z.len)});
    }
};

const TestCallableBlock = struct {
    block: Block,
    foo: usize,

    pub fn init() TestCallableBlock {
        return .{ .block = Block.init(@This()), .foo = 123 };
    }

    pub fn setFoo(self: *TestCallableBlock, value: usize) !void {
        if (value == 234) return error.Unsupported;
        self.foo = value;
    }

    pub fn resetFoo(self: *TestCallableBlock) void {
        self.foo = 123;
    }

    pub fn getFoo(self: *TestCallableBlock) usize {
        return self.foo;
    }

    pub fn process(_: *TestCallableBlock, x: []const f32, _: []f32) !ProcessResult {
        return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
    }
};

test "TestRawBlock start, stop" {
    // Create block
    var test_block = TestRawBlock.init();

    // Create dummy sample mux
    var test_block_sample_mux = try ThreadSafeRingBufferSampleMux.init(std.testing.allocator, &[0]*ThreadSafeRingBuffer{}, &[0]*ThreadSafeRingBuffer{});
    defer test_block_sample_mux.deinit();

    // Set rates
    try test_block.block.setRate(8000);

    // Create block runners
    var test_block_runner = try RawBlockRunner.init(std.testing.allocator, &test_block.block, test_block_sample_mux.sampleMux());
    defer test_block_runner.deinit();

    try std.testing.expectEqual(false, test_block.started);
    try std.testing.expectEqual(false, test_block.stopped);

    // Start block runner
    try test_block_runner.spawn();
    try std.testing.expectEqual(true, test_block.started);

    // Stop block runner
    test_block_runner.stop();
    try std.testing.expectEqual(true, test_block.stopped);

    // Join block runner
    test_block_runner.join();
}

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

    // Create sample muxes
    var test_source_sample_mux = try ThreadSafeRingBufferSampleMux.init(std.testing.allocator, &[0]*ThreadSafeRingBuffer{}, &[1]*ThreadSafeRingBuffer{&ring_buffer1});
    defer test_source_sample_mux.deinit();
    var test_block_sample_mux = try ThreadSafeRingBufferSampleMux.init(std.testing.allocator, &[1]*ThreadSafeRingBuffer{&ring_buffer1}, &[1]*ThreadSafeRingBuffer{&ring_buffer2});
    defer test_block_sample_mux.deinit();
    var test_sink_sample_mux = try ThreadSafeRingBufferSampleMux.init(std.testing.allocator, &[1]*ThreadSafeRingBuffer{&ring_buffer2}, &[0]*ThreadSafeRingBuffer{});
    defer test_sink_sample_mux.deinit();

    // Set rates
    try test_source.block.setRate(8000);
    try test_block.block.setRate(8000);
    try test_sink.block.setRate(8000);

    // Create block runners
    var test_source_runner = try ThreadedBlockRunner.init(std.testing.allocator, &test_source.block, test_source_sample_mux.sampleMux());
    defer test_source_runner.deinit();
    var test_block_runner = try ThreadedBlockRunner.init(std.testing.allocator, &test_block.block, test_block_sample_mux.sampleMux());
    defer test_block_runner.deinit();
    var test_sink_runner = try ThreadedBlockRunner.init(std.testing.allocator, &test_sink.block, test_sink_sample_mux.sampleMux());
    defer test_sink_runner.deinit();

    // Spawn block runners
    try test_source_runner.spawn();
    try test_block_runner.spawn();
    try test_sink_runner.spawn();

    // Join block runners
    test_source_runner.join();
    test_block_runner.join();
    test_sink_runner.join();

    // Check errors
    try std.testing.expect(test_source_runner.getError() == null);
    try std.testing.expect(test_block_runner.getError() == null);
    try std.testing.expect(test_sink_runner.getError() == null);

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

    // Create sample muxes
    var test_source_sample_mux = try ThreadSafeRingBufferSampleMux.init(std.testing.allocator, &[0]*ThreadSafeRingBuffer{}, &[1]*ThreadSafeRingBuffer{&ring_buffer});
    defer test_source_sample_mux.deinit();
    var test_sink_sample_mux = try ThreadSafeRingBufferSampleMux.init(std.testing.allocator, &[1]*ThreadSafeRingBuffer{&ring_buffer}, &[0]*ThreadSafeRingBuffer{});
    defer test_sink_sample_mux.deinit();

    // Set rates
    try test_source.block.setRate(8000);
    try test_sink.block.setRate(8000);

    // Create block runners
    var test_source_runner = try ThreadedBlockRunner.init(std.testing.allocator, &test_source.block, test_source_sample_mux.sampleMux());
    defer test_source_runner.deinit();
    var test_sink_runner = try ThreadedBlockRunner.init(std.testing.allocator, &test_sink.block, test_sink_sample_mux.sampleMux());
    defer test_sink_runner.deinit();

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

    // Check errors
    try std.testing.expect(test_source_runner.getError() == null);
    try std.testing.expect(test_sink_runner.getError() == null);

    // Check results in test sink
    try std.testing.expect(test_sink.count > 0);
}

test "ThreadedBlockRunner block errors" {
    // This test requires spawning threads
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    // Create blocks
    var test_source = TestSource2.init();
    var test_sink = TestErrorSink.init();

    // Create ring buffer
    var ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer ring_buffer.deinit();

    // Create sample muxes
    var test_source_sample_mux = try ThreadSafeRingBufferSampleMux.init(std.testing.allocator, &[0]*ThreadSafeRingBuffer{}, &[1]*ThreadSafeRingBuffer{&ring_buffer});
    defer test_source_sample_mux.deinit();
    var test_sink_sample_mux = try ThreadSafeRingBufferSampleMux.init(std.testing.allocator, &[1]*ThreadSafeRingBuffer{&ring_buffer}, &[0]*ThreadSafeRingBuffer{});
    defer test_sink_sample_mux.deinit();

    // Set rates
    try test_source.block.setRate(8000);
    try test_sink.block.setRate(8000);

    // Create block runners
    var test_source_runner = try ThreadedBlockRunner.init(std.testing.allocator, &test_source.block, test_source_sample_mux.sampleMux());
    defer test_source_runner.deinit();
    var test_sink_runner = try ThreadedBlockRunner.init(std.testing.allocator, &test_sink.block, test_sink_sample_mux.sampleMux());
    defer test_sink_runner.deinit();

    // Spawn block runners
    try test_source_runner.spawn();
    try test_sink_runner.spawn();

    // Run for 1ms
    std.time.sleep(std.time.ns_per_ms);

    // Join block runners
    test_source_runner.join();
    test_sink_runner.join();

    // Check errors
    try std.testing.expect(test_source_runner.getError() != null);
    try std.testing.expect(test_sink_runner.getError() != null);
    try std.testing.expectEqual(error.BrokenStream, test_source_runner.getError().?);
    try std.testing.expectEqual(error.Unexpected, test_sink_runner.getError().?);
}

test "ThreadedBlockRunner call" {
    // This test requires spawning threads
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    // Create blocks
    var test_source = TestSource3.init();
    var test_block = TestCallableBlock.init();

    // Create ring buffer
    var ring_buffer1 = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer ring_buffer1.deinit();
    var ring_buffer2 = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer ring_buffer2.deinit();

    // Create sample muxes
    var test_source_sample_mux = try ThreadSafeRingBufferSampleMux.init(std.testing.allocator, &[0]*ThreadSafeRingBuffer{}, &[1]*ThreadSafeRingBuffer{&ring_buffer1});
    defer test_source_sample_mux.deinit();
    var test_sink_sample_mux = try ThreadSafeRingBufferSampleMux.init(std.testing.allocator, &[1]*ThreadSafeRingBuffer{&ring_buffer1}, &[1]*ThreadSafeRingBuffer{&ring_buffer2});
    defer test_sink_sample_mux.deinit();

    // Set rates
    try test_block.block.setRate(800);

    // Create block runners
    var test_source_runner = try ThreadedBlockRunner.init(std.testing.allocator, &test_source.block, test_source_sample_mux.sampleMux());
    defer test_source_runner.deinit();
    var test_block_runner = try ThreadedBlockRunner.init(std.testing.allocator, &test_block.block, test_sink_sample_mux.sampleMux());
    defer test_block_runner.deinit();

    // Spawn block runners
    try test_source_runner.spawn();
    try test_block_runner.spawn();

    // Call block
    try std.testing.expectEqual(@as(usize, 123), test_block_runner.call(TestCallableBlock.getFoo, .{}));
    try test_block_runner.call(TestCallableBlock.setFoo, .{456});
    try std.testing.expectEqual(@as(usize, 456), test_block_runner.call(TestCallableBlock.getFoo, .{}));
    test_block_runner.call(TestCallableBlock.resetFoo, .{});
    try std.testing.expectEqual(@as(usize, 123), test_block_runner.call(TestCallableBlock.getFoo, .{}));
    try std.testing.expectError(error.Unsupported, test_block_runner.call(TestCallableBlock.setFoo, .{234}));

    // Stop source runner
    test_source_runner.stop();

    // Join block runners
    test_source_runner.join();
    test_block_runner.join();
}
