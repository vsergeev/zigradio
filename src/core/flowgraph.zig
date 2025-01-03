const std = @import("std");

const util = @import("util.zig");

const Block = @import("block.zig").Block;
const CompositeBlock = @import("composite.zig").CompositeBlock;
const RuntimeDataType = @import("type_signature.zig").RuntimeDataType;

const ThreadSafeRingBuffer = @import("ring_buffer.zig").ThreadSafeRingBuffer;
const ThreadedBlockRunner = @import("runner.zig").ThreadedBlockRunner;

////////////////////////////////////////////////////////////////////////////////
// Flowgraph Errors
////////////////////////////////////////////////////////////////////////////////

pub const FlowgraphError = error{
    InvalidPortCount,
    PortNotFound,
    UnderlyingPortNotFound,
    PortAlreadyConnected,
    InputPortUnconnected,
    CyclicDependency,
    RateMismatch,
    NotRunning,
    AlreadyRunning,
};

////////////////////////////////////////////////////////////////////////////////
// Port
////////////////////////////////////////////////////////////////////////////////

const BlockVariant = union(enum) {
    block: *Block,
    composite: *CompositeBlock,

    pub fn wrap(element: anytype) BlockVariant {
        return if (@TypeOf(element) == *Block) BlockVariant{ .block = element } else BlockVariant{ .composite = element };
    }
};

const InputPort = struct {
    block: BlockVariant,
    index: usize,
};

const OutputPort = struct {
    block: BlockVariant,
    index: usize,
};

const BlockInputPort = struct {
    block: *Block,
    index: usize,
};

const BlockOutputPort = struct {
    block: *Block,
    index: usize,
};

////////////////////////////////////////////////////////////////////////////////
// Helper Functions
////////////////////////////////////////////////////////////////////////////////

fn buildEvaluationOrder(allocator: std.mem.Allocator, flattened_connections: *const std.AutoHashMap(BlockInputPort, BlockOutputPort), block_set: *const std.AutoHashMap(*Block, void)) !std.AutoArrayHashMap(*Block, void) {
    var block_set_copy = try block_set.cloneWithAllocator(allocator);
    defer block_set_copy.deinit();

    var evaluation_order = std.AutoArrayHashMap(*Block, void).init(allocator);
    errdefer evaluation_order.deinit();

    const num_blocks = block_set_copy.count();
    while (evaluation_order.count() < num_blocks) {
        // For each block left in the block set
        var block_it = block_set_copy.keyIterator();
        const next_block: ?*Block = outer: while (block_it.next()) |k| {
            // For each input to the block
            for (0..k.*.inputs.len) |i| {
                // Check if upstream block is already in our evaluation order
                const upstream_block = flattened_connections.get(BlockInputPort{ .block = k.*, .index = i }).?.block;
                if (!evaluation_order.contains(upstream_block)) {
                    // Continue to next block
                    continue :outer;
                }
            }
            // Yield this block to add
            break k.*;
        } else null;

        // If we couldn't find a block to add, there is a dependency cycle
        if (next_block == null) return FlowgraphError.CyclicDependency;

        // Move the block from our set to our evaluation order
        _ = block_set_copy.remove(next_block.?);
        try evaluation_order.put(next_block.?, {});
    }

    return evaluation_order;
}

////////////////////////////////////////////////////////////////////////////////
// Flowgraph Run State
////////////////////////////////////////////////////////////////////////////////

const FlowgraphRunState = struct {
    ring_buffers: std.AutoHashMap(BlockOutputPort, ThreadSafeRingBuffer),
    block_runners: std.ArrayList(ThreadedBlockRunner),

    const RING_BUFFER_SIZE = 2 * 1048576;

    pub fn init(allocator: std.mem.Allocator, flattened_connections: *const std.AutoHashMap(BlockInputPort, BlockOutputPort), block_set: *const std.AutoHashMap(*Block, void)) !FlowgraphRunState {
        // Allocate ring buffer map
        var ring_buffers = std.AutoHashMap(BlockOutputPort, ThreadSafeRingBuffer).init(allocator);
        errdefer {
            var ring_buffers_it = ring_buffers.valueIterator();
            while (ring_buffers_it.next()) |ring_buffer| ring_buffer.deinit();
            ring_buffers.deinit();
        }

        // Allocate block runner list
        var block_runners = std.ArrayList(ThreadedBlockRunner).init(allocator);
        errdefer block_runners.deinit();

        // For each connection, create an output ring buffer
        var output_it = flattened_connections.valueIterator();
        while (output_it.next()) |output| {
            if (ring_buffers.contains(output.*)) continue;
            try ring_buffers.put(output.*, try ThreadSafeRingBuffer.init(allocator, RING_BUFFER_SIZE));
        }

        // Temporary storage for input and output ring buffer slices
        var input_ring_buffers = std.ArrayList(*ThreadSafeRingBuffer).init(allocator);
        defer input_ring_buffers.deinit();
        var output_ring_buffers = std.ArrayList(*ThreadSafeRingBuffer).init(allocator);
        defer output_ring_buffers.deinit();

        // For each block, collect ring buffers and create a block runner
        var block_it = block_set.keyIterator();
        while (block_it.next()) |block| {
            // Clear temporary ring buffer arrays
            input_ring_buffers.clearRetainingCapacity();
            output_ring_buffers.clearRetainingCapacity();

            // Collect input ring buffers
            for (0..block.*.inputs.len) |i| {
                const output = flattened_connections.get(BlockInputPort{ .block = block.*, .index = i }).?;
                try input_ring_buffers.append(ring_buffers.getPtr(output).?);
            }

            // Collect output ring buffers
            for (0..block.*.outputs.len) |i| {
                try output_ring_buffers.append(ring_buffers.getPtr(BlockOutputPort{ .block = block.*, .index = i }).?);
            }

            // Create block runner
            try block_runners.append(try ThreadedBlockRunner.init(allocator, block.*, input_ring_buffers.items, output_ring_buffers.items));
        }

        return .{
            .ring_buffers = ring_buffers,
            .block_runners = block_runners,
        };
    }

    pub fn deinit(self: *FlowgraphRunState) void {
        for (self.block_runners.items) |*block_runner| block_runner.deinit();
        self.block_runners.deinit();

        var ring_buffers_it = self.ring_buffers.valueIterator();
        while (ring_buffers_it.next()) |ring_buffer| ring_buffer.deinit();
        self.ring_buffers.deinit();
    }
};

////////////////////////////////////////////////////////////////////////////////
// Flowgraph
////////////////////////////////////////////////////////////////////////////////

