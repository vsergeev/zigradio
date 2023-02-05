const std = @import("std");

const util = @import("util.zig");

const Block = @import("block.zig").Block;
const BlockError = @import("block.zig").BlockError;
const ProcessResult = @import("block.zig").ProcessResult;
const RuntimeDataType = @import("type_signature.zig").RuntimeDataType;

const SampleMux = @import("sample_mux.zig").SampleMux;
const TestSampleMux = @import("sample_mux.zig").TestSampleMux;

////////////////////////////////////////////////////////////////////////////////
// BlockTester Errors
////////////////////////////////////////////////////////////////////////////////

pub const BlockTesterError = error{
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
    for (expected) |_, i| {
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
        // Create runtime data types
        comptime var runtime_data_types: [input_data_types.len]RuntimeDataType = undefined;
        inline for (input_data_types) |t, i| {
            runtime_data_types[i] = comptime RuntimeDataType.map(t);
        }

        // Differentiate block
        try self.instance.differentiate(&runtime_data_types, rate);

        // Validate block output data types
        inline for (output_data_types) |t, i| {
            if (try self.instance.getOutputType(i) != comptime RuntimeDataType.map(t)) {
                return BlockTesterError.DataTypeMismatch;
            }
        }

        // Convert input vectors to byte buffers
        var input_buffers: [input_data_types.len][]const u8 = undefined;
        inline for (input_data_types) |_, i| input_buffers[i] = std.mem.sliceAsBytes(input_vectors[i][0..]);

        // Test input vectors entire vector at a time, followed by one sample at a time
        for (&[2]bool{ false, true }) |single_samples| {
            // Initialize block
            try self.instance.initialize(std.testing.allocator);

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
            inline for (output_data_types) |data_type, i| {
                const actual_vector = tester_sample_mux.getOutputVector(data_type, i);
                try expectEqualVectors(data_type, output_vectors[i], actual_vector, i, self.epsilon, self.silent);
            }
        }
    }

    pub fn checkSource(self: *BlockTester, comptime output_data_types: []const type, output_vectors: util.makeTupleConstSliceTypes(output_data_types)) !void {
        // Differentiate block
        try self.instance.differentiate(&[0]RuntimeDataType{}, 0);

        // Validate block output data types
        inline for (output_data_types) |t, i| {
            if (try self.instance.getOutputType(i) != comptime RuntimeDataType.map(t)) {
                return BlockTesterError.DataTypeMismatch;
            }
        }

        // Test entire output vector at a time, followed by one sample at a time
        for (&[2]bool{ false, true }) |single_samples| {
            // Initialize block
            try self.instance.initialize(std.testing.allocator);

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
                inline for (output_data_types) |_, i| {
                    if (tester_sample_mux.getNumOutputSamples(output_data_types[i], i) >= output_vectors[i].len) {
                        break :blk;
                    }
                }
            }

            // Compare output vectors
            inline for (output_data_types) |data_type, i| {
                const actual_vector = tester_sample_mux.getOutputVector(data_type, i);
                try expectEqualVectors(data_type, output_vectors[i], actual_vector[0..output_vectors[i].len], i, self.epsilon, self.silent);
            }
        }
    }
};

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const TestBlock = struct {
    block: Block,
    initialized: usize,

    pub fn init() TestBlock {
        return .{ .block = Block.init(@This()), .initialized = 0 };
    }

    pub fn initialize1(self: *TestBlock, _: std.mem.Allocator) !void {
        self.initialized = 1;
    }

    pub fn process1(_: *TestBlock, x: []const u32, y: []const u16, z: []u32) !ProcessResult {
        for (x) |_, i| {
            z[i] = x[i] + y[i];
        }
        return ProcessResult.init(&[2]usize{ x.len, y.len }, &[1]usize{x.len});
    }

    pub fn initialize2(self: *TestBlock, _: std.mem.Allocator) !void {
        self.initialized = 2;
    }

    pub fn process2(_: *TestBlock, x: []const u8, y: []const u16, z: []u16) !ProcessResult {
        for (x) |_, i| {
            z[i] = x[i] + y[i] + y[i];
        }
        return ProcessResult.init(&[2]usize{ x.len, y.len }, &[1]usize{x.len});
    }

    pub fn initialize3(_: *TestBlock, _: std.mem.Allocator) !void {
        return error.NotImplemented;
    }

    pub fn process3(_: *TestBlock, _: []const u8, _: []const u8, _: []u8) !ProcessResult {
        return error.NotImplemented;
    }

    pub fn initialize4(self: *TestBlock, _: std.mem.Allocator) !void {
        self.initialized = 4;
    }

    pub fn process4(_: *TestBlock, x: []const f32, y: []const f32, z: []f32) !ProcessResult {
        for (x) |_, i| {
            z[i] = x[i] + y[i];
        }
        return ProcessResult.init(&[2]usize{ x.len, y.len }, &[1]usize{x.len});
    }

    pub fn initialize5(self: *TestBlock, _: std.mem.Allocator) !void {
        self.initialized = 5;
    }

    pub fn process5(_: *TestBlock, x: []const std.math.Complex(f32), y: []const std.math.Complex(f32), z: []std.math.Complex(f32)) !ProcessResult {
        for (x) |_, i| {
            z[i] = x[i].sub(y[i]);
        }
        return ProcessResult.init(&[2]usize{ x.len, y.len }, &[1]usize{x.len});
    }
};

