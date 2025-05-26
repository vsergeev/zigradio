const std = @import("std");

////////////////////////////////////////////////////////////////////////////////
// Comptime Type Signatures
////////////////////////////////////////////////////////////////////////////////

pub const ComptimeTypeSignature = struct {
    inputs: []const type,
    outputs: []const type,

    pub fn init(comptime process_fn: anytype) ComptimeTypeSignature {
        const process_args = @typeInfo(@TypeOf(process_fn)).@"fn".params[1..];

        var _comptime_inputs: [process_args.len]type = undefined;
        var _comptime_outputs: [process_args.len]type = undefined;
        var num_inputs: usize = 0;
        var num_outputs: usize = 0;

        inline for (process_args) |arg| {
            const arg_is_input = @typeInfo(arg.type orelse unreachable).pointer.is_const;
            if (arg_is_input) {
                _comptime_inputs[num_inputs] = @typeInfo(arg.type orelse unreachable).pointer.child;
                num_inputs += 1;
            } else {
                _comptime_outputs[num_outputs] = @typeInfo(arg.type orelse unreachable).pointer.child;
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

    pub fn fromTypes(comptime input_data_types: []const type, comptime output_data_types: []const type) ComptimeTypeSignature {
        return .{ .inputs = input_data_types, .outputs = output_data_types };
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
            u1 => "Bit",
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
// Special Types
////////////////////////////////////////////////////////////////////////////////

const TypeTag = enum {
    RefCounted,
};

pub fn hasTypeTag(T: type, tag: TypeTag) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "typeTag") and T.typeTag() == tag;
}

pub fn RefCounted(T: type) type {
    // Atomic reference count implementation based on zig stdlib atomic.zig and
    // https://www.boost.org/doc/libs/1_87_0/libs/atomic/doc/html/atomic/usage_examples.html#boost_atomic.usage_examples.example_reference_counters
    return struct {
        const Self = @This();

        value: T,
        rc: std.atomic.Value(usize),

        pub fn init(args: anytype) Self {
            return .{ .value = @call(.auto, T.init, args), .rc = std.atomic.Value(usize).init(1) };
        }

        pub fn ref(self: *Self, count: usize) void {
            _ = self.rc.fetchAdd(count, .monotonic);
        }

        pub fn unref(self: *Self) void {
            if (self.rc.fetchSub(1, .acq_rel) == 1) {
                self.value.deinit();
            }
        }

        pub fn typeName() []const u8 {
            return "RefCounted(" ++ comptime RuntimeTypeSignature.map(T) ++ ")";
        }

        pub fn typeTag() TypeTag {
            return .RefCounted;
        }
    };
}

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

test "ComptimeTypeSignature.fromTypes" {
    const ts = ComptimeTypeSignature.fromTypes(&[2]type{ f32, u16 }, &[1]type{u8});
    try std.testing.expectEqual(2, ts.inputs.len);
    try std.testing.expectEqual(f32, ts.inputs[0]);
    try std.testing.expectEqual(u16, ts.inputs[1]);
    try std.testing.expectEqual(1, ts.outputs.len);
    try std.testing.expectEqual(u8, ts.outputs[0]);
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

const Foo2 = Foo;

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
    try std.testing.expectEqualStrings("Foo", RuntimeTypeSignature.map(Foo2));
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

////////////////////////////////////////////////////////////////////////////////
// RefCounted Tests
////////////////////////////////////////////////////////////////////////////////

const Bar = struct {
    x: usize,
    valid: bool,

    pub fn init(x: usize) Bar {
        return .{ .x = x, .valid = true };
    }

    pub fn deinit(self: *Bar) void {
        self.valid = false;
    }

    pub fn typeName() []const u8 {
        return "Bar";
    }
};

test "RefCounted" {
    try std.testing.expectEqualStrings("RefCounted(Bar)", RefCounted(Bar).typeName());
    try std.testing.expectEqual(false, hasTypeTag(Bar, .RefCounted));
    try std.testing.expectEqual(true, hasTypeTag(RefCounted(Bar), .RefCounted));

    var bar = RefCounted(Bar).init(.{123});
    try std.testing.expectEqual(123, bar.value.x);
    try std.testing.expectEqual(true, bar.value.valid);
    try std.testing.expectEqual(1, bar.rc.load(.seq_cst));

    bar.ref(1);
    try std.testing.expectEqual(2, bar.rc.load(.seq_cst));

    bar.unref();
    try std.testing.expectEqual(true, bar.value.valid);
    bar.unref();
    try std.testing.expectEqual(false, bar.value.valid);
}
