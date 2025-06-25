* v0.8.0 - 06/25/2025
    * Fix flowgraph stall from waiting on excess output samples in SampleMux.
    * Refactor FIRFilter to support runtime length taps.
    * Simplify bandwidth parameter for TunerBlock.
    * Reduce default target power in AGCBlock.
    * Add asynchronous `reset()` API to AGCBlock.
    * Add support for bit type (`u1`).
    * Add new blocks:
        * AddBlock
        * SubtractBlock
        * MultiplyBlock
        * MultiplyConjugateBlock
        * DelayBlock
        * RealToComplexBlock
        * RectangularMatchedFilterBlock
        * ComplexPLLBlock
        * SlicerBlock
        * DifferentialDecoderBlock
        * JSONStreamSink
    * Add new composites:
        * NBFMDemodulatorBlock
        * AMSynchronousDemodulatorBlock
        * WBFMMonoDemodulatorBlock
        * WBFMStereoDemodulatorBlock
    * Add new examples:
        * rtlsdr_am_synchronous
        * rtlsdr_wbfm_stereo
    * Add block docstrings.
    * Add website.

* v0.7.0 - 05/14/2025
    * Migrate to Zig 0.14.0.
    * Fix stuck multiple readers in ThreadSafeRingBuffer.
    * Fix stream cut-off handling in ThreadSafeRingBuffer.
    * Fix `setFrequency()` build error in AirspyHFSource.
    * Add `push()` convenience API to ApplicationSource.
    * Add `pop()` and `discard()` convenience APIs to ApplicationSink.
    * Improve tests portability (e.g. aarch64).

* v0.6.0 - 02/26/2025
    * Refactor SampleMux API.
    * Add raw block mode that uses SampleMux directly.
    * Add block termination on broken write stream.
    * Add block error propagation to flowgraph.
    * Simplify configuration of FrequencyDiscriminatorBlock.
    * Add new blocks:
        * ApplicationSource
        * ApplicationSink
        * PowerMeterBlock
        * IQStreamSource
        * IQStreamSink
        * RealStreamSource
        * RealStreamSink
        * AirspyHFSource
    * Add new composites:
        * AMEnvelopeDemodulatorBlock
    * Add new examples:
        * iqfile_converter
    * Fix bandwidth in rtlsdr_wbfm_mono example.
    * Improve tune offsets and sample rates in rtlsdr_* examples.

* v0.5.0 - 02/05/2025
    * Fix flowgraph initialization for blocks with unconnected outputs.
    * Fix flowgraph stalls caused by blocks with unconnected outputs.
    * Add support for asynchronous calls to running blocks.
    * Add asynchronous APIs to several blocks:
        * FIRFilterBlock: `updateTaps()`, `reset()`
        * LowpassFilterBlock: `setCutoff()`, `reset()`
        * HighpassFilterBlock: `setCutoff()`, `reset()`
        * AGCBlock: `setMode()`
        * RtlSdrSource: `setFrequency()`
    * Refactor testing helpers.
    * Add testing with acceleration libraries to CI.
    * Add package manifest.

* v0.4.0 - 01/26/2025
    * Fix spinning on read available wait in SampleMux.
    * Refactor SampleMux API.
    * Refactor block wrapping in Block and Composite.
    * Add support for RefCounted(T) wrapper type.
    * Add new signal blocks:
        * AGCBlock
    * Add AGCBlock to rtlsdr_ssb and rtlsdr_am_envelope examples.

* v0.3.0 - 01/18/2025
    * Migrate to dynamically loaded libraries.
    * Add acceleration (VOLK, liquid-dsp) to signal blocks.
    * Add support for complex taps to FIRFilterBlock.
    * Add new signal blocks:
        * ComplexToRealBlock
        * ComplexToImagBlock
        * ComplexMagnitudeBlock
        * HighpassFilterBlock
        * SinglepoleHighpassFilterBlock
        * BandpassFilterBlock
        * BandstopFilterBlock
        * ComplexBandpassFilterBlock
        * ComplexBandstopFilterBlock
    * Add new examples:
        * rtlsdr_nbfm
        * rtlsdr_ssb
        * rtlsdr_am_envelope
    * Add benchmarking suite.

* v0.2.0 - 12/25/2024
    * Add support for composite blocks.
    * Migrate to Zig 0.13.0.

* v0.1.0 - 03/14/2023
    * Initial release.
