const std = @import("std");

const util = @import("util.zig");
const platform = @import("platform.zig");

const Block = @import("block.zig").Block;
const RuntimeTypeSignature = @import("type_signature.zig").RuntimeTypeSignature;
const SampleMux = @import("sample_mux.zig").SampleMux;
const TestSampleMux = @import("sample_mux.zig").TestSampleMux;

////////////////////////////////////////////////////////////////////////////////
// BlockTester Errors
////////////////////////////////////////////////////////////////////////////////

pub const BlockTesterError = error{
    InputMismatch,
    OutputMismatch,
    DataTypeMismatch,
    LengthMismatch,
    ValueMismatch,
};

////////////////////////////////////////////////////////////////////////////////
// BlockTester
////////////////////////////////////////////////////////////////////////////////

pub fn expectEqualValue(comptime T: type, expected: T, actual: T, index: usize, epsilon: f32, silent: bool) !void {
    const approx_equal = switch (T) {
        // Integers
        u8, u16, u32, u64, i8, i16, i32, i64 => expected == actual,
        // Floats
        f32, f64 => std.math.approxEqAbs(T, expected, actual, epsilon),
        // Complex Floats
        std.math.Complex(f32), std.math.Complex(f64) => expected.sub(actual).magnitude() < epsilon,
        // Unknown
        else => unreachable,
    };

    if (!approx_equal) {
        if (!silent) std.debug.print("Mismatch in output vector (type {any}) at index {d}: expected {any}, got {any}\n", .{ T, index, expected, actual });
        return BlockTesterError.ValueMismatch;
    }
}

pub fn expectEqualVectors(comptime T: type, expected: []const T, actual: []const T, index: usize, epsilon: f32, silent: bool) !void {
    // Compare vector length
    if (actual.len != expected.len) {
        if (!silent) std.debug.print("Mismatch in output vector (type {any}) index {d} length: expected {d}, got {d}\n", .{ T, index, expected.len, actual.len });
        return BlockTesterError.LengthMismatch;
    }

    // Compare vector values
    for (expected, 0..) |_, i| {
        try expectEqualValue(T, expected[i], actual[i], i, epsilon, silent);
    }
}

