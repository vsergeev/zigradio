const std = @import("std");

const WindowFunction = @import("./window.zig").WindowFunction;
const window = @import("./window.zig").window;

////////////////////////////////////////////////////////////////////////////////
// FIR Filter Functions
////////////////////////////////////////////////////////////////////////////////

// Causal FIR filters computed from truncations of ideal IIR filters
//
// See http://www.labbookpages.co.uk/audio/firWindowing.html for derivations.

pub fn firLowpass(comptime N: comptime_int, cutoff: f32) [N]f32 {
    var h: [N]f32 = undefined;

    for (h) |_, i| {
        if (N % 2 == 1 and i == (N - 1) / 2) {
            h[i] = cutoff;
        } else {
            const arg = @intToFloat(f32, i) - ((@intToFloat(f32, N) - 1) / 2);
            h[i] = std.math.sin(std.math.pi * cutoff * arg) / (std.math.pi * arg);
        }
    }

    return h;
}

pub fn firHighpass(comptime N: comptime_int, cutoff: f32) [N]f32 {
    var h: [N]f32 = undefined;

    std.debug.assert((N % 2) == 1);

    for (h) |_, i| {
        if (i == (N - 1) / 2) {
            h[i] = 1 - cutoff;
        } else {
            const arg = @intToFloat(f32, i) - ((@intToFloat(f32, N) - 1) / 2);
            h[i] = -std.math.sin(std.math.pi * cutoff * arg) / (std.math.pi * arg);
        }
    }

    return h;
}

pub fn firBandpass(comptime N: comptime_int, cutoffs: std.meta.Tuple(&[2]type{ f32, f32 })) [N]f32 {
    var h: [N]f32 = undefined;

    std.debug.assert((N % 2) == 1);

    for (h) |_, i| {
        if (i == (N - 1) / 2) {
            h[i] = cutoffs[1] - cutoffs[0];
        } else {
            const arg = @intToFloat(f32, i) - ((@intToFloat(f32, N) - 1) / 2);
            h[i] = std.math.sin(std.math.pi * cutoffs[1] * arg) / (std.math.pi * arg) - std.math.sin(std.math.pi * cutoffs[0] * arg) / (std.math.pi * arg);
        }
    }

    return h;
}

pub fn firBandstop(comptime N: comptime_int, cutoffs: std.meta.Tuple(&[2]type{ f32, f32 })) [N]f32 {
    var h: [N]f32 = undefined;

    std.debug.assert((N % 2) == 1);

    for (h) |_, i| {
        if (i == (N - 1) / 2) {
            h[i] = 1 - (cutoffs[1] - cutoffs[0]);
        } else {
            const arg = @intToFloat(f32, i) - ((@intToFloat(f32, N) - 1) / 2);
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
    for (hw) |_, i| {
        hw[i] = h[i] * w[i];
    }

    // Scale magnitude response
    var scale: f32 = 0;
    for (hw) |_, i| {
        const arg = @intToFloat(f32, i) - ((@intToFloat(f32, N) - 1) / 2);
        scale += hw[i] * std.math.cos(std.math.pi * arg * scale_freq);
    }
    for (hw) |*e| {
        e.* /= scale;
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

pub fn firwinBandpass(comptime N: comptime_int, cutoffs: std.meta.Tuple(&[2]type{ f32, f32 }), window_func: WindowFunction) [N]f32 {
    // Generate truncated bandpass filter taps
    const h = firBandpass(N, cutoffs);
    // Apply window and scale by passband gain
    return firwin(N, h, window_func, (cutoffs[0] + cutoffs[1]) / 2);
}

pub fn firwinBandstop(comptime N: comptime_int, cutoffs: std.meta.Tuple(&[2]type{ f32, f32 }), window_func: WindowFunction) [N]f32 {
    // Generate truncated bandpass filter taps
    const h = firBandstop(N, cutoffs);
    // Apply window and scale by DC gain
    return firwin(N, h, window_func, 0.0);
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const expectEqualVectors = @import("radio").testing.expectEqualVectors;

const vectors = @import("../vectors/utils/filter.zig");

test "firwin" {
    try expectEqualVectors(f32, &vectors.firwin_lowpass, &firwinLowpass(128, 0.5, WindowFunction.Hamming), 0, 1e-6, false);
    try expectEqualVectors(f32, &vectors.firwin_highpass, &firwinHighpass(129, 0.5, WindowFunction.Hamming), 0, 1e-6, false);
    try expectEqualVectors(f32, &vectors.firwin_bandpass, &firwinBandpass(129, .{ 0.4, 0.6 }, WindowFunction.Hamming), 0, 1e-6, false);
    try expectEqualVectors(f32, &vectors.firwin_bandstop, &firwinBandstop(129, .{ 0.4, 0.6 }, WindowFunction.Hamming), 0, 1e-6, false);
}
