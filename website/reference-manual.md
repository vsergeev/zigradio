---
permalink: reference-manual.html
layout: refman.njk
templateEngineOverride: njk,md

categories:
  - Sources
  - Sinks
  - Filtering
  - Math Operations
  - Level Control
  - Sample Rate Manipulation
  - Spectrum Manipulation
  - Carrier and Clock Recovery
  - Digital
  - Type Conversion
  - Miscellaneous
  - Demodulation
---

# ZigRadio Reference Manual

Generated from ZigRadio `{{ version.git_tag_long }}`.

## Example

##### Wideband FM Broadcast Stereo Receiver

```zig
const std = @import("std");

const radio = @import("radio");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const frequency = 91.1e6; // 91.1 MHz

    var source = radio.blocks.RtlSdrSource.init(frequency - 250e3, 960000, .{ .debug = true });
    var tuner = radio.blocks.TunerBlock.init(-250e3, 200e3, 4);
    var demodulator = radio.blocks.WBFMStereoDemodulatorBlock.init(.{});
    var l_af_downsampler = radio.blocks.DownsamplerBlock(f32).init(5);
    var r_af_downsampler = radio.blocks.DownsamplerBlock(f32).init(5);
    var sink = radio.blocks.PulseAudioSink(2).init();

    var top = radio.Flowgraph.init(gpa.allocator(), .{ .debug = true });
    defer top.deinit();
    try top.connect(&source.block, &tuner.block);
    try top.connect(&tuner.block, &demodulator.block);
    try top.connectPort(&demodulator.block, "out1", &l_af_downsampler.block, "in1");
    try top.connectPort(&demodulator.block, "out2", &r_af_downsampler.block, "in1");
    try top.connectPort(&l_af_downsampler.block, "out1", &sink.block, "in1");
    try top.connectPort(&r_af_downsampler.block, "out1", &sink.block, "in2");

    try top.start();
    radio.platform.waitForInterrupt();
    _ = try top.stop();
}
```

## Building

Fetch the ZigRadio package:

```
zig fetch --save git+https://github.com/vsergeev/zigradio#master
```

Add ZigRadio as a dependency to your `build.zig`:

```zig
const radio = b.dependency("radio", .{});
...
exe.root_module.addImport("radio", radio.module("radio"));
exe.linkLibC();
```

Optimization `ReleaseFast` is recommended for real-time applications. libc is
required for loading dynamic libraries used for acceleration and I/O.

## Running

### Acceleration

