const std = @import("std");

const ComptimeTypeSignature = @import("type_signature.zig").ComptimeTypeSignature;
const RuntimeTypeSignature = @import("type_signature.zig").RuntimeTypeSignature;
const RuntimeDataType = @import("type_signature.zig").RuntimeDataType;
const SampleMux = @import("sample_mux.zig").SampleMux;

////////////////////////////////////////////////////////////////////////////////
// Block Errors
////////////////////////////////////////////////////////////////////////////////

pub const BlockError = error{
    TypeSignatureNotFound,
    InputNotFound,
    OutputNotFound,
    NotDifferentiated,
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
// Runtime Differentiation Derivation
////////////////////////////////////////////////////////////////////////////////

pub const RuntimeDifferentiation = struct {
    type_signature: RuntimeTypeSignature,
    set_rate_fn: *const fn (self: *Block, upstream_rate: f64) anyerror!f64,
    initialize_fn: *const fn (self: *Block, allocator: std.mem.Allocator) anyerror!void,
    deinitialize_fn: *const fn (self: *Block, allocator: std.mem.Allocator) void,
    process_fn: *const fn (self: *Block, sample_mux: *SampleMux) anyerror!ProcessResult,

    pub fn derive(comptime block_type: anytype) []const RuntimeDifferentiation {
        const declarations = std.meta.declarations(block_type);

        comptime var _runtime_differentiations: [declarations.len]RuntimeDifferentiation = undefined;
        comptime var count: usize = 0;

        inline for (declarations) |decl| {
            if (comptime std.mem.startsWith(u8, decl.name, "process")) {
                const process_fn = @field(block_type, decl.name);

                const set_rate_fn_name = "setRate";
                const set_rate_fn = if (@hasDecl(block_type, set_rate_fn_name)) @field(block_type, set_rate_fn_name) else null;

                const initialize_fn_name = "initialize" ++ decl.name[7..];
                const initialize_fn = if (@hasDecl(block_type, initialize_fn_name)) @field(block_type, initialize_fn_name) else if (@hasDecl(block_type, "initialize")) @field(block_type, "initialize") else null;

                const deinitialize_fn_name = "deinitialize" ++ decl.name[7..];
                const deinitialize_fn = if (@hasDecl(block_type, deinitialize_fn_name)) @field(block_type, deinitialize_fn_name) else if (@hasDecl(block_type, "deinitialize")) @field(block_type, "deinitialize") else null;

                const type_signature = ComptimeTypeSignature.init(process_fn);

                if (type_signature.inputs.len == 0 and @TypeOf(set_rate_fn) == @TypeOf(null)) {
                    @compileError("Source block " ++ @typeName(block_type) ++ " is missing the setRate() method.");
                }

                _runtime_differentiations[count].type_signature = comptime RuntimeTypeSignature.init(type_signature);
                _runtime_differentiations[count].set_rate_fn = comptime wrapSetRateFunction(block_type, set_rate_fn);
                _runtime_differentiations[count].initialize_fn = comptime wrapInitializeFunction(block_type, initialize_fn);
                _runtime_differentiations[count].deinitialize_fn = comptime wrapDeinitializeFunction(block_type, deinitialize_fn);
                _runtime_differentiations[count].process_fn = comptime wrapProcessFunction(block_type, process_fn, type_signature);

                count += 1;
            }
        }

        if (count == 0) {
            @compileError("Block " ++ @typeName(block_type) ++ " is missing a process() method.");
        }

        const runtime_differentiations = _runtime_differentiations;

        return runtime_differentiations[0..count];
    }
};

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

            // Get buffers, catching read EOF
            const buffers = sample_mux.getBuffers(type_signature.inputs, type_signature.outputs) catch |err| {
                if (err == error.EndOfFile) {
                    sample_mux.setEOF();
                    return ProcessResult.eof();
                } else {
                    return err;
                }
            };

            // Process buffers
            const process_result = try @call(.auto, process_fn, .{self} ++ buffers.inputs ++ buffers.outputs);

            // Update buffers
            sample_mux.updateBuffers(type_signature.inputs, &process_result.samples_consumed, type_signature.outputs, &process_result.samples_produced);

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

////////////////////////////////////////////////////////////////////////////////
// Block
////////////////////////////////////////////////////////////////////////////////

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

pub const Block = struct {
    name: []const u8,
    inputs: []const []const u8,
    outputs: []const []const u8,
    differentiations: []const RuntimeDifferentiation,

    _differentiation: ?*const RuntimeDifferentiation = null,
    _rate: ?f64 = null,

    pub fn init(comptime block_type: type) Block {
        const differentiations = comptime RuntimeDifferentiation.derive(block_type);

        comptime var _inputs: [differentiations[0].type_signature.inputs.len][]const u8 = undefined;
        comptime var _outputs: [differentiations[0].type_signature.outputs.len][]const u8 = undefined;

        inline for (differentiations[0].type_signature.inputs, 0..) |_, i| _inputs[i] = comptime std.fmt.comptimePrint("in{d}", .{i + 1});
        inline for (differentiations[0].type_signature.outputs, 0..) |_, i| _outputs[i] = comptime std.fmt.comptimePrint("out{d}", .{i + 1});

        const inputs = _inputs;
        const outputs = _outputs;

        return .{
            .name = comptime extractBlockName(block_type),
            .inputs = inputs[0..],
            .outputs = outputs[0..],
            .differentiations = differentiations,
        };
    }

    // Primary Block API

    pub fn differentiate(self: *Block, data_types: []const RuntimeDataType, rate: f64) !void {
        for (self.differentiations, 0..) |differentiation, i| {
            if (differentiation.type_signature.inputs.len != data_types.len)
                std.debug.panic("Attempted differentiation with invalid number of input types for block", .{});

            const match = for (data_types, 0..) |_, j| {
                if (data_types[j] != differentiation.type_signature.inputs[j])
                    break false;
            } else true;

            if (match) {
                self._differentiation = &self.differentiations[i];
                self._rate = try self._differentiation.?.set_rate_fn(self, rate);

                return;
            }
        }

        return BlockError.TypeSignatureNotFound;
    }

    pub fn initialize(self: *Block, allocator: std.mem.Allocator) !void {
        try self._differentiation.?.initialize_fn(self, allocator);
    }

    pub fn deinitialize(self: *Block, allocator: std.mem.Allocator) void {
        self._differentiation.?.deinitialize_fn(self, allocator);
    }

    pub fn process(self: *Block, sample_mux: *SampleMux) !ProcessResult {
        return try self._differentiation.?.process_fn(self, sample_mux);
    }

    pub fn getInputType(self: *Block, index: usize) BlockError!RuntimeDataType {
        if (self._differentiation == null) return BlockError.NotDifferentiated;
        if (index >= self._differentiation.?.type_signature.inputs.len) return BlockError.InputNotFound;

        return self._differentiation.?.type_signature.inputs[index];
    }

    pub fn getOutputType(self: *Block, index: usize) BlockError!RuntimeDataType {
        if (self._differentiation == null) return BlockError.NotDifferentiated;
        if (index >= self._differentiation.?.type_signature.outputs.len) return BlockError.OutputNotFound;

        return self._differentiation.?.type_signature.outputs[index];
    }

    pub fn getRate(self: *const Block, comptime T: type) BlockError!T {
        if (self._differentiation == null) return BlockError.NotDifferentiated;

        return std.math.lossyCast(T, self._rate.?);
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
    init_u32_called: bool,
    init_f32_called: bool,

    pub fn init() TestBlock {
        return .{ .block = Block.init(@This()), .init_u32_called = false, .init_f32_called = false };
    }

    pub fn setRate(_: *TestBlock, upstream_rate: f64) !f64 {
        if (upstream_rate < 8000) return error.Unsupported;
        return upstream_rate / 2;
    }

    pub fn initializeUnsigned32(self: *TestBlock, _: std.mem.Allocator) !void {
        self.init_u32_called = true;
    }

    pub fn deinitializeUnsigned32(self: *TestBlock, _: std.mem.Allocator) void {
        self.init_u32_called = false;
    }

    pub fn processUnsigned32(_: *TestBlock, _: []const u32, _: []const u8, _: []u32) !ProcessResult {
        return ProcessResult.init(&[2]usize{ 0, 0 }, &[1]usize{0});
    }

    pub fn initializeFloat32(self: *TestBlock, _: std.mem.Allocator) !void {
        self.init_f32_called = true;
    }

    pub fn deinitializeFloat32(self: *TestBlock, _: std.mem.Allocator) void {
        self.init_f32_called = false;
    }

    pub fn processFloat32(_: *TestBlock, _: []const f32, _: []const u16, _: []f32) !ProcessResult {
        return ProcessResult.init(&[2]usize{ 0, 0 }, &[1]usize{0});
    }

    pub fn initializeUnsigned8(_: *TestBlock, _: std.mem.Allocator) !void {
        return error.Unsupported;
    }

    pub fn processUnsigned8(_: *TestBlock, _: []const u8, _: []const u8, _: []u8) !ProcessResult {
        return ProcessResult.init(&[2]usize{ 0, 0 }, &[1]usize{0});
    }
};

const TestAddBlock = struct {
    block: Block,

    pub fn init() TestAddBlock {
        return .{ .block = Block.init(@This()) };
    }

    pub fn processUnsigned32(_: *TestAddBlock, x: []const u32, y: []const u32, z: []u32) !ProcessResult {
        for (x, 0..) |_, i| {
            z[i] = x[i] + y[i];
        }
        return ProcessResult.init(&[2]usize{ x.len, y.len }, &[1]usize{x.len});
    }

    pub fn processUnsigned8(_: *TestAddBlock, x: []const u8, y: []const u8, z: []u8) !ProcessResult {
        for (x, 0..) |_, i| {
            z[i] = x[i] + y[i];
        }
        return ProcessResult.init(&[2]usize{ x.len, y.len }, &[1]usize{x.len});
    }

    pub fn processUnsigned16(_: *TestAddBlock, _: []const u16, _: []const u16, _: []u16) !ProcessResult {
        return error.Unsupported;
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
    try std.testing.expectEqual(test_block.block.differentiations.len, 3);

    try std.testing.expectEqual(@as(usize, 2), test_block.block.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), test_block.block.outputs.len);

    try std.testing.expectEqualSlices(u8, "in1", test_block.block.inputs[0]);
    try std.testing.expectEqualSlices(u8, "in2", test_block.block.inputs[1]);
    try std.testing.expectEqualSlices(u8, "out1", test_block.block.outputs[0]);

    try std.testing.expectEqualSlices(RuntimeDataType, &[2]RuntimeDataType{ RuntimeDataType.Unsigned32, RuntimeDataType.Unsigned8 }, test_block.block.differentiations[0].type_signature.inputs);
    try std.testing.expectEqualSlices(RuntimeDataType, &[1]RuntimeDataType{RuntimeDataType.Unsigned32}, test_block.block.differentiations[0].type_signature.outputs);

    try std.testing.expectEqualSlices(RuntimeDataType, &[2]RuntimeDataType{ RuntimeDataType.Float32, RuntimeDataType.Unsigned16 }, test_block.block.differentiations[1].type_signature.inputs);
    try std.testing.expectEqualSlices(RuntimeDataType, &[1]RuntimeDataType{RuntimeDataType.Float32}, test_block.block.differentiations[1].type_signature.outputs);

    try std.testing.expectEqualSlices(RuntimeDataType, &[2]RuntimeDataType{ RuntimeDataType.Unsigned8, RuntimeDataType.Unsigned8 }, test_block.block.differentiations[2].type_signature.inputs);
    try std.testing.expectEqualSlices(RuntimeDataType, &[1]RuntimeDataType{RuntimeDataType.Unsigned8}, test_block.block.differentiations[2].type_signature.outputs);
}

test "Block.differentiate" {
    var test_block = TestBlock.init();

    try std.testing.expectError(BlockError.NotDifferentiated, test_block.block.getRate(usize));
    try std.testing.expectError(BlockError.NotDifferentiated, test_block.block.getInputType(0));
    try std.testing.expectError(BlockError.NotDifferentiated, test_block.block.getInputType(1));
    try std.testing.expectError(BlockError.NotDifferentiated, test_block.block.getOutputType(0));

    try test_block.block.differentiate(&[2]RuntimeDataType{ RuntimeDataType.Unsigned32, RuntimeDataType.Unsigned8 }, 8000);
    try std.testing.expectEqual(test_block.block._differentiation, &test_block.block.differentiations[0]);
    try std.testing.expectEqual(RuntimeDataType.Unsigned32, try test_block.block.getInputType(0));
    try std.testing.expectEqual(RuntimeDataType.Unsigned8, try test_block.block.getInputType(1));
    try std.testing.expectEqual(RuntimeDataType.Unsigned32, try test_block.block.getOutputType(0));
    try std.testing.expectEqual(@as(usize, 4000), try test_block.block.getRate(usize));

    try std.testing.expectError(BlockError.InputNotFound, test_block.block.getInputType(2));
    try std.testing.expectError(BlockError.OutputNotFound, test_block.block.getOutputType(1));

    try test_block.block.differentiate(&[2]RuntimeDataType{ RuntimeDataType.Float32, RuntimeDataType.Unsigned16 }, 8000);
    try std.testing.expectEqual(test_block.block._differentiation, &test_block.block.differentiations[1]);
    try std.testing.expectEqual(RuntimeDataType.Float32, try test_block.block.getInputType(0));
    try std.testing.expectEqual(RuntimeDataType.Unsigned16, try test_block.block.getInputType(1));
    try std.testing.expectEqual(RuntimeDataType.Float32, try test_block.block.getOutputType(0));
    try std.testing.expectEqual(@as(usize, 4000), try test_block.block.getRate(usize));

    try std.testing.expectError(BlockError.TypeSignatureNotFound, test_block.block.differentiate(&[2]RuntimeDataType{ RuntimeDataType.Float32, RuntimeDataType.Float32 }, 8000));
    try std.testing.expectError(error.Unsupported, test_block.block.differentiate(&[2]RuntimeDataType{ RuntimeDataType.Unsigned32, RuntimeDataType.Unsigned8 }, 2000));

    var test_source = TestSource.init();

    try std.testing.expectError(BlockError.NotDifferentiated, test_source.block.getRate(usize));
    try std.testing.expectError(BlockError.NotDifferentiated, test_source.block.getOutputType(0));

    try test_source.block.differentiate(&[0]RuntimeDataType{}, 0);
    try std.testing.expectEqual(RuntimeDataType.Unsigned16, try test_source.block.getOutputType(0));
    try std.testing.expectEqual(@as(usize, 8000), try test_source.block.getRate(usize));

    try std.testing.expectError(BlockError.InputNotFound, test_source.block.getInputType(0));
}

test "Block.initialize and Block.deinitialize" {
    var test_block = TestBlock.init();

    try std.testing.expectEqual(false, test_block.init_u32_called);
    try test_block.block.differentiate(&[2]RuntimeDataType{ RuntimeDataType.Unsigned32, RuntimeDataType.Unsigned8 }, 8000);
    try test_block.block.initialize(std.testing.allocator);
    try std.testing.expectEqual(true, test_block.init_u32_called);
    test_block.block.deinitialize(std.testing.allocator);
    try std.testing.expectEqual(false, test_block.init_u32_called);

    try std.testing.expectEqual(false, test_block.init_f32_called);
    try test_block.block.differentiate(&[2]RuntimeDataType{ RuntimeDataType.Float32, RuntimeDataType.Unsigned16 }, 8000);
    try test_block.block.initialize(std.testing.allocator);
    try std.testing.expectEqual(true, test_block.init_f32_called);
    test_block.block.deinitialize(std.testing.allocator);
    try std.testing.expectEqual(false, test_block.init_f32_called);

    try test_block.block.differentiate(&[2]RuntimeDataType{ RuntimeDataType.Unsigned8, RuntimeDataType.Unsigned8 }, 8000);
    try std.testing.expectError(error.Unsupported, test_block.block.initialize(std.testing.allocator));
}

test "Block.process" {
    const ibuf1: [8]u8 = .{ 0x01, 0x02, 0x03, 0x04, 0x10, 0x20, 0x30, 0x40 };
    const ibuf2: [8]u8 = .{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };

    var test_block = TestAddBlock.init();

    // Try u32 differentiation
    {
        var test_sample_mux = try TestSampleMux(2, 1).init([2][]const u8{ ibuf1[0..], ibuf2[0..] }, .{});
        defer test_sample_mux.deinit();
        var sample_mux = test_sample_mux.sampleMux();

        try test_block.block.differentiate(&[2]RuntimeDataType{ RuntimeDataType.Unsigned32, RuntimeDataType.Unsigned32 }, 8000);

        var process_result = try test_block.block.process(&sample_mux);
        try std.testing.expectEqual(@as(usize, 2), process_result.samples_consumed[0]);
        try std.testing.expectEqual(@as(usize, 2), process_result.samples_consumed[1]);
        try std.testing.expectEqual(@as(usize, 2), process_result.samples_produced[0]);
        try std.testing.expectEqualSlices(u32, &[_]u32{ 0x48362412, 0xc8a78665 }, test_sample_mux.getOutputVector(u32, 0));

        process_result = try test_block.block.process(&sample_mux);
        try std.testing.expect(process_result.eof);
    }

    // Try u8 differentiation
    {
        var test_sample_mux = try TestSampleMux(2, 1).init([2][]const u8{ ibuf1[0..], ibuf2[0..] }, .{});
        defer test_sample_mux.deinit();
        var sample_mux = test_sample_mux.sampleMux();

        try test_block.block.differentiate(&[2]RuntimeDataType{ RuntimeDataType.Unsigned8, RuntimeDataType.Unsigned8 }, 8000);

        var process_result = try test_block.block.process(&sample_mux);
        try std.testing.expectEqual(@as(usize, 8), process_result.samples_consumed[0]);
        try std.testing.expectEqual(@as(usize, 8), process_result.samples_consumed[1]);
        try std.testing.expectEqual(@as(usize, 8), process_result.samples_produced[0]);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x24, 0x36, 0x48, 0x65, 0x86, 0xa7, 0xc8 }, test_sample_mux.getOutputVector(u8, 0));

        process_result = try test_block.block.process(&sample_mux);
        try std.testing.expect(process_result.eof);
    }

    // Try u16 differentiation
    {
        var test_sample_mux = try TestSampleMux(2, 1).init([2][]const u8{ ibuf1[0..], ibuf2[0..] }, .{});
        defer test_sample_mux.deinit();
        var sample_mux = test_sample_mux.sampleMux();

        try test_block.block.differentiate(&[2]RuntimeDataType{ RuntimeDataType.Unsigned16, RuntimeDataType.Unsigned16 }, 8000);
        try std.testing.expectError(error.Unsupported, test_block.block.process(&sample_mux));
    }
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
    try test_block.block.differentiate(&[2]RuntimeDataType{ RuntimeDataType.Unsigned32, RuntimeDataType.Unsigned32 }, 8000);

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
    try test_source.block.differentiate(&[0]RuntimeDataType{}, 8000);

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
