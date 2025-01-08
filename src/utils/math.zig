const std = @import("std");

////////////////////////////////////////////////////////////////////////////////
// Utility Functions
////////////////////////////////////////////////////////////////////////////////

pub fn zero(comptime T: type) T {
    if (T == std.math.Complex(f32)) {
        return .{ .re = 0, .im = 0 };
    } else if (T == f32) {
        return 0;
    } else unreachable;
}

pub fn sub(comptime T: type, x: T, y: T) T {
    if (T == std.math.Complex(f32)) {
        return x.sub(y);
    } else if (T == f32) {
        return x - y;
    } else unreachable;
}

pub fn scalarDiv(comptime T: type, x: T, scalar: f32) T {
    if (T == std.math.Complex(f32)) {
        return .{ .re = x.re / scalar, .im = x.im / scalar };
    } else if (T == f32) {
        return x / scalar;
    } else unreachable;
}

pub fn innerProduct(comptime T: type, comptime U: type, x: []const T, y: []const U) T {
    var acc = zero(T);

    std.debug.assert(x.len == y.len);

    if (T == std.math.Complex(f32) and U == std.math.Complex(f32)) {
        for (x, 0..) |_, i| acc = acc.add(x[i].mul(y[i]));
    } else if (T == std.math.Complex(f32) and U == f32) {
        for (x, 0..) |_, i| acc = acc.add(.{ .re = x[i].re * y[i], .im = x[i].im * y[i] });
    } else if (T == f32 and U == f32) {
        for (x, 0..) |_, i| acc += x[i] * y[i];
    } else unreachable;

    return acc;
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

test "zero" {
    try std.testing.expectEqual(std.math.Complex(f32).init(0, 0), zero(std.math.Complex(f32)));
    try std.testing.expectEqual(@as(f32, 0), zero(f32));
}

test "sub" {
    try std.testing.expectEqual(std.math.Complex(f32).init(1, 2), sub(std.math.Complex(f32), std.math.Complex(f32).init(2, 3), std.math.Complex(f32).init(1, 1)));
    try std.testing.expectEqual(@as(f32, 2), sub(f32, 4, 2));
}

test "scalarDiv" {
    try std.testing.expectEqual(std.math.Complex(f32).init(1, 2), scalarDiv(std.math.Complex(f32), std.math.Complex(f32).init(3, 6), 3));
    try std.testing.expectEqual(@as(f32, 2), scalarDiv(f32, 6, 3));
}

test "innerProduct" {
    try std.testing.expectEqual(std.math.Complex(f32).init(-24, 85), innerProduct(std.math.Complex(f32), std.math.Complex(f32), &[3]std.math.Complex(f32){ .{ .re = 1, .im = 2 }, .{ .re = 2, .im = 3 }, .{ .re = 3, .im = 4 } }, &[3]std.math.Complex(f32){ .{ .re = 4, .im = 5 }, .{ .re = 5, .im = 6 }, .{ .re = 6, .im = 7 } }));
    try std.testing.expectEqual(std.math.Complex(f32).init(14, 20), innerProduct(std.math.Complex(f32), f32, &[3]std.math.Complex(f32){ .{ .re = 1, .im = 2 }, .{ .re = 2, .im = 3 }, .{ .re = 3, .im = 4 } }, &[3]f32{ 1, 2, 3 }));
    try std.testing.expectEqual(@as(f32, 32), innerProduct(f32, f32, &[3]f32{ 1, 2, 3 }, &[3]f32{ 4, 5, 6 }));
}
