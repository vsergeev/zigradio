# ZigRadio [![Tests Status](https://github.com/vsergeev/zigradio/actions/workflows/tests.yml/badge.svg)](https://github.com/vsergeev/zigradio/actions/workflows/tests.yml) [![GitHub release](https://img.shields.io/github/release/vsergeev/zigradio.svg?maxAge=7200)](https://github.com/vsergeev/zigradio) [![License](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/vsergeev/zigradio/blob/master/LICENSE)

**ZigRadio** is a lightweight flow graph signal processing framework for
software-defined radio. It provides a suite of source, sink, and processing
blocks, with a simple API for defining flow graphs, running flow graphs, and
creating blocks. ZigRadio has an API similar to that of
[LuaRadio](https://luaradio.io/) and is also MIT licensed.

ZigRadio can be used to rapidly prototype software radios,
modulation/demodulation utilities, and signal processing experiments.

## Example

##### Wideband FM Broadcast Radio Receiver

``` zig
const std = @import("std");

const radio = @import("radio");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const frequency: f64 = 91.1e6; // 91.1 MHz
    const tune_offset = -250e3;

    var source = radio.blocks.RtlSdrSource.init(frequency + tune_offset, 960000, .{ .debug = true });
    var if_translator = radio.blocks.FrequencyTranslatorBlock.init(tune_offset);
    var if_filter = radio.blocks.LowpassFilterBlock(std.math.Complex(f32), 128).init(200e3, .{});
    var if_downsampler = radio.blocks.DownsamplerBlock(std.math.Complex(f32)).init(4);
    var fm_demod = radio.blocks.FrequencyDiscriminatorBlock.init(75e3);
    var af_filter = radio.blocks.LowpassFilterBlock(f32, 128).init(15e3, .{});
    var af_deemphasis = radio.blocks.FMDeemphasisFilterBlock.init(75e-6);
    var af_downsampler = radio.blocks.DownsamplerBlock(f32).init(5);
    var sink = radio.blocks.PulseAudioSink(1).init();

    var top = radio.Flowgraph.init(gpa.allocator(), .{ .debug = true });
    defer top.deinit();
    try top.connect(&source.block, &if_translator.block);
    try top.connect(&if_translator.block, &if_filter.block);
    try top.connect(&if_filter.block, &if_downsampler.block);
    try top.connect(&if_downsampler.block, &fm_demod.block);
    try top.connect(&fm_demod.block, &af_filter.block);
    try top.connect(&af_filter.block, &af_deemphasis.block);
    try top.connect(&af_deemphasis.block, &af_downsampler.block);
    try top.connect(&af_downsampler.block, &sink.block);

    _ = try top.run();
}
```

Check out some more [examples](examples) of what you can build with ZigRadio.

## Building

ZigRadio requires Zig version 0.14.0.

```
$ git clone https://github.com/vsergeev/zigradio.git
$ cd zigradio
```

Build examples:

``` shell
$ zig build examples
```

Try out one of the [examples](examples) with an
[RTL-SDR](http://www.rtl-sdr.com/about-rtl-sdr/) dongle:

```
$ ./zig-out/bin/example-rtlsdr_wbfm_mono 89.7e6
```

## Embedding ZigRadio

Fetch the ZigRadio package:

```
zig fetch --save git+https://github.com/vsergeev/zigradio#master
```

Add ZigRadio as a dependency to your `build.zig`:

```
const radio = b.dependency("radio", .{});
...
exe.root_module.addImport("radio", radio.module("radio"));
exe.linkLibC();
```

Optimization `ReleaseFast` is recommended for real-time applications. libc is
required for loading dynamic libraries used for acceleration and I/O.

## Project Structure

* [src/](src/) - Sources
    * [radio.zig](src/radio.zig) - Top-level package
    * [core/](src/core) - Core framework
    * [blocks/](src/blocks) - Blocks
        * [sources/](src/blocks/sources) - Sources
        * [sinks/](src/blocks/sinks) - Sinks
        * [signal/](src/blocks/signal) - Signal blocks
        * [composites/](src/blocks/composites) - Composite blocks
    * [utils/](src/utils) - Utility functions
    * [vectors/](src/vectors) - Generated test vectors
* [examples/](examples) - Examples
* [benchmarks/](benchmarks) - Benchmark Suite
* [docs/](docs) - Documentation
* [build.zig](build.zig) - Zig build script
* [build.zig.zon](build.zig.zon) - Zig package manifest
* [CHANGELOG.md](CHANGELOG.md) - Change log
* [LICENSE](LICENSE) - MIT License
* [README.md](README.md) - This README

## Testing

Run unit tests with:

```
$ zig build test
```

Test vectors are generated with Python 3 and NumPy/SciPy:

```
$ zig build generate
```

## Benchmarking

Run the benchmark suite with:

```
$ zig build benchmark
```

## License

ZigRadio is MIT licensed. See the included [LICENSE](LICENSE) file.
