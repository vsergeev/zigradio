const std = @import("std");

const ComptimeTypeSignature = @import("type_signature.zig").ComptimeTypeSignature;
const RuntimeTypeSignature = @import("type_signature.zig").RuntimeTypeSignature;
const SampleMux = @import("sample_mux.zig").SampleMux;

////////////////////////////////////////////////////////////////////////////////
// Block Errors
////////////////////////////////////////////////////////////////////////////////

pub const BlockError = error{
    RateNotSet,
};

////////////////////////////////////////////////////////////////////////////////
// Process Result
////////////////////////////////////////////////////////////////////////////////

pub const ProcessResult = struct {
    samples_consumed: [8]usize = [_]usize{0} ** 8,
    samples_produced: [8]usize = [_]usize{0} ** 8,
    eof: bool = false,

    pub fn init(consumed: []const usize, produced: []const usize) ProcessResult {
        var self = ProcessResult{};
        @memcpy(self.samples_consumed[0..consumed.len], consumed);
        @memcpy(self.samples_produced[0..produced.len], produced);
        return self;
    }

    pub fn eof() ProcessResult {
        return ProcessResult{
            .eof = true,
        };
    }
};

////////////////////////////////////////////////////////////////////////////////
// Helper Functions
////////////////////////////////////////////////////////////////////////////////

fn wrapInitializeFunction(comptime block_type: anytype, comptime initialize_fn: anytype) fn (self: *Block, allocator: std.mem.Allocator) anyerror!void {
    if (@TypeOf(initialize_fn) != @TypeOf(null)) {
        const impl = struct {
            fn initialize(block: *Block, allocator: std.mem.Allocator) anyerror!void {
                const self: *block_type = @fieldParentPtr("block", block);

                try initialize_fn(self, allocator);
            }
        };
        return impl.initialize;
    } else {
        const impl = struct {
            fn initialize(block: *Block, allocator: std.mem.Allocator) anyerror!void {
                _ = block;
                _ = allocator;
            }
        };
        return impl.initialize;
    }
}

fn wrapDeinitializeFunction(comptime block_type: anytype, comptime deinitialize_fn: anytype) fn (self: *Block, allocator: std.mem.Allocator) void {
    if (@TypeOf(deinitialize_fn) != @TypeOf(null)) {
        const impl = struct {
            fn deinitialize(block: *Block, allocator: std.mem.Allocator) void {
                const self: *block_type = @fieldParentPtr("block", block);

                deinitialize_fn(self, allocator);
            }
        };
        return impl.deinitialize;
    } else {
        const impl = struct {
            fn deinitialize(block: *Block, allocator: std.mem.Allocator) void {
                _ = block;
                _ = allocator;
            }
        };
        return impl.deinitialize;
    }
}

fn wrapSetRateFunction(comptime block_type: anytype, comptime set_rate_fn: anytype) fn (self: *Block, upstream_rate: f64) anyerror!f64 {
    if (@TypeOf(set_rate_fn) != @TypeOf(null)) {
        const impl = struct {
            fn setRate(block: *Block, upstream_rate: f64) anyerror!f64 {
                const self: *block_type = @fieldParentPtr("block", block);

                return try set_rate_fn(self, upstream_rate);
            }
        };
        return impl.setRate;
    } else {
        const impl = struct {
            fn setRate(block: *Block, upstream_rate: f64) anyerror!f64 {
                _ = block;

                // Default setRate() retains upstream rate
                return upstream_rate;
            }
        };
        return impl.setRate;
    }
}

fn wrapProcessFunction(comptime block_type: anytype, comptime process_fn: anytype, comptime type_signature: ComptimeTypeSignature) fn (self: *Block, sample_mux: *SampleMux) anyerror!ProcessResult {
    const impl = struct {
        fn process(block: *Block, sample_mux: *SampleMux) anyerror!ProcessResult {
            const self: *block_type = @fieldParentPtr("block", block);

            // Get sample buffers, catching read EOF
            const buffers = sample_mux.get(type_signature) catch |err| switch (err) {
                error.EndOfFile => {
                    sample_mux.setEOF();
                    return ProcessResult.eof();
                },
            };

            // Process sample buffers
            const process_result = try @call(.auto, process_fn, .{self} ++ buffers.inputs ++ buffers.outputs);

            // Update sample buffers
            sample_mux.update(type_signature, process_result);

            // If block completed, set write EOF
            if (process_result.eof) {
                sample_mux.setEOF();
            }

            // Return process result
            return process_result;
        }
    };
    return impl.process;
}