pub const BlockTester = struct {
    instance: *Block,
    epsilon: f32,
    silent: bool,

    pub fn init(instance: *Block, epsilon: f32) BlockTester {
        return .{ .instance = instance, .epsilon = epsilon, .silent = false };
    }

    pub fn check(self: *BlockTester, rate: f64, comptime input_data_types: []const type, input_vectors: util.makeTupleConstSliceTypes(input_data_types), comptime output_data_types: []const type, output_vectors: util.makeTupleConstSliceTypes(output_data_types)) !void {
        // Validate input and outputs lengths
        if (input_data_types.len != self.instance.type_signature.inputs.len) {
            return BlockTesterError.InputMismatch;
        } else if (output_data_types.len != self.instance.type_signature.outputs.len) {
            return BlockTesterError.OutputMismatch;
        }

        // Create runtime data types
        var runtime_data_types: [input_data_types.len][]const u8 = undefined;
        inline for (input_data_types, 0..) |t, i| {
            runtime_data_types[i] = comptime RuntimeTypeSignature.map(t);
        }

        // Validate block input data types
        inline for (runtime_data_types, 0..) |_, i| {
            if (!std.mem.eql(u8, self.instance.type_signature.inputs[i], runtime_data_types[i])) {
                return BlockTesterError.DataTypeMismatch;
            }
        }

        // Validate block output data types
        inline for (output_data_types, 0..) |t, i| {
            if (!std.mem.eql(u8, self.instance.type_signature.outputs[i], comptime RuntimeTypeSignature.map(t))) {
                return BlockTesterError.DataTypeMismatch;
            }
        }

        // Set rate on block
        try self.instance.setRate(rate);

        // Convert input vectors to byte buffers
        var input_buffers: [input_data_types.len][]const u8 = undefined;
        inline for (input_data_types, 0..) |_, i| input_buffers[i] = std.mem.sliceAsBytes(input_vectors[i][0..]);

        // Initialize platform
        try platform.initialize(std.testing.allocator);

        // Test input vectors entire vector at a time, followed by one sample at a time
        for (&[2]bool{ false, true }) |single_samples| {
            // Initialize block
            try self.instance.initialize(std.testing.allocator);
            defer self.instance.deinitialize(std.testing.allocator);

            // Create sample mux
            var tester_sample_mux = try TestSampleMux(input_data_types.len, output_data_types.len).init(input_buffers, .{ .single_input_samples = single_samples });
            defer tester_sample_mux.deinit();

            // Run block
            var sample_mux = tester_sample_mux.sampleMux();
            while (true) {
                const process_result = try self.instance.process(&sample_mux);
                if (process_result.eof) {
                    break;
                }
            }

            // Compare output vectors
            inline for (output_data_types, 0..) |data_type, i| {
                const actual_vector = tester_sample_mux.getOutputVector(data_type, i);
                try expectEqualVectors(data_type, output_vectors[i], actual_vector, i, self.epsilon, self.silent);
            }
        }
    }

    pub fn checkSource(self: *BlockTester, comptime output_data_types: []const type, output_vectors: util.makeTupleConstSliceTypes(output_data_types)) !void {
        // Validate input and outputs lengths
        if (output_data_types.len != self.instance.type_signature.outputs.len) {
            return BlockTesterError.OutputMismatch;
        }

        // Validate block output data types
        inline for (output_data_types, 0..) |t, i| {
            if (!std.mem.eql(u8, self.instance.type_signature.outputs[i], comptime RuntimeTypeSignature.map(t))) {
                return BlockTesterError.DataTypeMismatch;
            }
        }

        // Set rate on block
        try self.instance.setRate(0);

        // Initialize platform
        try platform.initialize(std.testing.allocator);

        // Test entire output vector at a time, followed by one sample at a time
        for (&[2]bool{ false, true }) |single_samples| {
            // Initialize block
            try self.instance.initialize(std.testing.allocator);
            defer self.instance.deinitialize(std.testing.allocator);

            // Create sample mux
            var tester_sample_mux = try TestSampleMux(0, output_data_types.len).init([0][]const u8{}, .{ .single_output_samples = single_samples });
            defer tester_sample_mux.deinit();

            // Run block
            var sample_mux = tester_sample_mux.sampleMux();
            blk: while (true) {
                const process_result = try self.instance.process(&sample_mux);
                if (process_result.eof) {
                    break;
                }
                inline for (output_data_types, 0..) |_, i| {
                    if (tester_sample_mux.getNumOutputSamples(output_data_types[i], i) >= output_vectors[i].len) {
                        break :blk;
                    }
                }
            }

            // Compare output vectors
            inline for (output_data_types, 0..) |data_type, i| {
                const actual_vector = tester_sample_mux.getOutputVector(data_type, i);
                try expectEqualVectors(data_type, output_vectors[i], actual_vector[0..output_vectors[i].len], i, self.epsilon, self.silent);
            }
        }
    }
};

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockError = @import("block.zig").BlockError;
const ProcessResult = @import("block.zig").ProcessResult;

const TestBlock1 = struct {
    block: Block,
    initialized: usize,

    pub fn init() TestBlock1 {
        return .{ .block = Block.init(@This()), .initialized = 0 };
    }

    pub fn initialize(self: *TestBlock1, _: std.mem.Allocator) !void {
        self.initialized = 1;
    }

    pub fn deinitialize(self: *TestBlock1, _: std.mem.Allocator) void {
        self.initialized += 10;
    }

    pub fn process(_: *TestBlock1, x: []const u32, y: []const u16, z: []u32) !ProcessResult {
        for (x, 0..) |_, i| {
            z[i] = x[i] + y[i];
        }
        return ProcessResult.init(&[2]usize{ x.len, y.len }, &[1]usize{x.len});
    }
};

const TestBlock2 = struct {
    block: Block,
    initialized: usize,

    pub fn init() TestBlock2 {
        return .{ .block = Block.init(@This()), .initialized = 0 };
    }

    pub fn initialize(self: *TestBlock2, _: std.mem.Allocator) !void {
        self.initialized = 2;
    }

    pub fn deinitialize(self: *TestBlock2, _: std.mem.Allocator) void {
        self.initialized += 20;
    }

    pub fn process(_: *TestBlock2, x: []const f32, y: []const f32, z: []f32) !ProcessResult {
        for (x, 0..) |_, i| {
            z[i] = x[i] + y[i];
        }
        return ProcessResult.init(&[2]usize{ x.len, y.len }, &[1]usize{x.len});
    }
};