test "BlockTester for Block" {
    var block = TestBlock.init();

    var tester = BlockTester.init(&block.block, 0.1);

    // Test differentiation failure
    try std.testing.expectError(BlockError.TypeSignatureNotFound, tester.check(8000, &[2]type{ u64, u64 }, .{ &[_]u64{ 1, 2, 3 }, &[_]u64{ 2, 3, 4 } }, &[1]type{u32}, .{&[_]u32{ 3, 5, 7 }}));

    // Test output data type count mismatch
    try std.testing.expectError(BlockError.OutputNotFound, tester.check(8000, &[2]type{ u32, u16 }, .{ &[_]u32{ 1, 2, 3 }, &[_]u16{ 2, 3, 4 } }, &[2]type{ u32, u32 }, .{ &[_]u32{ 3, 5, 7 }, &[_]u32{ 3, 5, 7 } }));

    // Test output data type mismatch
    try std.testing.expectError(BlockTesterError.DataTypeMismatch, tester.check(8000, &[2]type{ u32, u16 }, .{ &[_]u32{ 1, 2, 3 }, &[_]u16{ 2, 3, 4 } }, &[1]type{u64}, .{&[_]u64{ 3, 5, 7 }}));

    // Test initialization error
    try std.testing.expectError(error.NotImplemented, tester.check(8000, &[2]type{ u8, u8 }, .{ &[_]u8{ 1, 2 }, &[_]u8{ 3, 4 } }, &[1]type{u8}, .{&[_]u8{2}}));

    // Test success
    try tester.check(8000, &[2]type{ u32, u16 }, .{ &[_]u32{ 1, 2, 3 }, &[_]u16{ 2, 3, 4 } }, &[1]type{u32}, .{&[_]u32{ 3, 5, 7 }});
    try std.testing.expectEqual(@as(usize, 1), block.initialized);
    try tester.check(8000, &[2]type{ u8, u16 }, .{ &[_]u8{ 1, 2, 3 }, &[_]u16{ 2, 3, 4 } }, &[1]type{u16}, .{&[_]u16{ 5, 8, 11 }});
    try std.testing.expectEqual(@as(usize, 2), block.initialized);

    // Test success with floats
    try tester.check(8000, &[2]type{ f32, f32 }, .{ &[_]f32{ 1.2, 2.4, 3.6 }, &[_]f32{ 1, 2, 3 } }, &[1]type{f32}, .{&[_]f32{ 2.2, 4.4, 6.6 }});
    try std.testing.expectEqual(@as(usize, 4), block.initialized);
    try tester.check(8000, &[2]type{ f32, f32 }, .{ &[_]f32{ 1.2, 2.4, 3.6 }, &[_]f32{ 1, 2, 3 } }, &[1]type{f32}, .{&[_]f32{ 2.15, 4.45, 6.55 }});
    try std.testing.expectEqual(@as(usize, 4), block.initialized);

    // Test success with complex floats
    try tester.check(8000, &[2]type{ std.math.Complex(f32), std.math.Complex(f32) }, .{ &[_]std.math.Complex(f32){ std.math.Complex(f32).init(1, 2), std.math.Complex(f32).init(3, 4), std.math.Complex(f32).init(5, 6) }, &[_]std.math.Complex(f32){ std.math.Complex(f32).init(0.5, 0.5), std.math.Complex(f32).init(0.25, 0.25), std.math.Complex(f32).init(0.75, 0.75) } }, &[1]type{std.math.Complex(f32)}, .{&[_]std.math.Complex(f32){ std.math.Complex(f32).init(0.5, 1.5), std.math.Complex(f32).init(2.75, 3.75), std.math.Complex(f32).init(4.25, 5.25) }});
    try std.testing.expectEqual(@as(usize, 5), block.initialized);
    try tester.check(8000, &[2]type{ std.math.Complex(f32), std.math.Complex(f32) }, .{ &[_]std.math.Complex(f32){ std.math.Complex(f32).init(1, 2), std.math.Complex(f32).init(3, 4), std.math.Complex(f32).init(5, 6) }, &[_]std.math.Complex(f32){ std.math.Complex(f32).init(0.5, 0.5), std.math.Complex(f32).init(0.25, 0.25), std.math.Complex(f32).init(0.75, 0.75) } }, &[1]type{std.math.Complex(f32)}, .{&[_]std.math.Complex(f32){ std.math.Complex(f32).init(0.45, 1.55), std.math.Complex(f32).init(2.70, 3.80), std.math.Complex(f32).init(4.20, 5.30) }});
    try std.testing.expectEqual(@as(usize, 5), block.initialized);

    // Silence output on block tester for error tests
    tester.silent = true;

    // Test vector mismatch
    try std.testing.expectError(BlockTesterError.LengthMismatch, tester.check(8000, &[2]type{ u32, u16 }, .{ &[_]u32{ 1, 2, 3 }, &[_]u16{ 2, 3, 4 } }, &[1]type{u32}, .{&[_]u32{ 3, 5 }}));
    try std.testing.expectError(BlockTesterError.ValueMismatch, tester.check(8000, &[2]type{ u32, u16 }, .{ &[_]u32{ 1, 2, 3 }, &[_]u16{ 2, 3, 4 } }, &[1]type{u32}, .{&[_]u32{ 3, 5, 8 }}));
    try std.testing.expectError(BlockTesterError.LengthMismatch, tester.check(8000, &[2]type{ u8, u16 }, .{ &[_]u8{ 1, 2, 3 }, &[_]u16{ 2, 3, 4 } }, &[1]type{u16}, .{&[_]u16{ 4, 8 }}));
    try std.testing.expectError(BlockTesterError.ValueMismatch, tester.check(8000, &[2]type{ u8, u16 }, .{ &[_]u8{ 1, 2, 3 }, &[_]u16{ 2, 3, 4 } }, &[1]type{u16}, .{&[_]u16{ 4, 8, 11 }}));

    // Test vector mismatch with epsilon
    try std.testing.expectError(BlockTesterError.ValueMismatch, tester.check(8000, &[2]type{ f32, f32 }, .{ &[_]f32{ 1.2, 2.4, 3.6 }, &[_]f32{ 1, 2, 3 } }, &[1]type{f32}, .{&[_]f32{ 2.2, 4.0, 6.6 }}));
    try std.testing.expectError(BlockTesterError.ValueMismatch, tester.check(8000, &[2]type{ std.math.Complex(f32), std.math.Complex(f32) }, .{ &[_]std.math.Complex(f32){ std.math.Complex(f32).init(1, 2), std.math.Complex(f32).init(3, 4), std.math.Complex(f32).init(5, 6) }, &[_]std.math.Complex(f32){ std.math.Complex(f32).init(0.5, 0.5), std.math.Complex(f32).init(0.25, 0.25), std.math.Complex(f32).init(0.75, 0.75) } }, &[1]type{std.math.Complex(f32)}, .{&[_]std.math.Complex(f32){ std.math.Complex(f32).init(0.5, 1.5), std.math.Complex(f32).init(2.65, 3.85), std.math.Complex(f32).init(4.25, 5.25) }}));
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

    pub fn process(self: *TestSource, z: []f32) !ProcessResult {
        for (z) |*e| {
            e.* = @intToFloat(f32, self.counter);
            self.counter += 1;
        }

        return ProcessResult.init(&[0]usize{}, &[1]usize{z.len});
    }
};

