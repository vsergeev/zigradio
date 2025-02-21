const std = @import("std");

const util = @import("util.zig");
const platform = @import("platform.zig");

const Block = @import("block.zig").Block;
const RuntimeTypeSignature = @import("types.zig").RuntimeTypeSignature;
const SampleMux = @import("sample_mux.zig").SampleMux;
const TestSampleMux = @import("sample_mux.zig").TestSampleMux;

////////////////////////////////////////////////////////////////////////////////
// Expect Helpers
////////////////////////////////////////////////////////////////////////////////

fn _expectEqualValue(comptime T: type, expected: T, actual: T, index: usize, epsilon: f32, silent: bool) !void {
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
        return error.TestExpectedEqual;
    }
}

fn _expectEqualVectors(comptime T: type, expected: []const T, actual: []const T, index: usize, epsilon: f32, silent: bool) !void {
    // Compare vector length
    if (actual.len != expected.len) {
        if (!silent) std.debug.print("Mismatch in output vector (type {any}) index {d} length: expected {d}, got {d}\n", .{ T, index, expected.len, actual.len });
        return error.TestExpectedEqual;
    }

    // Compare vector values
    for (expected, 0..) |_, i| {
        try _expectEqualValue(T, expected[i], actual[i], i, epsilon, silent);
    }
}

pub fn expectEqualVectors(comptime T: type, expected: []const T, actual: []const T, epsilon: f32) !void {
    try _expectEqualVectors(T, expected, actual, 0, epsilon, false);
}

////////////////////////////////////////////////////////////////////////////////
// BlockTester
////////////////////////////////////////////////////////////////////////////////

pub const BlockTesterError = error{
    InputMismatch,
    OutputMismatch,
    DataTypeMismatch,
};

