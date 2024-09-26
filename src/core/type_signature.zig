const std = @import("std");

////////////////////////////////////////////////////////////////////////////////
// Comptime Type Signatures
////////////////////////////////////////////////////////////////////////////////

pub const ComptimeTypeSignature = struct {
    inputs: []type,
    outputs: []type,

    pub fn init(comptime process_fn: anytype) ComptimeTypeSignature {
        const process_args = @typeInfo(@TypeOf(process_fn)).Fn.params[1..];

        comptime var comptime_inputs: [process_args.len]type = undefined;
        comptime var comptime_outputs: [process_args.len]type = undefined;
        comptime var num_inputs: usize = 0;
        comptime var num_outputs: usize = 0;

        inline for (process_args) |arg| {
            const arg_is_input = @typeInfo(arg.type orelse unreachable).Pointer.is_const;
            if (arg_is_input) {
                comptime_inputs[num_inputs] = @typeInfo(arg.type orelse unreachable).Pointer.child;
                num_inputs += 1;
            } else {
                comptime_outputs[num_outputs] = @typeInfo(arg.type orelse unreachable).Pointer.child;
                num_outputs += 1;
            }
        }

        return ComptimeTypeSignature{
            .inputs = comptime_inputs[0..num_inputs],
            .outputs = comptime_outputs[0..num_outputs],
        };
    }

    pub fn getInputTypes(comptime self: *const ComptimeTypeSignature) []const type {
        comptime var data_types: [self.inputs.len]type = undefined;

        inline for (self.inputs, 0..) |input, i| {
            data_types[i] = input;
        }

        return data_types[0..];
    }

    pub fn getOutputTypes(comptime self: *const ComptimeTypeSignature) []const type {
        comptime var data_types: [self.outputs.len]type = undefined;

        inline for (self.outputs, 0..) |output, i| {
            data_types[i] = output;
        }

        return data_types[0..];
    }
};

////////////////////////////////////////////////////////////////////////////////
// Runtime Type Signatures
////////////////////////////////////////////////////////////////////////////////

pub const RuntimeDataType = enum {
    ComplexFloat32,
    ComplexFloat64,
    Float32,
    Float64,
    Unsigned8,
    Unsigned16,
    Unsigned32,
    Unsigned64,
    Signed8,
    Signed16,
    Signed32,
    Signed64,

    pub fn map(comptime data_type: type) RuntimeDataType {
        return switch (data_type) {
            std.math.Complex(f32) => RuntimeDataType.ComplexFloat32,
            std.math.Complex(f64) => RuntimeDataType.ComplexFloat64,
            f32 => RuntimeDataType.Float32,
            f64 => RuntimeDataType.Float64,
            u8 => RuntimeDataType.Unsigned8,
            u16 => RuntimeDataType.Unsigned16,
            u32 => RuntimeDataType.Unsigned32,
            u64 => RuntimeDataType.Unsigned64,
            i8 => RuntimeDataType.Signed8,
            i16 => RuntimeDataType.Signed16,
            i32 => RuntimeDataType.Signed32,
            i64 => RuntimeDataType.Signed64,
            else => unreachable,
        };
    }
};

pub const RuntimeTypeSignature = struct {
    inputs: []RuntimeDataType,
    outputs: []RuntimeDataType,

    pub fn init(comptime type_signature: ComptimeTypeSignature) RuntimeTypeSignature {
        comptime var runtime_inputs: [type_signature.inputs.len]RuntimeDataType = undefined;
        comptime var runtime_outputs: [type_signature.outputs.len]RuntimeDataType = undefined;

        inline for (type_signature.inputs, 0..) |input, i| runtime_inputs[i] = comptime RuntimeDataType.map(input);
        inline for (type_signature.outputs, 0..) |output, i| runtime_outputs[i] = comptime RuntimeDataType.map(output);

        return RuntimeTypeSignature{
            .inputs = runtime_inputs[0..],
            .outputs = runtime_outputs[0..],
        };
    }
};