pub const Flowgraph = struct {
    pub const Options = struct {
        debug: bool = false,
    };

    allocator: std.mem.Allocator,
    options: Options,

    input_aliases: std.AutoHashMap(InputPort, std.ArrayList(InputPort)),
    output_aliases: std.AutoHashMap(OutputPort, OutputPort),
    connections: std.AutoHashMap(InputPort, OutputPort),
    flattened_connections: std.AutoHashMap(BlockInputPort, BlockOutputPort),
    block_set: std.AutoHashMap(*Block, void),
    composite_set: std.AutoHashMap(*CompositeBlock, void),
    run_state: ?FlowgraphRunState = null,

    pub fn init(allocator: std.mem.Allocator, options: Options) Flowgraph {
        return .{
            .allocator = allocator,
            .options = options,
            .input_aliases = std.AutoHashMap(InputPort, std.ArrayList(InputPort)).init(allocator),
            .output_aliases = std.AutoHashMap(OutputPort, OutputPort).init(allocator),
            .connections = std.AutoHashMap(InputPort, OutputPort).init(allocator),
            .flattened_connections = std.AutoHashMap(BlockInputPort, BlockOutputPort).init(allocator),
            .block_set = std.AutoHashMap(*Block, void).init(allocator),
            .composite_set = std.AutoHashMap(*CompositeBlock, void).init(allocator),
        };
    }

    pub fn deinit(self: *Flowgraph) void {
        if (self.run_state) |*run_state| run_state.deinit();

        self.composite_set.deinit();
        self.block_set.deinit();
        self.flattened_connections.deinit();
        self.connections.deinit();

        self.output_aliases.deinit();
        var input_aliases_it = self.input_aliases.valueIterator();
        while (input_aliases_it.next()) |input_aliases| input_aliases.deinit();
        self.input_aliases.deinit();
    }

    pub fn _connect(self: *Flowgraph, src_port: OutputPort, dst_port: InputPort) !void {
        if (self.connections.contains(dst_port)) return FlowgraphError.PortAlreadyConnected;

        try self.connections.put(dst_port, src_port);

        switch (src_port.block) {
            BlockVariant.block => try self.block_set.put(src_port.block.block, {}),
            BlockVariant.composite => {
                if (!self.composite_set.contains(src_port.block.composite)) {
                    try self.composite_set.put(src_port.block.composite, {});
                    try src_port.block.composite.*.connect(self);
                }
            },
        }

        switch (dst_port.block) {
            BlockVariant.block => try self.block_set.put(dst_port.block.block, {}),
            BlockVariant.composite => {
                if (!self.composite_set.contains(dst_port.block.composite)) {
                    try self.composite_set.put(dst_port.block.composite, {});
                    try dst_port.block.composite.*.connect(self);
                }
            },
        }

        // Crawl aliases for underlying source port
        var underlying_src_port = src_port;
        while (underlying_src_port.block != BlockVariant.block) {
            underlying_src_port = self.output_aliases.get(underlying_src_port) orelse return FlowgraphError.UnderlyingPortNotFound;
        }

        // Crawl aliases for underlying destination ports
        var underlying_dst_ports = std.ArrayList(InputPort).init(self.allocator);
        defer underlying_dst_ports.deinit();
        try underlying_dst_ports.append(dst_port);

        while (underlying_dst_ports.items.len > 0) {
            const next_dst_port = underlying_dst_ports.pop();

            if (next_dst_port.block == BlockVariant.block) {
                // Add flattened connection from underlying source port to underlying destination port
                try self.flattened_connections.put(BlockInputPort{ .block = next_dst_port.block.block, .index = next_dst_port.index }, BlockOutputPort{ .block = underlying_src_port.block.block, .index = underlying_src_port.index });
            } else {
                const aliased_ports = self.input_aliases.get(next_dst_port) orelse return FlowgraphError.UnderlyingPortNotFound;
                try underlying_dst_ports.appendSlice(aliased_ports.items);
            }
        }
    }

    pub fn connect(self: *Flowgraph, src: anytype, dst: anytype) !void {
        if (@TypeOf(src) != *Block and @TypeOf(src) != *CompositeBlock) @compileError("Unsupported src type, expected *Block or *CompositeBlock");
        if (@TypeOf(dst) != *Block and @TypeOf(dst) != *CompositeBlock) @compileError("Unsupported dst type, expected *Block or *CompositeBlock");

        if (src.outputs.len != 1) return FlowgraphError.InvalidPortCount;
        if (dst.inputs.len != 1) return FlowgraphError.InvalidPortCount;

        const src_port = OutputPort{ .block = BlockVariant.wrap(src), .index = 0 };
        const dst_port = InputPort{ .block = BlockVariant.wrap(dst), .index = 0 };

        try self._connect(src_port, dst_port);
    }

    pub fn connectPort(self: *Flowgraph, src: anytype, src_port_name: []const u8, dst: anytype, dst_port_name: []const u8) !void {
        if (@TypeOf(src) != *Block and @TypeOf(src) != *CompositeBlock) @compileError("Unsupported src type, expected *Block or *CompositeBlock");
        if (@TypeOf(dst) != *Block and @TypeOf(dst) != *CompositeBlock) @compileError("Unsupported dst type, expected *Block or *CompositeBlock");

        const src_port = OutputPort{ .block = BlockVariant.wrap(src), .index = util.indexOfString(src.outputs, src_port_name) orelse return FlowgraphError.PortNotFound };
        const dst_port = InputPort{ .block = BlockVariant.wrap(dst), .index = util.indexOfString(dst.inputs, dst_port_name) orelse return FlowgraphError.PortNotFound };

        try self._connect(src_port, dst_port);
    }

    pub fn alias(self: *Flowgraph, composite: *CompositeBlock, port_name: []const u8, aliased_block: anytype, aliased_port_name: []const u8) !void {
        if (@TypeOf(aliased_block) != *Block and @TypeOf(aliased_block) != *CompositeBlock) @compileError("Unsupported aliased_block type, expected *Block or *CompositeBlock");

        if (@TypeOf(aliased_block) == *CompositeBlock) {
            if (!self.composite_set.contains(aliased_block)) {
                try self.composite_set.put(aliased_block, {});
                try aliased_block.connect(self);
            }
        }

        if (util.indexOfString(composite.inputs, port_name)) |index| {
            const composite_port = InputPort{ .block = BlockVariant.wrap(composite), .index = index };
            const aliased_port = InputPort{ .block = BlockVariant.wrap(aliased_block), .index = util.indexOfString(aliased_block.inputs, aliased_port_name) orelse return FlowgraphError.PortNotFound };

            if (!self.input_aliases.contains(composite_port)) {
                try self.input_aliases.put(composite_port, std.ArrayList(InputPort).init(self.allocator));
            }

            try self.input_aliases.getPtr(composite_port).?.append(aliased_port);
        } else if (util.indexOfString(composite.outputs, port_name)) |index| {
            const composite_port = OutputPort{ .block = BlockVariant.wrap(composite), .index = index };
            const aliased_port = OutputPort{ .block = BlockVariant.wrap(aliased_block), .index = util.indexOfString(aliased_block.outputs, aliased_port_name) orelse return FlowgraphError.PortNotFound };

            try self.output_aliases.putNoClobber(composite_port, aliased_port);
        } else {
            return FlowgraphError.PortNotFound;
        }
    }

    pub fn _validate(self: *Flowgraph) !void {
        // For each block in the block set
        var block_it = self.block_set.keyIterator();
        while (block_it.next()) |k| {
            // Check all inputs are connected
            for (0..k.*.inputs.len) |i| {
                if (!self.flattened_connections.contains(BlockInputPort{ .block = k.*, .index = i })) {
                    return FlowgraphError.InputPortUnconnected;
                }
            }
        }
    }

    pub fn _differentiate(self: *Flowgraph, evaluation_order: *const std.AutoArrayHashMap(*Block, void)) !void {
        // For each block in the evaluation order
        for (evaluation_order.keys()) |block| {
            // Allocate a slice for input types
            var input_types: []RuntimeDataType = try self.allocator.alloc(RuntimeDataType, block.inputs.len);
            defer self.allocator.free(input_types);

            // For each block input port, collect the type of the connected output port
            for (0..block.inputs.len) |i| {
                const output_port = self.flattened_connections.get(BlockInputPort{ .block = block, .index = i }).?;
                input_types[i] = try output_port.block.getOutputType(output_port.index);
            }

            // Get upstream rate
            const upstream_rate = if (block.inputs.len > 0) try self.flattened_connections.get(BlockInputPort{ .block = block, .index = 0 }).?.block.getRate(f64) else 0;

            // Differentiate the block
            try block.differentiate(input_types, upstream_rate);

            // Compare other input port rates
            var i: usize = 1;
            while (i < block.inputs.len) : (i += 1) {
                const rate = try self.flattened_connections.get(BlockInputPort{ .block = block, .index = i }).?.block.getRate(f64);
                if (rate != upstream_rate) return FlowgraphError.RateMismatch;
            }
        }
    }

    pub fn _initialize(self: *Flowgraph) !void {
        // Validate flowgraph
        try self._validate();

        // Build the evaluation order
        var evaluation_order = try buildEvaluationOrder(self.allocator, &self.flattened_connections, &self.block_set);
        defer evaluation_order.deinit();

        // Differentiate flowgraph
        try self._differentiate(&evaluation_order);

        // Dump flowgraph if debug is enabled
        if (self.options.debug) {
            self._dump(&evaluation_order);
        }

        // Initialize blocks
        for (evaluation_order.keys()) |block| try block.initialize(self.allocator);
    }

    pub fn _deinitialize(self: *Flowgraph) void {
        // Deinitialize blocks
        var block_it = self.block_set.keyIterator();
        while (block_it.next()) |block| {
            block.*.deinitialize(self.allocator);
        }
    }

    fn _dump(self: *Flowgraph, evaluation_order: *std.AutoArrayHashMap(*Block, void)) void {
        std.debug.print("[Flowgraph] Flow graph:\n", .{});

        // For each block in the evaluation order
        for (evaluation_order.keys()) |block| {
            std.debug.print("[Flowgraph]    {s} [{d} Hz]\n", .{ block.name, block.getRate(f64) catch unreachable });

            // For each input port
            for (0..block.inputs.len) |i| {
                const input_port_name = block.inputs[i];
                const input_port_type = block.getInputType(i) catch unreachable;
                const output_port = self.flattened_connections.get(BlockInputPort{ .block = block, .index = i }).?;
                const output_port_name = output_port.block.outputs[output_port.index];
                const block_name = output_port.block.name;
                std.debug.print("[Flowgraph]        .{s} [{any}] <- {s}.{s}\n", .{ input_port_name, input_port_type, block_name, output_port_name });
            }

            // For each output port
            for (0..block.outputs.len) |i| {
                const output_port_name = block.outputs[i];
                const output_port_type = block.getOutputType(i) catch unreachable;

                std.debug.print("[Flowgraph]        .{s} [{any}] -> ", .{ output_port_name, output_port_type });

                // Find all connected input ports (quadratic, but this is a debug dump)
                var it = self.flattened_connections.keyIterator();
                var print_separator = false;
                while (it.next()) |input_port| {
                    const output_port = self.flattened_connections.get(input_port.*).?;
                    if (output_port.block == block and output_port.index == i) {
                        const input_port_name = input_port.block.inputs[input_port.index];
                        const block_name = input_port.block.name;
                        if (print_separator) std.debug.print(", ", .{});
                        std.debug.print("{s}.{s}", .{ block_name, input_port_name });
                        print_separator = true;
                    }
                }

                std.debug.print("\n", .{});
            }
        }
    }

    pub fn start(self: *Flowgraph) !void {
        if (self.run_state != null) return FlowgraphError.AlreadyRunning;

        // Differentiate and initialize blocks
        try self._initialize();

        // Build run state
        self.run_state = try FlowgraphRunState.init(self.allocator, &self.flattened_connections, &self.block_set);

        // Spawn block runners
        for (self.run_state.?.block_runners.items) |*block_runner| {
            try block_runner.spawn();
        }
    }

    pub fn wait(self: *Flowgraph) !void {
        if (self.run_state == null) return FlowgraphError.NotRunning;

        // Join all block runners
        for (self.run_state.?.block_runners.items) |*block_runner| {
            block_runner.join();
        }

        // Free run state
        self.run_state.?.deinit();
        self.run_state = null;

        // Deinitialize
        self._deinitialize();
    }

    pub fn stop(self: *Flowgraph) !void {
        if (self.run_state == null) return FlowgraphError.NotRunning;

        // For each block runner
        for (self.run_state.?.block_runners.items) |*block_runner| {
            // If this block is a source
            if (block_runner.block.inputs.len == 0) {
                // Stop the block
                block_runner.stop();
            }
        }

        // Wait for termination
        try self.wait();
    }

    pub fn run(self: *Flowgraph) !void {
        if (self.run_state != null) return FlowgraphError.AlreadyRunning;

        try self.start();
        try self.wait();
    }
};

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockError = @import("block.zig").BlockError;
const ProcessResult = @import("block.zig").ProcessResult;

