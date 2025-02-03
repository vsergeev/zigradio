const std = @import("std");

const WindowFunction = @import("./window.zig").WindowFunction;
const window = @import("./window.zig").window;

const scalarMul = @import("./math.zig").scalarMul;

////////////////////////////////////////////////////////////////////////////////
// FIR Filter Functions
////////////////////////////////////////////////////////////////////////////////

// Causal FIR filters computed from truncations of ideal IIR filters
//
// See http://www.labbookpages.co.uk/audio/firWindowing.html for derivations.

pub fn firLowpass(comptime N: comptime_int, cutoff: f32) [N]f32 {
    var h: [N]f32 = undefined;

    for (h, 0..) |_, i| {
        if (N % 2 == 1 and i == (N - 1) / 2) {
            h[i] = cutoff;
        } else {
            const arg = @as(f32, @floatFromInt(i)) - (@as(f32, @floatFromInt(N - 1)) / 2);
            h[i] = std.math.sin(std.math.pi * cutoff * arg) / (std.math.pi * arg);
        }
    }

    return h;
}

pub fn firHighpass(comptime N: comptime_int, cutoff: f32) [N]f32 {
    var h: [N]f32 = undefined;

    std.debug.assert((N % 2) == 1);

    for (h, 0..) |_, i| {
        if (i == (N - 1) / 2) {
            h[i] = 1 - cutoff;
        } else {
            const arg = @as(f32, @floatFromInt(i)) - (@as(f32, @floatFromInt(N - 1)) / 2);
            h[i] = -std.math.sin(std.math.pi * cutoff * arg) / (std.math.pi * arg);
        }
    }

    return h;
}

pub fn firBandpass(comptime N: comptime_int, cutoffs: struct { f32, f32 }) [N]f32 {
    var h: [N]f32 = undefined;

    std.debug.assert((N % 2) == 1);

    for (h, 0..) |_, i| {
        if (i == (N - 1) / 2) {
            h[i] = cutoffs[1] - cutoffs[0];
        } else {
            const arg = @as(f32, @floatFromInt(i)) - (@as(f32, @floatFromInt(N - 1)) / 2);
            h[i] = std.math.sin(std.math.pi * cutoffs[1] * arg) / (std.math.pi * arg) - std.math.sin(std.math.pi * cutoffs[0] * arg) / (std.math.pi * arg);
        }
    }

    return h;
}

pub fn firBandstop(comptime N: comptime_int, cutoffs: struct { f32, f32 }) [N]f32 {
    var h: [N]f32 = undefined;

    std.debug.assert((N % 2) == 1);

    for (h, 0..) |_, i| {
        if (i == (N - 1) / 2) {
            h[i] = 1 - (cutoffs[1] - cutoffs[0]);
        } else {
            const arg = @as(f32, @floatFromInt(i)) - (@as(f32, @floatFromInt(N - 1)) / 2);
            h[i] = std.math.sin(std.math.pi * cutoffs[0] * arg) / (std.math.pi * arg) - std.math.sin(std.math.pi * cutoffs[1] * arg) / (std.math.pi * arg);
        }
    }

    return h;
}

////////////////////////////////////////////////////////////////////////////////
// FIR Windowing
////////////////////////////////////////////////////////////////////////////////

// FIR window method filter design
//
// See http://www.labbookpages.co.uk/audio/firWindowing.html for derivations.

pub fn firwin(comptime N: comptime_int, h: [N]f32, window_func: WindowFunction, scale_freq: f32) [N]f32 {
    var hw: [N]f32 = undefined;

    // Generate and apply window
    const w = window(N, window_func, false);
    for (hw, 0..) |_, i| {
        hw[i] = h[i] * w[i];
    }

    // Scale magnitude response
    var scale: f32 = 0;
    for (hw, 0..) |_, i| {
        const arg = @as(f32, @floatFromInt(i)) - (@as(f32, @floatFromInt(N - 1)) / 2);
        scale += hw[i] * std.math.cos(std.math.pi * arg * scale_freq);
    }
    for (&hw) |*e| {
        e.* /= scale;
    }

    return hw;
}

// Complex FIR window method filter design

pub fn complexFirwin(comptime N: comptime_int, h: [N]f32, center_freq: f32, window_func: WindowFunction, scale_freq: f32) [N]std.math.Complex(f32) {
    var hw: [N]std.math.Complex(f32) = undefined;

    // Translate real filter to center frequency, making it complex
    for (hw, 0..) |_, i| {
        hw[i] = .{ .re = h[i] * std.math.cos(std.math.pi * center_freq * @as(f32, @floatFromInt(i))), .im = h[i] * std.math.sin(std.math.pi * center_freq * @as(f32, @floatFromInt(i))) };
    }

    // Generate and apply window
    const w = window(N, window_func, false);
    for (hw, 0..) |_, i| {
        hw[i] = scalarMul(std.math.Complex(f32), hw[i], w[i]);
    }

    // Scale magnitude response
    var scale = std.math.Complex(f32).init(0, 0);
    for (hw, 0..) |_, i| {
        const arg = @as(f32, @floatFromInt(i)) - (@as(f32, @floatFromInt(N - 1)) / 2);
        const exponential = .{ .re = std.math.cos(std.math.pi * arg * scale_freq), .im = std.math.sin(-1 * std.math.pi * arg * scale_freq) };
        scale = scale.add(hw[i].mul(exponential));
    }
    for (&hw) |*e| {
        e.* = e.div(scale);
    }

    return hw;
}

