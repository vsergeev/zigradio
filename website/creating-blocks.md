---
permalink: creating-blocks.html
layout: default.njk
---

# Creating Blocks

ZigRadio blocks are essentially Zig structures that implement a `process()`
function to convert input samples to output samples. Additionally, blocks may
implement optional hooks for initialization, deinitialization, and sample rate
manipulation, which are automatically called by the ZigRadio framework during
the setup and teardown of a flow graph.

Blocks may also implement arbitrary functions to set or get their state at
runtime, or trigger other functionality, which can be called in a thread-safe
manner through the flow graph.

## Basic Block

```zig
const radio = @import("radio");

pub const MultiplyBlock = struct {
    block: radio.Block,

    pub fn init() MultiplyBlock {
        return .{ .block = radio.Block.init(@This()) };
    }

    pub fn process(_: *MultiplyBlock, x: []const f32, y: []const f32, z: []f32) !radio.ProcessResult {
        for (x, 0..) |_, i| {
            z[i] = x[i] * y[i];
        }

        return radio.ProcessResult.init(&[2]usize{ x.len, x.len }, &[1]usize{x.len});
    }
};
```

At a minimum, a ZigRadio block requires a `block: radio.Block` field and a
`process()` function.

The `block` field holds the relevant information about the block, including its
type signature, port names, implemented hooks, etc., which are required by the
framework to connect and run the block. This field is automatically populated
at compile-time with introspection by calling `radio.Block.init(@This())`. A
reference to the `block` field for a particular block instance (e.g.
`&multiplyblock.block`) is the unique handle used by `Flowgraph` APIs for
connecting blocks or for calling into them.

The `process()` function is the main function of the block, called by the
framework repeatedly to convert input samples to output samples. The framework
deduces the input and output ports and their data types from the type signature
of a block's `process()` function. Arguments of a constant slice type map to
input ports, and those of mutable slice type map to output ports. The
`process()` function may access and manipulate a block's state through `self`
argument.

The ZigRadio framework guarantees that `process()` is only called when there
are a non-zero amount of input samples available across all inputs, and at
least as many output samples available, across all outputs. Blocks that need to
produce more or less output samples relative to input samples are responsible
for managing the available samples, which may require buffering them.

The return value of `process()` is a `ProcessResult`, which provides an
accounting of how many samples were consumed and produced, allowing the
framework to acknowledge input samples from upstream blocks and make output
samples available to downstream blocks. This type can be constructed with
`ProcessResult.init(consumed: []const usize, produced: []const usize)
ProcessResult`, where `consumed` contains the input samples consumed, and
`produced` contains the output samples produced. The order of inputs in
`consumed` and outputs in `produced` follow the order of inputs and outputs in
the `process()` type signature, respectively.

The `process()` function may also return an error, which will cause the block
to terminate and the flow graph to collapse.

## Block Hooks

ZigRadio blocks may implement a few optional hooks that are automatically
called by the framework.

```zig
pub fn initialize(self: *Self, allocator: std.mem.Allocator) !void { ... }
```

The `initialize()` hook is used for memory allocation, I/O initialization, and
sample rate dependent initialization. This function is called by the framework
during flow graph setup, after all blocks are connected and their sample rates
are determined.