pub fn extractBlockName(comptime block_type: type) []const u8 {
    // Split ( for generic blocks
    comptime var it = std.mem.split(u8, @typeName(block_type), "(");
    const first = comptime it.first();
    const suffix = comptime it.rest();
    // Split . backwards for block name
    comptime var it_back = std.mem.splitBackwards(u8, first, ".");
    const prefix = comptime it_back.first();

    // Concatenate prefix and suffix
    return prefix ++ (if (suffix.len > 0) "(" else "") ++ suffix;
}

////////////////////////////////////////////////////////////////////////////////
// Block
////////////////////////////////////////////////////////////////////////////////

pub const Block = struct {
    name: []const u8,
    inputs: []const []const u8,
    outputs: []const []const u8,
    type_signature: RuntimeTypeSignature,
    set_rate_fn: *const fn (self: *Block, upstream_rate: f64) anyerror!f64,
    initialize_fn: *const fn (self: *Block, allocator: std.mem.Allocator) anyerror!void,
    deinitialize_fn: *const fn (self: *Block, allocator: std.mem.Allocator) void,
    process_fn: *const fn (self: *Block, sample_mux: *SampleMux) anyerror!ProcessResult,

    rate: ?f64 = null,

    pub fn init(comptime block_type: type) Block {
        const process_fn = if (@hasDecl(block_type, "process")) @field(block_type, "process") else null;
        const set_rate_fn = if (@hasDecl(block_type, "setRate")) @field(block_type, "setRate") else null;
        const initialize_fn = if (@hasDecl(block_type, "initialize")) @field(block_type, "initialize") else null;
        const deinitialize_fn = if (@hasDecl(block_type, "deinitialize")) @field(block_type, "deinitialize") else null;

        if (@TypeOf(process_fn) == @TypeOf(null)) {
            @compileError("Block " ++ @typeName(block_type) ++ " is missing the process() method.");
        }

        const type_signature = ComptimeTypeSignature.init(process_fn);

        if (type_signature.inputs.len == 0 and @TypeOf(set_rate_fn) == @TypeOf(null)) {
            @compileError("Source block " ++ @typeName(block_type) ++ " is missing the setRate() method.");
        }

        comptime var _inputs: [type_signature.inputs.len][]const u8 = undefined;
        comptime var _outputs: [type_signature.outputs.len][]const u8 = undefined;
        inline for (type_signature.inputs, 0..) |_, i| _inputs[i] = comptime std.fmt.comptimePrint("in{d}", .{i + 1});
        inline for (type_signature.outputs, 0..) |_, i| _outputs[i] = comptime std.fmt.comptimePrint("out{d}", .{i + 1});
        const inputs = _inputs;
        const outputs = _outputs;

        return .{
            .name = comptime extractBlockName(block_type),
            .inputs = inputs[0..],
            .outputs = outputs[0..],
            .type_signature = comptime RuntimeTypeSignature.init(type_signature),
            .set_rate_fn = comptime wrapSetRateFunction(block_type, set_rate_fn),
            .initialize_fn = comptime wrapInitializeFunction(block_type, initialize_fn),
            .deinitialize_fn = comptime wrapDeinitializeFunction(block_type, deinitialize_fn),
            .process_fn = comptime wrapProcessFunction(block_type, process_fn, type_signature),
        };
    }

    // Primary Block API

    pub fn setRate(self: *Block, rate: f64) !void {
        self.rate = try self.set_rate_fn(self, rate);
    }

    pub fn initialize(self: *Block, allocator: std.mem.Allocator) !void {
        try self.initialize_fn(self, allocator);
    }

    pub fn deinitialize(self: *Block, allocator: std.mem.Allocator) void {
        self.deinitialize_fn(self, allocator);
    }

    pub fn process(self: *Block, sample_mux: *SampleMux) !ProcessResult {
        return try self.process_fn(self, sample_mux);
    }

    pub fn getRate(self: *const Block, comptime T: type) BlockError!T {
        if (self.rate == null) return BlockError.RateNotSet;
        return std.math.lossyCast(T, self.rate.?);
    }
};

////////////////////////////////////////////////////////////////////////////////
// Block Tests
////////////////////////////////////////////////////////////////////////////////

const TestSampleMux = @import("sample_mux.zig").TestSampleMux;
const ThreadSafeRingBuffer = @import("ring_buffer.zig").ThreadSafeRingBuffer;
const ThreadSafeRingBufferSampleMux = @import("sample_mux.zig").ThreadSafeRingBufferSampleMux;

