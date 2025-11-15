---
permalink: integrating-zigradio.html
layout: default.njk
---

# Integrating ZigRadio

ZigRadio is available as a Zig package that can be compiled directly into host
applications. Its only dependencies are an execution environment that supports
multi-threading and the C library for dynamic library loading.

ZigRadio dynamically loads optional acceleration and I/O libraries at runtime.
Host applications do not need to link against these — or any libraries outside
of the C library — to integrate ZigRadio.

Blocks in a ZigRadio flow graph run in their own thread, so a flow graph can be
started without blocking the host application. Host applications can then use
the thread-safe
[`ApplicationSource(T)`](/reference-manual.html#applicationsource) to push
samples into flow graphs and
[`ApplicationSink(T)`](/reference-manual.html#applicationsink) to consume
samples from a flow graph.

## Application Source

The `ApplicationSource(T)` can be instantiated for any data type and is
initialized with `init(rate: f64) Application(T)`. This requires a sample rate,
as it is a source.

The `wait(self: *Self, min_count: usize, timeout_ns: ?u64) error{ BrokenStream,
Timeout }!void` API waits until a minimum number of samples are available
writing, with an optional timeout. The `available(self: *Self)
error{BrokenStream}!usize` API returns the number of samples that can be
written, or a `BrokenStream` error if the flow graph collapsed downstream.

The low-level `get(self: *Self) []T` API provides direct access to the write
buffer and `update(self: *Self, count: usize) void` advances the write buffer
with the number of samples written.

The high-level `write(self: *Self, samples: []const T) usize` API writes a
slice of samples and returns the number of samples successfully written, which
may be zero.

The high-level `push(self: *Self, value: T) error{Unavailable}!void` API writes
a single sample, or returns an error if space was not available.

The `setEOS(self: *Self) void` sets the end-of-stream condition on the source,
which will subsequently collapse the flow graph.

## Application Sink

The `ApplicationSink(T)` can be instantiated for any data type and is
initialized with `init() ApplicationSink(T)`.

The `wait(self: *Self, min_count: usize, timeout_ns: ?u64) error{ EndOfStream,
Timeout }!void` API waits until a minimum number of samples are available for
reading, with an optional timeout. The `available(self: *Self)
error{EndOfStream}!usize` API returns the number of samples that can be read,
or a `EndOfStream` error if the flow graph collapsed upstream.

The low-level `get(self: *Self) []const T` API provides direct access to the
read buffer and `update(self: *Self, count: usize) void` advances the read
buffer with the number of samples read.

The high-level `read(self: *Self, samples: []T) usize` API reads into a slice
of samples and returns the number of samples successfully read, which may be
zero.

The high-level `pop(self: *Self) ?T` API reads a single sample, or returns
`null` if none was available.

The high-level `discard(self: *Self) !void` API discards all available samples.

## Example

This example creates a flow graph that doubles and then squares samples sourced
from, and then sinked to, an `ApplicationSource(f32)`, and `ApplicationSink(f32)`,
respectively.

```zig
const std = @import("std");

const radio = @import("radio");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var source = radio.blocks.ApplicationSource(f32).init(10000);
    var adder = radio.blocks.AddBlock(f32).init();
    var multiplier = radio.blocks.MultiplyBlock(f32).init();
    var sink = radio.blocks.ApplicationSink(f32).init();

    var top = radio.Flowgraph.init(gpa.allocator(), .{});
    defer top.deinit();

    try top.connectPort(&source.block, "out1", &adder.block, "in1");
    try top.connectPort(&source.block, "out1", &adder.block, "in2");
    try top.connectPort(&adder.block, "out1", &multiplier.block, "in1");
    try top.connectPort(&adder.block, "out1", &multiplier.block, "in2");
    try top.connect(&multiplier.block, &sink.block);

    try top.start();

    // Wait for 3 samples available for writing
    try source.wait(3, null);

    // Write samples 1, 2, 3
    try source.push(1);
    try source.push(2);
    try source.push(3);

    // Wait for 3 samples available for reading
    try sink.wait(3, null);

    // Read three samples
    std.debug.print("{any}\n", .{sink.pop()});
    std.debug.print("{any}\n", .{sink.pop()});
    std.debug.print("{any}\n", .{sink.pop()});

    // Set end-of-stream on source
    source.setEOS();

    // Wait for flowgraph collapse
    _ = try top.wait();
}
```

Run the example within the ZigRadio source tree with:

```plain
$ zig run -lc --dep radio -Mroot=example.zig -Mradio=src/radio.zig
4
16
36
$
```
