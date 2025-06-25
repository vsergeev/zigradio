---
permalink: /examples/rtlsdr-am-synchronous.html
layout: default.njk
subtitle: AM (Synchronous) Receiver Example
---

# `rtlsdr_am_synchronous.zig`

This example is an AM radio receiver, implemented with a phase-locked loop for
synchronous demodulation. It can be used to listen to broadcast stations on the
MF ([AM Broadcast](https://en.wikipedia.org/wiki/AM_broadcasting)) and HF
([Shortwave
Broadcast](https://en.wikipedia.org/wiki/Shortwave_radio#Shortwave_broadcasting))
bands, as well as aviation communication on the VHF
[airband](https://en.wikipedia.org/wiki/Airband). It uses the RTL-SDR as an SDR
source and plays audio with PulseAudio.

This AM synchronous demodulator composition is available in ZigRadio as the
`AMSynchronousDemodulator` block.

### Source

```zig
{% include "../examples/rtlsdr_am_synchronous.zig" %}
```

### Usage

```plain
Usage: ./zig-out/bin/example-rtlsdr_am_synchronous <frequency>
```

For example, listen to [WWV](<https://en.wikipedia.org/wiki/WWV_(radio_station)>) at 5 MHz:

```plain
$ ./zig-out/bin/example-rtlsdr_am_synchronous 5e6
```

For example, listen to an AM radio station at 890 kHz:

```plain
$ ./zig-out/bin/example-rtlsdr_am_synchronous 890e3
```
