const std = @import("std");

////////////////////////////////////////////////////////////////////////////////
// Comptime Type Signatures
////////////////////////////////////////////////////////////////////////////////

pub const ComptimeTypeSignature = struct {
    inputs: []const type,
    outputs: []const type,

    pub fn init(comptime process_fn: anytype) ComptimeTypeSignature {
        const process_args = @typeInfo(@TypeOf(process_fn)).Fn.params[1..];

        var _comptime_inputs: [process_args.len]type = undefined;
        var _comptime_outputs: [process_args.len]type = undefined;
        var num_inputs: usize = 0;
        var num_outputs: usize = 0;

        inline for (process_args) |arg| {
            const arg_is_input = @typeInfo(arg.type orelse unreachable).Pointer.is_const;
            if (arg_is_input) {
                _comptime_inputs[num_inputs] = @typeInfo(arg.type orelse unreachable).Pointer.child;
                num_inputs += 1;
            } else {
                _comptime_outputs[num_outputs] = @typeInfo(arg.type orelse unreachable).Pointer.child;
                num_outputs += 1;
            }
        }

        const comptime_inputs = _comptime_inputs;
        const comptime_outputs = _comptime_outputs;

        return ComptimeTypeSignature{
            .inputs = comptime_inputs[0..num_inputs],
            .outputs = comptime_outputs[0..num_outputs],
        };
    }
};

////////////////////////////////////////////////////////////////////////////////
// Runtime Type Signatures
////////////////////////////////////////////////////////////////////////////////