const TestSource = struct {
    block: Block,
    initialized: bool = false,

    pub fn init() TestSource {
        return .{ .block = Block.init(@This()) };
    }

    pub fn setRate(_: *TestSource, _: f64) !f64 {
        return 8000;
    }

    pub fn initialize(self: *TestSource, _: std.mem.Allocator) !void {
        self.initialized = true;
    }

    pub fn deinitialize(self: *TestSource, _: std.mem.Allocator) void {
        self.initialized = false;
    }

    pub fn process(_: *TestSource, _: []u32) !ProcessResult {
        return ProcessResult.init(&[0]usize{}, &[1]usize{1});
    }
};

const TestSourceFloat32 = struct {
    block: Block,

    pub fn init() TestSourceFloat32 {
        return .{ .block = Block.init(@This()) };
    }

    pub fn setRate(_: *TestSourceFloat32, _: f64) !f64 {
        return 4000;
    }

    pub fn process(_: *TestSourceFloat32, _: []f32) !ProcessResult {
        return ProcessResult.init(&[0]usize{}, &[1]usize{1});
    }
};

const TestSink = struct {
    block: Block,
    initialized: bool = false,

    pub fn init() TestSink {
        return .{ .block = Block.init(@This()) };
    }

    pub fn initialize(self: *TestSink, _: std.mem.Allocator) !void {
        self.initialized = true;
    }

    pub fn deinitialize(self: *TestSink, _: std.mem.Allocator) void {
        self.initialized = false;
    }

    pub fn processUnsigned32(_: *TestSink, _: []const u32) !ProcessResult {
        return ProcessResult.init(&[1]usize{1}, &[0]usize{});
    }

    pub fn processFloat32(_: *TestSink, _: []const f32) !ProcessResult {
        return ProcessResult.init(&[1]usize{1}, &[0]usize{});
    }
};

const TestBlock = struct {
    block: Block,

    pub fn init() TestBlock {
        return .{ .block = Block.init(@This()) };
    }

    pub fn setRate(_: *TestBlock, upstream_rate: f64) !f64 {
        return upstream_rate / 2;
    }

    pub fn processUnsigned32(_: *TestBlock, _: []const u32, _: []f32) !ProcessResult {
        return ProcessResult.init(&[1]usize{1}, &[1]usize{1});
    }

    pub fn processFloat32(_: *TestBlock, _: []const f32, _: []u32) !ProcessResult {
        return ProcessResult.init(&[1]usize{1}, &[1]usize{1});
    }
};

const TestAddBlock = struct {
    block: Block,
    initialized: bool = false,

    pub fn init() TestAddBlock {
        return .{ .block = Block.init(@This()) };
    }

    pub fn initialize(self: *TestAddBlock, _: std.mem.Allocator) !void {
        self.initialized = true;
    }

    pub fn deinitialize(self: *TestAddBlock, _: std.mem.Allocator) void {
        self.initialized = false;
    }

    pub fn processUnsigned32(_: *TestAddBlock, _: []const u32, _: []const u32, _: []u32) !ProcessResult {
        return ProcessResult.init(&[2]usize{ 1, 1 }, &[1]usize{1});
    }

    pub fn processFloat32(_: *TestAddBlock, _: []const f32, _: []const f32, _: []f32) !ProcessResult {
        return ProcessResult.init(&[2]usize{ 1, 1 }, &[1]usize{1});
    }
};

const TestErrorBlock = struct {
    block: Block,

    pub fn init() TestErrorBlock {
        return .{ .block = Block.init(@This()) };
    }

    pub fn initialize(_: *TestErrorBlock, _: std.mem.Allocator) !void {
        return error.NotImplemented;
    }

    pub fn process(_: *TestErrorBlock, _: []const u32, _: []f32) !ProcessResult {
        return ProcessResult.init(&[1]usize{1}, &[1]usize{1});
    }
};

const TestCompositeBlock1 = struct {
    composite: CompositeBlock,
    b1: TestBlock,
    b2: TestBlock,
    b3: TestBlock,

    pub fn init() TestCompositeBlock1 {
        return .{
            .composite = CompositeBlock.init(@This(), &.{"in1"}, &.{ "out1", "out2" }),
            .b1 = TestBlock.init(),
            .b2 = TestBlock.init(),
            .b3 = TestBlock.init(),
        };
    }

    pub fn connect(self: *TestCompositeBlock1, flowgraph: *Flowgraph) !void {
        //            2
        //     -----------------
        // -->|---[1] -> [2]---|-->
        //    |       \> [3]---|-->
        //    ------------------

        // Internal connections
        try flowgraph.connect(&self.b1.block, &self.b2.block);
        try flowgraph.connect(&self.b1.block, &self.b3.block);

        // Alias inputs and outputs
        try flowgraph.alias(&self.composite, "in1", &self.b1.block, "in1");
        try flowgraph.alias(&self.composite, "out1", &self.b2.block, "out1");
        try flowgraph.alias(&self.composite, "out2", &self.b3.block, "out1");
    }
};

