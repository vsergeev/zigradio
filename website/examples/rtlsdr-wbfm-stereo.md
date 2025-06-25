---
permalink: /examples/rtlsdr-wbfm-stereo.html
layout: default.njk
subtitle: WBFM Stereo Receiver Example
---

# `rtlsdr_wbfm_stereo.zig`

This example is a stereo Wideband FM broadcast radio receiver. It can be used
to listen to [FM Broadcast](https://en.wikipedia.org/wiki/FM_broadcasting)
stations, like the mono Wideband FM example, but it also supports stereo sound.
It uses the RTL-SDR as an SDR source and plays audio with PulseAudio.

This stereo Wideband FM broadcast demodulator composition is available in
ZigRadio as the `WBFMStereoDemodulator` block.

### Source

```zig
{% include "../examples/rtlsdr_wbfm_stereo.zig" %}
```

### Usage

```plain
Usage: ./zig-out/bin/example-rtlsdr_wbfm_stereo <FM radio frequency>
```

For example, listen to 91.1 MHz:

```plain
$ ./zig-out/bin/example-rtlsdr_wbfm_stereo 91.1e6
```