pub const RuntimeTypeSignature = struct {
    inputs: []const []const u8,
    outputs: []const []const u8,

    pub fn map(comptime data_type: type) []const u8 {
        return switch (data_type) {
            std.math.Complex(f32) => "ComplexFloat32",
            std.math.Complex(f64) => "ComplexFloat64",
            f32 => "Float32",
            f64 => "Float64",
            u8 => "Unsigned8",
            u16 => "Unsigned16",
            u32 => "Unsigned32",
            u64 => "Unsigned64",
            i8 => "Signed8",
            i16 => "Signed16",
            i32 => "Signed32",
            i64 => "Signed64",
            else => {
                if (@hasDecl(data_type, "typeName")) return data_type.typeName();
                @compileError("User-defined type " ++ @typeName(data_type) ++ " is missing a typeName() getter.");
            },
        };
    }

    pub fn init(comptime type_signature: ComptimeTypeSignature) RuntimeTypeSignature {
        comptime var _runtime_inputs: [type_signature.inputs.len][]const u8 = undefined;
        comptime var _runtime_outputs: [type_signature.outputs.len][]const u8 = undefined;

        inline for (type_signature.inputs, 0..) |input, i| _runtime_inputs[i] = comptime RuntimeTypeSignature.map(input);
        inline for (type_signature.outputs, 0..) |output, i| _runtime_outputs[i] = comptime RuntimeTypeSignature.map(output);

        const runtime_inputs = _runtime_inputs;
        const runtime_outputs = _runtime_outputs;

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

////////////////////////////////////////////////////////////////////////////////
// RuntimeTypeSignature Tests
////////////////////////////////////////////////////////////////////////////////

const Foo = struct {
    a: f32,
    b: f32,

    pub fn typeName() []const u8 {
        return "Foo";
    }
};

const Bar = Foo;

test "RuntimeTypeSignature.map" {
    try std.testing.expectEqualStrings("ComplexFloat32", RuntimeTypeSignature.map(std.math.Complex(f32)));
    try std.testing.expectEqualStrings("ComplexFloat64", RuntimeTypeSignature.map(std.math.Complex(f64)));
    try std.testing.expectEqualStrings("Float32", RuntimeTypeSignature.map(f32));
    try std.testing.expectEqualStrings("Float64", RuntimeTypeSignature.map(f64));
    try std.testing.expectEqualStrings("Unsigned8", RuntimeTypeSignature.map(u8));
    try std.testing.expectEqualStrings("Unsigned16", RuntimeTypeSignature.map(u16));
    try std.testing.expectEqualStrings("Unsigned32", RuntimeTypeSignature.map(u32));
    try std.testing.expectEqualStrings("Unsigned64", RuntimeTypeSignature.map(u64));
    try std.testing.expectEqualStrings("Signed8", RuntimeTypeSignature.map(i8));
    try std.testing.expectEqualStrings("Signed16", RuntimeTypeSignature.map(i16));
    try std.testing.expectEqualStrings("Signed32", RuntimeTypeSignature.map(i32));
    try std.testing.expectEqualStrings("Signed64", RuntimeTypeSignature.map(i64));
    try std.testing.expectEqualStrings("Foo", RuntimeTypeSignature.map(Foo));
    try std.testing.expectEqualStrings("Foo", RuntimeTypeSignature.map(Bar));
}

test "RuntimeTypeSignature.init" {
    // 1 input, 0 outputs
    const TestProcess10 = struct {
        fn process(_: *@This(), _: []const u32) void {}
    };
    const ts10 = RuntimeTypeSignature.init(ComptimeTypeSignature.init(TestProcess10.process));
    try std.testing.expectEqual(1, ts10.inputs.len);
    try std.testing.expectEqualStrings("Unsigned32", ts10.inputs[0]);
    try std.testing.expectEqual(0, ts10.outputs.len);

    // 0 inputs, 1 outputs
    const TestProcess01 = struct {
        fn process(_: *@This(), _: []u32) void {}
    };
    const ts01 = RuntimeTypeSignature.init(ComptimeTypeSignature.init(TestProcess01.process));
    try std.testing.expectEqual(0, ts01.inputs.len);
    try std.testing.expectEqual(1, ts01.outputs.len);
    try std.testing.expectEqualStrings("Unsigned32", ts01.outputs[0]);

    // 1 inputs, 1 outputs
    const TestProcess11 = struct {
        fn process(_: *@This(), _: []const f32, _: []u32) void {}
    };
    const ts11 = RuntimeTypeSignature.init(ComptimeTypeSignature.init(TestProcess11.process));
    try std.testing.expectEqual(1, ts11.inputs.len);
    try std.testing.expectEqualStrings("Float32", ts11.inputs[0]);
    try std.testing.expectEqual(1, ts11.outputs.len);
    try std.testing.expectEqualStrings("Unsigned32", ts11.outputs[0]);

    // 2 inputs, 2 outputs
    const TestProcess22 = struct {
        fn process(_: *@This(), _: []const f32, _: []const u16, _: []u32, _: []f64) void {}
    };
    const ts22 = RuntimeTypeSignature.init(ComptimeTypeSignature.init(TestProcess22.process));
    try std.testing.expectEqual(2, ts22.inputs.len);
    try std.testing.expectEqualStrings("Float32", ts22.inputs[0]);
    try std.testing.expectEqualStrings("Unsigned16", ts22.inputs[1]);
    try std.testing.expectEqual(2, ts22.outputs.len);
    try std.testing.expectEqualStrings("Unsigned32", ts22.outputs[0]);
    try std.testing.expectEqualStrings("Float64", ts22.outputs[1]);

    // 2 inputs, 1 outputs, with user defined type
    const TestProcess21 = struct {
        fn process(_: *@This(), _: []const f32, _: []const u16, _: []Foo) void {}
    };
    const ts21 = RuntimeTypeSignature.init(ComptimeTypeSignature.init(TestProcess21.process));
    try std.testing.expectEqual(2, ts21.inputs.len);
    try std.testing.expectEqualStrings("Float32", ts21.inputs[0]);
    try std.testing.expectEqualStrings("Unsigned16", ts21.inputs[1]);
    try std.testing.expectEqual(1, ts21.outputs.len);
    try std.testing.expectEqualStrings("Foo", ts21.outputs[0]);
}
