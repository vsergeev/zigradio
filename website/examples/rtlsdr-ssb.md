---
permalink: /examples/rtlsdr-ssb.html
layout: default.njk
subtitle: SSB Receiver Example
---

# `rtlsdr_ssb.zig`

This example is a
[Single-Sideband](https://en.wikipedia.org/wiki/Single-sideband_modulation)
(SSB) radio receiver. SSB is commonly used by amateur radio operators on the HF
band, and sometimes on the VHF and UHF bands, for voice and digital (modulated
in the audio) communication. This example uses the RTL-SDR as an SDR source and
plays audio with PulseAudio.

This single-sideband demodulator composition is available in ZigRadio as the
`SSBDemodulator` block.

### Source

```zig
{% include "../examples/rtlsdr_ssb.zig" %}
```

### Usage

```plain
Usage: ./zig-out/bin/example-rtlsdr_ssb <frequency> <sideband>
```

For example, listen to 3.745 MHz, lower sideband:

```plain
$ ./zig-out/bin/example-rtlsdr_nbfm 3.745e6 lsb
```