////////////////////////////////////////////////////////////////////////////////
// ComptimeTypeSignature Tests
////////////////////////////////////////////////////////////////////////////////

test "ComptimeTypeSignature.init" {
    // 0 inputs, 0 outputs
    const TestProcess00 = struct {
        fn process(_: *@This()) void {}
    };
    const ts00 = ComptimeTypeSignature.init(TestProcess00.process);
    try std.testing.expectEqual(0, ts00.inputs.len);
    try std.testing.expectEqual(0, ts00.outputs.len);

    // 1 input, 0 outputs
    const TestProcess10 = struct {
        fn process(_: *@This(), _: []const u32) void {}
    };
    const ts10 = ComptimeTypeSignature.init(TestProcess10.process);
    try std.testing.expectEqual(1, ts10.inputs.len);
    try std.testing.expectEqual(u32, ts10.inputs[0]);
    try std.testing.expectEqual(0, ts10.outputs.len);

    // 0 inputs, 1 output
    const TestProcess01 = struct {
        fn process(_: *@This(), _: []u32) void {}
    };
    const ts01 = ComptimeTypeSignature.init(TestProcess01.process);
    try std.testing.expectEqual(0, ts01.inputs.len);
    try std.testing.expectEqual(1, ts01.outputs.len);
    try std.testing.expectEqual(u32, ts01.outputs[0]);

    // 1 input, 1 output
    const TestProcess11 = struct {
        fn process(_: *@This(), _: []const u16, _: []u8) void {}
    };
    const ts11 = ComptimeTypeSignature.init(TestProcess11.process);
    try std.testing.expectEqual(1, ts11.inputs.len);
    try std.testing.expectEqual(u16, ts11.inputs[0]);
    try std.testing.expectEqual(1, ts11.outputs.len);
    try std.testing.expectEqual(u8, ts11.outputs[0]);

    // 2 inputs, 2 outputs
    const TestProcess22 = struct {
        fn process(_: *@This(), _: []const u16, _: []const u32, _: []u8, _: []bool) void {}
    };
    const ts22 = ComptimeTypeSignature.init(TestProcess22.process);
    try std.testing.expectEqual(2, ts22.inputs.len);
    try std.testing.expectEqual(u16, ts22.inputs[0]);
    try std.testing.expectEqual(u32, ts22.inputs[1]);
    try std.testing.expectEqual(2, ts22.outputs.len);
    try std.testing.expectEqual(u8, ts22.outputs[0]);
    try std.testing.expectEqual(bool, ts22.outputs[1]);
}

test "ComptimeTypeSignature.getInputTypes" {
    // 2 inputs, 2 outputs
    const TestProcess22 = struct {
        fn process(_: *@This(), _: []const u16, _: []const u32, _: []u8, _: []bool) void {}
    };
    comptime var ts22 = ComptimeTypeSignature.init(TestProcess22.process);
    const input_types = ts22.getInputTypes();
    try std.testing.expectEqual(2, input_types.len);
    try std.testing.expectEqual(u16, input_types[0]);
    try std.testing.expectEqual(u32, input_types[1]);
}

test "ComptimeTypeSignature.getOutputTypes" {
    // 2 inputs, 2 outputs
    const TestProcess22 = struct {
        fn process(_: *@This(), _: []const u16, _: []const u32, _: []u8, _: []bool) void {}
    };
    comptime var ts22 = ComptimeTypeSignature.init(TestProcess22.process);
    const output_types = ts22.getOutputTypes();
    try std.testing.expectEqual(2, output_types.len);
    try std.testing.expectEqual(u8, output_types[0]);
    try std.testing.expectEqual(bool, output_types[1]);
}

////////////////////////////////////////////////////////////////////////////////
// RuntimeDataType Tests
////////////////////////////////////////////////////////////////////////////////

