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
