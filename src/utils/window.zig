const std = @import("std");

////////////////////////////////////////////////////////////////////////////////
// Window Functions
////////////////////////////////////////////////////////////////////////////////

pub const WindowFunction = enum {
    Rectangular,
    Hamming,
    Hanning,
    Bartlett,
    Blackman,
};

pub fn window(comptime N: comptime_int, func: WindowFunction, periodic: bool) [N]f32 {
    var w: [N]f32 = undefined;

    const M = @intToFloat(f32, if (periodic) @as(usize, N) + 1 else @as(usize, N));

    for (w) |_, i| {
        const index = @intToFloat(f32, i);
        w[i] = switch (func) {
            WindowFunction.Rectangular => 1.0,
            WindowFunction.Hamming => 0.54 - 0.46 * std.math.cos((2 * std.math.pi * index) / (M - 1)),
            WindowFunction.Hanning => 0.5 - 0.5 * std.math.cos((2 * std.math.pi * index) / (M - 1)),
            WindowFunction.Bartlett => (2 / (M - 1)) * ((M - 1) / 2 - std.math.fabs(index - (M - 1) / 2)),
            WindowFunction.Blackman => 0.42 - 0.5 * std.math.cos((2 * std.math.pi * index) / (M - 1)) + 0.08 * std.math.cos((4 * std.math.pi * index) / (M - 1)),
        };
    }

    return w;
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const expectEqualVectors = @import("radio").testing.expectEqualVectors;

const vectors = @import("../vectors/utils/window.zig");

test "rectangular window()" {
    try expectEqualVectors(f32, &vectors.window_rectangular, &window(128, WindowFunction.Rectangular, false), 0, 1e-6, false);
    try expectEqualVectors(f32, &vectors.window_rectangular_periodic, &window(128, WindowFunction.Rectangular, true), 0, 1e-6, false);
}

test "hamming window()" {
    try expectEqualVectors(f32, &vectors.window_hamming, &window(128, WindowFunction.Hamming, false), 0, 1e-6, false);
    try expectEqualVectors(f32, &vectors.window_hamming_periodic, &window(128, WindowFunction.Hamming, true), 0, 1e-6, false);
}

test "hanning window()" {
    try expectEqualVectors(f32, &vectors.window_hanning, &window(128, WindowFunction.Hanning, false), 0, 1e-6, false);
    try expectEqualVectors(f32, &vectors.window_hanning_periodic, &window(128, WindowFunction.Hanning, true), 0, 1e-6, false);
}

test "bartlett window()" {
    try expectEqualVectors(f32, &vectors.window_bartlett, &window(128, WindowFunction.Bartlett, false), 0, 1e-6, false);
    try expectEqualVectors(f32, &vectors.window_bartlett_periodic, &window(128, WindowFunction.Bartlett, true), 0, 1e-6, false);
}

test "blackman window()" {
    try expectEqualVectors(f32, &vectors.window_blackman, &window(128, WindowFunction.Blackman, false), 0, 1e-6, false);
    try expectEqualVectors(f32, &vectors.window_blackman_periodic, &window(128, WindowFunction.Blackman, true), 0, 1e-6, false);
}
