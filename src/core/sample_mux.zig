const std = @import("std");

const util = @import("util.zig");

const ComptimeTypeSignature = @import("types.zig").ComptimeTypeSignature;
const ProcessResult = @import("block.zig").ProcessResult;
const RefCounted = @import("types.zig").RefCounted;
const hasTypeTag = @import("types.zig").hasTypeTag;

////////////////////////////////////////////////////////////////////////////////
// SampleMux
////////////////////////////////////////////////////////////////////////////////

pub const SampleMux = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        waitInputAvailable: *const fn (ptr: *anyopaque, index: usize, min_count: usize, timeout_ns: ?u64) error{ EndOfStream, Timeout }!void,
        waitOutputAvailable: *const fn (ptr: *anyopaque, index: usize, min_count: usize, timeout_ns: ?u64) error{ BrokenStream, Timeout }!void,
        getInputAvailable: *const fn (ptr: *anyopaque, index: usize) error{EndOfStream}!usize,
        getOutputAvailable: *const fn (ptr: *anyopaque, index: usize) error{BrokenStream}!usize,
        getInputBuffer: *const fn (ptr: *anyopaque, index: usize) []const u8,
        getOutputBuffer: *const fn (ptr: *anyopaque, index: usize) []u8,
        updateInputBuffer: *const fn (ptr: *anyopaque, index: usize, count: usize) void,
        updateOutputBuffer: *const fn (ptr: *anyopaque, index: usize, count: usize) void,
        getNumReadersForOutput: *const fn (ptr: *anyopaque, index: usize) usize,
        setEOS: *const fn (ptr: *anyopaque) void,
    };

    ////////////////////////////////////////////////////////////////////////////
    // Sample Buffers API
    ////////////////////////////////////////////////////////////////////////////

    pub fn SampleBuffers(comptime type_signature: ComptimeTypeSignature) type {
        return struct {
            inputs: util.makeTupleConstSliceTypes(type_signature.inputs),
            outputs: util.makeTupleSliceTypes(type_signature.outputs),
        };
    }

    pub fn wait(self: SampleMux, comptime type_signature: ComptimeTypeSignature, timeout_ns: ?u64) error{ Timeout, EndOfStream, BrokenStream }!usize {
        const input_element_sizes = comptime util.dataTypeSizes(type_signature.inputs);
        const output_element_sizes = comptime util.dataTypeSizes(type_signature.outputs);

        var input_samples_available: [type_signature.inputs.len]usize = undefined;
        var output_samples_available: [type_signature.outputs.len]usize = undefined;
        var min_samples_available: usize = 0;

        while (min_samples_available == 0) {
            // Get input and output samples available across all inputs and outputs
            inline for (type_signature.inputs, 0..) |input_type, i| {
                input_samples_available[i] = try self.vtable.getInputAvailable(self.ptr, i) / @sizeOf(input_type);
            }
            inline for (type_signature.outputs, 0..) |output_type, i| {
                output_samples_available[i] = try self.vtable.getOutputAvailable(self.ptr, i) / @sizeOf(output_type);
            }

            // Compute minimum input and output samples available
            const min_input_samples_index = if (type_signature.inputs.len != 0) std.mem.indexOfMin(usize, input_samples_available[0..type_signature.inputs.len]) else void;
            const min_output_samples_index = if (type_signature.outputs.len != 0) std.mem.indexOfMin(usize, output_samples_available[0..type_signature.outputs.len]) else void;
            const min_input_samples = if (type_signature.inputs.len != 0) input_samples_available[min_input_samples_index] else void;
            const min_output_samples = if (type_signature.outputs.len != 0) output_samples_available[min_output_samples_index] else void;

            if (type_signature.inputs.len > 0 and min_input_samples == 0) {
                // No input samples available for at least one input
                try self.vtable.waitInputAvailable(self.ptr, min_input_samples_index, input_element_sizes[min_input_samples_index], timeout_ns);
            } else if (type_signature.outputs.len > 0 and min_output_samples == 0) {
                // No output samples available for at least one output
                try self.vtable.waitOutputAvailable(self.ptr, min_output_samples_index, output_element_sizes[min_output_samples_index], timeout_ns);
            } else {
                min_samples_available = if (type_signature.inputs.len == 0) min_output_samples else if (type_signature.outputs.len == 0) min_input_samples else @min(min_input_samples, min_output_samples);
            }
        }

        return min_samples_available;
    }

    pub fn get(self: SampleMux, comptime type_signature: ComptimeTypeSignature) error{ EndOfStream, BrokenStream }!SampleBuffers(type_signature) {
        // Wait for sufficient number of samples
        const min_samples_available = self.wait(type_signature, null) catch |err| switch (err) {
            error.EndOfStream, error.BrokenStream => |e| return e,
            error.Timeout => unreachable,
        };

        // Get sample buffers
        var sample_buffers: SampleBuffers(type_signature) = undefined;
        inline for (type_signature.inputs, 0..) |input_type, i| {
            const buffer = self.vtable.getInputBuffer(self.ptr, i);
            sample_buffers.inputs[i] = @alignCast(std.mem.bytesAsSlice(input_type, buffer[0 .. min_samples_available * @sizeOf(type_signature.inputs[i])]));
        }
        inline for (type_signature.outputs, 0..) |output_type, i| {
            const buffer = self.vtable.getOutputBuffer(self.ptr, i);
            sample_buffers.outputs[i] = @alignCast(std.mem.bytesAsSlice(output_type, buffer[0..std.mem.alignBackward(usize, buffer.len, @sizeOf(type_signature.outputs[i]))]));
        }

        // Return typed input and output buffers
        return sample_buffers;
    }

    pub fn update(self: SampleMux, comptime type_signature: ComptimeTypeSignature, buffers: SampleBuffers(type_signature), process_result: ProcessResult) void {
        // Handle RefCounted(T) inputs (decrement reference count)
        inline for (type_signature.inputs, 0..) |input_type, i| {
            if (comptime hasTypeTag(input_type, .RefCounted)) {
                // TODO @constCast() here is ugly, but safe
                for (buffers.inputs[i]) |*e| @constCast(e).unref();
            }
        }

        // Handle RefCounted(T) outputs (increment reference count for additional readers)
        inline for (type_signature.outputs, 0..) |output_type, i| {
            if (comptime hasTypeTag(output_type, .RefCounted)) {
                const num_readers = self.vtable.getNumReadersForOutput(self.ptr, i);
                switch (num_readers) {
                    0 => for (buffers.outputs[i]) |*e| e.unref(), // No readers
                    1 => {}, // Elements already initialized with an rc of 1
                    else => for (buffers.outputs[i]) |*e| e.ref(num_readers - 1), // Ref additional readers
                }
            }
        }

        // Update sample buffers
        inline for (type_signature.inputs, 0..) |_, i| {
            self.vtable.updateInputBuffer(self.ptr, i, process_result.samples_consumed[i] * @sizeOf(type_signature.inputs[i]));
        }
        inline for (type_signature.outputs, 0..) |_, i| {
            self.vtable.updateOutputBuffer(self.ptr, i, process_result.samples_produced[i] * @sizeOf(type_signature.outputs[i]));
        }
    }

    pub fn setEOS(self: SampleMux) void {
        self.vtable.setEOS(self.ptr);
    }
};

////////////////////////////////////////////////////////////////////////////////
// ThreadSafeRingBufferSampleMux
////////////////////////////////////////////////////////////////////////////////

const ThreadSafeRingBuffer = @import("ring_buffer.zig").ThreadSafeRingBuffer;

