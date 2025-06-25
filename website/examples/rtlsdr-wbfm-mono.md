---
permalink: /examples/rtlsdr-wbfm-mono.html
layout: default.njk
subtitle: WBFM Mono Receiver Example
---

# `rtlsdr_wbfm_mono.zig`

This example is a mono Wideband FM broadcast radio receiver. It can be used to
listen to [FM Broadcast](https://en.wikipedia.org/wiki/FM_broadcasting)
stations. It uses the RTL-SDR as an SDR source and plays audio with PulseAudio.

This mono Wideband FM broadcast demodulator is available in ZigRadio as the
`WBFMMonoDemodulator` block.

### Source

```zig
{% include "../examples/rtlsdr_wbfm_mono.zig" %}
```

### Usage

```plain
Usage: ./zig-out/bin/example-rtlsdr_wbfm_mono <FM radio frequency>
```

For example, listen to 91.1 MHz:

```plain
$ ./zig-out/bin/example-rtlsdr_wbfm_mono 91.1e6
```
