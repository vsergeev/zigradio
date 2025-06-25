---
permalink: /examples/rtlsdr-nbfm.html
layout: default.njk
subtitle: NBFM Receiver Example
---

# `rtlsdr_nbfm.zig`

This example is a Narrowband FM radio receiver. It can be used to listen to
analog commercial, police, and emergency services, amateur radio operators,
[NOAA weather radio](https://en.wikipedia.org/wiki/NOAA_Weather_Radio) in the
US, and more, on the VHF and UHF bands. It uses the RTL-SDR as an SDR source
and plays audio with PulseAudio.

This NBFM demodulator composition is available in ZigRadio as the `NBFMDemodulator` block.

### Source

```zig
{% include "../examples/rtlsdr_nbfm.zig" %}
```

### Usage

```plain
Usage: ./zig-out/bin/example-rtlsdr_nbfm <frequency>
```

For example, listen to NOAA1, 162.400 MHz:

```plain
$ ./zig-out/bin/example-rtlsdr_nbfm 162.400e6
```

Additional NOAA weather radio station frequencies: `162.400 MHz` (NOAA1),
`162.425 MHz` (NOAA2), `162.450 MHz` (NOAA3), `162.475 MHz` (NOAA4),
`162.500 MHz` (NOAA5), `162.525 MHz` (NOAA6), `162.550 MHz` (NOAA7).