pub const ThreadSafeRingBufferSampleMux = struct {
    const Self = @This();

    readers: std.ArrayList(ThreadSafeRingBuffer.Reader),
    writers: std.ArrayList(ThreadSafeRingBuffer.Writer),

    pub fn init(allocator: std.mem.Allocator, inputs: []const *ThreadSafeRingBuffer, outputs: []const *ThreadSafeRingBuffer) !Self {
        var readers = std.ArrayList(ThreadSafeRingBuffer.Reader).init(allocator);
        for (inputs) |ring_buffer| try readers.append(ring_buffer.reader());

        var writers = std.ArrayList(ThreadSafeRingBuffer.Writer).init(allocator);
        for (outputs) |ring_buffer| try writers.append(ring_buffer.writer());

        return .{
            .readers = readers,
            .writers = writers,
        };
    }

    pub fn deinit(self: *Self) void {
        self.readers.deinit();
        self.writers.deinit();
    }

    ////////////////////////////////////////////////////////////////////////////
    // SampleMux API
    ////////////////////////////////////////////////////////////////////////////

    pub fn waitInputAvailable(ptr: *anyopaque, index: usize, min_count: usize, timeout_ns: ?u64) error{ EndOfStream, Timeout }!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.readers.items[index].waitAvailable(min_count, timeout_ns);
    }

    pub fn waitOutputAvailable(ptr: *anyopaque, index: usize, min_count: usize, timeout_ns: ?u64) error{ BrokenStream, Timeout }!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.writers.items[index].waitAvailable(min_count, timeout_ns);
    }

    pub fn getInputAvailable(ptr: *anyopaque, index: usize) error{EndOfStream}!usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.readers.items[index].getAvailable();
    }

    pub fn getOutputAvailable(ptr: *anyopaque, index: usize) error{BrokenStream}!usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.writers.items[index].getAvailable();
    }

    pub fn getInputBuffer(ptr: *anyopaque, index: usize) []const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.readers.items[index].getBuffer();
    }

    pub fn getOutputBuffer(ptr: *anyopaque, index: usize) []u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.writers.items[index].getBuffer();
    }

    pub fn updateInputBuffer(ptr: *anyopaque, index: usize, count: usize) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.readers.items[index].update(count);
    }

    pub fn updateOutputBuffer(ptr: *anyopaque, index: usize, count: usize) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.writers.items[index].getNumReaders() > 0) {
            self.writers.items[index].update(count);
        }
    }

    pub fn getNumReadersForOutput(ptr: *anyopaque, index: usize) usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.writers.items[index].getNumReaders();
    }

    pub fn setEOS(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        for (self.writers.items) |*writer| writer.setEOS();
        for (self.readers.items) |*reader| reader.setEOS();
    }

    pub fn sampleMux(self: *Self) SampleMux {
        return .{
            .ptr = self,
            .vtable = &.{
                .waitInputAvailable = waitInputAvailable,
                .waitOutputAvailable = waitOutputAvailable,
                .getInputAvailable = getInputAvailable,
                .getOutputAvailable = getOutputAvailable,
                .getInputBuffer = getInputBuffer,
                .getOutputBuffer = getOutputBuffer,
                .updateInputBuffer = updateInputBuffer,
                .updateOutputBuffer = updateOutputBuffer,
                .getNumReadersForOutput = getNumReadersForOutput,
                .setEOS = setEOS,
            },
        };
    }
};

////////////////////////////////////////////////////////////////////////////////
// TestSampleMux
////////////////////////////////////////////////////////////////////////////////