const TestBlock3 = struct {
    block: Block,
    initialized: usize,

    pub fn init() TestBlock3 {
        return .{ .block = Block.init(@This()), .initialized = 0 };
    }

    pub fn initialize(self: *TestBlock3, _: std.mem.Allocator) !void {
        self.initialized = 3;
    }

    pub fn deinitialize(self: *TestBlock3, _: std.mem.Allocator) void {
        self.initialized += 30;
    }

    pub fn process(_: *TestBlock3, x: []const std.math.Complex(f32), y: []const std.math.Complex(f32), z: []std.math.Complex(f32)) !ProcessResult {
        for (x, 0..) |_, i| {
            z[i] = x[i].sub(y[i]);
        }
        return ProcessResult.init(&[2]usize{ x.len, y.len }, &[1]usize{x.len});
    }
};

test "BlockTester for Block" {
    var block1 = TestBlock1.init();
    var block2 = TestBlock2.init();
    var block3 = TestBlock3.init();

    var tester1 = BlockTester.init(&block1.block, 0.1);
    var tester2 = BlockTester.init(&block2.block, 0.1);
    var tester3 = BlockTester.init(&block3.block, 0.1);

    // Test input data type count mismatch
    try std.testing.expectError(BlockTesterError.InputMismatch, tester1.check(8000, &[1]type{u32}, .{&[_]u32{ 1, 2, 3 }}, &[1]type{u32}, .{&[_]u32{ 3, 5, 7 }}));
    // Test output data type count mismatch
    try std.testing.expectError(BlockTesterError.OutputMismatch, tester1.check(8000, &[2]type{ u32, u16 }, .{ &[_]u32{ 1, 2, 3 }, &[_]u16{ 2, 3, 4 } }, &[2]type{ u32, u32 }, .{ &[_]u32{ 3, 5, 7 }, &[_]u32{ 3, 5, 7 } }));

    // Test input data type mismatch
    try std.testing.expectError(BlockTesterError.DataTypeMismatch, tester1.check(8000, &[2]type{ u8, u16 }, .{ &[_]u8{ 1, 2, 3 }, &[_]u16{ 2, 3, 4 } }, &[1]type{u32}, .{&[_]u32{ 3, 5, 7 }}));
    // Test output data type mismatch
    try std.testing.expectError(BlockTesterError.DataTypeMismatch, tester1.check(8000, &[2]type{ u32, u16 }, .{ &[_]u32{ 1, 2, 3 }, &[_]u16{ 2, 3, 4 } }, &[1]type{u64}, .{&[_]u64{ 3, 5, 7 }}));

    // Test success
    try tester1.check(8000, &[2]type{ u32, u16 }, .{ &[_]u32{ 1, 2, 3 }, &[_]u16{ 2, 3, 4 } }, &[1]type{u32}, .{&[_]u32{ 3, 5, 7 }});
    try std.testing.expectEqual(@as(usize, 11), block1.initialized);

    // Test success with floats
    try tester2.check(8000, &[2]type{ f32, f32 }, .{ &[_]f32{ 1.2, 2.4, 3.6 }, &[_]f32{ 1, 2, 3 } }, &[1]type{f32}, .{&[_]f32{ 2.2, 4.4, 6.6 }});
    try std.testing.expectEqual(@as(usize, 22), block2.initialized);

    // Test success with complex floats
    try tester3.check(8000, &[2]type{ std.math.Complex(f32), std.math.Complex(f32) }, .{ &[_]std.math.Complex(f32){ std.math.Complex(f32).init(1, 2), std.math.Complex(f32).init(3, 4), std.math.Complex(f32).init(5, 6) }, &[_]std.math.Complex(f32){ std.math.Complex(f32).init(0.5, 0.5), std.math.Complex(f32).init(0.25, 0.25), std.math.Complex(f32).init(0.75, 0.75) } }, &[1]type{std.math.Complex(f32)}, .{&[_]std.math.Complex(f32){ std.math.Complex(f32).init(0.5, 1.5), std.math.Complex(f32).init(2.75, 3.75), std.math.Complex(f32).init(4.25, 5.25) }});
    try std.testing.expectEqual(@as(usize, 33), block3.initialized);

    // Silence output on block tester for error tests
    tester1.silent = true;
    tester2.silent = true;
    tester3.silent = true;

    // Test vector mismatch
    try std.testing.expectError(BlockTesterError.LengthMismatch, tester1.check(8000, &[2]type{ u32, u16 }, .{ &[_]u32{ 1, 2, 3 }, &[_]u16{ 2, 3, 4 } }, &[1]type{u32}, .{&[_]u32{ 3, 5 }}));
    try std.testing.expectError(BlockTesterError.ValueMismatch, tester1.check(8000, &[2]type{ u32, u16 }, .{ &[_]u32{ 1, 2, 3 }, &[_]u16{ 2, 3, 4 } }, &[1]type{u32}, .{&[_]u32{ 3, 5, 8 }}));

    // Test vector mismatch with epsilon
    try std.testing.expectError(BlockTesterError.ValueMismatch, tester2.check(8000, &[2]type{ f32, f32 }, .{ &[_]f32{ 1.2, 2.4, 3.6 }, &[_]f32{ 1, 2, 3 } }, &[1]type{f32}, .{&[_]f32{ 2.2, 4.0, 6.6 }}));
    try std.testing.expectError(BlockTesterError.ValueMismatch, tester3.check(8000, &[2]type{ std.math.Complex(f32), std.math.Complex(f32) }, .{ &[_]std.math.Complex(f32){ std.math.Complex(f32).init(1, 2), std.math.Complex(f32).init(3, 4), std.math.Complex(f32).init(5, 6) }, &[_]std.math.Complex(f32){ std.math.Complex(f32).init(0.5, 0.5), std.math.Complex(f32).init(0.25, 0.25), std.math.Complex(f32).init(0.75, 0.75) } }, &[1]type{std.math.Complex(f32)}, .{&[_]std.math.Complex(f32){ std.math.Complex(f32).init(0.5, 1.5), std.math.Complex(f32).init(2.65, 3.85), std.math.Complex(f32).init(4.25, 5.25) }}));
}