pub fn BlockTester(comptime input_data_types: []const type, comptime output_data_types: []const type) type {
    return struct {
        const Self = @This();

        instance: *Block,
        epsilon: f32,
        silent: bool,

        pub fn init(instance: *Block, epsilon: f32) !Self {
            // Validate input and outputs lengths
            if (input_data_types.len != instance.type_signature.inputs.len) {
                return BlockTesterError.InputMismatch;
            } else if (output_data_types.len != instance.type_signature.outputs.len) {
                return BlockTesterError.OutputMismatch;
            }

            // Validate block input data types
            inline for (input_data_types, 0..) |t, i| {
                if (!std.mem.eql(u8, instance.type_signature.inputs[i], comptime RuntimeTypeSignature.map(t))) {
                    return BlockTesterError.DataTypeMismatch;
                }
            }

            // Validate block output data types
            inline for (output_data_types, 0..) |t, i| {
                if (!std.mem.eql(u8, instance.type_signature.outputs[i], comptime RuntimeTypeSignature.map(t))) {
                    return BlockTesterError.DataTypeMismatch;
                }
            }

            return .{ .instance = instance, .epsilon = epsilon, .silent = false };
        }

        pub fn check(self: *Self, rate: f64, input_vectors: util.makeTupleConstSliceTypes(input_data_types), output_vectors: util.makeTupleConstSliceTypes(output_data_types)) !void {
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
                var tester_sample_mux = try TestSampleMux(input_data_types, output_data_types).init(input_buffers, .{ .single_input_samples = single_samples });
                defer tester_sample_mux.deinit();

                // Run block
                const sample_mux = tester_sample_mux.sampleMux();
                while (true) {
                    const process_result = self.instance.process(sample_mux) catch |err| switch (err) {
                        error.EndOfStream => break,
                        else => return err,
                    };
                    if (process_result.eos) {
                        break;
                    }
                }

                // Compare output vectors
                inline for (output_data_types, 0..) |data_type, i| {
                    const actual_vector = tester_sample_mux.getOutputVector(data_type, i);
                    try _expectEqualVectors(data_type, output_vectors[i], actual_vector, i, self.epsilon, self.silent);
                }
            }
        }

        pub fn checkSource(self: *Self, output_vectors: util.makeTupleConstSliceTypes(output_data_types)) !void {
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
                var tester_sample_mux = try TestSampleMux(&[0]type{}, output_data_types).init([0][]const u8{}, .{ .single_output_samples = single_samples });
                defer tester_sample_mux.deinit();

                // Run block
                const sample_mux = tester_sample_mux.sampleMux();
                blk: while (true) {
                    const process_result = try self.instance.process(sample_mux);
                    if (process_result.eos) {
                        break;
                    }

                    inline for (output_data_types, 0..) |_, i| {
                        if (tester_sample_mux.getOutputVector(output_data_types[i], i).len >= output_vectors[i].len) {
                            break :blk;
                        }
                    }
                }

                // Compare output vectors
                inline for (output_data_types, 0..) |data_type, i| {
                    const actual_vector = tester_sample_mux.getOutputVector(data_type, i);
                    try _expectEqualVectors(data_type, output_vectors[i], actual_vector[0..output_vectors[i].len], i, self.epsilon, self.silent);
                }
            }
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// BlockFixture
////////////////////////////////////////////////////////////////////////////////

pub fn BlockFixture(comptime input_data_types: []const type, comptime output_data_types: []const type) type {
    return struct {
        const Self = @This();

        instance: *Block,
        test_sample_mux: TestSampleMux(input_data_types, output_data_types),

        pub fn init(instance: *Block, rate: f64) !Self {
            try platform.initialize(std.testing.allocator);

            try instance.setRate(rate);
            try instance.initialize(std.testing.allocator);

            return .{ .instance = instance, .test_sample_mux = try TestSampleMux(input_data_types, output_data_types).init(.{&[_]u8{}} ** input_data_types.len, .{}) };
        }

        pub fn deinit(self: *Self) void {
            self.test_sample_mux.deinit();
            self.instance.deinitialize(std.testing.allocator);
        }

        pub fn process(self: *Self, input_vectors: util.makeTupleConstSliceTypes(input_data_types)) !util.makeTupleConstSliceTypes(output_data_types) {
            // Convert input vectors to byte buffers in test sample mux
            inline for (input_data_types, 0..) |_, i| {
                self.test_sample_mux.input_buffers[i] = std.mem.sliceAsBytes(input_vectors[i][0..]);
                self.test_sample_mux.input_buffer_indices[i] = 0;
            }

            // Reset output vectors in test sample mux
            inline for (output_data_types, 0..) |_, i| {
                self.test_sample_mux.output_buffer_indices[i] = 0;
            }

            // Run block
            const sample_mux = self.test_sample_mux.sampleMux();
            const process_result = try self.instance.process(sample_mux);
            if (process_result.eos) {
                return error.EndOfStream;
            }

            // Convert output vectors in test sample mux to typed vcetors
            var outputs: util.makeTupleConstSliceTypes(output_data_types) = undefined;
            inline for (output_data_types, 0..) |data_type, i| {
                outputs[i] = self.test_sample_mux.getOutputVector(data_type, i);
            }

            return outputs;
        }
    };
}

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

    // Test input data type count mismatch
    try std.testing.expectError(BlockTesterError.InputMismatch, BlockTester(&[1]type{u32}, &[1]type{u32}).init(&block1.block, 0.1));
    // Test output data type count mismatch
    try std.testing.expectError(BlockTesterError.OutputMismatch, BlockTester(&[2]type{ u32, u16 }, &[2]type{ u32, u32 }).init(&block1.block, 0.1));
    // Test input data type mismatch
    try std.testing.expectError(BlockTesterError.DataTypeMismatch, BlockTester(&[2]type{ u8, u16 }, &[1]type{u32}).init(&block1.block, 0.1));
    // Test output data type mismatch
    try std.testing.expectError(BlockTesterError.DataTypeMismatch, BlockTester(&[2]type{ u32, u16 }, &[1]type{u64}).init(&block1.block, 0.1));

    var tester1 = try BlockTester(&[2]type{ u32, u16 }, &[1]type{u32}).init(&block1.block, 0.1);
    var tester2 = try BlockTester(&[2]type{ f32, f32 }, &[1]type{f32}).init(&block2.block, 0.1);
    var tester3 = try BlockTester(&[2]type{ std.math.Complex(f32), std.math.Complex(f32) }, &[1]type{std.math.Complex(f32)}).init(&block3.block, 0.1);

    // Test success
    try tester1.check(8000, .{ &[_]u32{ 1, 2, 3 }, &[_]u16{ 2, 3, 4 } }, .{&[_]u32{ 3, 5, 7 }});
    try std.testing.expectEqual(@as(usize, 11), block1.initialized);

    // Test success with floats
    try tester2.check(8000, .{ &[_]f32{ 1.2, 2.4, 3.6 }, &[_]f32{ 1, 2, 3 } }, .{&[_]f32{ 2.2, 4.4, 6.6 }});
    try std.testing.expectEqual(@as(usize, 22), block2.initialized);

    // Test success with complex floats
    try tester3.check(8000, .{ &[_]std.math.Complex(f32){ std.math.Complex(f32).init(1, 2), std.math.Complex(f32).init(3, 4), std.math.Complex(f32).init(5, 6) }, &[_]std.math.Complex(f32){ std.math.Complex(f32).init(0.5, 0.5), std.math.Complex(f32).init(0.25, 0.25), std.math.Complex(f32).init(0.75, 0.75) } }, .{&[_]std.math.Complex(f32){ std.math.Complex(f32).init(0.5, 1.5), std.math.Complex(f32).init(2.75, 3.75), std.math.Complex(f32).init(4.25, 5.25) }});
    try std.testing.expectEqual(@as(usize, 33), block3.initialized);

    // Silence output on block tester for error tests
    tester1.silent = true;
    tester2.silent = true;
    tester3.silent = true;

    // Test vector mismatch
    try std.testing.expectError(error.TestExpectedEqual, tester1.check(8000, .{ &[_]u32{ 1, 2, 3 }, &[_]u16{ 2, 3, 4 } }, .{&[_]u32{ 3, 5 }}));
    try std.testing.expectError(error.TestExpectedEqual, tester1.check(8000, .{ &[_]u32{ 1, 2, 3 }, &[_]u16{ 2, 3, 4 } }, .{&[_]u32{ 3, 5, 8 }}));

    // Test vector mismatch with epsilon
    try std.testing.expectError(error.TestExpectedEqual, tester2.check(8000, .{ &[_]f32{ 1.2, 2.4, 3.6 }, &[_]f32{ 1, 2, 3 } }, .{&[_]f32{ 2.2, 4.0, 6.6 }}));
    try std.testing.expectError(error.TestExpectedEqual, tester3.check(8000, .{ &[_]std.math.Complex(f32){ std.math.Complex(f32).init(1, 2), std.math.Complex(f32).init(3, 4), std.math.Complex(f32).init(5, 6) }, &[_]std.math.Complex(f32){ std.math.Complex(f32).init(0.5, 0.5), std.math.Complex(f32).init(0.25, 0.25), std.math.Complex(f32).init(0.75, 0.75) } }, .{&[_]std.math.Complex(f32){ std.math.Complex(f32).init(0.5, 1.5), std.math.Complex(f32).init(2.65, 3.85), std.math.Complex(f32).init(4.25, 5.25) }}));
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

    // Test input data type count mismatch
    try std.testing.expectError(BlockTesterError.InputMismatch, BlockTester(&[1]type{f32}, &[1]type{f32}).init(&block.block, 0.1));
    // Test output data type count mismatch
    try std.testing.expectError(BlockTesterError.OutputMismatch, BlockTester(&[0]type{}, &[2]type{ f32, f32 }).init(&block.block, 0.1));
    // Test output data type mismatch
    try std.testing.expectError(BlockTesterError.DataTypeMismatch, BlockTester(&[0]type{}, &[1]type{u32}).init(&block.block, 0.1));

    var tester = try BlockTester(&[0]type{}, &[1]type{f32}).init(&block.block, 0.1);

    // Test initialization error
    block.error_on_initialize = true;
    try std.testing.expectError(error.NotImplemented, tester.checkSource(.{&[_]f32{2}}));
    block.error_on_initialize = false;

    // Test success
    try tester.checkSource(.{&[_]f32{ 1, 2, 3 }});
    try std.testing.expectEqual(@as(usize, 123), block.counter);

    // Silence output on block tester for error tests
    tester.silent = true;

    // Test vector mismatch
    try std.testing.expectError(error.TestExpectedEqual, tester.checkSource(.{&[_]f32{ 2, 3, 4 }}));

    // Test vector mismatch with epsilon
    try std.testing.expectError(error.TestExpectedEqual, tester.checkSource(.{&[_]f32{ 1, 2.5, 3 }}));
}

