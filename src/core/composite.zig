const std = @import("std");

const extractBlockName = @import("block.zig").extractBlockName;

const Flowgraph = @import("flowgraph.zig").Flowgraph;

////////////////////////////////////////////////////////////////////////////////
// Helper Functions
////////////////////////////////////////////////////////////////////////////////

fn wrapConnectFunction(comptime block_type: anytype, comptime connect_fn: anytype) fn (self: *CompositeBlock, flowgraph: *Flowgraph) anyerror!void {
    const impl = struct {
        fn connect(block: *CompositeBlock, flowgraph: *Flowgraph) anyerror!void {
            const self: *block_type = @fieldParentPtr("composite", block);

            try connect_fn(self, flowgraph);
        }
    };
    return impl.connect;
}

////////////////////////////////////////////////////////////////////////////////
// CompositeBlock
////////////////////////////////////////////////////////////////////////////////

pub const CompositeBlock = struct {
    name: []const u8,
    inputs: []const []const u8,
    outputs: []const []const u8,

    _connect_fn: *const fn (self: *CompositeBlock, flowgraph: *Flowgraph) anyerror!void,

    pub fn init(comptime block_type: type, inputs: []const []const u8, outputs: []const []const u8) CompositeBlock {
        return CompositeBlock{
            .name = comptime extractBlockName(block_type),
            .inputs = inputs,
            .outputs = outputs,
            ._connect_fn = wrapConnectFunction(block_type, @field(block_type, "connect")),
        };
    }

    pub fn connect(self: *CompositeBlock, flowgraph: *Flowgraph) !void {
        try self._connect_fn(self, flowgraph);
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