const TestBlock = struct {
    block: Block,
    initialize_called: bool,

    pub fn init() TestBlock {
        return .{ .block = Block.init(@This()), .initialize_called = false };
    }

    pub fn setRate(_: *TestBlock, upstream_rate: f64) !f64 {
        if (upstream_rate < 8000) return error.Unsupported;
        return upstream_rate / 2;
    }

    pub fn initialize(self: *TestBlock, _: std.mem.Allocator) !void {
        self.initialize_called = true;
    }

    pub fn deinitialize(self: *TestBlock, _: std.mem.Allocator) void {
        self.initialize_called = false;
    }

    pub fn process(_: *TestBlock, _: []const u32, _: []const u8, _: []u32) !ProcessResult {
        return ProcessResult.init(&[2]usize{ 0, 0 }, &[1]usize{0});
    }
};

const TestAddBlock = struct {
    block: Block,

    pub fn init() TestAddBlock {
        return .{ .block = Block.init(@This()) };
    }

    pub fn process(_: *TestAddBlock, x: []const u32, y: []const u32, z: []u32) !ProcessResult {
        for (x, 0..) |_, i| {
            z[i] = x[i] + y[i];
        }
        return ProcessResult.init(&[2]usize{ x.len, y.len }, &[1]usize{x.len});
    }
};

const TestSource = struct {
    block: Block,
    eof: bool = false,

    pub fn init() TestSource {
        return .{ .block = Block.init(@This()) };
    }

    pub fn setRate(_: *TestSource, _: f64) !f64 {
        return 8000;
    }

    pub fn process(self: *TestSource, z: []u16) !ProcessResult {
        if (self.eof) {
            return ProcessResult.eof();
        }

        z[0] = 0x2222;
        z[1] = 0x3333;
        self.eof = true;
        return ProcessResult.init(&[0]usize{}, &[1]usize{2});
    }
};

test "Block.init" {
    const test_block = TestBlock.init();

    try std.testing.expectEqualSlices(u8, test_block.block.name, "TestBlock");

    try std.testing.expectEqual(@as(usize, 2), test_block.block.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), test_block.block.outputs.len);

    try std.testing.expectEqualSlices(u8, "in1", test_block.block.inputs[0]);
    try std.testing.expectEqualSlices(u8, "in2", test_block.block.inputs[1]);
    try std.testing.expectEqualSlices(u8, "out1", test_block.block.outputs[0]);

    try std.testing.expectEqualStrings("Unsigned32", test_block.block.type_signature.inputs[0]);
    try std.testing.expectEqualStrings("Unsigned8", test_block.block.type_signature.inputs[1]);
    try std.testing.expectEqualStrings("Unsigned32", test_block.block.type_signature.outputs[0]);
}

test "Block.initialize and Block.deinitialize" {
    var test_block = TestBlock.init();

    try std.testing.expectEqual(false, test_block.initialize_called);
    try test_block.block.initialize(std.testing.allocator);
    try std.testing.expectEqual(true, test_block.initialize_called);
    test_block.block.deinitialize(std.testing.allocator);
    try std.testing.expectEqual(false, test_block.initialize_called);
}

test "Block.setRate and Block.getRate" {
    var test_block = TestBlock.init();

    try std.testing.expectError(BlockError.RateNotSet, test_block.block.getRate(u32));
    try std.testing.expectError(error.Unsupported, test_block.block.setRate(4000));

    try test_block.block.setRate(8000);
    try std.testing.expectEqual(4000, try test_block.block.getRate(u32));
}

test "Block.process" {
    const ibuf1: [8]u8 = .{ 0x01, 0x02, 0x03, 0x04, 0x10, 0x20, 0x30, 0x40 };
    const ibuf2: [8]u8 = .{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };

    var test_block = TestAddBlock.init();

    const ts = ComptimeTypeSignature.init(TestAddBlock.process);

    var test_sample_mux = try TestSampleMux(ts.inputs, ts.outputs).init([2][]const u8{ ibuf1[0..], ibuf2[0..] }, .{});
    defer test_sample_mux.deinit();
    var sample_mux = test_sample_mux.sampleMux();

    var process_result = try test_block.block.process(&sample_mux);
    try std.testing.expectEqual(@as(usize, 2), process_result.samples_consumed[0]);
    try std.testing.expectEqual(@as(usize, 2), process_result.samples_consumed[1]);
    try std.testing.expectEqual(@as(usize, 2), process_result.samples_produced[0]);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 0x48362412, 0xc8a78665 }, test_sample_mux.getOutputVector(u32, 0));

    process_result = try test_block.block.process(&sample_mux);
    try std.testing.expect(process_result.eof);
}

