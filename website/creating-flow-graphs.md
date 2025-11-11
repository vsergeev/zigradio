---
permalink: creating-flow-graphs.html
layout: default.njk
---

# Creating Flow Graphs

The [`Flowgraph`](/reference-manual.html#flowgraph) is the top-level container
for a ZigRadio flow graph, and provides a simple API for connecting blocks,
running the flow graph, and making asynchronous calls into blocks.

## Instantiation

A `Flowgraph` is instantiated with `init(allocator: std.mem.Allocator, options:
Options) Flowgraph`, which takes an allocator and additional options.

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

var top = radio.Flowgraph.init(gpa.allocator(), .{});
defer top.deinit();
```

## Connecting Blocks

Blocks can be connected within a flow graph in one of two ways.

```zig
// Example of explicit block connections
try top.connectPort(&source.block, "out1", &mixer.block, "in1");
try top.connectPort(&pilot_pll.block, "out1", &mixer.block, "in2");
```

The explicit block connection API `connectPort(self: *Flowgraph, src: anytype,
src_port_name: []const u8, dst: anytype, dst_port_name: []const u8) !void`
connects an output port by name of a source block to an input port by name of a
destination block. This syntax is required when connecting blocks with multiple
outputs or multiple inputs.

```zig
// Example of linear block connections
try top.connect(&source.block, &tuner.block);
try top.connect(&tuner.block, &fm_demod.block);
try top.connect(&fm_demod.block, &af_filter.block);
```

The linear block connection API `connect(self: *Flowgraph, src: anytype, dst:
anytype) !void` omits the port names, and connects the single output port of a
source block to the single input port of a destination block. This syntax can
only be used when connecting single output blocks to single input blocks, which
is most blocks.

A third connection API `alias(self: *Flowgraph, composite: *CompositeBlock,
port_name: []const u8, aliased_block: anytype, aliased_port_name: []const u8)
!void` is used with composite blocks to alias a composite block's input or
output port to an internal block's input or output port. See the [Creating
Blocks](/creating-blocks.html#composite-blocks) guide for more information.

## Running Flow Graphs

```zig
// Start a flow graph and wait until completion
try top.start();
_ = try top.wait();

// Alternatively
_ = try top.run();
```

A flow graph is started with the non-blocking `start(self: *Flowgraph) !void`
API. The blocking `wait(self: *Flowgraph) !bool` API can then be used to wait
for a flow graph to terminate naturally. For convenience, the blocking
`run(self: *Flowgraph) !bool` API combines `start()` and `wait()`. Both
`wait()` and `run()` return a success boolean, indicating the flow graph
completed without block process errors.

For flow graphs that run indefinitely, the blocking `stop(self: *Flowgraph)
!bool` API can be used to shutdown all source blocks and wait for termination
as the flow graph collapses.

## Asynchronous Control

```zig
// Set the cutoff frequency of audio filter
try top.call(&af_filter.block, radio.blocks.LowpassFilterBlock(f32, 128).setCutoff, .{5e3});

// Get cutoff frequency of audio filter
const cutoff = try top.call(&af_filter.block, radio.blocks.LowpassFilterBlock(f32, 128).getCutoff, .{});
```

Since flow graph blocks run in their own threads, calls into blocks must be
made from their running thread for race and memory safety. The `Flowgraph`
wrapper `call(self: *Flowgraph, block: anytype, comptime function: anytype,
args: anytype) CallReturnType(function)` API is used to make arbitrary
thread-safe calls into a block. This API can be used to set and get parameters,
trigger functionality, etc. in a block.