pub fn TestSampleMux(comptime input_data_types: []const type, comptime output_data_types: []const type) type {
    return struct {
        const Self = @This();

        pub const Options = struct {
            single_input_samples: bool = false,
            single_output_samples: bool = false,
        };

        input_buffers: [input_data_types.len][]const u8,
        input_buffer_indices: [input_data_types.len]usize = .{0} ** input_data_types.len,
        output_buffers: [output_data_types.len][]u8,
        output_buffer_indices: [output_data_types.len]usize = .{0} ** output_data_types.len,
        options: Options,

        pub fn init(input_buffers: [input_data_types.len][]const u8, options: Options) !Self {
            var output_buffers: [output_data_types.len][]u8 = undefined;
            inline for (&output_buffers) |*output_buffer| output_buffer.* = try std.testing.allocator.alloc(u8, 16384);

            return .{
                .input_buffers = input_buffers,
                .output_buffers = output_buffers,
                .options = options,
            };
        }

        pub fn deinit(self: *Self) void {
            inline for (self.output_buffers) |output_buffer| std.testing.allocator.free(output_buffer);
        }

        ////////////////////////////////////////////////////////////////////////////
        // Getters
        ////////////////////////////////////////////////////////////////////////////

        pub fn getOutputVector(self: *Self, comptime T: type, index: usize) []const T {
            return @alignCast(std.mem.bytesAsSlice(T, self.output_buffers[index][0..self.output_buffer_indices[index]]));
        }

        ////////////////////////////////////////////////////////////////////////////
        // SampleMux API
        ////////////////////////////////////////////////////////////////////////////

        pub fn waitInputAvailable(ptr: *anyopaque, index: usize, _: usize, _: ?u64) error{ EndOfStream, Timeout }!void {
            _ = try getInputAvailable(ptr, index);
        }

        pub fn waitOutputAvailable(_: *anyopaque, _: usize, _: usize, _: ?u64) error{ BrokenStream, Timeout }!void {}

        pub fn getInputAvailable(ptr: *anyopaque, index: usize) error{EndOfStream}!usize {
            const self: *Self = @ptrCast(@alignCast(ptr));

            if (input_data_types.len == 0) return 0;

            if (self.input_buffer_indices[index] == self.input_buffers[index].len) {
                return error.EndOfStream;
            } else if (self.input_buffer_indices[index] < self.input_buffers[index].len and self.options.single_input_samples) {
                return (comptime util.dataTypeSizes(input_data_types))[index];
            } else {
                return self.input_buffers[index].len - self.input_buffer_indices[index];
            }
        }

        pub fn getOutputAvailable(ptr: *anyopaque, index: usize) error{BrokenStream}!usize {
            const self: *Self = @ptrCast(@alignCast(ptr));

            if (output_data_types.len == 0) return 0;

            if (self.options.single_output_samples) {
                return (comptime util.dataTypeSizes)(output_data_types)[index];
            } else {
                return self.output_buffers[index].len - self.output_buffer_indices[index];
            }
        }

        pub fn getInputBuffer(ptr: *anyopaque, index: usize) []const u8 {
            const self: *Self = @ptrCast(@alignCast(ptr));

            if (input_data_types.len == 0) return &.{};

            if (self.options.single_input_samples) {
                return self.input_buffers[index][self.input_buffer_indices[index] .. self.input_buffer_indices[index] + (comptime util.dataTypeSizes(input_data_types))[index]];
            } else {
                return self.input_buffers[index][self.input_buffer_indices[index]..];
            }
        }

        pub fn getOutputBuffer(ptr: *anyopaque, index: usize) []u8 {
            const self: *Self = @ptrCast(@alignCast(ptr));

            if (output_data_types.len == 0) return &.{};

            if (self.options.single_output_samples) {
                return self.output_buffers[index][self.output_buffer_indices[index] .. self.output_buffer_indices[index] + (comptime util.dataTypeSizes(output_data_types))[index]];
            } else {
                return self.output_buffers[index][self.output_buffer_indices[index]..];
            }
        }

        pub fn updateInputBuffer(ptr: *anyopaque, index: usize, count: usize) void {
            const self: *Self = @ptrCast(@alignCast(ptr));

            if (input_data_types.len == 0) return;

            self.input_buffer_indices[index] += count;
        }

        pub fn updateOutputBuffer(ptr: *anyopaque, index: usize, count: usize) void {
            const self: *Self = @ptrCast(@alignCast(ptr));

            if (output_data_types.len == 0) return;

            self.output_buffer_indices[index] += count;
        }

        pub fn getNumReadersForOutput(_: *anyopaque, _: usize) usize {
            return 0;
        }

        pub fn setEOS(_: *anyopaque) void {
            // TestSampleMux has no readers
        }

        pub fn sampleMux(self: *Self) SampleMux {
            return .{
                .ptr = self,
                .vtable = &.{
                    .waitInputAvailable = waitInputAvailable,
                    .waitOutputAvailable = waitOutputAvailable,
                    .getInputAvailable = getInputAvailable,
                    .getOutputAvailable = getOutputAvailable,
                    .getInputBuffer = getInputBuffer,
                    .getOutputBuffer = getOutputBuffer,
                    .updateInputBuffer = updateInputBuffer,
                    .updateOutputBuffer = updateOutputBuffer,
                    .getNumReadersForOutput = getNumReadersForOutput,
                    .setEOS = setEOS,
                },
            };
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const builtin = @import("builtin");

test "TestSampleMux multiple input, single output" {
    const ibuf1: [8]u8 = .{ 0xaa, 0xbb, 0xcc, 0xdd, 0xab, 0xcd, 0xee, 0xff };
    const ibuf2: [8]u8 = .{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };

    const ts = ComptimeTypeSignature.fromTypes(&[2]type{ u32, u32 }, &[1]type{u16});

    var test_sample_mux = try TestSampleMux(ts.inputs, ts.outputs).init([2][]const u8{ &ibuf1, &ibuf2 }, .{});
    defer test_sample_mux.deinit();

    var sample_mux = test_sample_mux.sampleMux();

    var buffers = try sample_mux.get(ts);

    try std.testing.expectEqual(@as(usize, 2), buffers.inputs.len);
    try std.testing.expectEqual(@as(usize, 2), buffers.inputs[0].len);
    try std.testing.expectEqual(@as(usize, 2), buffers.inputs[1].len);
    try std.testing.expectEqual(@as(usize, 1), buffers.outputs.len);
    try std.testing.expect(buffers.outputs[0].len > 4);

    try std.testing.expectEqual(std.mem.bigToNative(u32, 0xaabbccdd), buffers.inputs[0][0]);
    try std.testing.expectEqual(std.mem.bigToNative(u32, 0xabcdeeff), buffers.inputs[0][1]);
    try std.testing.expectEqual(std.mem.bigToNative(u32, 0x11223344), buffers.inputs[1][0]);
    try std.testing.expectEqual(std.mem.bigToNative(u32, 0x55667788), buffers.inputs[1][1]);

    @memcpy(buffers.outputs[0][0..4], &[_]u16{ 0x1122, 0x3344, 0x5566, 0x7788 });

    sample_mux.update(ts, buffers, ProcessResult.init(&[2]usize{ 1, 1 }, &[1]usize{4}));

    try std.testing.expectEqualSlices(u16, &[_]u16{ 0x1122, 0x3344, 0x5566, 0x7788 }, test_sample_mux.getOutputVector(u16, 0));

    buffers = try sample_mux.get(ts);

    try std.testing.expectEqual(@as(usize, 2), buffers.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), buffers.inputs[0].len);
    try std.testing.expectEqual(@as(usize, 1), buffers.inputs[1].len);
    try std.testing.expectEqual(@as(usize, 1), buffers.outputs.len);
    try std.testing.expect(buffers.outputs[0].len > 4);

    try std.testing.expectEqual(std.mem.bigToNative(u32, 0xabcdeeff), buffers.inputs[0][0]);
    try std.testing.expectEqual(std.mem.bigToNative(u32, 0x55667788), buffers.inputs[1][0]);

    @memcpy(buffers.outputs[0][0..4], &[_]u16{ 0x99aa, 0xbbcc, 0xddee, 0xff00 });

    sample_mux.update(ts, buffers, ProcessResult.init(&[2]usize{ 1, 0 }, &[1]usize{4}));

    try std.testing.expectEqualSlices(u16, &[_]u16{ 0x99aa, 0xbbcc, 0xddee, 0xff00 }, test_sample_mux.getOutputVector(u16, 0)[4..]);

    try std.testing.expectError(error.EndOfStream, sample_mux.get(ts));
}

test "TestSampleMux single input samples" {
    const ibuf1: [8]u8 = .{ 0xaa, 0xbb, 0xcc, 0xdd, 0xab, 0xcd, 0xee, 0xff };
    const ibuf2: [8]u8 = .{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };

    const ts = ComptimeTypeSignature.fromTypes(&[2]type{ u32, u32 }, &[1]type{u16});

    var test_sample_mux = try TestSampleMux(ts.inputs, ts.outputs).init([2][]const u8{ &ibuf1, &ibuf2 }, .{ .single_input_samples = true });
    defer test_sample_mux.deinit();

    var sample_mux = test_sample_mux.sampleMux();

    var buffers = try sample_mux.get(ts);

    try std.testing.expectEqual(@as(usize, 2), buffers.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), buffers.inputs[0].len);
    try std.testing.expectEqual(@as(usize, 1), buffers.inputs[1].len);
    try std.testing.expectEqual(@as(usize, 1), buffers.outputs.len);
    try std.testing.expect(buffers.outputs[0].len > 4);

    try std.testing.expectEqual(std.mem.bigToNative(u32, 0xaabbccdd), buffers.inputs[0][0]);
    try std.testing.expectEqual(std.mem.bigToNative(u32, 0x11223344), buffers.inputs[1][0]);

    sample_mux.update(ts, buffers, ProcessResult.init(&[2]usize{ 1, 1 }, &[1]usize{0}));

    buffers = try sample_mux.get(ts);

    try std.testing.expectEqual(@as(usize, 2), buffers.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), buffers.inputs[0].len);
    try std.testing.expectEqual(@as(usize, 1), buffers.inputs[1].len);
    try std.testing.expectEqual(@as(usize, 1), buffers.outputs.len);
    try std.testing.expect(buffers.outputs[0].len > 4);

    try std.testing.expectEqual(std.mem.bigToNative(u32, 0xabcdeeff), buffers.inputs[0][0]);
    try std.testing.expectEqual(std.mem.bigToNative(u32, 0x55667788), buffers.inputs[1][0]);

    sample_mux.update(ts, buffers, ProcessResult.init(&[2]usize{ 1, 1 }, &[1]usize{0}));

    try std.testing.expectError(error.EndOfStream, sample_mux.get(ts));
}

test "TestSampleMux single output samples" {
    const ts = ComptimeTypeSignature.fromTypes(&[0]type{}, &[1]type{u32});

    var test_sample_mux = try TestSampleMux(ts.inputs, ts.outputs).init([0][]const u8{}, .{ .single_output_samples = true });
    defer test_sample_mux.deinit();

    var sample_mux = test_sample_mux.sampleMux();

    var buffers = try sample_mux.get(ts);

    try std.testing.expectEqual(@as(usize, 0), buffers.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), buffers.outputs.len);
    try std.testing.expect(buffers.outputs[0].len == 1);

    sample_mux.update(ts, buffers, ProcessResult.init(&[0]usize{}, &[1]usize{1}));

    buffers = try sample_mux.get(ts);

    try std.testing.expectEqual(@as(usize, 0), buffers.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), buffers.outputs.len);
    try std.testing.expect(buffers.outputs[0].len == 1);
}