test "Block.process read eof" {
    var b: [4]u8 = .{0x00} ** 4;

    var input1_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer input1_ring_buffer.deinit();
    var input2_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer input2_ring_buffer.deinit();
    var output1_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer output1_ring_buffer.deinit();

    // Get ring buffer reader/write interfaces
    var input1_writer = input1_ring_buffer.writer();
    var input2_writer = input2_ring_buffer.writer();
    var output1_reader = output1_ring_buffer.reader();

    // Create ring buffer sample mux
    var ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux(ThreadSafeRingBuffer).init(std.testing.allocator, &[2]*ThreadSafeRingBuffer{ &input1_ring_buffer, &input2_ring_buffer }, &[1]*ThreadSafeRingBuffer{&output1_ring_buffer});
    defer ring_buffer_sample_mux.deinit();
    var sample_mux = ring_buffer_sample_mux.sampleMux();

    // Create block
    var test_block = TestAddBlock.init();

    // Preload buffers
    @memcpy(input1_ring_buffer.impl.memory.buf[0..8], &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x10, 0x20, 0x30, 0x40 });
    @memcpy(input2_ring_buffer.impl.memory.buf[0..8], &[_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 });

    // Load 1 sample
    input1_writer.update(4);
    input2_writer.update(4);

    // Process 1 sample
    var process_result = try test_block.block.process(&sample_mux);
    try std.testing.expectEqual(@as(usize, 1), process_result.samples_consumed[0]);
    try std.testing.expectEqual(@as(usize, 1), process_result.samples_consumed[1]);
    try std.testing.expectEqual(@as(usize, 1), process_result.samples_produced[0]);
    try std.testing.expectEqual(false, process_result.eof);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x24, 0x36, 0x48 }, output1_reader.read(b[0..]));

    // Load 1 sample and set EOF
    input1_writer.update(4);
    input2_writer.update(4);
    input1_writer.setEOF();
    input2_writer.setEOF();

    // Process 1 sample
    process_result = try test_block.block.process(&sample_mux);
    try std.testing.expectEqual(@as(usize, 1), process_result.samples_consumed[0]);
    try std.testing.expectEqual(@as(usize, 1), process_result.samples_consumed[1]);
    try std.testing.expectEqual(@as(usize, 1), process_result.samples_produced[0]);
    try std.testing.expectEqual(false, process_result.eof);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x65, 0x86, 0xa7, 0xc8 }, output1_reader.read(b[0..]));

    // Process now return EOF
    process_result = try test_block.block.process(&sample_mux);
    try std.testing.expectEqual(@as(usize, 0), process_result.samples_consumed[0]);
    try std.testing.expectEqual(@as(usize, 0), process_result.samples_consumed[1]);
    try std.testing.expectEqual(@as(usize, 0), process_result.samples_produced[0]);
    try std.testing.expectEqual(true, process_result.eof);
}

test "Block.process write eof" {
    var b: [2]u8 = .{0x00} ** 2;

    var output1_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer output1_ring_buffer.deinit();

    // Get ring buffer reader/write interfaces
    var output1_reader = output1_ring_buffer.reader();

    // Create ring buffer sample mux
    var ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux(ThreadSafeRingBuffer).init(std.testing.allocator, &[0]*ThreadSafeRingBuffer{}, &[1]*ThreadSafeRingBuffer{&output1_ring_buffer});
    defer ring_buffer_sample_mux.deinit();
    var sample_mux = ring_buffer_sample_mux.sampleMux();

    // Create block
    var test_source = TestSource.init();

    // Process
    var process_result = try test_source.block.process(&sample_mux);
    try std.testing.expectEqual(@as(usize, 0), process_result.samples_consumed[0]);
    try std.testing.expectEqual(@as(usize, 2), process_result.samples_produced[0]);
    try std.testing.expectEqual(false, process_result.eof);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x22, 0x22 }, output1_reader.read(b[0..]));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x33, 0x33 }, output1_reader.read(b[0..]));

    // Process should return EOF
    process_result = try test_source.block.process(&sample_mux);
    try std.testing.expectEqual(@as(usize, 0), process_result.samples_consumed[0]);
    try std.testing.expectEqual(@as(usize, 0), process_result.samples_produced[0]);
    try std.testing.expectEqual(true, process_result.eof);
    try std.testing.expectError(error.EndOfFile, output1_reader.getAvailable());
}