test "BlockFixture for Block" {
    var block = TestBlock2.init();

    var fixture = try BlockFixture(&[2]type{ f32, f32 }, &[1]type{f32}).init(&block.block, 2);
    defer fixture.deinit();

    // Validate initial block state
    try std.testing.expectEqual(2, block.block.getRate(usize));
    try std.testing.expectEqual(2, block.initialized);

    // Run block
    const outputs1 = try fixture.process(.{ &[_]f32{ 1, 2, 3 }, &[_]f32{ 4, 5, 6 } });
    try std.testing.expectEqualSlices(f32, &[_]f32{ 5, 7, 9 }, outputs1[0]);
    const outputs2 = try fixture.process(.{ &[_]f32{ 2, 2, 2 }, &[_]f32{ 3, 3, 3 } });
    try std.testing.expectEqualSlices(f32, &[_]f32{ 5, 5, 5 }, outputs2[0]);
}

test "BlockFixture for Source" {
    var block = TestSource.init();

    var fixture = try BlockFixture(&[0]type{}, &[1]type{f32}).init(&block.block, 2);
    defer fixture.deinit();

    // Validate initial block state
    try std.testing.expectEqual(8000, block.block.getRate(usize));

    // Run block
    const outputs1 = try fixture.process(.{});
    for (outputs1[0], 0..) |e, i| try std.testing.expectEqual(@as(f32, @floatFromInt(i + 1)), e);
    const outputs2 = try fixture.process(.{});
    for (outputs2[0], 0..) |e, i| try std.testing.expectEqual(@as(f32, @floatFromInt(i + 1 + outputs1[0].len)), e);
}