const TestCompositeBlock2 = struct {
    composite: CompositeBlock,
    b1: TestBlock,
    b2: TestBlock,

    pub fn init() TestCompositeBlock2 {
        return .{
            .composite = CompositeBlock.init(@This(), &.{"in1"}, &.{"out1"}),
            .b1 = TestBlock.init(),
            .b2 = TestBlock.init(),
        };
    }

    pub fn connect(self: *TestCompositeBlock2, flowgraph: *Flowgraph) !void {
        //
        //    ------------------
        // -->|---[1] -> [2]---|-->
        //    ------------------
        //

        // Internal connections
        try flowgraph.connect(&self.b1.block, &self.b2.block);

        // Alias inputs and outputs
        try flowgraph.alias(&self.composite, "in1", &self.b1.block, "in1");
        try flowgraph.alias(&self.composite, "out1", &self.b2.block, "out1");
    }
};

const TestNestedCompositeBlock = struct {
    composite: CompositeBlock,
    b1: TestBlock,
    b2: TestBlock,
    b3: TestCompositeBlock2,

    pub fn init() TestNestedCompositeBlock {
        return .{
            .composite = CompositeBlock.init(@This(), &.{"in1"}, &.{ "out1", "out2" }),
            .b1 = TestBlock.init(),
            .b2 = TestBlock.init(),
            .b3 = TestCompositeBlock2.init(),
        };
    }

    pub fn connect(self: *TestNestedCompositeBlock, flowgraph: *Flowgraph) !void {
        //
        //    ------------------
        // -->|---[1] -- [2]---|-->
        //    |\--|[ ] -> [ ]|-|-->
        //    ------------------
        //

        // Internal connections
        try flowgraph.connect(&self.b1.block, &self.b2.block);

        // Alias inputs and outputs
        try flowgraph.alias(&self.composite, "in1", &self.b1.block, "in1");
        try flowgraph.alias(&self.composite, "in1", &self.b3.composite, "in1");
        try flowgraph.alias(&self.composite, "out1", &self.b2.block, "out1");
        try flowgraph.alias(&self.composite, "out2", &self.b3.composite, "out1");
    }
};

const TestMissingInputAliasCompositeBlock = struct {
    composite: CompositeBlock,
    b1: TestBlock,
    b2: TestBlock,
    b3: TestBlock,

    pub fn init() TestMissingInputAliasCompositeBlock {
        return .{
            .composite = CompositeBlock.init(@This(), &.{"in1"}, &.{ "out1", "out2" }),
            .b1 = TestBlock.init(),
            .b2 = TestBlock.init(),
            .b3 = TestBlock.init(),
        };
    }

    pub fn connect(self: *TestMissingInputAliasCompositeBlock, flowgraph: *Flowgraph) !void {
        //            2
        //     -----------------
        // -->|   [1] -> [2]---|-->
        //    |       \> [3]---|-->
        //    ------------------

        // Internal connections
        try flowgraph.connect(&self.b1.block, &self.b2.block);
        try flowgraph.connect(&self.b1.block, &self.b3.block);

        // Alias inputs and outputs
        try flowgraph.alias(&self.composite, "out1", &self.b2.block, "out1");
        try flowgraph.alias(&self.composite, "out2", &self.b3.block, "out1");
    }
};

const TestMissingOutputAliasCompositeBlock = struct {
    composite: CompositeBlock,
    b1: TestBlock,
    b2: TestBlock,
    b3: TestBlock,

    pub fn init() TestMissingOutputAliasCompositeBlock {
        return .{
            .composite = CompositeBlock.init(@This(), &.{"in1"}, &.{ "out1", "out2" }),
            .b1 = TestBlock.init(),
            .b2 = TestBlock.init(),
            .b3 = TestBlock.init(),
        };
    }

    pub fn connect(self: *TestMissingOutputAliasCompositeBlock, flowgraph: *Flowgraph) !void {
        //            2
        //     -----------------
        // -->|---[1] -> [2]---|-->
        //    |       \> [3]   |-->
        //    ------------------

        // Internal connections
        try flowgraph.connect(&self.b1.block, &self.b2.block);
        try flowgraph.connect(&self.b1.block, &self.b3.block);

        // Alias inputs and outputs
        try flowgraph.alias(&self.composite, "in1", &self.b1.block, "in1");
        try flowgraph.alias(&self.composite, "out1", &self.b2.block, "out1");
    }
};

test "buildEvaluationOrder" {
    //
    // [1] -- [2] -- [3] -- [4] -- [5]
    //                | \
    //        [6] -- [7] \- [8] -- [9]
    //

    var top = Flowgraph.init(std.testing.allocator, .{});
    defer top.deinit();

    var b1 = TestSource.init();
    var b2 = TestBlock.init();
    var b3 = TestAddBlock.init();
    var b4 = TestBlock.init();
    var b5 = TestSink.init();
    var b6 = TestSource.init();
    var b7 = TestBlock.init();
    var b8 = TestBlock.init();
    var b9 = TestSink.init();

    try top.connect(&b1.block, &b2.block);
    try top.connect(&b6.block, &b7.block);
    try top.connectPort(&b2.block, "out1", &b3.block, "in1");
    try top.connectPort(&b7.block, "out1", &b3.block, "in2");
    try top.connect(&b3.block, &b4.block);
    try top.connect(&b4.block, &b5.block);
    try top.connect(&b3.block, &b8.block);
    try top.connect(&b8.block, &b9.block);

    var evaluation_order = try buildEvaluationOrder(top.allocator, &top.flattened_connections, &top.block_set);
    defer evaluation_order.deinit();

    try std.testing.expectEqual(@as(usize, 9), evaluation_order.count());
    try std.testing.expect(evaluation_order.contains(&b1.block));
    try std.testing.expect(evaluation_order.contains(&b2.block));
    try std.testing.expect(evaluation_order.contains(&b3.block));
    try std.testing.expect(evaluation_order.contains(&b4.block));
    try std.testing.expect(evaluation_order.contains(&b5.block));
    try std.testing.expect(evaluation_order.contains(&b6.block));
    try std.testing.expect(evaluation_order.contains(&b7.block));
    try std.testing.expect(evaluation_order.contains(&b8.block));
    try std.testing.expect(evaluation_order.contains(&b9.block));
    try std.testing.expect(evaluation_order.getIndex(&b1.block).? < evaluation_order.getIndex(&b2.block).?);
    try std.testing.expect(evaluation_order.getIndex(&b2.block).? < evaluation_order.getIndex(&b3.block).?);
    try std.testing.expect(evaluation_order.getIndex(&b3.block).? < evaluation_order.getIndex(&b4.block).?);
    try std.testing.expect(evaluation_order.getIndex(&b4.block).? < evaluation_order.getIndex(&b5.block).?);
    try std.testing.expect(evaluation_order.getIndex(&b6.block).? < evaluation_order.getIndex(&b7.block).?);
    try std.testing.expect(evaluation_order.getIndex(&b7.block).? < evaluation_order.getIndex(&b3.block).?);
    try std.testing.expect(evaluation_order.getIndex(&b3.block).? < evaluation_order.getIndex(&b8.block).?);
    try std.testing.expect(evaluation_order.getIndex(&b8.block).? < evaluation_order.getIndex(&b9.block).?);
}