test "ThreadSafeRingBufferSampleMux single input, single output" {
    const ts = ComptimeTypeSignature.fromTypes(&[1]type{u16}, &[1]type{u32});

    // Create ring buffers
    var input_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer input_ring_buffer.deinit();
    var output_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer output_ring_buffer.deinit();

    // Get ring buffer reader/write interfaces
    var input_writer = input_ring_buffer.writer();
    var output_reader = output_ring_buffer.reader();

    // Create ring buffer sample mux
    var ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux.init(std.testing.allocator, &[_]*ThreadSafeRingBuffer{&input_ring_buffer}, &[1]*ThreadSafeRingBuffer{&output_ring_buffer});
    defer ring_buffer_sample_mux.deinit();
    var sample_mux = ring_buffer_sample_mux.sampleMux();

    // Load 3 samples into input ring buffer
    input_writer.write(&[_]u8{0xaa} ** 2);
    input_writer.write(&[_]u8{0xbb} ** 2);
    input_writer.write(&[_]u8{0xcc} ** 2);

    // Verify wait returns lowest common number of samples available
    try std.testing.expectEqual(@as(usize, 3), try sample_mux.wait(ts, null));

    // Get sample buffers
    var buffers = try sample_mux.get(ts);

    // Verify lengths and input samples
    try std.testing.expectEqual(@as(usize, 1), buffers.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), buffers.outputs.len);
    try std.testing.expectEqual(@as(usize, 3), buffers.inputs[0].len);
    try std.testing.expectEqual(@as(u16, 0xaaaa), buffers.inputs[0][0]);
    try std.testing.expectEqual(@as(u16, 0xbbbb), buffers.inputs[0][1]);
    try std.testing.expectEqual(@as(u16, 0xcccc), buffers.inputs[0][2]);

    // Write three samples
    buffers.outputs[0][0] = 0xaaaaaaaa;
    buffers.outputs[0][1] = 0xbbbbbbbb;
    buffers.outputs[0][2] = 0xcccccccc;

    // Update sample mux
    sample_mux.update(ts, buffers, ProcessResult.init(&[1]usize{3}, &[1]usize{3}));

    // Verify ring buffer state
    try std.testing.expectEqual(@as(usize, 0), input_ring_buffer.impl.getReadAvailable(0));
    try std.testing.expectEqual(@as(usize, 12), output_ring_buffer.impl.getReadAvailable(0));

    // Verify written samples
    var b: [4]u8 = .{0x00} ** 4;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xaa, 0xaa, 0xaa, 0xaa }, output_reader.read(b[0..]));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xbb, 0xbb, 0xbb, 0xbb }, output_reader.read(b[0..]));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xcc, 0xcc, 0xcc, 0xcc }, output_reader.read(b[0..]));

    // Load 3 more samples into input ring buffer
    input_writer.write(&[_]u8{0xdd} ** 2);
    input_writer.write(&[_]u8{0xee} ** 2);
    input_writer.write(&[_]u8{0xff} ** 2);

    // Get sample buffers
    buffers = try sample_mux.get(ts);

    // Verify lengths and input samples
    try std.testing.expectEqual(@as(usize, 3), buffers.inputs[0].len);
    try std.testing.expectEqual(@as(u16, 0xdddd), buffers.inputs[0][0]);
    try std.testing.expectEqual(@as(u16, 0xeeee), buffers.inputs[0][1]);
    try std.testing.expectEqual(@as(u16, 0xffff), buffers.inputs[0][2]);

    // Write two samples
    buffers.outputs[0][0] = 0x11111111;
    buffers.outputs[0][1] = 0x22222222;

    // Update sample mux with 1 consumed and 2 produced
    sample_mux.update(ts, buffers, ProcessResult.init(&[1]usize{1}, &[1]usize{2}));

    // Verify ring buffer state
    try std.testing.expectEqual(@as(usize, 4), input_ring_buffer.impl.getReadAvailable(0));
    try std.testing.expectEqual(@as(usize, 8), output_ring_buffer.impl.getReadAvailable(0));

    // Verify written samples
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x11, 0x11, 0x11 }, output_reader.read(b[0..]));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x22, 0x22, 0x22, 0x22 }, output_reader.read(b[0..]));

    // Get sample buffers
    buffers = try sample_mux.get(ts);

    // Verify lengths and input samples
    try std.testing.expectEqual(@as(usize, 2), buffers.inputs[0].len);
    try std.testing.expectEqual(@as(u16, 0xeeee), buffers.inputs[0][0]);
    try std.testing.expectEqual(@as(u16, 0xffff), buffers.inputs[0][1]);

    // Write one sample
    buffers.outputs[0][0] = 0x33333333;

    // Update sample mux with 1 consumed and 1 produced
    sample_mux.update(ts, buffers, ProcessResult.init(&[1]usize{2}, &[1]usize{1}));

    // Verify ring buffer state
    try std.testing.expectEqual(@as(usize, 0), input_ring_buffer.impl.getReadAvailable(0));
    try std.testing.expectEqual(@as(usize, 4), output_ring_buffer.impl.getReadAvailable(0));

    // Verify written samples
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x33, 0x33, 0x33, 0x33 }, output_reader.read(b[0..]));
}

test "ThreadSafeRingBufferSampleMux multiple input, multiple output" {
    const ts = ComptimeTypeSignature.fromTypes(&[2]type{ u16, u8 }, &[2]type{ u32, u8 });

    // Create ring buffers
    var input1_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer input1_ring_buffer.deinit();
    var input2_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer input2_ring_buffer.deinit();
    var output1_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer output1_ring_buffer.deinit();
    var output2_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer output2_ring_buffer.deinit();

    // Get ring buffer reader/write interfaces
    var input1_writer = input1_ring_buffer.writer();
    var input2_writer = input2_ring_buffer.writer();
    var output1_reader = output1_ring_buffer.reader();
    var output2_reader = output2_ring_buffer.reader();

    // Create ring buffer sample mux
    var ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux.init(std.testing.allocator, &[2]*ThreadSafeRingBuffer{ &input1_ring_buffer, &input2_ring_buffer }, &[2]*ThreadSafeRingBuffer{ &output1_ring_buffer, &output2_ring_buffer });
    defer ring_buffer_sample_mux.deinit();
    var sample_mux = ring_buffer_sample_mux.sampleMux();

    // Load 3 samples into input 1 ring buffer
    input1_writer.write(&[_]u8{0xaa} ** 2);
    input1_writer.write(&[_]u8{0xbb} ** 2);
    input1_writer.write(&[_]u8{0xcc} ** 2);

    // Load 4 samples into input 2 ring buffer
    input2_writer.write(&[_]u8{0x11} ** 1);
    input2_writer.write(&[_]u8{0x22} ** 1);
    input2_writer.write(&[_]u8{0x33} ** 1);
    input2_writer.write(&[_]u8{0x44} ** 1);

    // Verify wait returns lowest common number of samples available
    try std.testing.expectEqual(@as(usize, 3), try sample_mux.wait(ts, null));

    // Get sample buffers
    var buffers = try sample_mux.get(ts);

    // Verify lengths and input samples
    try std.testing.expectEqual(@as(usize, 2), buffers.inputs.len);
    try std.testing.expectEqual(@as(usize, 2), buffers.outputs.len);
    try std.testing.expectEqual(@as(usize, 3), buffers.inputs[0].len);
    try std.testing.expectEqual(@as(usize, 3), buffers.inputs[1].len);
    try std.testing.expectEqual(@as(u16, 0xaaaa), buffers.inputs[0][0]);
    try std.testing.expectEqual(@as(u16, 0xbbbb), buffers.inputs[0][1]);
    try std.testing.expectEqual(@as(u16, 0xcccc), buffers.inputs[0][2]);
    try std.testing.expectEqual(@as(u16, 0x11), buffers.inputs[1][0]);
    try std.testing.expectEqual(@as(u16, 0x22), buffers.inputs[1][1]);
    try std.testing.expectEqual(@as(u16, 0x33), buffers.inputs[1][2]);

    // Write two samples to output 1
    buffers.outputs[0][0] = 0xaaaaaaaa;
    buffers.outputs[0][1] = 0xbbbbbbbb;

    // Write three samples to output 2
    buffers.outputs[1][0] = 0xcc;
    buffers.outputs[1][1] = 0xdd;
    buffers.outputs[1][2] = 0xee;

    // Update sample mux
    sample_mux.update(ts, buffers, ProcessResult.init(&[2]usize{ 1, 2 }, &[2]usize{ 2, 3 }));

    // Verify ring buffer state
    try std.testing.expectEqual(@as(usize, 4), input1_ring_buffer.impl.getReadAvailable(0));
    try std.testing.expectEqual(@as(usize, 2), input2_ring_buffer.impl.getReadAvailable(0));
    try std.testing.expectEqual(@as(usize, 8), output1_ring_buffer.impl.getReadAvailable(0));
    try std.testing.expectEqual(@as(usize, 3), output2_ring_buffer.impl.getReadAvailable(0));

    // Verify written samples
    var b: [4]u8 = .{0x00} ** 4;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xaa, 0xaa, 0xaa, 0xaa }, output1_reader.read(b[0..]));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xbb, 0xbb, 0xbb, 0xbb }, output1_reader.read(b[0..]));
    try std.testing.expectEqualSlices(u8, &[_]u8{0xcc}, output2_reader.read(b[0..1]));
    try std.testing.expectEqualSlices(u8, &[_]u8{0xdd}, output2_reader.read(b[0..1]));
    try std.testing.expectEqualSlices(u8, &[_]u8{0xee}, output2_reader.read(b[0..1]));
}

