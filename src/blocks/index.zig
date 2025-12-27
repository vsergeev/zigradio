// Sources
pub const ZeroSource = @import("sources/zero.zig").ZeroSource;
pub const SignalSource = @import("sources/signal.zig").SignalSource;
pub const ApplicationSource = @import("sources/application.zig").ApplicationSource;
pub const IQStreamSource = @import("sources/iqstream.zig").IQStreamSource;
pub const RealStreamSource = @import("sources/realstream.zig").RealStreamSource;
pub const RtlSdrSource = @import("sources/rtlsdr.zig").RtlSdrSource;
pub const AirspyHFSource = @import("sources/airspyhf.zig").AirspyHFSource;
pub const WAVFileSource = @import("sources/wavfile.zig").WAVFileSource;

// Signal
pub const AddBlock = @import("signal/add.zig").AddBlock;
pub const SubtractBlock = @import("signal/subtract.zig").SubtractBlock;
pub const MultiplyBlock = @import("signal/multiply.zig").MultiplyBlock;
pub const MultiplyConjugateBlock = @import("signal/multiplyconjugate.zig").MultiplyConjugateBlock;
pub const DelayBlock = @import("signal/delay.zig").DelayBlock;
pub const DownsamplerBlock = @import("signal/downsampler.zig").DownsamplerBlock;
pub const FrequencyTranslatorBlock = @import("signal/frequencytranslator.zig").FrequencyTranslatorBlock;
pub const FrequencyDiscriminatorBlock = @import("signal/frequencydiscriminator.zig").FrequencyDiscriminatorBlock;
pub const FIRFilterBlock = @import("signal/firfilter.zig").FIRFilterBlock;
pub const IIRFilterBlock = @import("signal/iirfilter.zig").IIRFilterBlock;
pub const SinglepoleLowpassFilterBlock = @import("signal/singlepolelowpassfilter.zig").SinglepoleLowpassFilterBlock;
pub const SinglepoleHighpassFilterBlock = @import("signal/singlepolehighpassfilter.zig").SinglepoleHighpassFilterBlock;
pub const FMDeemphasisFilterBlock = @import("signal/fmdeemphasisfilter.zig").FMDeemphasisFilterBlock;
pub const LowpassFilterBlock = @import("signal/lowpassfilter.zig").LowpassFilterBlock;
pub const HighpassFilterBlock = @import("signal/highpassfilter.zig").HighpassFilterBlock;
pub const BandpassFilterBlock = @import("signal/bandpassfilter.zig").BandpassFilterBlock;
pub const BandstopFilterBlock = @import("signal/bandstopfilter.zig").BandstopFilterBlock;
pub const ComplexBandpassFilterBlock = @import("signal/complexbandpassfilter.zig").ComplexBandpassFilterBlock;
pub const ComplexBandstopFilterBlock = @import("signal/complexbandstopfilter.zig").ComplexBandstopFilterBlock;
pub const ComplexToRealBlock = @import("signal/complextoreal.zig").ComplexToRealBlock;
pub const ComplexToImagBlock = @import("signal/complextoimag.zig").ComplexToImagBlock;
pub const RealToComplexBlock = @import("signal/realtocomplex.zig").RealToComplexBlock;
pub const ComplexMagnitudeBlock = @import("signal/complexmagnitude.zig").ComplexMagnitudeBlock;
pub const AGCBlock = @import("signal/agc.zig").AGCBlock;
pub const PowerMeterBlock = @import("signal/powermeter.zig").PowerMeterBlock;
pub const RectangularMatchedFilterBlock = @import("signal/rectangularmatchedfilter.zig").RectangularMatchedFilterBlock;
pub const ComplexPLLBlock = @import("signal/complexpll.zig").ComplexPLLBlock;

// Digital
pub const DifferentialDecoderBlock = @import("digital/differentialdecoder.zig").DifferentialDecoderBlock;
pub const SlicerBlock = @import("digital/slicer.zig").SlicerBlock;
pub const BinarySlicer = @import("digital/slicer.zig").BinarySlicer;

// Sinks
pub const PrintSink = @import("sinks/print.zig").PrintSink;
pub const BenchmarkSink = @import("sinks/benchmark.zig").BenchmarkSink;
pub const ApplicationSink = @import("sinks/application.zig").ApplicationSink;
pub const IQStreamSink = @import("sinks/iqstream.zig").IQStreamSink;
pub const RealStreamSink = @import("sinks/realstream.zig").RealStreamSink;
pub const JSONStreamSink = @import("sinks/jsonstream.zig").JSONStreamSink;
pub const PulseAudioSink = @import("sinks/pulseaudio.zig").PulseAudioSink;
pub const WAVFileSink = @import("sinks/wavfile.zig").WAVFileSink;

// Composites
pub const TunerBlock = @import("composites/tuner.zig").TunerBlock;
pub const AMEnvelopeDemodulatorBlock = @import("composites/amenvelopedemodulator.zig").AMEnvelopeDemodulatorBlock;
pub const AMSynchronousDemodulatorBlock = @import("composites/amsynchronousdemodulator.zig").AMSynchronousDemodulatorBlock;
pub const NBFMDemodulatorBlock = @import("composites/nbfmdemodulator.zig").NBFMDemodulatorBlock;
pub const WBFMMonoDemodulatorBlock = @import("composites/wbfmmonodemodulator.zig").WBFMMonoDemodulatorBlock;
pub const WBFMStereoDemodulatorBlock = @import("composites/wbfmstereodemodulator.zig").WBFMStereoDemodulatorBlock;

// Pull in all tests
test {
    @import("std").testing.refAllDecls(@This());
}