const TestSource = struct {
    block: Block,
    counter: usize = 1,
    error_on_initialize: bool = false,

    pub fn init() TestSource {
        return .{ .block = Block.init(@This()) };
    }

    pub fn setRate(_: *TestSource, _: f64) !f64 {
        return 8000;
    }

    pub fn initialize(self: *TestSource, _: std.mem.Allocator) !void {
        if (self.error_on_initialize) {
            return error.NotImplemented;
        }
        self.counter = 1;
    }

    pub fn deinitialize(self: *TestSource, _: std.mem.Allocator) void {
        self.counter = 123;
    }

    pub fn process(self: *TestSource, z: []f32) !ProcessResult {
        for (z) |*e| {
            e.* = @as(f32, @floatFromInt(self.counter));
            self.counter += 1;
        }

        return ProcessResult.init(&[0]usize{}, &[1]usize{z.len});
    }
};

test "BlockTester for Source" {
    var block = TestSource.init();

    var tester = BlockTester.init(&block.block, 0.1);

    // Test output data type count mismatch
    try std.testing.expectError(BlockTesterError.OutputMismatch, tester.checkSource(&[2]type{ f32, f32 }, .{ &[_]f32{ 3, 5, 7 }, &[_]f32{ 3, 5, 7 } }));

    // Test output data type mismatch
    try std.testing.expectError(BlockTesterError.DataTypeMismatch, tester.checkSource(&[1]type{u32}, .{&[_]u32{ 3, 5, 7 }}));

    // Test initialization error
    block.error_on_initialize = true;
    try std.testing.expectError(error.NotImplemented, tester.checkSource(&[1]type{f32}, .{&[_]f32{2}}));
    block.error_on_initialize = false;

    // Test success
    try tester.checkSource(&[1]type{f32}, .{&[_]f32{ 1, 2, 3 }});
    try std.testing.expectEqual(@as(usize, 123), block.counter);

    // Silence output on block tester for error tests
    tester.silent = true;

    // Test vector mismatch
    try std.testing.expectError(BlockTesterError.ValueMismatch, tester.checkSource(&[1]type{f32}, .{&[_]f32{ 2, 3, 4 }}));

    // Test vector mismatch with epsilon
    try std.testing.expectError(BlockTesterError.ValueMismatch, tester.checkSource(&[1]type{f32}, .{&[_]f32{ 1, 2.5, 3 }}));
}