test "ThreadSafeRingBufferSampleMux only inputs" {
    const ts = ComptimeTypeSignature.fromTypes(&[2]type{ u16, u8 }, &[0]type{});

    // Create ring buffers
    var input1_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer input1_ring_buffer.deinit();
    var input2_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer input2_ring_buffer.deinit();

    // Get ring buffer reader/write interfaces
    var input1_writer = input1_ring_buffer.writer();
    var input2_writer = input2_ring_buffer.writer();

    // Create ring buffer sample mux
    var ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux.init(std.testing.allocator, &[2]*ThreadSafeRingBuffer{ &input1_ring_buffer, &input2_ring_buffer }, &[0]*ThreadSafeRingBuffer{});
    defer ring_buffer_sample_mux.deinit();
    var sample_mux = ring_buffer_sample_mux.sampleMux();

    // Load 3 samples into input 1 ring buffer
    input1_writer.write(&[_]u8{0xaa} ** 2);
    input1_writer.write(&[_]u8{0xbb} ** 2);
    input1_writer.write(&[_]u8{0xcc} ** 2);

    // Load 4 samples into input 2 ring buffer
    input2_writer.write(&[_]u8{0x11} ** 1);
    input2_writer.write(&[_]u8{0x22} ** 1);
    input2_writer.write(&[_]u8{0x33} ** 1);
    input2_writer.write(&[_]u8{0x44} ** 1);

    // Verify wait returns lowest common number of samples available
    try std.testing.expectEqual(@as(usize, 3), try sample_mux.wait(ts, null));

    // Get sample buffers
    var buffers = try sample_mux.get(ts);

    // Verify lengths and input samples
    try std.testing.expectEqual(@as(usize, 2), buffers.inputs.len);
    try std.testing.expectEqual(@as(usize, 0), buffers.outputs.len);
    try std.testing.expectEqual(@as(usize, 3), buffers.inputs[0].len);
    try std.testing.expectEqual(@as(usize, 3), buffers.inputs[1].len);
    try std.testing.expectEqual(@as(u16, 0xaaaa), buffers.inputs[0][0]);
    try std.testing.expectEqual(@as(u16, 0xbbbb), buffers.inputs[0][1]);
    try std.testing.expectEqual(@as(u16, 0xcccc), buffers.inputs[0][2]);
    try std.testing.expectEqual(@as(u16, 0x11), buffers.inputs[1][0]);
    try std.testing.expectEqual(@as(u16, 0x22), buffers.inputs[1][1]);
    try std.testing.expectEqual(@as(u16, 0x33), buffers.inputs[1][2]);

    // Update sample mux
    sample_mux.update(ts, buffers, ProcessResult.init(&[2]usize{ 2, 3 }, &[0]usize{}));

    // Verify ring buffer state
    try std.testing.expectEqual(@as(usize, 2), input1_ring_buffer.impl.getReadAvailable(0));
    try std.testing.expectEqual(@as(usize, 1), input2_ring_buffer.impl.getReadAvailable(0));

    // Get sample buffers
    buffers = try sample_mux.get(ts);

    // Verify lengths and input samples
    try std.testing.expectEqual(@as(usize, 2), buffers.inputs.len);
    try std.testing.expectEqual(@as(usize, 0), buffers.outputs.len);
    try std.testing.expectEqual(@as(usize, 1), buffers.inputs[0].len);
    try std.testing.expectEqual(@as(usize, 1), buffers.inputs[1].len);
    try std.testing.expectEqual(@as(u16, 0xcccc), buffers.inputs[0][0]);
    try std.testing.expectEqual(@as(u16, 0x44), buffers.inputs[1][0]);
}

test "ThreadSafeRingBufferSampleMux only outputs" {
    const ts = ComptimeTypeSignature.fromTypes(&[0]type{}, &[2]type{ u32, u8 });

    // Create ring buffers
    var output1_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer output1_ring_buffer.deinit();
    var output2_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer output2_ring_buffer.deinit();

    // Get ring buffer reader/write interfaces
    var output1_reader = output1_ring_buffer.reader();
    var output2_reader = output2_ring_buffer.reader();

    // Create ring buffer sample mux
    var ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux.init(std.testing.allocator, &[0]*ThreadSafeRingBuffer{}, &[2]*ThreadSafeRingBuffer{ &output1_ring_buffer, &output2_ring_buffer });
    defer ring_buffer_sample_mux.deinit();
    var sample_mux = ring_buffer_sample_mux.sampleMux();

    // Verify wait returns lowest common number of samples available
    try std.testing.expectEqual(@as(usize, (std.heap.page_size_min / @sizeOf(u32)) - 1), try sample_mux.wait(ts, null));

    // Get sample buffers
    var buffers = try sample_mux.get(ts);

    // Verify lengths and input samples
    try std.testing.expectEqual(@as(usize, 0), buffers.inputs.len);
    try std.testing.expectEqual(@as(usize, 2), buffers.outputs.len);

    // Write two samples to output 1
    buffers.outputs[0][0] = 0xaaaaaaaa;
    buffers.outputs[0][1] = 0xbbbbbbbb;

    // Write three samples to output 2
    buffers.outputs[1][0] = 0xcc;
    buffers.outputs[1][1] = 0xdd;
    buffers.outputs[1][2] = 0xee;

    // Update sample mux
    sample_mux.update(ts, buffers, ProcessResult.init(&[0]usize{}, &[2]usize{ 2, 3 }));

    // Verify ring buffer state
    try std.testing.expectEqual(@as(usize, 8), try output1_reader.getAvailable());
    try std.testing.expectEqual(@as(usize, 3), try output2_reader.getAvailable());

    // Verify written samples
    var b: [4]u8 = .{0x00} ** 4;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xaa, 0xaa, 0xaa, 0xaa }, output1_reader.read(b[0..]));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xbb, 0xbb, 0xbb, 0xbb }, output1_reader.read(b[0..]));
    try std.testing.expectEqualSlices(u8, &[_]u8{0xcc}, output2_reader.read(b[0..1]));
    try std.testing.expectEqualSlices(u8, &[_]u8{0xdd}, output2_reader.read(b[0..1]));
    try std.testing.expectEqualSlices(u8, &[_]u8{0xee}, output2_reader.read(b[0..1]));
}