test "Flowgraph connect" {
    //
    //          a        c        d        f
    //    [ 1 ] -> [ 3 ] -> [ 4 ] -> [ 6 ] -> [ 7 ]
    //               ^                 ^
    //             b |               e |   g        h
    //             [ 2 ]             [ 5 ] -> [ 8 ] -> [ 9 ]
    //

    // Connect by port

    var top1 = Flowgraph.init(std.testing.allocator, .{});
    defer top1.deinit();

    var b1 = TestSource.init();
    var b2 = TestSource.init();
    var b3 = TestAddBlock.init();
    var b4 = TestBlock.init();
    var b5 = TestSource.init();
    var b6 = TestAddBlock.init();
    var b7 = TestSink.init();
    var b8 = TestBlock.init();
    var b9 = TestSink.init();

    try top1.connectPort(&b1.block, "out1", &b3.block, "in1");
    try top1.connectPort(&b2.block, "out1", &b3.block, "in2");
    try top1.connectPort(&b3.block, "out1", &b4.block, "in1");
    try top1.connectPort(&b4.block, "out1", &b6.block, "in1");
    try top1.connectPort(&b5.block, "out1", &b6.block, "in2");
    try top1.connectPort(&b6.block, "out1", &b7.block, "in1");
    try top1.connectPort(&b5.block, "out1", &b8.block, "in1");
    try top1.connectPort(&b8.block, "out1", &b9.block, "in1");

    try std.testing.expectEqual(@as(usize, 8), top1.connections.count());
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b1.block), .index = 0 }, top1.connections.get(InputPort{ .block = BlockVariant.wrap(&b3.block), .index = 0 }).?); // a
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b2.block), .index = 0 }, top1.connections.get(InputPort{ .block = BlockVariant.wrap(&b3.block), .index = 1 }).?); // b
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b3.block), .index = 0 }, top1.connections.get(InputPort{ .block = BlockVariant.wrap(&b4.block), .index = 0 }).?); // c
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b4.block), .index = 0 }, top1.connections.get(InputPort{ .block = BlockVariant.wrap(&b6.block), .index = 0 }).?); // d
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b5.block), .index = 0 }, top1.connections.get(InputPort{ .block = BlockVariant.wrap(&b6.block), .index = 1 }).?); // e
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b5.block), .index = 0 }, top1.connections.get(InputPort{ .block = BlockVariant.wrap(&b8.block), .index = 0 }).?); // g
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b6.block), .index = 0 }, top1.connections.get(InputPort{ .block = BlockVariant.wrap(&b7.block), .index = 0 }).?); // f
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b8.block), .index = 0 }, top1.connections.get(InputPort{ .block = BlockVariant.wrap(&b9.block), .index = 0 }).?); // h

    try std.testing.expectEqual(@as(usize, 9), top1.block_set.count());
    try std.testing.expect(top1.block_set.contains(&b1.block));
    try std.testing.expect(top1.block_set.contains(&b2.block));
    try std.testing.expect(top1.block_set.contains(&b3.block));
    try std.testing.expect(top1.block_set.contains(&b4.block));
    try std.testing.expect(top1.block_set.contains(&b5.block));
    try std.testing.expect(top1.block_set.contains(&b6.block));
    try std.testing.expect(top1.block_set.contains(&b7.block));
    try std.testing.expect(top1.block_set.contains(&b8.block));
    try std.testing.expect(top1.block_set.contains(&b9.block));

    // Connect linear

    var top2 = Flowgraph.init(std.testing.allocator, .{});
    defer top2.deinit();

    try top2.connect(&b3.block, &b4.block);
    try top2.connect(&b6.block, &b7.block);
    try top2.connect(&b5.block, &b8.block);
    try top2.connect(&b8.block, &b9.block);
    try top2.connectPort(&b1.block, "out1", &b3.block, "in1");
    try top2.connectPort(&b2.block, "out1", &b3.block, "in2");
    try top2.connectPort(&b4.block, "out1", &b6.block, "in1");
    try top2.connectPort(&b5.block, "out1", &b6.block, "in2");

    try std.testing.expectEqual(@as(usize, 8), top2.connections.count());
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b1.block), .index = 0 }, top2.connections.get(InputPort{ .block = BlockVariant.wrap(&b3.block), .index = 0 }).?); // a
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b2.block), .index = 0 }, top2.connections.get(InputPort{ .block = BlockVariant.wrap(&b3.block), .index = 1 }).?); // b
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b3.block), .index = 0 }, top2.connections.get(InputPort{ .block = BlockVariant.wrap(&b4.block), .index = 0 }).?); // c
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b4.block), .index = 0 }, top2.connections.get(InputPort{ .block = BlockVariant.wrap(&b6.block), .index = 0 }).?); // d
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b5.block), .index = 0 }, top2.connections.get(InputPort{ .block = BlockVariant.wrap(&b6.block), .index = 1 }).?); // e
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b5.block), .index = 0 }, top2.connections.get(InputPort{ .block = BlockVariant.wrap(&b8.block), .index = 0 }).?); // g
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b6.block), .index = 0 }, top2.connections.get(InputPort{ .block = BlockVariant.wrap(&b7.block), .index = 0 }).?); // f
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b8.block), .index = 0 }, top2.connections.get(InputPort{ .block = BlockVariant.wrap(&b9.block), .index = 0 }).?); // h

    try std.testing.expectEqual(@as(usize, 9), top2.block_set.count());
    try std.testing.expect(top2.block_set.contains(&b1.block));
    try std.testing.expect(top2.block_set.contains(&b2.block));
    try std.testing.expect(top2.block_set.contains(&b3.block));
    try std.testing.expect(top2.block_set.contains(&b4.block));
    try std.testing.expect(top2.block_set.contains(&b5.block));
    try std.testing.expect(top2.block_set.contains(&b6.block));
    try std.testing.expect(top2.block_set.contains(&b7.block));
    try std.testing.expect(top2.block_set.contains(&b8.block));
    try std.testing.expect(top2.block_set.contains(&b9.block));

    // Connect errors

    var top3 = Flowgraph.init(std.testing.allocator, .{});
    defer top3.deinit();

    try std.testing.expectError(FlowgraphError.InvalidPortCount, top3.connect(&b7.block, &b4.block));
    try std.testing.expectError(FlowgraphError.InvalidPortCount, top3.connect(&b4.block, &b6.block));
    try std.testing.expectError(FlowgraphError.PortNotFound, top3.connectPort(&b3.block, "out1", &b4.block, "in2"));
    try std.testing.expectError(FlowgraphError.PortNotFound, top3.connectPort(&b3.block, "out2", &b4.block, "in1"));

    try top3.connect(&b5.block, &b8.block);
    try std.testing.expectError(FlowgraphError.PortAlreadyConnected, top3.connectPort(&b4.block, "out1", &b8.block, "in1"));
}

test "Flowgraph validate" {
    //
    //          a        c
    //    [ 1 ] -> [ 3 ] -> [ 4 ]
    //               ^
    //             b |
    //             [ 2 ]
    //

    var top1 = Flowgraph.init(std.testing.allocator, .{});
    defer top1.deinit();

    var b1 = TestSource.init();
    var b2 = TestSource.init();
    var b3 = TestAddBlock.init();
    var b4 = TestSink.init();

    try top1.connectPort(&b1.block, "out1", &b3.block, "in1"); // a
    try top1.connectPort(&b2.block, "out1", &b3.block, "in2"); // b
    try top1.connectPort(&b3.block, "out1", &b4.block, "in1"); // c

    try top1._initialize();

    //
    //          a        c
    //    [ 1 ] -> [ 3 ] -> [ 4 ]
    //               ^
    //               |
    //               x

    var top2 = Flowgraph.init(std.testing.allocator, .{});
    defer top2.deinit();

    try top2.connectPort(&b1.block, "out1", &b3.block, "in1"); // a
    try top2.connectPort(&b3.block, "out1", &b4.block, "in1"); // c

    try std.testing.expectError(FlowgraphError.InputPortUnconnected, top2._validate());
}

