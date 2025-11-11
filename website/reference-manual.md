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

## Flowgraph

The `Flowgraph` is the top-level container for a ZigRadio flow graph.

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

See the [Creating Blocks](/creating-blocks.html#composite-blocks) guide for more information.

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
