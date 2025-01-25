const std = @import("std");

const Flowgraph = @import("flowgraph.zig").Flowgraph;

const extractBlockName = @import("block.zig").extractBlockName;

////////////////////////////////////////////////////////////////////////////////
// Helper Functions
////////////////////////////////////////////////////////////////////////////////

fn wrapConnectFunction(comptime CompositeType: anytype, comptime connectFn: fn (self: *CompositeType, flowgraph: *Flowgraph) anyerror!void) fn (self: *CompositeBlock, flowgraph: *Flowgraph) anyerror!void {
    const gen = struct {
        fn connect(block: *CompositeBlock, flowgraph: *Flowgraph) anyerror!void {
            const self: *CompositeType = @fieldParentPtr("composite", block);
            try connectFn(self, flowgraph);
        }
    };
    return gen.connect;
}

////////////////////////////////////////////////////////////////////////////////
// CompositeBlock
////////////////////////////////////////////////////////////////////////////////

pub const CompositeBlock = struct {
    name: []const u8,
    inputs: []const []const u8,
    outputs: []const []const u8,
    connect_fn: *const fn (self: *CompositeBlock, flowgraph: *Flowgraph) anyerror!void,

    pub fn init(comptime CompositeType: type, inputs: []const []const u8, outputs: []const []const u8) CompositeBlock {
        // Composite needs to have a connect method
        if (!@hasDecl(CompositeType, "connect")) {
            @compileError("Composite " ++ @typeName(CompositeType) ++ " is missing the connect() method.");
        }

        return .{
            .name = comptime extractBlockName(CompositeType),
            .inputs = inputs,
            .outputs = outputs,
            .connect_fn = comptime wrapConnectFunction(CompositeType, CompositeType.connect),
        };
    }

    pub fn connect(self: *CompositeBlock, flowgraph: *Flowgraph) !void {
        try self.connect_fn(self, flowgraph);
    }
};

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const TestCompositeBlock = struct {
    composite: CompositeBlock,
    connect_called: bool,

    pub fn init() TestCompositeBlock {
        return .{
            .composite = CompositeBlock.init(@This(), &[_][]const u8{ "in1", "in2" }, &[_][]const u8{ "out1", "out2" }),
            .connect_called = false,
        };
    }

    pub fn connect(self: *TestCompositeBlock, _: *Flowgraph) !void {
        self.connect_called = true;
    }
};

test "CompositeBlock.init" {
    var test_block = TestCompositeBlock.init();

    try std.testing.expectEqualSlices(u8, test_block.composite.name, "TestCompositeBlock");
    try std.testing.expectEqual(test_block.composite.inputs.len, 2);
    try std.testing.expectEqual(test_block.composite.outputs.len, 2);

    try std.testing.expectEqualSlices(u8, test_block.composite.inputs[0], "in1");
    try std.testing.expectEqualSlices(u8, test_block.composite.inputs[1], "in2");
    try std.testing.expectEqualSlices(u8, test_block.composite.outputs[0], "out1");
    try std.testing.expectEqualSlices(u8, test_block.composite.outputs[1], "out2");

    var top = Flowgraph.init(std.testing.allocator, .{});
    defer top.deinit();

    try std.testing.expectEqual(false, test_block.connect_called);
    try test_block.composite.connect(&top);
    try std.testing.expectEqual(true, test_block.connect_called);
}