test "Flowgraph differentiate (type signature)" {
    //
    //          a        c        d        f
    //    [ 1 ] -> [ 3 ] -> [ 4 ] -> [ 6 ] -> [ 7 ]
    //               ^                 ^
    //             b |               e |   g        h
    //             [ 2 ]             [ 5 ] -> [ 8 ] -> [ 9 ]
    //

    // Connect by port

    var top1 = Flowgraph.init(std.testing.allocator, .{});
    defer top1.deinit();

    var b1 = TestSource.init();
    var b2 = TestSource.init();
    var b3 = TestAddBlock.init();
    var b4 = TestBlock.init();
    var b5 = TestSourceFloat32.init();
    var b6 = TestAddBlock.init();
    var b7 = TestSink.init();
    var b8 = TestBlock.init();
    var b9 = TestSink.init();

    try top1.connectPort(&b1.block, "out1", &b3.block, "in1"); // a u32
    try top1.connectPort(&b2.block, "out1", &b3.block, "in2"); // b u32
    try top1.connectPort(&b3.block, "out1", &b4.block, "in1"); // c u32
    try top1.connectPort(&b4.block, "out1", &b6.block, "in1"); // d f32
    try top1.connectPort(&b5.block, "out1", &b6.block, "in2"); // e f32
    try top1.connectPort(&b6.block, "out1", &b7.block, "in1"); // f f32
    try top1.connectPort(&b5.block, "out1", &b8.block, "in1"); // g f32
    try top1.connectPort(&b8.block, "out1", &b9.block, "in1"); // h u32

    try top1._initialize();

    try std.testing.expectEqual(b1.block._differentiation, &b1.block.differentiations[0]);
    try std.testing.expectEqual(b2.block._differentiation, &b2.block.differentiations[0]);
    try std.testing.expectEqual(b3.block._differentiation, &b3.block.differentiations[0]);
    try std.testing.expectEqual(b4.block._differentiation, &b4.block.differentiations[0]);
    try std.testing.expectEqual(b5.block._differentiation, &b5.block.differentiations[0]);
    try std.testing.expectEqual(b6.block._differentiation, &b6.block.differentiations[1]);
    try std.testing.expectEqual(b7.block._differentiation, &b7.block.differentiations[1]);
    try std.testing.expectEqual(b8.block._differentiation, &b8.block.differentiations[1]);
    try std.testing.expectEqual(b9.block._differentiation, &b9.block.differentiations[0]);

    try std.testing.expectEqual(@as(usize, 8000), try b1.block.getRate(usize));
    try std.testing.expectEqual(@as(usize, 8000), try b2.block.getRate(usize));
    try std.testing.expectEqual(@as(usize, 8000), try b3.block.getRate(usize));
    try std.testing.expectEqual(@as(usize, 4000), try b4.block.getRate(usize));
    try std.testing.expectEqual(@as(usize, 4000), try b5.block.getRate(usize));
    try std.testing.expectEqual(@as(usize, 4000), try b6.block.getRate(usize));
    try std.testing.expectEqual(@as(usize, 4000), try b7.block.getRate(usize));
    try std.testing.expectEqual(@as(usize, 2000), try b8.block.getRate(usize));
    try std.testing.expectEqual(@as(usize, 2000), try b9.block.getRate(usize));

    //
    //          a        c                 f
    //    [ 1 ] -> [ 3 ] ----------> [ 6 ] -> [ 7 ]
    //               ^                 ^
    //             b |               e |   g        h
    //             [ 2 ]             [ 5 ] -> [ 8 ] -> [ 9 ]
    //

    var top2 = Flowgraph.init(std.testing.allocator, .{});
    defer top2.deinit();

    try top2.connectPort(&b1.block, "out1", &b3.block, "in1"); // a u32
    try top2.connectPort(&b2.block, "out1", &b3.block, "in2"); // b u32
    try top2.connectPort(&b3.block, "out1", &b6.block, "in1"); // c u32
    try top2.connectPort(&b5.block, "out1", &b6.block, "in2"); // e f32
    try top2.connectPort(&b6.block, "out1", &b7.block, "in1"); // f f32
    try top2.connectPort(&b5.block, "out1", &b8.block, "in1"); // g f32
    try top2.connectPort(&b8.block, "out1", &b9.block, "in1"); // h u32

    try std.testing.expectError(BlockError.TypeSignatureNotFound, top2._initialize());
}

test "Flowgraph differentiate (rate validation)" {
    //
    //          a        c
    //    [ 1 ] -> [ 3 ] -> [ 4 ]
    //               ^
    //             b |
    //             [ 2 ]
    //

    var top1 = Flowgraph.init(std.testing.allocator, .{});
    defer top1.deinit();

    var b1 = TestSource.init();
    var b2 = TestSource.init();
    var b3 = TestAddBlock.init();
    var b4 = TestSink.init();

    try top1.connectPort(&b1.block, "out1", &b3.block, "in1"); // a
    try top1.connectPort(&b2.block, "out1", &b3.block, "in2"); // b
    try top1.connectPort(&b3.block, "out1", &b4.block, "in1"); // c

    try top1._initialize();

    //
    //          a        d
    //    [ 5 ] -> [ 8 ] -> [ 9 ]
    //               ^
    //             b |
    //             [ 7 ]
    //               ^
    //             c |
    //             [ 6 ]

    var top2 = Flowgraph.init(std.testing.allocator, .{});
    defer top2.deinit();

    var b5 = TestSource.init();
    var b6 = TestSourceFloat32.init();
    var b7 = TestBlock.init();
    var b8 = TestAddBlock.init();
    var b9 = TestSink.init();

    try top2.connectPort(&b5.block, "out1", &b8.block, "in1"); // a
    try top2.connectPort(&b7.block, "out1", &b8.block, "in2"); // b
    try top2.connect(&b6.block, &b7.block); // c
    try top2.connect(&b8.block, &b9.block); // d

    try std.testing.expectError(FlowgraphError.RateMismatch, top2._initialize());
}

test "Flowgraph initialize and deinitialize blocks" {
    //
    //          a        c
    //    [ 1 ] -> [ 3 ] -> [ 4 ]
    //               ^
    //             b |
    //             [ 2 ]
    //

    var top1 = Flowgraph.init(std.testing.allocator, .{});
    defer top1.deinit();

    var b1 = TestSource.init();
    var b2 = TestSource.init();
    var b3 = TestAddBlock.init();
    var b4 = TestSink.init();

    try top1.connectPort(&b1.block, "out1", &b3.block, "in1"); // a
    try top1.connectPort(&b2.block, "out1", &b3.block, "in2"); // b
    try top1.connectPort(&b3.block, "out1", &b4.block, "in1"); // c

    try std.testing.expectEqual(false, b1.initialized);
    try std.testing.expectEqual(false, b2.initialized);
    try std.testing.expectEqual(false, b3.initialized);
    try std.testing.expectEqual(false, b4.initialized);

    try top1._initialize();

    try std.testing.expectEqual(true, b1.initialized);
    try std.testing.expectEqual(true, b2.initialized);
    try std.testing.expectEqual(true, b3.initialized);
    try std.testing.expectEqual(true, b4.initialized);

    top1._deinitialize();

    try std.testing.expectEqual(false, b1.initialized);
    try std.testing.expectEqual(false, b2.initialized);
    try std.testing.expectEqual(false, b3.initialized);
    try std.testing.expectEqual(false, b4.initialized);

    //
    //          a        c
    //    [ 5 ] -> [ 6 ] -> [ 7 ]
    //
    //

    var top2 = Flowgraph.init(std.testing.allocator, .{});
    defer top2.deinit();

    var b5 = TestSource.init();
    var b6 = TestErrorBlock.init();
    var b7 = TestSink.init();

    try top2.connect(&b5.block, &b6.block);
    try top2.connect(&b6.block, &b7.block);

    try std.testing.expectEqual(false, b5.initialized);
    try std.testing.expectEqual(false, b7.initialized);

    try std.testing.expectError(error.NotImplemented, top2._initialize());

    try std.testing.expectEqual(true, b5.initialized);
    try std.testing.expectEqual(false, b7.initialized);
}

////////////////////////////////////////////////////////////////////////////////
// Composite Block Tests
////////////////////////////////////////////////////////////////////////////////

