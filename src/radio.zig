// Version
pub const version = @import("std").SemanticVersion{ .major = 0, .minor = 1, .patch = 0 };

// Top-level
pub const Block = @import("core/block.zig").Block;
pub const ProcessResult = @import("core/block.zig").ProcessResult;
pub const Flowgraph = @import("core/flowgraph.zig").Flowgraph;

// Subpackages
pub const platform = @import("core/platform.zig");
pub const testing = @import("core/testing.zig");
pub const utils = @import("utils/index.zig");
pub const blocks = @import("blocks/index.zig");

// Pull in all tests
test {
    @import("std").testing.refAllDecls(@This());
}
