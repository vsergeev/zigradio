const std = @import("std");

const ComptimeTypeSignature = @import("type_signature.zig").ComptimeTypeSignature;
const RuntimeTypeSignature = @import("type_signature.zig").RuntimeTypeSignature;
const RuntimeDataType = @import("type_signature.zig").RuntimeDataType;

const SampleMux = @import("sample_mux.zig").SampleMux;
const TestSampleMux = @import("sample_mux.zig").TestSampleMux;
const ThreadSafeRingBuffer = @import("ring_buffer.zig").ThreadSafeRingBuffer;
const RingBufferSampleMux = @import("sample_mux.zig").RingBufferSampleMux;

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
        std.mem.copy(usize, &self.samples_consumed, consumed[0..]);
        std.mem.copy(usize, &self.samples_produced, produced[0..]);
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
    initialize_fn: *const fn (self: *Block) anyerror!void,
    process_fn: *const fn (self: *Block, sample_mux: *SampleMux) anyerror!ProcessResult,

    pub fn derive(comptime block_type: anytype) []RuntimeDifferentiation {
        comptime var declarations = std.meta.declarations(block_type);

        comptime var runtime_differentiations: [declarations.len]RuntimeDifferentiation = undefined;
        comptime var count: usize = 0;

        inline for (declarations) |decl| {
            if (comptime std.mem.startsWith(u8, decl.name, "process")) {
                comptime var process_fn = @field(block_type, decl.name);

                comptime var set_rate_fn_name = "setRate";
                comptime var set_rate_fn = if (@hasDecl(block_type, set_rate_fn_name)) @field(block_type, set_rate_fn_name) else null;

                comptime var initialize_fn_name = "initialize" ++ decl.name[7..];
                comptime var initialize_fn = if (@hasDecl(block_type, initialize_fn_name)) @field(block_type, initialize_fn_name) else if (@hasDecl(block_type, "initialize")) @field(block_type, "initialize") else null;

                const type_signature = ComptimeTypeSignature.init(process_fn);
                runtime_differentiations[count].type_signature = comptime RuntimeTypeSignature.init(type_signature);
                runtime_differentiations[count].set_rate_fn = wrapSetRateFunction(block_type, set_rate_fn);
                runtime_differentiations[count].initialize_fn = wrapInitializeFunction(block_type, initialize_fn);
                runtime_differentiations[count].process_fn = wrapProcessFunction(block_type, process_fn, type_signature);

                count += 1;
            }
        }

        return runtime_differentiations[0..count];
    }
};

fn wrapInitializeFunction(comptime block_type: anytype, comptime initialize_fn: anytype) fn (self: *Block) anyerror!void {
    if (@TypeOf(initialize_fn) != @TypeOf(null)) {
        const impl = struct {
            fn initialize(block: *Block) anyerror!void {
                const self = @fieldParentPtr(block_type, "block", block);

                try initialize_fn(self);
            }
        };
        return impl.initialize;
    } else {
        const impl = struct {
            fn initialize(block: *Block) anyerror!void {
                _ = block;
            }
        };
        return impl.initialize;
    }
}