test "BlockTester for Source" {
    var block = TestSource.init();

    var tester = BlockTester.init(&block.block, 0.1);

    // Test output data type count mismatch
    try std.testing.expectError(BlockError.OutputNotFound, tester.checkSource(&[2]type{ f32, f32 }, .{ &[_]f32{ 3, 5, 7 }, &[_]f32{ 3, 5, 7 } }));

    // Test output data type mismatch
    try std.testing.expectError(BlockTesterError.DataTypeMismatch, tester.checkSource(&[1]type{u32}, .{&[_]u32{ 3, 5, 7 }}));

    // Test initialization error
    block.error_on_initialize = true;
    try std.testing.expectError(error.NotImplemented, tester.checkSource(&[1]type{f32}, .{&[_]f32{2}}));
    block.error_on_initialize = false;

    // Test success
    try tester.checkSource(&[1]type{f32}, .{&[_]f32{ 1, 2, 3 }});

    // Silence output on block tester for error tests
    tester.silent = true;

    // Test vector mismatch
    try std.testing.expectError(BlockTesterError.ValueMismatch, tester.checkSource(&[1]type{f32}, .{&[_]f32{ 2, 3, 4 }}));

    // Test vector mismatch with epsilon
    try std.testing.expectError(BlockTesterError.ValueMismatch, tester.checkSource(&[1]type{f32}, .{&[_]f32{ 1, 2.5, 3 }}));
}