test "ThreadSafeRingBufferSampleMux read eos" {
    const ts = ComptimeTypeSignature.fromTypes(&[2]type{ u16, u8 }, &[1]type{u32});

    // Create ring buffers
    var input1_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer input1_ring_buffer.deinit();
    var input2_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer input2_ring_buffer.deinit();
    var output1_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer output1_ring_buffer.deinit();

    // Get ring buffer reader/write interfaces
    var input1_writer = input1_ring_buffer.writer();
    var input2_writer = input2_ring_buffer.writer();
    var output1_reader = output1_ring_buffer.reader();

    // Create ring buffer sample mux
    var ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux.init(std.testing.allocator, &[2]*ThreadSafeRingBuffer{ &input1_ring_buffer, &input2_ring_buffer }, &[1]*ThreadSafeRingBuffer{&output1_ring_buffer});
    defer ring_buffer_sample_mux.deinit();
    var sample_mux = ring_buffer_sample_mux.sampleMux();

    // Load 3 samples into input 1 ring buffer
    input1_writer.write(&[_]u8{0xaa} ** 2);
    input1_writer.write(&[_]u8{0xbb} ** 2);
    input1_writer.write(&[_]u8{0xcc} ** 2);

    // Load 3 samples into input 2 ring buffer
    input2_writer.write(&[_]u8{0x11} ** 1);
    input2_writer.write(&[_]u8{0x22} ** 1);
    input2_writer.write(&[_]u8{0x33} ** 1);

    // Get sample buffers
    var buffers = try sample_mux.get(ts);

    // Verify lengths and input samples
    try std.testing.expectEqual(@as(usize, 2), buffers.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), buffers.outputs.len);
    try std.testing.expectEqual(@as(usize, 3), buffers.inputs[0].len);
    try std.testing.expectEqual(@as(usize, 3), buffers.inputs[1].len);
    try std.testing.expectEqual(@as(u16, 0xaaaa), buffers.inputs[0][0]);
    try std.testing.expectEqual(@as(u16, 0xbbbb), buffers.inputs[0][1]);
    try std.testing.expectEqual(@as(u16, 0xcccc), buffers.inputs[0][2]);
    try std.testing.expectEqual(@as(u16, 0x11), buffers.inputs[1][0]);
    try std.testing.expectEqual(@as(u16, 0x22), buffers.inputs[1][1]);
    try std.testing.expectEqual(@as(u16, 0x33), buffers.inputs[1][2]);

    // Write one sample to output 1
    buffers.outputs[0][0] = 0xaaaaaaaa;

    // Update sample mux to consume one sample
    sample_mux.update(ts, buffers, ProcessResult.init(&[2]usize{ 1, 1 }, &[1]usize{1}));

    // Verify ring buffer state
    try std.testing.expectEqual(@as(usize, 4), input1_ring_buffer.impl.getReadAvailable(0));
    try std.testing.expectEqual(@as(usize, 2), input2_ring_buffer.impl.getReadAvailable(0));
    try std.testing.expectEqual(@as(usize, 4), output1_ring_buffer.impl.getReadAvailable(0));

    // Verify written samples
    var b: [4]u8 = .{0x00} ** 4;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xaa, 0xaa, 0xaa, 0xaa }, output1_reader.read(b[0..]));

    // Set EOS on input 2
    input2_writer.setEOS();

    // Get sample buffers
    buffers = try sample_mux.get(ts);

    // Verify lengths and input samples
    try std.testing.expectEqual(@as(usize, 2), buffers.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), buffers.outputs.len);
    try std.testing.expectEqual(@as(usize, 2), buffers.inputs[0].len);
    try std.testing.expectEqual(@as(usize, 2), buffers.inputs[1].len);
    try std.testing.expectEqual(@as(u16, 0xbbbb), buffers.inputs[0][0]);
    try std.testing.expectEqual(@as(u16, 0xcccc), buffers.inputs[0][1]);
    try std.testing.expectEqual(@as(u16, 0x22), buffers.inputs[1][0]);
    try std.testing.expectEqual(@as(u16, 0x33), buffers.inputs[1][1]);

    // Write two samples to output 1
    buffers.outputs[0][0] = 0xbbbbbbbb;
    buffers.outputs[0][1] = 0xcccccccc;

    // Update sample mux to consume remaining samples
    sample_mux.update(ts, buffers, ProcessResult.init(&[2]usize{ 2, 2 }, &[1]usize{2}));

    // Wait sample buffers should return EOS
    try std.testing.expectError(error.EndOfStream, sample_mux.wait(ts, 0));

    // Get sample buffers should return EOS
    try std.testing.expectError(error.EndOfStream, sample_mux.get(ts));
}

test "ThreadSafeRingBufferSampleMux write eos" {
    const ts = ComptimeTypeSignature.fromTypes(&[1]type{u16}, &[1]type{u32});

    // Create ring buffers
    var input_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer input_ring_buffer.deinit();
    var output_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer output_ring_buffer.deinit();

    // Get ring buffer reader/write interfaces
    var input_writer = input_ring_buffer.writer();
    var output_reader = output_ring_buffer.reader();

    // Create ring buffer sample mux
    var ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux.init(std.testing.allocator, &[1]*ThreadSafeRingBuffer{&input_ring_buffer}, &[1]*ThreadSafeRingBuffer{&output_ring_buffer});
    defer ring_buffer_sample_mux.deinit();
    var sample_mux = ring_buffer_sample_mux.sampleMux();

    // Load 3 samples into input ring buffer
    input_writer.write(&[_]u8{0xaa} ** 2);
    input_writer.write(&[_]u8{0xbb} ** 2);
    input_writer.write(&[_]u8{0xcc} ** 2);

    // Get sample buffers
    var buffers = try sample_mux.get(ts);

    // Verify lengths and input samples
    try std.testing.expectEqual(@as(usize, 1), buffers.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), buffers.outputs.len);
    try std.testing.expectEqual(@as(usize, 3), buffers.inputs[0].len);
    try std.testing.expectEqual(@as(u16, 0xaaaa), buffers.inputs[0][0]);
    try std.testing.expectEqual(@as(u16, 0xbbbb), buffers.inputs[0][1]);
    try std.testing.expectEqual(@as(u16, 0xcccc), buffers.inputs[0][2]);

    // Write three samples
    buffers.outputs[0][0] = 0xaaaaaaaa;
    buffers.outputs[0][1] = 0xbbbbbbbb;
    buffers.outputs[0][2] = 0xcccccccc;

    // Update sample mux
    sample_mux.update(ts, buffers, ProcessResult.init(&[1]usize{3}, &[1]usize{3}));

    // Set write EOS
    sample_mux.setEOS();

    // Verify ring buffer state
    try std.testing.expectEqual(@as(usize, 0), input_ring_buffer.impl.getReadAvailable(0));
    try std.testing.expectEqual(@as(usize, 12), output_ring_buffer.impl.getReadAvailable(0));

    // Verify written samples
    var b: [4]u8 = .{0x00} ** 4;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xaa, 0xaa, 0xaa, 0xaa }, output_reader.read(b[0..]));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xbb, 0xbb, 0xbb, 0xbb }, output_reader.read(b[0..]));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xcc, 0xcc, 0xcc, 0xcc }, output_reader.read(b[0..]));

    // Verify output reader now gets EOS
    try std.testing.expectError(error.EndOfStream, output_reader.getAvailable());
}

test "ThreadSafeRingBufferSampleMux broken stream" {
    const ts = ComptimeTypeSignature.fromTypes(&[1]type{u16}, &[1]type{u32});

    // Create ring buffers
    var input_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer input_ring_buffer.deinit();
    var output_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer output_ring_buffer.deinit();

    // Get ring buffer reader/write interfaces
    var output_reader = output_ring_buffer.reader();

    // Create ring buffer sample mux
    var ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux.init(std.testing.allocator, &[1]*ThreadSafeRingBuffer{&input_ring_buffer}, &[1]*ThreadSafeRingBuffer{&output_ring_buffer});
    defer ring_buffer_sample_mux.deinit();
    var sample_mux = ring_buffer_sample_mux.sampleMux();

    // Set read EOS
    output_reader.setEOS();

    // Wait sample buffers should return BrokenStream
    try std.testing.expectError(error.BrokenStream, sample_mux.wait(ts, 0));

    // Get sample buffers should return EOS
    try std.testing.expectError(error.BrokenStream, sample_mux.get(ts));
}