test "Flowgraph connect composite" {
    //
    //                     2
    //              -----------------
    //    [ 1 ] -> |-[   ] -> [   ]-|--> [ 3 ] -> [ 4 ]
    //             |       \> [   ]-|--> [ 5 ]
    //             ------------------
    //

    var top1 = Flowgraph.init(std.testing.allocator, .{});
    defer top1.deinit();

    var b1 = TestSource.init();
    var b2 = TestCompositeBlock1.init();
    var b3 = TestBlock.init();
    var b4 = TestSink.init();
    var b5 = TestSink.init();

    try top1.connectPort(&b1.block, "out1", &b2.composite, "in1");
    try top1.connectPort(&b2.composite, "out1", &b3.block, "in1");
    try top1.connectPort(&b2.composite, "out2", &b5.block, "in1");
    try top1.connectPort(&b3.block, "out1", &b4.block, "in1");

    try std.testing.expectEqual(@as(usize, 6), top1.connections.count());
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b1.block), .index = 0 }, top1.connections.get(InputPort{ .block = BlockVariant.wrap(&b2.composite), .index = 0 }).?);
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b2.composite), .index = 0 }, top1.connections.get(InputPort{ .block = BlockVariant.wrap(&b3.block), .index = 0 }).?);
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b2.composite), .index = 1 }, top1.connections.get(InputPort{ .block = BlockVariant.wrap(&b5.block), .index = 0 }).?);
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b3.block), .index = 0 }, top1.connections.get(InputPort{ .block = BlockVariant.wrap(&b4.block), .index = 0 }).?);
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b2.b1.block), .index = 0 }, top1.connections.get(InputPort{ .block = BlockVariant.wrap(&b2.b2.block), .index = 0 }).?);
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b2.b1.block), .index = 0 }, top1.connections.get(InputPort{ .block = BlockVariant.wrap(&b2.b3.block), .index = 0 }).?);

    try std.testing.expectEqual(@as(usize, 1), top1.input_aliases.count());
    try std.testing.expectEqual(@as(usize, 1), top1.input_aliases.get(InputPort{ .block = BlockVariant.wrap(&b2.composite), .index = 0 }).?.items.len);
    try std.testing.expectEqual(InputPort{ .block = BlockVariant.wrap(&b2.b1.block), .index = 0 }, top1.input_aliases.get(InputPort{ .block = BlockVariant.wrap(&b2.composite), .index = 0 }).?.items[0]);

    try std.testing.expectEqual(@as(usize, 2), top1.output_aliases.count());
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b2.b2.block), .index = 0 }, top1.output_aliases.get(OutputPort{ .block = BlockVariant.wrap(&b2.composite), .index = 0 }).?);
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b2.b3.block), .index = 0 }, top1.output_aliases.get(OutputPort{ .block = BlockVariant.wrap(&b2.composite), .index = 1 }).?);

    try std.testing.expectEqual(@as(usize, 6), top1.flattened_connections.count());
    try std.testing.expectEqual(BlockOutputPort{ .block = &b1.block, .index = 0 }, top1.flattened_connections.get(BlockInputPort{ .block = &b2.b1.block, .index = 0 }).?);
    try std.testing.expectEqual(BlockOutputPort{ .block = &b2.b1.block, .index = 0 }, top1.flattened_connections.get(BlockInputPort{ .block = &b2.b2.block, .index = 0 }).?);
    try std.testing.expectEqual(BlockOutputPort{ .block = &b2.b1.block, .index = 0 }, top1.flattened_connections.get(BlockInputPort{ .block = &b2.b3.block, .index = 0 }).?);
    try std.testing.expectEqual(BlockOutputPort{ .block = &b2.b2.block, .index = 0 }, top1.flattened_connections.get(BlockInputPort{ .block = &b3.block, .index = 0 }).?);
    try std.testing.expectEqual(BlockOutputPort{ .block = &b2.b3.block, .index = 0 }, top1.flattened_connections.get(BlockInputPort{ .block = &b5.block, .index = 0 }).?);
    try std.testing.expectEqual(BlockOutputPort{ .block = &b3.block, .index = 0 }, top1.flattened_connections.get(BlockInputPort{ .block = &b4.block, .index = 0 }).?);

    try std.testing.expectEqual(@as(usize, 7), top1.block_set.count());
    try std.testing.expect(top1.block_set.contains(&b1.block));
    try std.testing.expect(top1.block_set.contains(&b2.b1.block));
    try std.testing.expect(top1.block_set.contains(&b2.b2.block));
    try std.testing.expect(top1.block_set.contains(&b2.b3.block));
    try std.testing.expect(top1.block_set.contains(&b3.block));
    try std.testing.expect(top1.block_set.contains(&b4.block));
    try std.testing.expect(top1.block_set.contains(&b5.block));

    try std.testing.expectEqual(@as(usize, 1), top1.composite_set.count());
    try std.testing.expect(top1.composite_set.contains(&b2.composite));
}

test "Flowgraph connect nested composite" {
    //
    //                     2
    //              -----------------
    //    [ 1 ] -> |-[   ] -> [   ]-|--> [ 3 ] -> [ 4 ]
    //             |\->|[ ] -> [ ]|-|--> [ 5 ]
    //             ------------------
    //

    var top1 = Flowgraph.init(std.testing.allocator, .{});
    defer top1.deinit();

    var b1 = TestSource.init();
    var b2 = TestNestedCompositeBlock.init();
    var b3 = TestBlock.init();
    var b4 = TestSink.init();
    var b5 = TestSink.init();

    try top1.connectPort(&b1.block, "out1", &b2.composite, "in1");
    try top1.connectPort(&b2.composite, "out1", &b3.block, "in1");
    try top1.connectPort(&b2.composite, "out2", &b5.block, "in1");
    try top1.connectPort(&b3.block, "out1", &b4.block, "in1");

    try std.testing.expectEqual(@as(usize, 6), top1.connections.count());
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b1.block), .index = 0 }, top1.connections.get(InputPort{ .block = BlockVariant.wrap(&b2.composite), .index = 0 }).?);
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b2.composite), .index = 0 }, top1.connections.get(InputPort{ .block = BlockVariant.wrap(&b3.block), .index = 0 }).?);
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b2.composite), .index = 1 }, top1.connections.get(InputPort{ .block = BlockVariant.wrap(&b5.block), .index = 0 }).?);
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b3.block), .index = 0 }, top1.connections.get(InputPort{ .block = BlockVariant.wrap(&b4.block), .index = 0 }).?);
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b2.b1.block), .index = 0 }, top1.connections.get(InputPort{ .block = BlockVariant.wrap(&b2.b2.block), .index = 0 }).?);
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b2.b3.b1.block), .index = 0 }, top1.connections.get(InputPort{ .block = BlockVariant.wrap(&b2.b3.b2.block), .index = 0 }).?);

    try std.testing.expectEqual(@as(usize, 2), top1.input_aliases.count());
    try std.testing.expectEqual(@as(usize, 2), top1.input_aliases.get(InputPort{ .block = BlockVariant.wrap(&b2.composite), .index = 0 }).?.items.len);
    try std.testing.expectEqual(InputPort{ .block = BlockVariant.wrap(&b2.b1.block), .index = 0 }, top1.input_aliases.get(InputPort{ .block = BlockVariant.wrap(&b2.composite), .index = 0 }).?.items[0]);
    try std.testing.expectEqual(InputPort{ .block = BlockVariant.wrap(&b2.b3.composite), .index = 0 }, top1.input_aliases.get(InputPort{ .block = BlockVariant.wrap(&b2.composite), .index = 0 }).?.items[1]);
    try std.testing.expectEqual(@as(usize, 1), top1.input_aliases.get(InputPort{ .block = BlockVariant.wrap(&b2.b3.composite), .index = 0 }).?.items.len);
    try std.testing.expectEqual(InputPort{ .block = BlockVariant.wrap(&b2.b3.b1.block), .index = 0 }, top1.input_aliases.get(InputPort{ .block = BlockVariant.wrap(&b2.b3.composite), .index = 0 }).?.items[0]);

    try std.testing.expectEqual(@as(usize, 3), top1.output_aliases.count());
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b2.b2.block), .index = 0 }, top1.output_aliases.get(OutputPort{ .block = BlockVariant.wrap(&b2.composite), .index = 0 }).?);
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b2.b3.composite), .index = 0 }, top1.output_aliases.get(OutputPort{ .block = BlockVariant.wrap(&b2.composite), .index = 1 }).?);
    try std.testing.expectEqual(OutputPort{ .block = BlockVariant.wrap(&b2.b3.b2.block), .index = 0 }, top1.output_aliases.get(OutputPort{ .block = BlockVariant.wrap(&b2.b3.composite), .index = 0 }).?);

    try std.testing.expectEqual(@as(usize, 7), top1.flattened_connections.count());
    try std.testing.expectEqual(BlockOutputPort{ .block = &b1.block, .index = 0 }, top1.flattened_connections.get(BlockInputPort{ .block = &b2.b1.block, .index = 0 }).?);
    try std.testing.expectEqual(BlockOutputPort{ .block = &b2.b1.block, .index = 0 }, top1.flattened_connections.get(BlockInputPort{ .block = &b2.b2.block, .index = 0 }).?);
    try std.testing.expectEqual(BlockOutputPort{ .block = &b1.block, .index = 0 }, top1.flattened_connections.get(BlockInputPort{ .block = &b2.b3.b1.block, .index = 0 }).?);
    try std.testing.expectEqual(BlockOutputPort{ .block = &b2.b3.b1.block, .index = 0 }, top1.flattened_connections.get(BlockInputPort{ .block = &b2.b3.b2.block, .index = 0 }).?);
    try std.testing.expectEqual(BlockOutputPort{ .block = &b2.b2.block, .index = 0 }, top1.flattened_connections.get(BlockInputPort{ .block = &b3.block, .index = 0 }).?);
    try std.testing.expectEqual(BlockOutputPort{ .block = &b2.b3.b2.block, .index = 0 }, top1.flattened_connections.get(BlockInputPort{ .block = &b5.block, .index = 0 }).?);
    try std.testing.expectEqual(BlockOutputPort{ .block = &b3.block, .index = 0 }, top1.flattened_connections.get(BlockInputPort{ .block = &b4.block, .index = 0 }).?);

    try std.testing.expectEqual(@as(usize, 8), top1.block_set.count());
    try std.testing.expect(top1.block_set.contains(&b1.block));
    try std.testing.expect(top1.block_set.contains(&b2.b1.block));
    try std.testing.expect(top1.block_set.contains(&b2.b2.block));
    try std.testing.expect(top1.block_set.contains(&b2.b3.b1.block));
    try std.testing.expect(top1.block_set.contains(&b2.b3.b2.block));
    try std.testing.expect(top1.block_set.contains(&b3.block));
    try std.testing.expect(top1.block_set.contains(&b4.block));
    try std.testing.expect(top1.block_set.contains(&b5.block));

    try std.testing.expectEqual(@as(usize, 2), top1.composite_set.count());
    try std.testing.expect(top1.composite_set.contains(&b2.composite));
    try std.testing.expect(top1.composite_set.contains(&b2.b3.composite));
}

