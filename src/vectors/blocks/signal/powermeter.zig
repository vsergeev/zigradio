const std = @import("std");

// @python
// # Cosine with 100 Hz frequency, 1000 Hz sample rate, 0.001 amplitude
// # Average power in dBFS = 10*log10(0.005^2 * 0.5) = -49 dBFS
// x = 0.005*numpy.cos(2*numpy.pi*(100/1000)*numpy.arange(100)).astype(numpy.float32)
// vector("input_cosine_49", x)
//
// # Complex exponential with 100 Hz frequency, 1000 Hz sample rate, 0.001 amplitude
// # Average power in dBFS = 10*log10(0.005^2 * 1.0) = -46 dBFS
// x = 0.005*numpy.exp(2*numpy.pi*1j*(100/1000)*numpy.arange(100)).astype(numpy.complex64)
// vector("input_exponential_46", x)
// @python

////////////////////////////////////////////////////////////////////////////////
// Auto-generated code below, do not edit!
////////////////////////////////////////////////////////////////////////////////

// @autogenerated

pub const input_cosine_49 = [100]f32{ 0.00500000, 0.00404509, 0.00154508, -0.00154508, -0.00404509, -0.00500000, -0.00404509, -0.00154508, 0.00154508, 0.00404509, 0.00500000, 0.00404509, 0.00154508, -0.00154508, -0.00404509, -0.00500000, -0.00404509, -0.00154508, 0.00154508, 0.00404509, 0.00500000, 0.00404509, 0.00154508, -0.00154508, -0.00404509, -0.00500000, -0.00404509, -0.00154508, 0.00154508, 0.00404509, 0.00500000, 0.00404509, 0.00154508, -0.00154508, -0.00404509, -0.00500000, -0.00404509, -0.00154508, 0.00154508, 0.00404509, 0.00500000, 0.00404509, 0.00154508, -0.00154508, -0.00404509, -0.00500000, -0.00404509, -0.00154508, 0.00154508, 0.00404509, 0.00500000, 0.00404509, 0.00154508, -0.00154508, -0.00404509, -0.00500000, -0.00404509, -0.00154508, 0.00154508, 0.00404509, 0.00500000, 0.00404509, 0.00154508, -0.00154508, -0.00404509, -0.00500000, -0.00404509, -0.00154508, 0.00154508, 0.00404509, 0.00500000, 0.00404509, 0.00154508, -0.00154508, -0.00404509, -0.00500000, -0.00404509, -0.00154508, 0.00154508, 0.00404509, 0.00500000, 0.00404509, 0.00154508, -0.00154508, -0.00404509, -0.00500000, -0.00404509, -0.00154508, 0.00154508, 0.00404509, 0.00500000, 0.00404509, 0.00154508, -0.00154508, -0.00404509, -0.00500000, -0.00404509, -0.00154508, 0.00154508, 0.00404509 };
pub const input_exponential_46 = [100]std.math.Complex(f32){ .{ .re = 0.00500000, .im = 0.00000000 }, .{ .re = 0.00404509, .im = 0.00293893 }, .{ .re = 0.00154508, .im = 0.00475528 }, .{ .re = -0.00154508, .im = 0.00475528 }, .{ .re = -0.00404509, .im = 0.00293893 }, .{ .re = -0.00500000, .im = 0.00000000 }, .{ .re = -0.00404509, .im = -0.00293893 }, .{ .re = -0.00154508, .im = -0.00475528 }, .{ .re = 0.00154508, .im = -0.00475528 }, .{ .re = 0.00404509, .im = -0.00293893 }, .{ .re = 0.00500000, .im = -0.00000000 }, .{ .re = 0.00404509, .im = 0.00293893 }, .{ .re = 0.00154508, .im = 0.00475528 }, .{ .re = -0.00154508, .im = 0.00475528 }, .{ .re = -0.00404509, .im = 0.00293893 }, .{ .re = -0.00500000, .im = 0.00000000 }, .{ .re = -0.00404509, .im = -0.00293893 }, .{ .re = -0.00154508, .im = -0.00475528 }, .{ .re = 0.00154508, .im = -0.00475528 }, .{ .re = 0.00404509, .im = -0.00293893 }, .{ .re = 0.00500000, .im = -0.00000000 }, .{ .re = 0.00404509, .im = 0.00293893 }, .{ .re = 0.00154508, .im = 0.00475528 }, .{ .re = -0.00154508, .im = 0.00475528 }, .{ .re = -0.00404509, .im = 0.00293893 }, .{ .re = -0.00500000, .im = 0.00000000 }, .{ .re = -0.00404509, .im = -0.00293893 }, .{ .re = -0.00154508, .im = -0.00475528 }, .{ .re = 0.00154508, .im = -0.00475528 }, .{ .re = 0.00404509, .im = -0.00293893 }, .{ .re = 0.00500000, .im = -0.00000000 }, .{ .re = 0.00404509, .im = 0.00293893 }, .{ .re = 0.00154508, .im = 0.00475528 }, .{ .re = -0.00154508, .im = 0.00475528 }, .{ .re = -0.00404509, .im = 0.00293893 }, .{ .re = -0.00500000, .im = 0.00000000 }, .{ .re = -0.00404509, .im = -0.00293893 }, .{ .re = -0.00154508, .im = -0.00475528 }, .{ .re = 0.00154508, .im = -0.00475528 }, .{ .re = 0.00404509, .im = -0.00293893 }, .{ .re = 0.00500000, .im = -0.00000000 }, .{ .re = 0.00404509, .im = 0.00293893 }, .{ .re = 0.00154508, .im = 0.00475528 }, .{ .re = -0.00154508, .im = 0.00475528 }, .{ .re = -0.00404509, .im = 0.00293893 }, .{ .re = -0.00500000, .im = 0.00000000 }, .{ .re = -0.00404509, .im = -0.00293893 }, .{ .re = -0.00154508, .im = -0.00475528 }, .{ .re = 0.00154508, .im = -0.00475528 }, .{ .re = 0.00404509, .im = -0.00293893 }, .{ .re = 0.00500000, .im = -0.00000000 }, .{ .re = 0.00404509, .im = 0.00293893 }, .{ .re = 0.00154508, .im = 0.00475528 }, .{ .re = -0.00154508, .im = 0.00475528 }, .{ .re = -0.00404509, .im = 0.00293893 }, .{ .re = -0.00500000, .im = 0.00000000 }, .{ .re = -0.00404509, .im = -0.00293893 }, .{ .re = -0.00154508, .im = -0.00475528 }, .{ .re = 0.00154508, .im = -0.00475528 }, .{ .re = 0.00404509, .im = -0.00293893 }, .{ .re = 0.00500000, .im = -0.00000000 }, .{ .re = 0.00404509, .im = 0.00293893 }, .{ .re = 0.00154508, .im = 0.00475528 }, .{ .re = -0.00154508, .im = 0.00475528 }, .{ .re = -0.00404509, .im = 0.00293893 }, .{ .re = -0.00500000, .im = -0.00000000 }, .{ .re = -0.00404509, .im = -0.00293893 }, .{ .re = -0.00154508, .im = -0.00475528 }, .{ .re = 0.00154508, .im = -0.00475528 }, .{ .re = 0.00404509, .im = -0.00293893 }, .{ .re = 0.00500000, .im = -0.00000000 }, .{ .re = 0.00404509, .im = 0.00293893 }, .{ .re = 0.00154508, .im = 0.00475528 }, .{ .re = -0.00154508, .im = 0.00475528 }, .{ .re = -0.00404509, .im = 0.00293893 }, .{ .re = -0.00500000, .im = 0.00000000 }, .{ .re = -0.00404509, .im = -0.00293893 }, .{ .re = -0.00154508, .im = -0.00475528 }, .{ .re = 0.00154508, .im = -0.00475528 }, .{ .re = 0.00404509, .im = -0.00293893 }, .{ .re = 0.00500000, .im = -0.00000000 }, .{ .re = 0.00404509, .im = 0.00293893 }, .{ .re = 0.00154508, .im = 0.00475528 }, .{ .re = -0.00154508, .im = 0.00475528 }, .{ .re = -0.00404509, .im = 0.00293893 }, .{ .re = -0.00500000, .im = -0.00000000 }, .{ .re = -0.00404509, .im = -0.00293893 }, .{ .re = -0.00154508, .im = -0.00475528 }, .{ .re = 0.00154508, .im = -0.00475528 }, .{ .re = 0.00404509, .im = -0.00293893 }, .{ .re = 0.00500000, .im = -0.00000000 }, .{ .re = 0.00404509, .im = 0.00293893 }, .{ .re = 0.00154508, .im = 0.00475528 }, .{ .re = -0.00154508, .im = 0.00475528 }, .{ .re = -0.00404509, .im = 0.00293893 }, .{ .re = -0.00500000, .im = 0.00000000 }, .{ .re = -0.00404509, .im = -0.00293893 }, .{ .re = -0.00154508, .im = -0.00475528 }, .{ .re = 0.00154508, .im = -0.00475528 }, .{ .re = 0.00404509, .im = -0.00293893 } };
