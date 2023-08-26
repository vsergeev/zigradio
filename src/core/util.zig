const std = @import("std");

////////////////////////////////////////////////////////////////////////////////
// Utility Functions
////////////////////////////////////////////////////////////////////////////////

pub fn dataTypeSizes(comptime data_types: []const type) []const usize {
    comptime var data_type_sizes: [data_types.len]usize = undefined;

    inline for (data_types, 0..) |data_type, i| {
        data_type_sizes[i] = @sizeOf(data_type);
    }

    return data_type_sizes[0..];
}

pub fn makeTupleConstSliceTypes(comptime data_types: []const type) type {
    comptime var slice_data_types: [data_types.len]type = undefined;

    inline for (data_types, 0..) |data_type, i| {
        slice_data_types[i] = []const data_type;
    }

    return std.meta.Tuple(&slice_data_types);
}

pub fn makeTupleSliceTypes(comptime data_types: []const type) type {
    comptime var slice_data_types: [data_types.len]type = undefined;

    inline for (data_types, 0..) |data_type, i| {
        slice_data_types[i] = []data_type;
    }

    return std.meta.Tuple(&slice_data_types);
}

pub fn makeTuplePointerSliceTypes(comptime data_types: []const type) type {
    comptime var slice_data_types: [data_types.len]type = undefined;

    inline for (data_types, 0..) |data_type, i| {
        slice_data_types[i] = *[]const data_type;
    }

    return std.meta.Tuple(&slice_data_types);
}

pub fn dereferenceTuplePointerSlices(comptime data_types: []const type, inputs: makeTuplePointerSliceTypes(data_types)) makeTupleConstSliceTypes(data_types) {
    var dereferenced_inputs: makeTupleConstSliceTypes(data_types) = undefined;

    inline for (data_types, 0..) |_, i| {
        dereferenced_inputs[i] = inputs[i].*;
    }

    return dereferenced_inputs;
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

test "dataTypeSizes" {
    try std.testing.expectEqualSlices(usize, &[0]usize{}, dataTypeSizes(&[0]type{}));
    try std.testing.expectEqualSlices(usize, &[4]usize{ 1, 16, 8, 1 }, dataTypeSizes(&[4]type{ u8, u128, u64, bool }));
}

test "make tuple const slice types" {
    try std.testing.expectEqual(makeTupleConstSliceTypes(&[0]type{}), std.meta.Tuple(&[0]type{}));
    try std.testing.expectEqual(makeTupleConstSliceTypes(&[1]type{u32}), std.meta.Tuple(&[1]type{[]const u32}));
    try std.testing.expectEqual(makeTupleConstSliceTypes(&[3]type{ u8, f32, bool }), std.meta.Tuple(&[3]type{ []const u8, []const f32, []const bool }));
}

test "make tuple slice types" {
    try std.testing.expectEqual(makeTupleSliceTypes(&[0]type{}), std.meta.Tuple(&[0]type{}));
    try std.testing.expectEqual(makeTupleSliceTypes(&[1]type{u32}), std.meta.Tuple(&[1]type{[]u32}));
    try std.testing.expectEqual(makeTupleSliceTypes(&[3]type{ u8, f32, bool }), std.meta.Tuple(&[3]type{ []u8, []f32, []bool }));
}

test "make tuple pointer slice types" {
    try std.testing.expectEqual(makeTuplePointerSliceTypes(&[0]type{}), std.meta.Tuple(&[0]type{}));
    try std.testing.expectEqual(makeTuplePointerSliceTypes(&[1]type{u32}), std.meta.Tuple(&[1]type{*[]const u32}));
    try std.testing.expectEqual(makeTuplePointerSliceTypes(&[3]type{ u8, f32, bool }), std.meta.Tuple(&[3]type{ *[]const u8, *[]const f32, *[]const bool }));
}

test "dereference tuple pointer slices" {
    var a: []const u8 = "hello";
    var b: []const u32 = &[_]u32{ 0xdeadbeef, 0xcafecafe };

    var x: makeTuplePointerSliceTypes(&[2]type{ u8, u32 }) = .{ &a, &b };
    var y = dereferenceTuplePointerSlices(&[2]type{ u8, u32 }, x);

    try std.testing.expectEqualSlices(u8, "hello", y[0]);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 0xdeadbeef, 0xcafecafe }, y[1]);
}
