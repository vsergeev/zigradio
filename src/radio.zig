// Top-level
pub const Block = @import("core/block.zig").Block;
pub const ProcessResult = @import("core/block.zig").ProcessResult;
pub const Flowgraph = @import("core/flowgraph.zig").Flowgraph;

// Subpackages
pub const testing = @import("core/testing.zig");

// Pull in all tests
test {
    @import("std").testing.refAllDecls(@This());
}
