---
permalink: /examples/iqfile-converter.html
layout: default.njk
subtitle: IQ File Converter Example
---

# `iqfile_converter.zig`

This example is an IQ file format converter. It converts the binary encoding of
IQ files from one format, e.g. signed 8-bit, to another, e.g. 32-bit float
little endian. This example doesn't use an SDR source at all, but instead
demonstrates how you can build file-based command-line utilities with
modulation, demodulation, decoding, file conversion, etc. flow graphs that run
to completion.

### Source

```zig
{% include "../examples/iqfile_converter.zig" %}
```

### Usage

```plain
Usage: ./zig-out/bin/example-iqfile_converter <input IQ file> <input format> <output IQ file> <output format>
Supported formats: u8, s8, u16le, u16be, s16le, s16be, u32le, u32be, s32le, s32be, f32le, f32be, f64le, f64be
```

For example, convert `test.u8.iq`, with unsigned 8-bit samples, to
`test.f32le.iq`, with 32-bit float little endian samples:

```plain
$ ./zig-out/bin/example-iqfile_converter test.u8.iq u8 test.f32le.iq f32le
```