test "ThreadSafeRingBufferSampleMux blocking read" {
    // This test requires spawning threads
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    const ts = ComptimeTypeSignature.fromTypes(&[2]type{ u16, u8 }, &[2]type{ u32, u8 });

    // Create ring buffers
    var input1_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer input1_ring_buffer.deinit();
    var input2_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer input2_ring_buffer.deinit();
    var output1_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer output1_ring_buffer.deinit();
    var output2_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer output2_ring_buffer.deinit();

    // Get ring buffer reader/write interfaces
    var input1_writer = input1_ring_buffer.writer();
    var input2_writer = input2_ring_buffer.writer();
    _ = output1_ring_buffer.reader();
    _ = output2_ring_buffer.reader();

    // Create ring buffer sample mux
    var ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux.init(std.testing.allocator, &[2]*ThreadSafeRingBuffer{ &input1_ring_buffer, &input2_ring_buffer }, &[2]*ThreadSafeRingBuffer{ &output1_ring_buffer, &output2_ring_buffer });
    defer ring_buffer_sample_mux.deinit();
    var sample_mux = ring_buffer_sample_mux.sampleMux();

    // Load 3 samples into input 1 ring buffer
    input1_writer.write(&[_]u8{0xaa} ** 2);
    input1_writer.write(&[_]u8{0xbb} ** 2);
    input1_writer.write(&[_]u8{0xcc} ** 2);

    // Leave input 2 ring buffer empty

    // Verify sample mux wait times out
    try std.testing.expectError(error.Timeout, sample_mux.wait(ts, 0));
    try std.testing.expectError(error.Timeout, sample_mux.wait(ts, std.time.ns_per_ms));

    const BufferWaiter = struct {
        fn run(sm: *SampleMux, done: *std.Thread.ResetEvent, _buffers: *SampleMux.SampleBuffers(ts)) !void {
            // Wait for update buffers
            _buffers.* = try sm.get(ts);
            // Signal done
            done.set();
        }
    };

    // Spawn a thread that blocks until sample buffers are available
    var buffers: SampleMux.SampleBuffers(ts) = undefined;
    var done_event = std.Thread.ResetEvent{};
    var thread = try std.Thread.spawn(.{}, BufferWaiter.run, .{ &sample_mux, &done_event, &buffers });

    // Check thread is blocking
    try std.testing.expectError(error.Timeout, done_event.timedWait(std.time.ns_per_ms));

    // Load 2 samples into input 2 ring buffer
    input2_writer.write(&[_]u8{ 0xdd, 0xee });

    // Check buffer waiter completed
    try done_event.timedWait(std.time.ns_per_ms);
    try std.testing.expectEqual(true, done_event.isSet());
    thread.join();

    // Verify lengths and input samples
    try std.testing.expectEqual(@as(usize, 2), buffers.inputs.len);
    try std.testing.expectEqual(@as(usize, 2), buffers.outputs.len);
    try std.testing.expectEqual(@as(usize, 2), buffers.inputs[0].len);
    try std.testing.expectEqual(@as(usize, 2), buffers.inputs[1].len);
    try std.testing.expectEqual(@as(u16, 0xaaaa), buffers.inputs[0][0]);
    try std.testing.expectEqual(@as(u16, 0xbbbb), buffers.inputs[0][1]);
    try std.testing.expectEqual(@as(u16, 0xdd), buffers.inputs[1][0]);
    try std.testing.expectEqual(@as(u16, 0xee), buffers.inputs[1][1]);

    // Update sample mux
    sample_mux.update(ts, buffers, ProcessResult.init(&[2]usize{ 1, 2 }, &[2]usize{ 2, 3 }));

    // Verify ring buffer state
    try std.testing.expectEqual(@as(usize, 4), input1_ring_buffer.impl.getReadAvailable(0));
    try std.testing.expectEqual(@as(usize, 0), input2_ring_buffer.impl.getReadAvailable(0));
    try std.testing.expectEqual(@as(usize, 8), output1_ring_buffer.impl.getReadAvailable(0));
    try std.testing.expectEqual(@as(usize, 3), output2_ring_buffer.impl.getReadAvailable(0));
}

test "ThreadSafeRingBufferSampleMux blocking write" {
    // This test requires spawning threads
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    const ts = ComptimeTypeSignature.fromTypes(&[2]type{ u16, u8 }, &[2]type{ u32, u8 });

    // Create ring buffers
    var input1_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer input1_ring_buffer.deinit();
    var input2_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer input2_ring_buffer.deinit();
    var output1_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer output1_ring_buffer.deinit();
    var output2_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer output2_ring_buffer.deinit();

    // Get ring buffer reader/write interfaces
    var input1_writer = input1_ring_buffer.writer();
    var input2_writer = input2_ring_buffer.writer();
    _ = output1_ring_buffer.reader();
    var output2_reader = output2_ring_buffer.reader();
    var output2_writer = output2_ring_buffer.writer();

    // Create ring buffer sample mux
    var ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux.init(std.testing.allocator, &[2]*ThreadSafeRingBuffer{ &input1_ring_buffer, &input2_ring_buffer }, &[2]*ThreadSafeRingBuffer{ &output1_ring_buffer, &output2_ring_buffer });
    defer ring_buffer_sample_mux.deinit();
    var sample_mux = ring_buffer_sample_mux.sampleMux();

    // Load 3 samples into input 1 ring buffer
    input1_writer.write(&[_]u8{0xaa} ** 2);
    input1_writer.write(&[_]u8{0xbb} ** 2);
    input1_writer.write(&[_]u8{0xcc} ** 2);

    // Load 3 samples into input 2 ring buffer
    input2_writer.write(&[_]u8{0xdd} ** 1);
    input2_writer.write(&[_]u8{0xee} ** 1);
    input2_writer.write(&[_]u8{0xff} ** 1);

    // Prewrite output 2 ring buffer to saturate it, leaving no samples available
    output2_writer.write(&[_]u8{0x11} ** (std.heap.page_size_min - 1));
    try std.testing.expectEqual(@as(usize, 0), output2_writer.getAvailable());

    // Verify sample mux wait times out
    try std.testing.expectError(error.Timeout, sample_mux.wait(ts, 0));
    try std.testing.expectError(error.Timeout, sample_mux.wait(ts, std.time.ns_per_ms));

    const BufferWaiter = struct {
        fn run(sm: *SampleMux, done: *std.Thread.ResetEvent, _buffers: *SampleMux.SampleBuffers(ts)) !void {
            // Wait for update buffers
            _buffers.* = try sm.get(ts);
            // Signal done
            done.set();
        }
    };

    // Spawn a thread that blocks until sample buffers are available
    var buffers: SampleMux.SampleBuffers(ts) = undefined;
    var done_event = std.Thread.ResetEvent{};
    var thread = try std.Thread.spawn(.{}, BufferWaiter.run, .{ &sample_mux, &done_event, &buffers });

    // Check thread is blocking
    try std.testing.expectError(error.Timeout, done_event.timedWait(std.time.ns_per_ms));

    // Consume 3 samples from output 2 ring buffer
    output2_reader.update(3);

    // Check buffer waiter completed
    try done_event.timedWait(std.time.ns_per_ms);
    try std.testing.expectEqual(true, done_event.isSet());
    thread.join();

    // Verify lengths and input samples
    try std.testing.expectEqual(@as(usize, 2), buffers.inputs.len);
    try std.testing.expectEqual(@as(usize, 2), buffers.outputs.len);
    try std.testing.expectEqual(@as(usize, 3), buffers.inputs[0].len);
    try std.testing.expectEqual(@as(usize, 3), buffers.inputs[1].len);
    try std.testing.expectEqual(@as(u16, 0xaaaa), buffers.inputs[0][0]);
    try std.testing.expectEqual(@as(u16, 0xbbbb), buffers.inputs[0][1]);
    try std.testing.expectEqual(@as(u16, 0xcccc), buffers.inputs[0][2]);
    try std.testing.expectEqual(@as(u16, 0xdd), buffers.inputs[1][0]);
    try std.testing.expectEqual(@as(u16, 0xee), buffers.inputs[1][1]);
    try std.testing.expectEqual(@as(u16, 0xff), buffers.inputs[1][2]);

    // Update sample mux
    sample_mux.update(ts, buffers, ProcessResult.init(&[2]usize{ 1, 2 }, &[2]usize{ 2, 3 }));

    // Verify ring buffer state
    try std.testing.expectEqual(@as(usize, 4), input1_ring_buffer.impl.getReadAvailable(0));
    try std.testing.expectEqual(@as(usize, 1), input2_ring_buffer.impl.getReadAvailable(0));
    try std.testing.expectEqual(@as(usize, 8), output1_ring_buffer.impl.getReadAvailable(0));
    try std.testing.expectEqual(@as(usize, std.heap.page_size_min - 1), output2_ring_buffer.impl.getReadAvailable(0));
}