ZigRadio uses optional external libraries for acceleration, including
[VOLK](https://www.libvolk.org/), [liquid-dsp](https://liquidsdr.org/), and
[FFTW](https://www.fftw.org/). These libraries are automatically loaded at
runtime, when available, and are recommended for real-time applications.

### Environment Variables

Several environment variables control ZigRadio's runtime behavior, and
can be enabled with truthy literals like `1`, `true`, or `yes`:

- `ZIGRADIO_DEBUG`: Enable debug verbosity
- `ZIGRADIO_DISABLE_LIQUID`: Disable liquid-dsp library
- `ZIGRADIO_DISABLE_VOLK`: Disable volk library
- `ZIGRADIO_DISABLE_FFTW3F`: Disable fftw3f library

For example, to enable debug verbosity:

```
$ ZIGRADIO_DEBUG=1 ./path/to/zigradio-program
```

To run a script with no external acceleration libraries:

```
$ ZIGRADIO_DISABLE_LIQUID=1 ZIGRADIO_DISABLE_VOLK=1 ZIGRADIO_DISABLE_FFTW3F=1 ./path/to/zigradio-program
```

## Core

### Flowgraph

The `Flowgraph` type is the top-level container for a ZigRadio flow graph.

##### `radio.Flowgraph.init(allocator: std.mem.Allocator, options: Options) Flowgraph`

Instantiate a flow graph with the provided allocator and options (`struct {
debug: bool = false }`).

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

var top = radio.Flowgraph.init(gpa.allocator(), .{ .debug = true });
defer top.deinit();
```

##### `radio.Flowgraph.connect(self: *Flowgraph, src: anytype, dst: anytype) !void`

Connect the first output port of `src` block to the first input port of `dst` block.

```zig
try top.connect(&src.block, &snk.block);
```

##### `radio.Flowgraph.connectPort(self: *Flowgraph, src: anytype, src_port_name: []const u8, dst: anytype, dst_port_name: []const u8) !void`

Connect the output port `src_port_name` of `src` block to the input port `dst_port_name` of `dst` block.

```zig
try top.connect(&l_filter.block, "out1", &sink.block, "in1");
try top.connect(&r_filter.block, "out1", &sink.block, "in2");
```

##### `radio.Flowgraph.alias(self: *Flowgraph, composite: *CompositeBlock, port_name: []const u8, aliased_block: anytype, aliased_port_name: []const u8) !void`

Alias the input or output `port_name` of `composite` block to the input or output port `aliased_port_name` of `aliased_block` block. Only used within the `connect()` hook of a composite block.

```zig
pub fn connect(self: *MyCompositeBlock, flowgraph: *Flowgraph) !void {
    ...
    try flowgraph.alias(&self.block, "in1", &self.b1.block, "in1");
    try flowgraph.alias(&self.block, "out1", &self.b2.block, "out1");
}
```

##### `radio.Flowgraph.start(self: *Flowgraph) !void`

Start the flow graph. This function does not block.

```zig
try top.start();
```

##### `radio.Flowgraph.wait(self: *Flowgraph) !bool`

Wait for the flow graph to terminate naturally. This function blocks. Returns
true on success, or false for any block process failures.

```zig
bool success = try top.wait();
```

##### `radio.Flowgraph.stop(self: *Flowgraph) !bool`

Stop the flow graph by stopping any source blocks and then waiting for the flow
graph to terminate naturally. This function blocks. Returns true on success, or
false for any block process failures.

```zig
bool success = try top.stop();
```

##### `radio.Flowgraph.run(self: *Flowgraph) !bool`

Run the flow graph. This is equivalent to calling `start()` and then `wait()`.
This function blocks.

```zig
bool success = try top.run();
```

##### `radio.Flowgraph.call(self: *Flowgraph, block: anytype, comptime function: anytype, args: anytype) CallReturnType(function)`

Make a thread-safe call into a block in the flow graph.

```zig
try top.call(&af_filter.block, radio.blocks.LowpassFilterBlock(f32, 128).setCutoff, .{5e3});
```

### Block

The `Block` type is the container for a ZigRadio block, holding its port names and
types, implemented hooks, and sample rate.

ZigRadio blocks are implemented by wrapping a nested `Block` structure, which
is initialized using introspection with the `radio.Block.init(comptime
BlockType: type) radio.Block` constructor and providing a `process()` hook.

#### Example

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

#### Process Hook

##### `pub fn process(self: *BlockType, in1: []const f32, in2: []const f32, ..., out1: []std.math.Complex(f32), out2: []std.math.Complex(f32), ...) !radio.ProcessResult { ... }`

The `process()` hook is the main function of the block, called by the framework
repeatedly to convert input samples to output samples.

The framework deduces the input and output ports and their data types of a
ZigRadio block from the type signature of the block's `process()` function.
Arguments of a constant slice type map to input ports, while those of mutable
slice type map to output ports. The `process()` function may access and
manipulate the block's state through the `self` argument.

The ZigRadio framework guarantees that `process()` is only called when there
are a non-zero amount of input samples available across all inputs, and at
least as many output samples available, across all outputs. Blocks that need to
produce more or less output samples relative to input samples are responsible
for managing the available samples, which may require buffering them.

The return value of `process()` is a `ProcessResult`, which provides an
accounting of how many samples were consumed and produced, allowing the
framework to acknowledge input samples from upstream blocks and make output
samples available to downstream blocks.

The `process()` function may also return an error, which will cause the block
to terminate and the flow graph to collapse.

##### `radio.ProcessResult.init(consumed: []const usize, produced: []const usize) ProcessResult`

Construct a `ProcessResult`, where `consumed` contains the input samples
consumed, and `produced` contains the output samples produced. The order of
inputs in `consumed` and outputs in `produced` follow the order of inputs and
outputs in the `process()` type signature, respectively.

#### Optional Hooks

Blocks may implement a few optional hooks called by the framework.

##### `pub fn initialize(self: *Self, allocator: std.mem.Allocator) !void { ... }`

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

##### `pub fn deinitialize(self: *Self, allocator: std.mem.Allocator) void { ... }`

The `deinitialize()` hook is used for memory deallocation, I/O
deinitialization, and other deinitialization. The function is called by the
framework on flow graph teardown. The `allocator` passed to `deinitialize()` is
the same as the one passed to `initialize()`, for convenience.

##### `pub fn setRate(self: *Self, upstream_rate: f64) !f64 { ... }`

The `setRate()` hook is used to override the block's sample rate. By default,
blocks inherit the sample rate of the upstream block connected to their first
input port. Blocks that produce samples at a different sample rate from their
inputs (e.g. downsamplers, upsamplers, etc.), may implement their own
`setRate()` which returns the modified sample rate. The upstream rate is passed
in the `upstream_rate` argument.

Blocks may return an error from `setRate()`, which will cause flow graph
initialization to fail.

### Composite Block

The `CompositeBlock` type is the container for a ZigRadio block composition of
blocks with internal connectivity and input/output ports at their boundary.

ZigRadio composite blocks are implemented by wrapping a nested `CompositeBlock` structure, which
is initialized the `init(comptime CompositeType: type, inputs: []const []const u8, outputs: []const []const u8) radio.CompositeBlock` constructor and providing a `connect()` hook.

#### Example

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

#### Connect Hook

##### `pub fn connect(self: *CompsiteType, flowgraph: *Flowgraph) !void`

The `connect()` hook is responsible for making internal connections and
defining the boundary ports of the composition, stored in the parent flow graph.

Within `connect()`, the ordinary flow graph [`connect()`](#radio-flowgraph-connect-self-flowgraph-src-anytype-dst-anytype-void) and [`connectPort()`](#radio-flowgraph-connectport-self-flowgraph-src-anytype-src-port-name-const-u8-dst-anytype-dst-port-name-const-u8-void) APIs are used to make internal block connections, while the flow graph [`alias()`](#radio-flowgraph-alias-self-flowgraph-composite-compositeblock-port-name-const-u8-aliased-block-anytype-aliased-port-name-const-u8-void) API is used to alias a composite block's input or output port to an internal block's input or output port.

Composite blocks may return an error from `connect()`, which will cause flow
graph initialization to fail.

### Data Types

ZigRadio blocks use native Zig types for their input and output ports. Common
data types include:

- `std.math.Complex(f32)`, for complex-valued samples
- `f32`, for real-valued samples
- `u8`, for byte samples
- `u1`, for bit samples

#### Custom Types

ZigRadio blocks can also use arbitrary `struct` and `union` types for inputs
and outputs, like any other type. Custom types must implement the `typeName()
[]const u8` getter for error reporting and debug logging by the framework.

```zig
pub const WeatherPacket = struct {
    temperature: i8 = 0,
    humidity: u8 = 0,
    wind_speed: u8 = 0,
    wind_direction: enum { N, E, S, W } = .N,

    pub fn typeName() []const u8 {
        return "WeatherPacket";
    }
};
```

#### Special Types

##### `RefCounted(T: type) type`

Create a reference-counted type wrapping an underlying type. Underlying type
must implement `init(...) T` for element initialization on first reference, and
`deinit(self: *T) void` for deinitialization on last unreference.

### Asynchronous Control

Blocks can provide arbitrary functions to access or modify their state at
runtime. These are normal functions, which are run exclusively of `process()`
by the block runner thread, and thus require no special locking.

#### Block Example

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
thread-safe manner through the flow graph [`call()`](#radio-flowgraph-call-self-flowgraph-block-anytype-comptime-function-anytype-args-anytype-callreturntype-function) API:

```zig
// Set Constant
try flowgraph.call(&multiplyconstant.block, MultiplyConstantBlock.setConstant, .{123});
```

```zig
// Get Constant
const constant = try flowgraph.call(&multiplyconstant.block, MultiplyConstantBlock.getConstant, .{});
```

#### Composite Block Example

Composite blocks also support asynchronous calls, but must nest calls into
child blocks through the passed `Flowgraph` instance:

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

    pub fn setConstant(self: *MultiplyConstantAndSquareBlock, flowgraph: *Flowgraph, constant: f32) !void {
        try flowgraph.call(&self.b1.block, MultiplyConstantBlock.setConstant, .{constant});
    }

    pub fn getConstant(self: *MultiplyConstantAndSquareBlock, flowgraph: *Flowgraph) !f32 {
        return try flowgraph.call(&self.b1.block, MultiplyConstantBlock.getConstant, .{});
    }
};
```

This composite block exposes a `setConstant()` function to update its constant,
and a `getConstant()` function to return it. These block functions can be
called in a thread-safe manner through the flow graph [`call()`](#radio-flowgraph-call-self-flowgraph-block-anytype-comptime-function-anytype-args-anytype-callreturntype-function) API:

```zig
// Set Constant
try flowgraph.call(&multiplyconstantandsquare.block, MultiplyConstantAndSquareBlock.setConstant, .{123});
```

```zig
// Get Constant
const constant = try flowgraph.call(&multiplyconstantandsquare.block, MultiplyConstantAndSquareBlock.getConstant, .{});
```

Note that nested asynchronous calls in a composite block will be executed
sequentially, but not simultaneously, due to independent locking of each child
block.

## Blocks

{% for category in categories %}

### {{ category }}

{% for block, tags in refman.blocks[category] %}

#### {{ block }}

<div class="block">

{{ tags['@description'][0] }}

{% set ctparamlist -%}
{%- set comma = joiner(', ') -%}
{%- for ctparam in tags['@ctparam'] -%}
{{ comma() }}comptime {{ ctparam.split(' ')[0] }}: {{ ctparam.split(' ')[1] }}
{%- endfor -%}
{%- endset -%}
{%- set paramlist -%}
{%- set comma = joiner(', ') -%}
{%- for param in tags['@param'] -%}
{{ comma() }}{{ param.split(' ')[0] }}: {{ param.split(' ')[1] }}
{%- endfor -%}
{%- endset -%}

##### `radio.blocks.{{ block }}{{ "(" + ctparamlist + ")" if tags['@ctparam'] else "" }}.init({{ paramlist }})`

{%if tags['@ctparam'] %}

###### Comptime Arguments

{% for ctparam in tags['@ctparam'] %}
{% set fields = ctparam.split(' ') %}

- `{{ fields[0] }}` (_{{ fields[1] }}_): {{ fields.slice(2).join(' ') }}

{% endfor %}
{% endif %}

{%if tags['@param'] %}

###### Arguments

{% for param in tags['@param'] %}
{% set fields = param.split(' ') %}

- `{{ fields[0] }}` (_{{ fields[1] }}_): {{ fields.slice(2).join(' ') }}

{% endfor %}
{% endif %}

###### Type Signature

{% set fields = tags['@signature'][0].split(' ') %}
{% set inputs = fields.slice(0, fields.indexOf('>')) %}
{% set outputs = fields.slice(fields.indexOf('>') + 1) %}
{% set representation = "➔❑➔" if inputs.length > 0 and outputs.length > 0 else ("➔❑" if inputs.length > 0 else "❑➔") %}

{%- set comma1 = joiner(', ') -%}
{%- set comma2 = joiner(', ') -%}

- {% for input in inputs %}{{ comma1() }}`{{ input.split(':')[0] }}` _{{ input.split(':')[1] }}_{% endfor %} {{ representation }} {% for output in outputs %}{{ comma2() }}`{{ output.split(':')[0] }}` _{{ output.split(':')[1] }}_{% endfor %}

{%if tags['@usage'] %}

###### Example

```zig
{{ tags['@usage'][0] | safe }}
```

{% endif %}

</div>

---

{% endfor %}

{% endfor %}