test "RuntimeDataType.map" {
    try std.testing.expectEqual(RuntimeDataType.ComplexFloat32, RuntimeDataType.map(std.math.Complex(f32)));
    try std.testing.expectEqual(RuntimeDataType.ComplexFloat64, RuntimeDataType.map(std.math.Complex(f64)));
    try std.testing.expectEqual(RuntimeDataType.Float32, RuntimeDataType.map(f32));
    try std.testing.expectEqual(RuntimeDataType.Float64, RuntimeDataType.map(f64));
    try std.testing.expectEqual(RuntimeDataType.Unsigned8, RuntimeDataType.map(u8));
    try std.testing.expectEqual(RuntimeDataType.Unsigned16, RuntimeDataType.map(u16));
    try std.testing.expectEqual(RuntimeDataType.Unsigned32, RuntimeDataType.map(u32));
    try std.testing.expectEqual(RuntimeDataType.Unsigned64, RuntimeDataType.map(u64));
    try std.testing.expectEqual(RuntimeDataType.Signed8, RuntimeDataType.map(i8));
    try std.testing.expectEqual(RuntimeDataType.Signed16, RuntimeDataType.map(i16));
    try std.testing.expectEqual(RuntimeDataType.Signed32, RuntimeDataType.map(i32));
    try std.testing.expectEqual(RuntimeDataType.Signed64, RuntimeDataType.map(i64));
}

////////////////////////////////////////////////////////////////////////////////
// RuntimeTypeSignature Tests
////////////////////////////////////////////////////////////////////////////////

test "RuntimeTypeSignature.init" {
    // 1 input, 0 outputs
    const TestProcess10 = struct {
        fn process(_: *@This(), _: []const u32) void {}
    };
    const ts10 = RuntimeTypeSignature.init(ComptimeTypeSignature.init(TestProcess10.process));
    try std.testing.expectEqualSlices(RuntimeDataType, &[1]RuntimeDataType{RuntimeDataType.Unsigned32}, ts10.inputs);
    try std.testing.expectEqualSlices(RuntimeDataType, &[0]RuntimeDataType{}, ts10.outputs);

    // 0 inputs, 1 outputs
    const TestProcess01 = struct {
        fn process(_: *@This(), _: []u32) void {}
    };
    const ts01 = RuntimeTypeSignature.init(ComptimeTypeSignature.init(TestProcess01.process));
    try std.testing.expectEqualSlices(RuntimeDataType, &[0]RuntimeDataType{}, ts01.inputs);
    try std.testing.expectEqualSlices(RuntimeDataType, &[1]RuntimeDataType{RuntimeDataType.Unsigned32}, ts01.outputs);

    // 1 inputs, 1 outputs
    const TestProcess11 = struct {
        fn process(_: *@This(), _: []const f32, _: []u32) void {}
    };
    const ts11 = RuntimeTypeSignature.init(ComptimeTypeSignature.init(TestProcess11.process));
    try std.testing.expectEqualSlices(RuntimeDataType, &[1]RuntimeDataType{RuntimeDataType.Float32}, ts11.inputs);
    try std.testing.expectEqualSlices(RuntimeDataType, &[1]RuntimeDataType{RuntimeDataType.Unsigned32}, ts11.outputs);

    // 2 inputs, 2 outputs
    const TestProcess22 = struct {
        fn process(_: *@This(), _: []const f32, _: []const u16, _: []u32, _: []f64) void {}
    };
    const ts22 = RuntimeTypeSignature.init(ComptimeTypeSignature.init(TestProcess22.process));
    try std.testing.expectEqualSlices(RuntimeDataType, &[2]RuntimeDataType{ RuntimeDataType.Float32, RuntimeDataType.Unsigned16 }, ts22.inputs);
    try std.testing.expectEqualSlices(RuntimeDataType, &[2]RuntimeDataType{ RuntimeDataType.Unsigned32, RuntimeDataType.Float64 }, ts22.outputs);
}