fn wrapSetRateFunction(comptime block_type: anytype, comptime set_rate_fn: anytype) fn (self: *Block, upstream_rate: f64) anyerror!f64 {
    if (@TypeOf(set_rate_fn) != @TypeOf(null)) {
        const impl = struct {
            fn setRate(block: *Block, upstream_rate: f64) anyerror!f64 {
                const self = @fieldParentPtr(block_type, "block", block);

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

fn wrapProcessFunction(comptime derived_type: anytype, comptime process_fn: anytype, comptime type_signature: ComptimeTypeSignature) fn (self: *Block, sample_mux: *SampleMux) anyerror!ProcessResult {
    const impl = struct {
        fn process(block: *Block, sample_mux: *SampleMux) anyerror!ProcessResult {
            const self = @fieldParentPtr(derived_type, "block", block);

            // Get buffers, catching read EOF
            const buffers = sample_mux.getBuffers(type_signature.getInputTypes(), type_signature.getOutputTypes()) catch |err| {
                if (err == error.EndOfFile) {
                    sample_mux.setEOF();
                    return ProcessResult.eof();
                } else {
                    return err;
                }
            };

            // Process buffers
            const process_result = try @call(.{}, process_fn, .{self} ++ buffers.inputs ++ buffers.outputs);

            // Update buffers
            sample_mux.updateBuffers(type_signature.getInputTypes(), &process_result.samples_consumed, type_signature.getOutputTypes(), &process_result.samples_produced);

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

pub const Block = struct {
    name: []const u8,
    differentiations: []const RuntimeDifferentiation,
    _differentiation: ?*const RuntimeDifferentiation = null,
    _rate: ?f64 = null,

    pub fn init(comptime block_type: type) Block {
        // Split full name (may include parent packages), until we get the type
        var it = std.mem.split(u8, @typeName(block_type), ".");
        var name: []const u8 = "";
        while (it.next()) |val| {
            name = val;
        }

        return Block{
            .name = name,
            .differentiations = RuntimeDifferentiation.derive(block_type),
        };
    }

    // Primary Block API

    pub fn differentiate(self: *Block, data_types: []const RuntimeDataType, rate: f64) !void {
        for (self.differentiations) |differentiation, i| {
            if (differentiation.type_signature.inputs.len != data_types.len)
                std.debug.panic("Attempted differentiation with invalid number of input types for block", .{});

            const match = for (data_types) |_, j| {
                if (data_types[j] != differentiation.type_signature.inputs[j].data_type)
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

    pub fn initialize(self: *Block) !void {
        try self._differentiation.?.initialize_fn(self);
    }

    pub fn process(self: *Block, sample_mux: *SampleMux) !ProcessResult {
        return try self._differentiation.?.process_fn(self, sample_mux);
    }

    // Getters

    pub fn getRate(self: *Block, comptime T: type) BlockError!T {
        if (self._differentiation == null) return BlockError.NotDifferentiated;
        return std.math.lossyCast(T, self._rate.?);
    }

    pub fn getNumInputs(self: *Block) usize {
        return self.differentiations[0].type_signature.inputs.len;
    }

    pub fn getInputIndex(self: *Block, name: []const u8) BlockError!usize {
        for (self.differentiations[0].type_signature.inputs) |input, index| {
            if (std.mem.eql(u8, input.name[0..], name[0..])) {
                return index;
            }
        }
        return BlockError.InputNotFound;
    }

    pub fn getInputName(self: *Block, index: usize) BlockError![]const u8 {
        if (self._differentiation == null) return BlockError.NotDifferentiated;
        if (index >= self._differentiation.?.type_signature.inputs.len) return BlockError.InputNotFound;

        return self._differentiation.?.type_signature.inputs[index].name;
    }

    pub fn getInputType(self: *Block, index: usize) BlockError!RuntimeDataType {
        if (self._differentiation == null) return BlockError.NotDifferentiated;
        if (index >= self._differentiation.?.type_signature.inputs.len) return BlockError.InputNotFound;

        return self._differentiation.?.type_signature.inputs[index].data_type;
    }

    pub fn getNumOutputs(self: *Block) usize {
        return self.differentiations[0].type_signature.outputs.len;
    }

    pub fn getOutputIndex(self: *Block, name: []const u8) BlockError!usize {
        for (self.differentiations[0].type_signature.outputs) |output, index| {
            if (std.mem.eql(u8, output.name[0..], name[0..])) {
                return index;
            }
        }
        return BlockError.OutputNotFound;
    }

    pub fn getOutputName(self: *Block, index: usize) BlockError![]const u8 {
        if (self._differentiation == null) return BlockError.NotDifferentiated;
        if (index >= self._differentiation.?.type_signature.outputs.len) return BlockError.OutputNotFound;

        return self._differentiation.?.type_signature.outputs[index].name;
    }

    pub fn getOutputType(self: *Block, index: usize) BlockError!RuntimeDataType {
        if (self._differentiation == null) return BlockError.NotDifferentiated;
        if (index >= self._differentiation.?.type_signature.outputs.len) return BlockError.OutputNotFound;

        return self._differentiation.?.type_signature.outputs[index].data_type;
    }
};

////////////////////////////////////////////////////////////////////////////////
// Block Tests
////////////////////////////////////////////////////////////////////////////////

const RuntimeInput = @import("type_signature.zig").RuntimeInput;
const RuntimeOutput = @import("type_signature.zig").RuntimeOutput;

fn expectEqualPorts(comptime T: type, expected: []const T, actual: []const T) anyerror!void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected) |exp, i| {
        try std.testing.expectEqualSlices(u8, exp.name, actual[i].name);
        try std.testing.expectEqual(exp.data_type, actual[i].data_type);
    }
}

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

    pub fn initializeUnsigned32(self: *TestBlock) !void {
        self.init_u32_called = true;
    }

    pub fn processUnsigned32(_: *TestBlock, _: []const u32, _: []const u8, _: []u32) !ProcessResult {
        return ProcessResult.init(&[2]usize{ 0, 0 }, &[1]usize{0});
    }

    pub fn initializeFloat32(self: *TestBlock) !void {
        self.init_f32_called = true;
    }

    pub fn processFloat32(_: *TestBlock, _: []const f32, _: []const u16, _: []f32) !ProcessResult {
        return ProcessResult.init(&[2]usize{ 0, 0 }, &[1]usize{0});
    }

    pub fn initializeUnsigned8(_: *TestBlock) !void {
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
        for (x) |_, i| {
            z[i] = x[i] + y[i];
        }
        return ProcessResult.init(&[2]usize{ x.len, y.len }, &[1]usize{x.len});
    }

    pub fn processUnsigned8(_: *TestAddBlock, x: []const u8, y: []const u8, z: []u8) !ProcessResult {
        for (x) |_, i| {
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
    var test_block = TestBlock.init();

    try std.testing.expectEqualSlices(u8, test_block.block.name, "TestBlock");
    try std.testing.expectEqual(test_block.block.differentiations.len, 3);

    try expectEqualPorts(RuntimeInput, &[2]RuntimeInput{ RuntimeInput{ .name = "in1", .data_type = RuntimeDataType.Unsigned32 }, RuntimeInput{ .name = "in2", .data_type = RuntimeDataType.Unsigned8 } }, test_block.block.differentiations[0].type_signature.inputs);
    try expectEqualPorts(RuntimeOutput, &[1]RuntimeOutput{RuntimeOutput{ .name = "out1", .data_type = RuntimeDataType.Unsigned32 }}, test_block.block.differentiations[0].type_signature.outputs);

    try expectEqualPorts(RuntimeInput, &[2]RuntimeInput{ RuntimeInput{ .name = "in1", .data_type = RuntimeDataType.Float32 }, RuntimeInput{ .name = "in2", .data_type = RuntimeDataType.Unsigned16 } }, test_block.block.differentiations[1].type_signature.inputs);
    try expectEqualPorts(RuntimeOutput, &[1]RuntimeOutput{RuntimeOutput{ .name = "out1", .data_type = RuntimeDataType.Float32 }}, test_block.block.differentiations[1].type_signature.outputs);

    try expectEqualPorts(RuntimeInput, &[2]RuntimeInput{ RuntimeInput{ .name = "in1", .data_type = RuntimeDataType.Unsigned8 }, RuntimeInput{ .name = "in2", .data_type = RuntimeDataType.Unsigned8 } }, test_block.block.differentiations[2].type_signature.inputs);
    try expectEqualPorts(RuntimeOutput, &[1]RuntimeOutput{RuntimeOutput{ .name = "out1", .data_type = RuntimeDataType.Unsigned8 }}, test_block.block.differentiations[2].type_signature.outputs);
}

test "Block getters" {
    var test_block = TestBlock.init();
    try std.testing.expectEqual(@as(usize, 2), test_block.block.getNumInputs());
    try std.testing.expectEqual(@as(usize, 1), test_block.block.getNumOutputs());
    try std.testing.expectEqual(@as(usize, 0), try test_block.block.getInputIndex("in1"));
    try std.testing.expectEqual(@as(usize, 1), try test_block.block.getInputIndex("in2"));
    try std.testing.expectEqual(@as(usize, 0), try test_block.block.getOutputIndex("out1"));
    try std.testing.expectError(BlockError.InputNotFound, test_block.block.getInputIndex("out1"));
    try std.testing.expectError(BlockError.InputNotFound, test_block.block.getInputIndex("in3"));
    try std.testing.expectError(BlockError.OutputNotFound, test_block.block.getOutputIndex("in1"));
    try std.testing.expectError(BlockError.OutputNotFound, test_block.block.getOutputIndex("out2"));

    try std.testing.expectError(BlockError.NotDifferentiated, test_block.block.getInputName(0));
    try std.testing.expectError(BlockError.NotDifferentiated, test_block.block.getInputType(0));
    try std.testing.expectError(BlockError.NotDifferentiated, test_block.block.getOutputName(0));
    try std.testing.expectError(BlockError.NotDifferentiated, test_block.block.getOutputType(0));
    try std.testing.expectError(BlockError.NotDifferentiated, test_block.block.getRate(usize));

    try test_block.block.differentiate(&[2]RuntimeDataType{ RuntimeDataType.Unsigned32, RuntimeDataType.Unsigned8 }, 8000);
    try std.testing.expectEqualSlices(u8, "in1", try test_block.block.getInputName(0));
    try std.testing.expectEqual(RuntimeDataType.Unsigned32, try test_block.block.getInputType(0));
    try std.testing.expectEqualSlices(u8, "in2", try test_block.block.getInputName(1));
    try std.testing.expectEqual(RuntimeDataType.Unsigned8, try test_block.block.getInputType(1));
    try std.testing.expectEqualSlices(u8, "out1", try test_block.block.getOutputName(0));
    try std.testing.expectEqual(RuntimeDataType.Unsigned32, try test_block.block.getOutputType(0));
    try std.testing.expectEqual(@as(usize, 4000), try test_block.block.getRate(usize));

    try test_block.block.differentiate(&[2]RuntimeDataType{ RuntimeDataType.Float32, RuntimeDataType.Unsigned16 }, 8000);
    try std.testing.expectEqualSlices(u8, "in1", try test_block.block.getInputName(0));
    try std.testing.expectEqual(RuntimeDataType.Float32, try test_block.block.getInputType(0));
    try std.testing.expectEqualSlices(u8, "in2", try test_block.block.getInputName(1));
    try std.testing.expectEqual(RuntimeDataType.Unsigned16, try test_block.block.getInputType(1));
    try std.testing.expectEqualSlices(u8, "out1", try test_block.block.getOutputName(0));
    try std.testing.expectEqual(RuntimeDataType.Float32, try test_block.block.getOutputType(0));
    try std.testing.expectEqual(@as(usize, 4000), try test_block.block.getRate(usize));

    try std.testing.expectError(BlockError.InputNotFound, test_block.block.getInputName(2));
    try std.testing.expectError(BlockError.InputNotFound, test_block.block.getInputType(2));
    try std.testing.expectError(BlockError.OutputNotFound, test_block.block.getOutputName(1));
    try std.testing.expectError(BlockError.OutputNotFound, test_block.block.getOutputType(1));

    var test_source = TestSource.init();
    try std.testing.expectEqual(@as(usize, 0), test_source.block.getNumInputs());
    try std.testing.expectEqual(@as(usize, 1), test_source.block.getNumOutputs());
    try std.testing.expectEqual(@as(usize, 0), try test_source.block.getOutputIndex("out1"));
    try std.testing.expectError(BlockError.InputNotFound, test_source.block.getInputIndex("in1"));
    try std.testing.expectError(BlockError.OutputNotFound, test_source.block.getOutputIndex("in1"));
    try std.testing.expectError(BlockError.OutputNotFound, test_source.block.getOutputIndex("out2"));

    try test_source.block.differentiate(&[0]RuntimeDataType{}, 0);
    try std.testing.expectEqualSlices(u8, "out1", try test_block.block.getOutputName(0));
    try std.testing.expectEqual(RuntimeDataType.Unsigned16, try test_source.block.getOutputType(0));
    try std.testing.expectError(BlockError.InputNotFound, test_source.block.getInputName(0));
    try std.testing.expectError(BlockError.InputNotFound, test_source.block.getInputType(0));
    try std.testing.expectError(BlockError.OutputNotFound, test_source.block.getOutputName(1));
    try std.testing.expectError(BlockError.OutputNotFound, test_source.block.getOutputType(1));
    try std.testing.expectEqual(@as(usize, 8000), try test_source.block.getRate(usize));
}

test "Block.differentiate" {
    var test_block = TestBlock.init();

    try test_block.block.differentiate(&[2]RuntimeDataType{ RuntimeDataType.Unsigned32, RuntimeDataType.Unsigned8 }, 8000);
    try std.testing.expectEqual(test_block.block._differentiation, &test_block.block.differentiations[0]);

    try test_block.block.differentiate(&[2]RuntimeDataType{ RuntimeDataType.Float32, RuntimeDataType.Unsigned16 }, 8000);
    try std.testing.expectEqual(test_block.block._differentiation, &test_block.block.differentiations[1]);

    try std.testing.expectError(BlockError.TypeSignatureNotFound, test_block.block.differentiate(&[2]RuntimeDataType{ RuntimeDataType.Float32, RuntimeDataType.Float32 }, 8000));
    try std.testing.expectError(error.Unsupported, test_block.block.differentiate(&[2]RuntimeDataType{ RuntimeDataType.Unsigned32, RuntimeDataType.Unsigned8 }, 2000));
}

test "Block.initialize" {
    var test_block = TestBlock.init();

    try std.testing.expectEqual(false, test_block.init_u32_called);
    try test_block.block.differentiate(&[2]RuntimeDataType{ RuntimeDataType.Unsigned32, RuntimeDataType.Unsigned8 }, 8000);
    try test_block.block.initialize();
    try std.testing.expectEqual(true, test_block.init_u32_called);

    try std.testing.expectEqual(false, test_block.init_f32_called);
    try test_block.block.differentiate(&[2]RuntimeDataType{ RuntimeDataType.Float32, RuntimeDataType.Unsigned16 }, 8000);
    try test_block.block.initialize();
    try std.testing.expectEqual(true, test_block.init_f32_called);

    try test_block.block.differentiate(&[2]RuntimeDataType{ RuntimeDataType.Unsigned8, RuntimeDataType.Unsigned8 }, 8000);
    try std.testing.expectError(error.Unsupported, test_block.block.initialize());
}

test "Block.process" {
    const ibuf1: [8]u8 = .{ 0x01, 0x02, 0x03, 0x04, 0x10, 0x20, 0x30, 0x40 };
    const ibuf2: [8]u8 = .{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };

    var test_block = TestAddBlock.init();

    // Try u32 differentiation
    {
        var test_sample_mux = try TestSampleMux(2, 1).init([2][]const u8{ ibuf1[0..], ibuf2[0..] }, false);
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
        var test_sample_mux = try TestSampleMux(2, 1).init([2][]const u8{ ibuf1[0..], ibuf2[0..] }, false);
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
        var test_sample_mux = try TestSampleMux(2, 1).init([2][]const u8{ ibuf1[0..], ibuf2[0..] }, false);
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
    var ring_buffer_sample_mux = try RingBufferSampleMux(ThreadSafeRingBuffer).init(std.testing.allocator, &[2]*ThreadSafeRingBuffer{ &input1_ring_buffer, &input2_ring_buffer }, &[1]*ThreadSafeRingBuffer{&output1_ring_buffer});
    defer ring_buffer_sample_mux.deinit();
    var sample_mux = ring_buffer_sample_mux.sampleMux();

    // Create block
    var test_block = TestAddBlock.init();
    try test_block.block.differentiate(&[2]RuntimeDataType{ RuntimeDataType.Unsigned32, RuntimeDataType.Unsigned32 }, 8000);

    // Preload buffers
    std.mem.copy(u8, input1_ring_buffer.impl.memory.buf, &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x10, 0x20, 0x30, 0x40 });
    std.mem.copy(u8, input2_ring_buffer.impl.memory.buf, &[_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 });

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
    var ring_buffer_sample_mux = try RingBufferSampleMux(ThreadSafeRingBuffer).init(std.testing.allocator, &[0]*ThreadSafeRingBuffer{}, &[1]*ThreadSafeRingBuffer{&output1_ring_buffer});
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