The `allocator` passed to `initialize()` is the same one that the
[`Flowgraph`](/reference-manual.html#flowgraph) was initialized with. Blocks
may call `self.block.getRate(comptime T: type) T` in `initialize()` to get
their sample rate in terms of their preferred numeric type (e.g. `f32`,
`usize`, etc.).

Blocks may return an error from `initialize()`, which will cause flow graph
initialization to fail.

```zig
pub fn deinitialize(self: *Self, allocator: std.mem.Allocator) void { ... }
```

The `deinitialize()` hook is used for memory deallocation, I/O
deinitialization, and other deinitialization. The function is called by the
framework on flow graph teardown. The `allocator` passed to `deinitialize()` is
the same as the one passed to `initialize()`, for convenience.

```zig
pub fn setRate(self: *Self, upstream_rate: f64) !f64 { ... }
```

The `setRate()` hook is used to override the block's sample rate. By default,
blocks inherit the sample rate of the upstream block connected to their first
input port. Blocks that produce samples at a different sample rate from their
inputs (e.g. downsamplers, upsamplers, etc.), may implement their own
`setRate()` which returns the modified sample rate. The upstream rate is passed
in the `upstream_rate` argument.

Blocks may return an error from `setRate()`, which will cause flow graph
initialization to fail.

## Data Types

ZigRadio blocks use native Zig types for their input and output ports. Common
data types include:

- `std.math.Complex(f32)`, for complex-valued samples
- `f32`, for real-valued samples
- `u8`, for byte samples
- `u1`, for bit samples

Blocks may also use arbitrary `struct` and `union` types for inputs and
outputs, like any other type. Custom types must implement the `typeName()
[]const u8` getter for error reporting and debug logging by the framework.

## Parametric Types

Blocks can accept parametric types in the typical fashion for Zig: with a
function that accepts a comptime type and returns a structure parameterized by
that type.

```zig
const radio = @import("radio");

pub fn MultiplyBlock(comptime T: type) type {
    return struct {
        const Self = @This();

        block: radio.Block,

        pub fn init() Self {
            return .{ .block = radio.Block.init(@This()) };
        }

        pub fn process(_: *Self, x: []const T, y: []const T, z: []T) !radio.ProcessResult {
            for (x, 0..) |_, i| {
                z[i] = x[i] * y[i];
            }

            return radio.ProcessResult.init(&[2]usize{ x.len, x.len }, &[1]usize{x.len});
        }
    };
}
```

In this case, `MultiplyBlock` is made parametric by accepting a comptime type
`T` that supports the multiply operator, which is most numeric types. This
`MultiplyBlock` can be instantiated as `MultiplyBlock(f32)`,
`MultiplyBlock(u32)`, etc.

## Special Types

Custom types that need resource management, e.g. memory allocation and
deallocation, require the reference counted wrapper type, `RefCounted(T)`. This
wrapper type calls `.init(...)` on the underlying type once on creation, and
`.deinit()` on the underlying type when its reference count has decremented to
zero.

This allows blocks to create dynamic samples (e.g. samples with memory or other
resource management) that are initialized once, propagated to multiple
downstream blocks, and then finally deinitialized after being processed by the
final block.

```zig
const std = @import("std");

const radio = @import("radio");

pub const MyPacket = struct {
    src: u32 = 0,
    dst: u32 = 0,
    payload: []u8 = &.{},

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MyPacket {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MyPacket) void {
        self.allocator.free(self.payload);
    }

    pub fn typeName() []const u8 {
        return "MyPacket";
    }
};
```

In this example, `MyPacket` has a dynamically allocated `payload` field. A block might produce
a `RefCounted(MyPacket)` as in the example below:

```zig
pub fn process(self: *MyPacketDecoderBlock, x: []const u1, z: []RefCounted(MyPacket)) !ProcessResult {
    ...
    z[j] = RefCounted(MyPacket).init(self.allocator);
    z[j].value.src = ...;
    z[j].value.dst = ...;
    z[j].value.payload = try self.allocator.dupe(u8, ...);
    j += 1;
    ...
    return ProcessResult.init(&[1]usize{i}, &[1]usize{j});
}
```

## Asynchronous Control

Blocks can provide arbitrary functions to access or modify their state at
runtime. These are normal functions, which are run exclusively of `process()`
by the block runner thread, and thus require no special locking.

```zig
const radio = @import("radio");

pub const MultiplyConstantBlock = struct {
    block: radio.Block,
    constant: f32,

    pub fn init(constant: f32) MultiplyConstantBlock {
        return .{ .block = radio.Block.init(@This()), .constant = constant };
    }

    pub fn process(self: *MultiplyConstantBlock, x: []const f32, z: []f32) !radio.ProcessResult {
        for (x, 0..) |_, i| {
            z[i] = x[i] * self.constant;
        }

        return radio.ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
    }

    pub fn setConstant(self: *MultiplyConstantBlock, constant: f32) !void {
        if (constant > 9000) return error.OutOfBounds;
        self.constant = constant;
    }

    pub fn getConstant(self: *MultiplyConstantBlock) f32 {
        return self.constant;
    }
};
```

This block exposes a `setConstant()` function to update its constant, and a
`getConstant()` function to return it. These block functions can be called in a
thread-safe manner through the flow graph with `try
flowgraph.call(&multiplyconstant.block, MultiplyConstantBlock.setConstant,
.{123});` and `const constant = try flowgraph.call(&multiplyconstant.block,
MultiplyConstantBlock.getConstant, .{});`.

## Composite Blocks

Composite blocks are a composition of blocks with internal connectivity
and input/output ports at their boundary.

```zig
const radio = @import("radio");

pub const MultiplyConstantAndSquareBlock = struct {
    block: radio.CompositeBlock,
    b1: radio.blocks.MultiplyConstantBlock,
    b2: radio.blocks.MultiplyBlock,

    pub fn init(constant: f32) MultiplyConstantAndSquareBlock {
        return .{
            .block = radio.CompositeBlock.init(@This(), &.{"in1"}, &.{"out1"}),
            .b1 = radio.blocks.MultiplyConstantBlock.init(constant),
            .b2 = radio.blocks.MultiplyBlock.init(),
        };
    }

    pub fn connect(self: *MultiplyConstantAndSquareBlock, flowgraph: *radio.Flowgraph) !void {
        // Internal connections
        try flowgraph.connectPort(&self.b1.block, "out1", &self.b2.block, "in1");
        try flowgraph.connectPort(&self.b1.block, "out1", &self.b2.block, "in2");

        // Alias inputs and outputs
        try flowgraph.alias(&self.block, "in1", &self.b1.block, "in1");
        try flowgraph.alias(&self.block, "out1", &self.b2.block, "out1");
    }
};
```

At a minimum, a composite block requires a `block: radio.CompositeBlock` field
and a `connect()` function.

The `block` field holds the relevant information about the composite block,
including its input and output port names, implemented hooks, etc., which are
required by the framework to connect the composition. This field is
automatically populated at compile-time by calling
`radio.CompositeBlock.init(@This(), &.{ inputs... }, &.{ outputs... })`, where
inputs and outputs are the names of the input and output ports, respectively.

The `connect()` function is responsible for making internal connections and
defining the boundary ports of the composition. These connections are stored
within the parent flow graph. Within `connect()`, the ordinary flow graph
`connect()` and `connectPort()` functions are used to make internal block
connections, while the flow graph `alias()` function is used to alias a
composite block's input or output port to an internal block's input or output
port.

The example above illustrates a composition of `MultiplyConstantBlock` and
`MultiplyBlock` to multiply a signal by a constant and then square it.

Composite blocks may also expose their own functions for asynchronous control.
However, they must call internal blocks through the provided `Flowgraph`
argument for thread safety:

```zig
pub const MultiplyConstantAndSquareBlock = struct {
    ...

    pub fn setConstant(self: *MultiplyConstantAndSquareBlock, flowgraph: *Flowgraph, constant: f32) !void {
        try flowgraph.call(&self.b1.block, MultiplyConstantBlock.setConstant, .{constant});
    }
};
```

This composite block function can be called in a thread-safe manner through a
flow graph with `try top.call(&multiplyconstantandsquare.block,
MultiplyConstantAndSquareBlock.setConstant, .{123});`.
