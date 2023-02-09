const std = @import("std");

const Block = @import("block.zig").Block;
const RuntimeTypeSignature = @import("type_signature.zig").RuntimeTypeSignature;
const RuntimeDataType = @import("type_signature.zig").RuntimeDataType;

const ThreadSafeRingBuffer = @import("ring_buffer.zig").ThreadSafeRingBuffer;
const RingBufferSampleMux = @import("sample_mux.zig").RingBufferSampleMux;

const ThreadedBlockRunner = @import("runner.zig").ThreadedBlockRunner;

////////////////////////////////////////////////////////////////////////////////
// Flowgraph Errors
////////////////////////////////////////////////////////////////////////////////

pub const FlowgraphError = error{
    InvalidPortCount,
    InputPortNotFound,
    OutputPortNotFound,
    InputPortAlreadyConnected,
    InputPortUnconnected,
    CyclicDependency,
    RateMismatch,
    NotRunning,
    AlreadyRunning,
};

////////////////////////////////////////////////////////////////////////////////
// Port
////////////////////////////////////////////////////////////////////////////////

const Port = struct {
    block: *Block,
    index: usize,
};

////////////////////////////////////////////////////////////////////////////////
// Helper Functions
////////////////////////////////////////////////////////////////////////////////

fn buildEvaluationOrder(allocator: std.mem.Allocator, connections: *const std.AutoHashMap(Port, Port), block_set: *const std.AutoHashMap(*Block, void)) !std.AutoArrayHashMap(*Block, void) {
    var block_set_copy = try block_set.cloneWithAllocator(allocator);
    defer block_set_copy.deinit();

    var evaluation_order = std.AutoArrayHashMap(*Block, void).init(allocator);
    errdefer evaluation_order.deinit();

    var num_blocks = block_set_copy.count();
    while (evaluation_order.count() < num_blocks) {
        // For each block left in the block set
        var block_it = block_set_copy.keyIterator();
        var next_block: ?*Block = outer: while (block_it.next()) |k| {
            // For each input to the block
            var index: usize = 0;
            while (index < k.*.getNumInputs()) : (index += 1) {
                // Check if upstream block is already in our evaluation order
                var upstream_block = connections.get(Port{ .block = k.*, .index = index }).?.block;
                if (!evaluation_order.contains(upstream_block)) {
                    // Continue to next block
                    continue :outer;
                }
            }
            // Yield this block to add
            break k.*;
        } orelse null;

        // If we couldn't find a block to add, there is a depdendency cyle
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
    ring_buffers: std.AutoHashMap(Port, ThreadSafeRingBuffer),
    sample_muxes: std.AutoHashMap(*Block, RingBufferSampleMux(ThreadSafeRingBuffer)),
    block_runners: std.ArrayList(ThreadedBlockRunner),

    const RING_BUFFER_SIZE = 2 * 1048576;

    pub fn init(allocator: std.mem.Allocator, connections: *std.AutoHashMap(Port, Port), block_set: *std.AutoHashMap(*Block, void)) !FlowgraphRunState {
        // Allocate ring buffer map
        var ring_buffers = std.AutoHashMap(Port, ThreadSafeRingBuffer).init(allocator);
        errdefer {
            var ring_buffers_it = ring_buffers.valueIterator();
            while (ring_buffers_it.next()) |ring_buffer| ring_buffer.deinit();
            ring_buffers.deinit();
        }
        // Allocate sample mux map
        var sample_muxes = std.AutoHashMap(*Block, RingBufferSampleMux(ThreadSafeRingBuffer)).init(allocator);
        errdefer {
            var sample_muxes_it = sample_muxes.valueIterator();
            while (sample_muxes_it.next()) |sample_mux| sample_mux.deinit();
            sample_muxes.deinit();
        }
        // Allocate block runner list
        var block_runners = std.ArrayList(ThreadedBlockRunner).init(allocator);
        errdefer block_runners.deinit();

        // For each connection, create an output ring buffer
        var output_it = connections.valueIterator();
        while (output_it.next()) |output| {
            if (ring_buffers.contains(output.*)) continue;
            try ring_buffers.put(output.*, try ThreadSafeRingBuffer.init(allocator, RING_BUFFER_SIZE));
        }

        // Temporary storage for input and output ring buffer slices
        var input_ring_buffers = std.ArrayList(*ThreadSafeRingBuffer).init(allocator);
        defer input_ring_buffers.deinit();
        var output_ring_buffers = std.ArrayList(*ThreadSafeRingBuffer).init(allocator);
        defer output_ring_buffers.deinit();

        // For each block, create a sample mux
        var block_it = block_set.keyIterator();
        while (block_it.next()) |block| {
            // Clear temporary ring buffer arrays
            input_ring_buffers.clearRetainingCapacity();
            output_ring_buffers.clearRetainingCapacity();

            // Collect input ring buffers
            var input_index: usize = 0;
            while (input_index < block.*.getNumInputs()) : (input_index += 1) {
                const output = connections.get(Port{ .block = block.*, .index = input_index }).?;
                try input_ring_buffers.append(ring_buffers.getPtr(output).?);
            }

            // Collect output ring buffers
            var output_index: usize = 0;
            while (output_index < block.*.getNumOutputs()) : (output_index += 1) {
                try output_ring_buffers.append(ring_buffers.getPtr(Port{ .block = block.*, .index = output_index }).?);
            }

            // Create sample mux
            try sample_muxes.put(block.*, try RingBufferSampleMux(ThreadSafeRingBuffer).init(allocator, input_ring_buffers.items, output_ring_buffers.items));
        }

        // For each block, create a block runner
        block_it = block_set.keyIterator();
        while (block_it.next()) |block| {
            // Create block runner
            try block_runners.append(ThreadedBlockRunner.init(block.*, sample_muxes.getPtr(block.*).?.sampleMux()));
        }

        return .{
            .ring_buffers = ring_buffers,
            .sample_muxes = sample_muxes,
            .block_runners = block_runners,
        };
    }

    pub fn deinit(self: *FlowgraphRunState) void {
        for (self.block_runners.items) |*block_runner| block_runner.deinit();
        self.block_runners.deinit();

        var sample_muxes_it = self.sample_muxes.valueIterator();
        while (sample_muxes_it.next()) |sample_mux| sample_mux.deinit();
        self.sample_muxes.deinit();

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

    connections: std.AutoHashMap(Port, Port),
    block_set: std.AutoHashMap(*Block, void),
    run_state: ?FlowgraphRunState = null,

    pub fn init(allocator: std.mem.Allocator, options: Options) Flowgraph {
        return .{
            .allocator = allocator,
            .options = options,
            .connections = std.AutoHashMap(Port, Port).init(allocator),
            .block_set = std.AutoHashMap(*Block, void).init(allocator),
        };
    }

    pub fn deinit(self: *Flowgraph) void {
        if (self.run_state) |*run_state| run_state.deinit();
        self.block_set.deinit();
        self.connections.deinit();
    }

    pub fn connect(self: *Flowgraph, src: *Block, dst: *Block) !void {
        if (src.getNumOutputs() != 1) return FlowgraphError.InvalidPortCount;
        if (dst.getNumInputs() != 1) return FlowgraphError.InvalidPortCount;

        const src_port = Port{ .block = src, .index = 0 };
        const dst_port = Port{ .block = dst, .index = 0 };

        if (self.connections.contains(dst_port)) return FlowgraphError.InputPortAlreadyConnected;

        try self.connections.put(dst_port, src_port);
        try self.block_set.put(src, {});
        try self.block_set.put(dst, {});
    }

    pub fn connectPort(self: *Flowgraph, src: *Block, src_port_name: []const u8, dst: *Block, dst_port_name: []const u8) !void {
        const src_port = Port{ .block = src, .index = src.getOutputIndex(src_port_name) catch return FlowgraphError.OutputPortNotFound };
        const dst_port = Port{ .block = dst, .index = dst.getInputIndex(dst_port_name) catch return FlowgraphError.InputPortNotFound };

        if (self.connections.contains(dst_port)) return FlowgraphError.InputPortAlreadyConnected;

        try self.connections.put(dst_port, src_port);
        try self.block_set.put(src, {});
        try self.block_set.put(dst, {});
    }

    pub fn _initialize(self: *Flowgraph) !void {
        // For each block in the block set
        var block_it = self.block_set.keyIterator();
        while (block_it.next()) |k| {
            // Check all inputs are connected
            var i: usize = 0;
            while (i < k.*.getNumInputs()) : (i += 1) {
                if (!self.connections.contains(Port{ .block = k.*, .index = i })) {
                    return FlowgraphError.InputPortUnconnected;
                }
            }
        }

        // Build the evaluation order
        var evaluation_order = try buildEvaluationOrder(self.allocator, &self.connections, &self.block_set);
        defer evaluation_order.deinit();

        // For each block in the evaluation order
        for (evaluation_order.keys()) |block| {
            // Allocate a slice for input types
            var input_types: []RuntimeDataType = try self.allocator.alloc(RuntimeDataType, block.getNumInputs());
            defer self.allocator.free(input_types);

            // For each block input port, collect the type of the connected output port
            var i: usize = 0;
            while (i < block.getNumInputs()) : (i += 1) {
                var output_port = self.connections.get(Port{ .block = block, .index = i }).?;
                input_types[i] = try output_port.block.getOutputType(output_port.index);
            }

            // Get upstream rate
            var upstream_rate = if (block.getNumInputs() > 0) try self.connections.get(Port{ .block = block, .index = 0 }).?.block.getRate(f64) else 0;

            // Differentiate the block
            try block.differentiate(input_types, upstream_rate);

            // Compare other input port rates
            i = 1;
            while (i < block.getNumInputs()) : (i += 1) {
                const rate = try self.connections.get(Port{ .block = block, .index = i }).?.block.getRate(f64);
                if (rate != upstream_rate) return FlowgraphError.RateMismatch;
            }
        }

        // For each block in the evaluation order
        for (evaluation_order.keys()) |block| {
            // Initialize the block
            try block.initialize(self.allocator);
        }
    }

    pub fn _deinitialize(self: *Flowgraph) void {
        // Deinitialize blocks
        var block_it = self.block_set.keyIterator();
        while (block_it.next()) |block| {
            block.*.deinitialize(self.allocator);
        }
    }

    pub fn start(self: *Flowgraph) !void {
        if (self.run_state != null) return FlowgraphError.AlreadyRunning;

        // Differentiate and initialize blocks
        try self._initialize();

        // Build run state
        self.run_state = try FlowgraphRunState.init(self.allocator, &self.connections, &self.block_set);

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
            if (block_runner.instance.getNumInputs() == 0) {
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

    var evaluation_order = try buildEvaluationOrder(top.allocator, &top.connections, &top.block_set);
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

    try std.testing.expectEqual(Port{ .block = &b1.block, .index = 0 }, top1.connections.get(Port{ .block = &b3.block, .index = 0 }).?); // a
    try std.testing.expectEqual(Port{ .block = &b2.block, .index = 0 }, top1.connections.get(Port{ .block = &b3.block, .index = 1 }).?); // b
    try std.testing.expectEqual(Port{ .block = &b3.block, .index = 0 }, top1.connections.get(Port{ .block = &b4.block, .index = 0 }).?); // c
    try std.testing.expectEqual(Port{ .block = &b4.block, .index = 0 }, top1.connections.get(Port{ .block = &b6.block, .index = 0 }).?); // d
    try std.testing.expectEqual(Port{ .block = &b5.block, .index = 0 }, top1.connections.get(Port{ .block = &b6.block, .index = 1 }).?); // e
    try std.testing.expectEqual(Port{ .block = &b5.block, .index = 0 }, top1.connections.get(Port{ .block = &b8.block, .index = 0 }).?); // g
    try std.testing.expectEqual(Port{ .block = &b6.block, .index = 0 }, top1.connections.get(Port{ .block = &b7.block, .index = 0 }).?); // f
    try std.testing.expectEqual(Port{ .block = &b8.block, .index = 0 }, top1.connections.get(Port{ .block = &b9.block, .index = 0 }).?); // h

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

    try std.testing.expectEqual(Port{ .block = &b1.block, .index = 0 }, top2.connections.get(Port{ .block = &b3.block, .index = 0 }).?); // a
    try std.testing.expectEqual(Port{ .block = &b2.block, .index = 0 }, top2.connections.get(Port{ .block = &b3.block, .index = 1 }).?); // b
    try std.testing.expectEqual(Port{ .block = &b3.block, .index = 0 }, top2.connections.get(Port{ .block = &b4.block, .index = 0 }).?); // c
    try std.testing.expectEqual(Port{ .block = &b4.block, .index = 0 }, top2.connections.get(Port{ .block = &b6.block, .index = 0 }).?); // d
    try std.testing.expectEqual(Port{ .block = &b5.block, .index = 0 }, top2.connections.get(Port{ .block = &b6.block, .index = 1 }).?); // e
    try std.testing.expectEqual(Port{ .block = &b5.block, .index = 0 }, top2.connections.get(Port{ .block = &b8.block, .index = 0 }).?); // g
    try std.testing.expectEqual(Port{ .block = &b6.block, .index = 0 }, top2.connections.get(Port{ .block = &b7.block, .index = 0 }).?); // f
    try std.testing.expectEqual(Port{ .block = &b8.block, .index = 0 }, top2.connections.get(Port{ .block = &b9.block, .index = 0 }).?); // h

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
    try std.testing.expectError(FlowgraphError.InputPortNotFound, top3.connectPort(&b3.block, "out1", &b4.block, "in2"));
    try std.testing.expectError(FlowgraphError.OutputPortNotFound, top3.connectPort(&b3.block, "out2", &b4.block, "in1"));

    try top3.connect(&b5.block, &b8.block);
    try std.testing.expectError(FlowgraphError.InputPortAlreadyConnected, top3.connectPort(&b4.block, "out1", &b8.block, "in1"));
}

test "Flowgraph differentiate (input validation)" {
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

    try std.testing.expectError(FlowgraphError.InputPortUnconnected, top2._initialize());
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

    var foo = try FlowgraphRunState.init(top1.allocator, &top1.connections, &top1.block_set);
    defer foo.deinit();

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
        for (x) |_, i| {
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
    for (test_vector) |_, i| {
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
    var expected_output_vector = try std.testing.allocator.alloc(u8, sink_block.buf.items.len);
    defer std.testing.allocator.free(expected_output_vector);
    prng.fill(expected_output_vector);
    for (expected_output_vector) |*e| {
        e.* = ~e.*;
    }

    // Validate output vector
    try std.testing.expectEqualSlices(u8, expected_output_vector, sink_block.buf.items);
}