test "Flowgraph connect composite with unaliased composite input" {
    //
    //                     2
    //              -----------------
    //    [ 1 ] -> | [   ] -> [   ]-|--> [ 3 ] -> [ 4 ]
    //             |       \> [   ]-|--> [ 5 ]
    //             ------------------
    //

    var top1 = Flowgraph.init(std.testing.allocator, .{});
    defer top1.deinit();

    var b1 = TestSource.init();
    var b2 = TestMissingInputAliasCompositeBlock.init();

    try std.testing.expectError(FlowgraphError.UnderlyingPortNotFound, top1.connectPort(&b1.block, "out1", &b2.composite, "in1"));
}

test "Flowgraph connect composite with unaliased composite output" {
    //
    //                     2
    //              -----------------
    //    [ 1 ] -> |-[   ] -> [   ]-|--> [ 3 ] -> [ 4 ]
    //             |       \> [   ] |--> [ 5 ]
    //             ------------------
    //

    var top1 = Flowgraph.init(std.testing.allocator, .{});
    defer top1.deinit();

    var b1 = TestSource.init();
    var b2 = TestMissingOutputAliasCompositeBlock.init();
    var b3 = TestBlock.init();
    var b4 = TestSink.init();
    var b5 = TestSink.init();

    try top1.connectPort(&b1.block, "out1", &b2.composite, "in1");
    try top1.connectPort(&b2.composite, "out1", &b3.block, "in1");
    try top1.connectPort(&b3.block, "out1", &b4.block, "in1");

    try std.testing.expectError(FlowgraphError.UnderlyingPortNotFound, top1.connectPort(&b2.composite, "out2", &b5.block, "in1"));
}

test "Flowgraph validate composite with unconnected input" {
    //
    //                     2
    //              -----------------
    //          X> |-[   ] -> [   ]-|--> [ 3 ] -> [ 4 ]
    //             |       \> [   ]-|--> [ 5 ]
    //             ------------------
    //

    var top1 = Flowgraph.init(std.testing.allocator, .{});
    defer top1.deinit();

    var b2 = TestCompositeBlock1.init();
    var b3 = TestBlock.init();
    var b4 = TestSink.init();
    var b5 = TestSink.init();

    try top1.connectPort(&b2.composite, "out1", &b3.block, "in1");
    try top1.connectPort(&b2.composite, "out2", &b5.block, "in1");
    try top1.connectPort(&b3.block, "out1", &b4.block, "in1");

    try std.testing.expectError(FlowgraphError.InputPortUnconnected, top1._validate());
}

////////////////////////////////////////////////////////////////////////////////
// Flowgraph Tests
////////////////////////////////////////////////////////////////////////////////

const TestBufferSource = struct {
    block: Block,
    buf: []const u8,
    index: usize = 0,
    initialized: bool = false,

    pub fn init(buf: []const u8) TestBufferSource {
        return .{ .block = Block.init(@This()), .buf = buf };
    }

    pub fn setRate(_: *TestBufferSource, _: f64) !f64 {
        return 8000;
    }

    pub fn process(self: *TestBufferSource, z: []u8) !ProcessResult {
        if (self.index == self.buf.len) return ProcessResult.eof();

        z[0] = self.buf[self.index];
        self.index += 1;

        return ProcessResult.init(&[0]usize{}, &[1]usize{1});
    }
};

const TestRandomSource = struct {
    block: Block,
    prng: std.rand.DefaultPrng,

    pub fn init(seed: u64) TestRandomSource {
        return .{ .block = Block.init(@This()), .prng = std.rand.DefaultPrng.init(seed) };
    }

    pub fn setRate(_: *TestRandomSource, _: f64) !f64 {
        return 8000;
    }

    pub fn process(self: *TestRandomSource, z: []u8) !ProcessResult {
        self.prng.fill(z);

        return ProcessResult.init(&[0]usize{}, &[1]usize{z.len});
    }
};

const TestInverterBlock = struct {
    block: Block,

    pub fn init() TestInverterBlock {
        return .{ .block = Block.init(@This()) };
    }

    pub fn process(_: *TestInverterBlock, x: []const u8, z: []u8) !ProcessResult {
        for (x, 0..) |_, i| {
            z[i] = ~x[i];
        }

        return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
    }
};

const TestBufferSink = struct {
    block: Block,
    buf: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) TestBufferSink {
        return .{ .block = Block.init(@This()), .buf = std.ArrayList(u8).init(allocator) };
    }

    pub fn deinit(self: *TestBufferSink) void {
        self.buf.deinit();
    }

    pub fn process(self: *TestBufferSink, x: []const u8) !ProcessResult {
        try self.buf.appendSlice(x);

        return ProcessResult.init(&[1]usize{x.len}, &[0]usize{});
    }
};

test "Flowgraph run to completion" {
    // Input test vector
    var test_vector: [8192]u8 = .{0x00} ** 8192;
    var prng = std.rand.DefaultPrng.init(123);
    prng.fill(&test_vector);

    // Expected output vector
    var expected_output_vector: [8192]u8 = .{0x00} ** 8192;
    for (test_vector, 0..) |_, i| {
        expected_output_vector[i] = ~test_vector[i];
    }

    // Create flow graph
    var top = Flowgraph.init(std.testing.allocator, .{});
    defer top.deinit();

    var source_block = TestBufferSource.init(&test_vector);
    var inverter_block = TestInverterBlock.init();
    var sink_block = TestBufferSink.init(std.testing.allocator);
    defer sink_block.deinit();

    try top.connect(&source_block.block, &inverter_block.block);
    try top.connect(&inverter_block.block, &sink_block.block);

    // Run flow graph
    try top.run();

    // Validate output vector
    try std.testing.expectEqualSlices(u8, &expected_output_vector, sink_block.buf.items);
}

test "Flowgraph start, stop" {
    // Create flow graph
    var top = Flowgraph.init(std.testing.allocator, .{});
    defer top.deinit();

    var source_block = TestRandomSource.init(123);
    var inverter_block = TestInverterBlock.init();
    var sink_block = TestBufferSink.init(std.testing.allocator);
    defer sink_block.deinit();

    try top.connect(&source_block.block, &inverter_block.block);
    try top.connect(&inverter_block.block, &sink_block.block);

    // Start flow graph
    try top.start();

    // Run for 1 ms
    std.time.sleep(std.time.ns_per_ms);

    // Stop flow graph
    try top.stop();

    // Generate expected output buffer
    var prng = std.rand.DefaultPrng.init(123);
    const expected_output_vector = try std.testing.allocator.alloc(u8, sink_block.buf.items.len);
    defer std.testing.allocator.free(expected_output_vector);
    prng.fill(expected_output_vector);
    for (expected_output_vector) |*e| {
        e.* = ~e.*;
    }

    // Validate output vector
    try std.testing.expectEqualSlices(u8, expected_output_vector, sink_block.buf.items);
}
