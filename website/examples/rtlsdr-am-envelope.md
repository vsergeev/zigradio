---
permalink: /examples/rtlsdr-am-envelope.html
layout: default.njk
subtitle: AM (Envelope) Receiver Example
---

# `rtlsdr_am_envelope.zig`

This example is an AM radio receiver, implemented with an envelope detector. It
can be used to listen to broadcast stations on the MF ([AM
Broadcast](https://en.wikipedia.org/wiki/AM_broadcasting)) and HF ([Shortwave
Broadcast](https://en.wikipedia.org/wiki/Shortwave_radio#Shortwave_broadcasting))
bands, as well as aviation communication on the VHF
[airband](https://en.wikipedia.org/wiki/Airband). It uses the RTL-SDR as an SDR
source and plays audio with PulseAudio.

This AM envelope demodulator composition is available in ZigRadio as the
`AMEnvelopeDemodulator` block.

### Source

```zig
{% include "../examples/rtlsdr_am_envelope.zig" %}
```

### Usage

```plain
Usage: ./zig-out/bin/example-rtlsdr_am_envelope <frequency>
```

For example, listen to [WWV](<https://en.wikipedia.org/wiki/WWV_(radio_station)>) at 5 MHz:

```plain
$ ./zig-out/bin/example-rtlsdr_am_envelope 5e6
```

For example, listen to an AM radio station at 890 kHz:

```plain
$ ./zig-out/bin/example-rtlsdr_am_envelope 890e3
```