////////////////////////////////////////////////////////////////////////////////
// Top-level Firwin Filters
////////////////////////////////////////////////////////////////////////////////

pub fn firwinLowpass(comptime N: comptime_int, cutoff: f32, window_func: WindowFunction) [N]f32 {
    // Generate truncated lowpass filter taps
    const h = firLowpass(N, cutoff);
    // Apply window and scale by DC gain
    return firwin(N, h, window_func, 0.0);
}

pub fn firwinHighpass(comptime N: comptime_int, cutoff: f32, window_func: WindowFunction) [N]f32 {
    // Generate truncated highpass filter taps
    const h = firHighpass(N, cutoff);
    // Apply window and scale by Nyquist gain
    return firwin(N, h, window_func, 1.0);
}

pub fn firwinBandpass(comptime N: comptime_int, cutoffs: struct { f32, f32 }, window_func: WindowFunction) [N]f32 {
    // Generate truncated bandpass filter taps
    const h = firBandpass(N, cutoffs);
    // Apply window and scale by passband gain
    return firwin(N, h, window_func, (cutoffs[0] + cutoffs[1]) / 2);
}

pub fn firwinBandstop(comptime N: comptime_int, cutoffs: struct { f32, f32 }, window_func: WindowFunction) [N]f32 {
    // Generate truncated bandpass filter taps
    const h = firBandstop(N, cutoffs);
    // Apply window and scale by DC gain
    return firwin(N, h, window_func, 0.0);
}

pub fn firwinComplexBandpass(comptime N: comptime_int, cutoffs: struct { f32, f32 }, window_func: WindowFunction) [N]std.math.Complex(f32) {
    // Generate truncated lowpass filter taps
    const h = firLowpass(N, (@max(cutoffs[0], cutoffs[1]) - @min(cutoffs[0], cutoffs[1])) / 2);
    // Translate filter, apply window, and scale by passband gain
    return complexFirwin(N, h, (cutoffs[0] + cutoffs[1]) / 2, window_func, (cutoffs[0] + cutoffs[1]) / 2);
}

pub fn firwinComplexBandstop(comptime N: comptime_int, cutoffs: struct { f32, f32 }, window_func: WindowFunction) [N]std.math.Complex(f32) {
    // Generate truncated highpass filter taps
    const h = firHighpass(N, (@max(cutoffs[0], cutoffs[1]) - @min(cutoffs[0], cutoffs[1])) / 2);
    // Use either DC or Nyquist frequency for scaling, whichever is not in the stopband
    const scale_freq: f32 = if (cutoffs[0] < 0.0 and cutoffs[1] > 0.0) 1.0 else 0.0;
    // Translate filter, apply window, and scale by passband gain
    return complexFirwin(N, h, (cutoffs[0] + cutoffs[1]) / 2, window_func, scale_freq);
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const expectEqualVectors = @import("../core/testing.zig").expectEqualVectors;

const vectors = @import("../vectors/utils/filter.zig");

test "firwin" {
    try expectEqualVectors(f32, &vectors.firwin_lowpass, &firwinLowpass(128, 0.5, WindowFunction.Hamming), 1e-6);
    try expectEqualVectors(f32, &vectors.firwin_highpass, &firwinHighpass(129, 0.5, WindowFunction.Hamming), 1e-6);
    try expectEqualVectors(f32, &vectors.firwin_bandpass, &firwinBandpass(129, .{ 0.4, 0.6 }, WindowFunction.Hamming), 1e-6);
    try expectEqualVectors(f32, &vectors.firwin_bandstop, &firwinBandstop(129, .{ 0.4, 0.6 }, WindowFunction.Hamming), 1e-6);
}

test "complexFirwin" {
    try expectEqualVectors(std.math.Complex(f32), &vectors.firwin_complex_bandpass_positive, &firwinComplexBandpass(129, .{ 0.1, 0.3 }, WindowFunction.Hamming), 1e-6);
    try expectEqualVectors(std.math.Complex(f32), &vectors.firwin_complex_bandpass_negative, &firwinComplexBandpass(129, .{ -0.1, -0.3 }, WindowFunction.Hamming), 1e-6);
    try expectEqualVectors(std.math.Complex(f32), &vectors.firwin_complex_bandpass_zero, &firwinComplexBandpass(129, .{ -0.2, 0.2 }, WindowFunction.Hamming), 1e-6);

    try expectEqualVectors(std.math.Complex(f32), &vectors.firwin_complex_bandstop_positive, &firwinComplexBandstop(129, .{ 0.1, 0.3 }, WindowFunction.Hamming), 1e-6);
    try expectEqualVectors(std.math.Complex(f32), &vectors.firwin_complex_bandstop_negative, &firwinComplexBandstop(129, .{ -0.1, -0.3 }, WindowFunction.Hamming), 1e-6);
    try expectEqualVectors(std.math.Complex(f32), &vectors.firwin_complex_bandstop_zero, &firwinComplexBandstop(129, .{ -0.2, 0.2 }, WindowFunction.Hamming), 1e-6);
}
