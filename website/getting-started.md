---
permalink: getting-started.html
layout: default.njk
---

# Getting Started

## Introduction

ZigRadio is a framework for building signal processing flow graphs. A flow
graph is a directed graph of blocks that processes data samples. Samples in a
flow graph originate at source blocks, are manipulated through intermediate
processing blocks, and terminate at sink blocks. This paradigm — also called
dataflow programming — is useful for software-defined radio, because it allows
you to model the architectures of conventional hardware radios.

In a software-defined radio flow graph, source and sink blocks tend to
implement some kind of I/O, like reading samples from an SDR dongle, or writing
samples to an audio device, while processing blocks tend to be computational,
like filters and multipliers.

### Type Signatures

ZigRadio blocks have data types associated with their input and output ports.
For example, the
[`ComplexMagnitudeBlock`](/reference-manual.html#complexmagnitudeblock) has a
complex-valued input port of type `std.math.Complex(f32)` and real-valued
output port of type `f32`. Block ports can use any Zig type, including custom
types. Many generic processing blocks, such as the
[`MultiplyBlock`](/reference-manual.html#multiplyblock), support compile-time
type parameterization of their ports, and can be instantiated for a variety of
types.

### Sample Rate

ZigRadio blocks have a sample rate associated with them. This is the rate at
which the discrete samples are spaced in time, relative to one another, but not
the rate that they are computationally produced, processed, or consumed by the
framework. Source blocks define their sample rates, while downstream blocks
inherit — and possibly modify — the sample rate of their upstream block. For
example, upsampler and downsampler blocks will multiply and divide the sample
rate, respectively.

ZigRadio propagates sample rates between blocks for you, and ensures that
sample rates match across multiple inputs. Blocks can access their runtime
sample rate to perform sample rate dependent initialization and processing.
Since blocks know their sample rate, blocks can accept parameters in terms of
actual frequencies, e.g. cut-off frequencies in hertz for a filter.

### Flow Graph Termination

While some flow graphs implement a continuously running system (e.g. an FM
broadcast radio receiver), ZigRadio flow graphs are not required to run
forever. When a source terminates, the framework will gracefully collapse the
flow graph as the final samples propagate their way though the graph. This
allows you to build utilities that process finite inputs, like files, to
completion.

## Example

In this example, we will create a simple flow graph to double the frequency of
a tone. It will demonstrate the basic mechanics of instantiating blocks,
connecting blocks, and running a flow graph.

This flow graph [mixes](https://en.wikipedia.org/wiki/Frequency_mixer) a 440 Hz
(A4) tone with itself to create the sum and difference frequency tones at 0 Hz
and 880 Hz, respectively. This output is then filtered with a highpass filter
to leave the 880 Hz (A5) tone, which is played out the speakers with a
PulseAudio sink.

```zig
const std = @import("std");

const radio = @import("radio");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var source = radio.blocks.SignalSource.init(radio.blocks.SignalSource.WaveformFunction.Cosine, 440, 44100, .{});
    var mixer = radio.blocks.MultiplyBlock(f32).init();
    var filter = radio.blocks.SinglepoleHighpassFilterBlock(f32).init(100);
    var sink = radio.blocks.PulseAudioSink(1).init();

    var top = radio.Flowgraph.init(gpa.allocator(), .{ .debug = true });
    defer top.deinit();

    try top.connectPort(&source.block, "out1", &mixer.block, "in1");
    try top.connectPort(&source.block, "out1", &mixer.block, "in2");
    try top.connect(&mixer.block, &filter.block);
    try top.connect(&filter.block, &sink.block);

    try top.start();
    radio.platform.waitForInterrupt();
    _ = try top.stop();
}
```

Run the example within the ZigRadio source tree with:

```plain
$ zig run -lc --dep radio -Mroot=frequency_doubler.zig -Mradio=src/radio.zig
```

The flow graph can be terminated with `SIGINT` (e.g. Ctrl-C).

### Explanation

```zig
const std = @import("std");
```

The first line of the example imports the Zig standard library.

```zig
const radio = @import("radio");
```

The second line imports the `radio` package containing ZigRadio. This package
exposes all ZigRadio blocks, as well the facilities to create flow graphs,
blocks, and types.

```zig
var source = radio.blocks.SignalSource.init(radio.blocks.SignalSource.WaveformFunction.Cosine, 440, 44100, .{});
var mixer = radio.blocks.MultiplyBlock(f32).init();
var filter = radio.blocks.SinglepoleHighpassFilterBlock(f32).init(100);
var sink = radio.blocks.PulseAudioSink(1).init();
```

These lines instantiate each block of the flow graph. Note that the sample rate
is only required for the source block; all other blocks inherit their sample
rate through the connections in the flow graph.

```zig
var top = radio.Flowgraph.init(gpa.allocator(), .{ .debug = true });
defer top.deinit();

try top.connectPort(&source.block, "out1", &mixer.block, "in1");
try top.connectPort(&source.block, "out1", &mixer.block, "in2");
try top.connect(&mixer.block, &filter.block);
try top.connect(&filter.block, &sink.block);
```

The next lines instantiate a flow graph with a default general purpose
allocator, and connect the blocks within the flow graph.

The first two connections demonstrate the explicit connection syntax. For
example, `try top.connectPort(&source.block, "out1", &mixer.block, "in1);`,
where `source`'s output port named `out1` is connected the `mixer`'s input port
named `in1`. In this case, the mixer has two inputs, `in1` and `in2`, so we use
the explicit connection syntax to connect the `source`'s one output to both of
the `mixer`'s inputs.

The third and fourth connections demonstrate the linear block connection
syntax, which is used to connect the first output to the first input of two
blocks. This syntax is convenient for connecting blocks that only have one
input and output, which is most blocks.

```zig
try top.start();
radio.platform.waitForInterrupt();
_ = try top.stop();
```

The last lines of the example start the flow graph, wait for the user's
`SIGINT` signal, and then stop the flow graph. The flow graph will run
indefinitely until the user raises `SIGINT` (e.g. Ctrl-C).

## Blocks and Types

Building flow graphs with ZigRadio is a matter of choosing the right blocks and
connecting them. The [ZigRadio Reference Manual](/reference-manual.html) documents all packaged
blocks, including a description of their operation, their arguments, and their
input/output port names and data types.

ZigRadio blocks use native Zig types for their input and output ports. Common
data types include:

- `std.math.Complex(f32)`, for complex-valued samples
- `f32`, for real-valued samples
- `u8`, for byte samples
- `u1`, for bit samples

In addition, users can create custom data types to represent complex
structures like digital protocol frames.

ZigRadio blocks can also leverage the C APIs of external libraries for custom
processing, acceleration, or I/O.

## Next Steps...

The [Creating Flow Graphs](/creating-flow-graphs.html) guide describes the connecting, running, and
modifying flow graphs.

The [Creating Blocks](/creating-blocks.html) guide describes creating blocks and data types.