const Foo = struct {
    valid: bool,

    pub fn init() Foo {
        return .{ .valid = true };
    }

    pub fn deinit(self: *Foo) void {
        self.valid = false;
    }

    pub fn typeName() []const u8 {
        return "Foo";
    }
};

test "RefCounted output with no readers" {
    const ts = ComptimeTypeSignature.fromTypes(&[0]type{}, &[1]type{RefCounted(Foo)});

    // Create ring buffers
    var output_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer output_ring_buffer.deinit();

    // Create ring buffer sample mux
    var ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux.init(std.testing.allocator, &[0]*ThreadSafeRingBuffer{}, &[1]*ThreadSafeRingBuffer{&output_ring_buffer});
    defer ring_buffer_sample_mux.deinit();
    var sample_mux = ring_buffer_sample_mux.sampleMux();

    // Get sample buffers
    var buffers = try sample_mux.get(ts);

    // Create two samples
    buffers.outputs[0][0] = RefCounted(Foo).init(.{});
    buffers.outputs[0][1] = RefCounted(Foo).init(.{});

    // Verify valid
    try std.testing.expectEqual(1, buffers.outputs[0][0].rc.load(.seq_cst));
    try std.testing.expectEqual(1, buffers.outputs[0][1].rc.load(.seq_cst));
    try std.testing.expectEqual(true, buffers.outputs[0][0].value.valid);
    try std.testing.expectEqual(true, buffers.outputs[0][1].value.valid);

    // Update sample mux
    sample_mux.update(ts, buffers, ProcessResult.init(&[0]usize{}, &[1]usize{2}));

    // Verify samples are deinited
    try std.testing.expectEqual(0, buffers.outputs[0][0].rc.load(.seq_cst));
    try std.testing.expectEqual(0, buffers.outputs[0][1].rc.load(.seq_cst));
    try std.testing.expectEqual(false, buffers.outputs[0][0].value.valid);
    try std.testing.expectEqual(false, buffers.outputs[0][1].value.valid);
}

test "RefCounted output with one reader" {
    const ts = ComptimeTypeSignature.fromTypes(&[0]type{}, &[1]type{RefCounted(Foo)});

    // Create ring buffers
    var output_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer output_ring_buffer.deinit();

    // Create reader
    _ = output_ring_buffer.reader();

    // Create ring buffer sample mux
    var ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux.init(std.testing.allocator, &[0]*ThreadSafeRingBuffer{}, &[1]*ThreadSafeRingBuffer{&output_ring_buffer});
    defer ring_buffer_sample_mux.deinit();
    var sample_mux = ring_buffer_sample_mux.sampleMux();

    // Get sample buffers
    var buffers = try sample_mux.get(ts);

    // Create two samples
    buffers.outputs[0][0] = RefCounted(Foo).init(.{});
    buffers.outputs[0][1] = RefCounted(Foo).init(.{});

    // Update sample mux
    sample_mux.update(ts, buffers, ProcessResult.init(&[0]usize{}, &[1]usize{2}));

    // Verify samples are still valid
    try std.testing.expectEqual(1, buffers.outputs[0][0].rc.load(.seq_cst));
    try std.testing.expectEqual(1, buffers.outputs[0][1].rc.load(.seq_cst));
    try std.testing.expectEqual(true, buffers.outputs[0][0].value.valid);
    try std.testing.expectEqual(true, buffers.outputs[0][1].value.valid);
}

test "RefCounted output with two readers" {
    const ts = ComptimeTypeSignature.fromTypes(&[0]type{}, &[1]type{RefCounted(Foo)});

    // Create ring buffers
    var output_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer output_ring_buffer.deinit();

    // Create two readers
    _ = output_ring_buffer.reader();
    _ = output_ring_buffer.reader();

    // Create ring buffer sample mux
    var ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux.init(std.testing.allocator, &[0]*ThreadSafeRingBuffer{}, &[1]*ThreadSafeRingBuffer{&output_ring_buffer});
    defer ring_buffer_sample_mux.deinit();
    var sample_mux = ring_buffer_sample_mux.sampleMux();

    // Get sample buffers
    var buffers = try sample_mux.get(ts);

    // Create two samples
    buffers.outputs[0][0] = RefCounted(Foo).init(.{});
    buffers.outputs[0][1] = RefCounted(Foo).init(.{});

    // Update sample mux
    sample_mux.update(ts, buffers, ProcessResult.init(&[0]usize{}, &[1]usize{2}));

    // Verify samples are still valid with incremented ref count
    try std.testing.expectEqual(2, buffers.outputs[0][0].rc.load(.seq_cst));
    try std.testing.expectEqual(2, buffers.outputs[0][1].rc.load(.seq_cst));
    try std.testing.expectEqual(true, buffers.outputs[0][0].value.valid);
    try std.testing.expectEqual(true, buffers.outputs[0][1].value.valid);
}

test "RefCounted input" {
    const ts = ComptimeTypeSignature.fromTypes(&[1]type{RefCounted(Foo)}, &[0]type{});

    // Create ring buffers
    var input_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.heap.page_size_min);
    defer input_ring_buffer.deinit();

    // Create one writer
    var writer = input_ring_buffer.writer();

    // Create ring buffer sample mux
    var ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux.init(std.testing.allocator, &[1]*ThreadSafeRingBuffer{&input_ring_buffer}, &[0]*ThreadSafeRingBuffer{});
    defer ring_buffer_sample_mux.deinit();
    var sample_mux = ring_buffer_sample_mux.sampleMux();

    // Write two samples of RefCounted(Foo)
    var buf = writer.getBuffer();
    var slice: []RefCounted(Foo) = @alignCast(std.mem.bytesAsSlice(RefCounted(Foo), buf[0..std.mem.alignBackward(usize, buf.len, @sizeOf(RefCounted(Foo)))]));
    slice[0] = RefCounted(Foo).init(.{});
    slice[1] = RefCounted(Foo).init(.{});
    writer.update(2 * @sizeOf(RefCounted(Foo)));

    // Get sample buffers
    var buffers = try sample_mux.get(ts);

    // Verify samples
    try std.testing.expectEqual(1, buffers.inputs[0][0].rc.load(.seq_cst));
    try std.testing.expectEqual(1, buffers.inputs[0][1].rc.load(.seq_cst));
    try std.testing.expectEqual(true, buffers.inputs[0][0].value.valid);
    try std.testing.expectEqual(true, buffers.inputs[0][1].value.valid);

    // Update sample mux
    sample_mux.update(ts, buffers, ProcessResult.init(&[1]usize{2}, &[0]usize{}));

    // Verify samples are deinited
    try std.testing.expectEqual(0, buffers.inputs[0][0].rc.load(.seq_cst));
    try std.testing.expectEqual(0, buffers.inputs[0][1].rc.load(.seq_cst));
    try std.testing.expectEqual(false, buffers.inputs[0][0].value.valid);
    try std.testing.expectEqual(false, buffers.inputs[0][1].value.valid);
}
