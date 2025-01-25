const std = @import("std");

const util = @import("util.zig");
const ComptimeTypeSignature = @import("type_signature.zig").ComptimeTypeSignature;
const ProcessResult = @import("block.zig").ProcessResult;

const ThreadSafeRingBuffer = @import("ring_buffer.zig").ThreadSafeRingBuffer;

////////////////////////////////////////////////////////////////////////////////
// SampleMux
////////////////////////////////////////////////////////////////////////////////

pub const SampleMux = struct {
    ptr: *anyopaque,
    waitAvailableFn: *const fn (ptr: *anyopaque, input_element_sizes: []const usize, output_element_sizes: []const usize) error{EndOfFile}!usize,
    getInputBufferFn: *const fn (ptr: *anyopaque, index: usize) []const u8,
    getOutputBufferFn: *const fn (ptr: *anyopaque, index: usize) []u8,
    updateInputBufferFn: *const fn (ptr: *anyopaque, index: usize, count: usize) void,
    updateOutputBufferFn: *const fn (ptr: *anyopaque, index: usize, count: usize) void,
    setEOFFn: *const fn (ptr: *anyopaque) void,

    pub fn init(
        pointer: anytype,
        comptime waitAvailableFn: fn (ptr: @TypeOf(pointer), input_element_sizes: []const usize, output_element_sizes: []const usize) error{EndOfFile}!usize,
        comptime getInputBufferFn: fn (ptr: @TypeOf(pointer), index: usize) []const u8,
        comptime getOutputBufferFn: fn (ptr: @TypeOf(pointer), index: usize) []u8,
        comptime updateInputBufferFn: fn (ptr: @TypeOf(pointer), index: usize, count: usize) void,
        comptime updateOutputBufferFn: fn (ptr: @TypeOf(pointer), index: usize, count: usize) void,
        comptime setEOFFn: fn (ptr: @TypeOf(pointer)) void,
    ) SampleMux {
        const Ptr = @TypeOf(pointer);
        std.debug.assert(@typeInfo(Ptr) == .Pointer); // Must be a pointer
        std.debug.assert(@typeInfo(Ptr).Pointer.size == .One); // Must be a single-item pointer
        std.debug.assert(@typeInfo(@typeInfo(Ptr).Pointer.child) == .Struct); // Must point to a struct

        const gen = struct {
            fn waitAvailable(ptr: *anyopaque, input_element_sizes: []const usize, output_element_sizes: []const usize) error{EndOfFile}!usize {
                const self: Ptr = @ptrCast(@alignCast(ptr));
                return try waitAvailableFn(self, input_element_sizes, output_element_sizes);
            }

            fn getInputBuffer(ptr: *anyopaque, index: usize) []const u8 {
                const self: Ptr = @ptrCast(@alignCast(ptr));
                return getInputBufferFn(self, index);
            }

            fn getOutputBuffer(ptr: *anyopaque, index: usize) []u8 {
                const self: Ptr = @ptrCast(@alignCast(ptr));
                return getOutputBufferFn(self, index);
            }

            fn updateInputBuffer(ptr: *anyopaque, index: usize, count: usize) void {
                const self: Ptr = @ptrCast(@alignCast(ptr));
                updateInputBufferFn(self, index, count);
            }

            fn updateOutputBuffer(ptr: *anyopaque, index: usize, count: usize) void {
                const self: Ptr = @ptrCast(@alignCast(ptr));
                updateOutputBufferFn(self, index, count);
            }

            fn setEOF(ptr: *anyopaque) void {
                const self: Ptr = @ptrCast(@alignCast(ptr));
                setEOFFn(self);
            }
        };

        return .{
            .ptr = pointer,
            .waitAvailableFn = gen.waitAvailable,
            .getInputBufferFn = gen.getInputBuffer,
            .getOutputBufferFn = gen.getOutputBuffer,
            .updateInputBufferFn = gen.updateInputBuffer,
            .updateOutputBufferFn = gen.updateOutputBuffer,
            .setEOFFn = gen.setEOF,
        };
    }

    ////////////////////////////////////////////////////////////////////////////
    // Sample Buffers API
    ////////////////////////////////////////////////////////////////////////////

    pub fn SampleBuffers(comptime type_signature: ComptimeTypeSignature) type {
        return struct {
            inputs: util.makeTupleConstSliceTypes(type_signature.inputs),
            outputs: util.makeTupleSliceTypes(type_signature.outputs),
        };
    }

    pub fn get(self: *SampleMux, comptime type_signature: ComptimeTypeSignature) error{EndOfFile}!SampleBuffers(type_signature) {
        // Wait for sufficient number of samples
        const min_samples_available = try self.waitAvailableFn(self.ptr, comptime util.dataTypeSizes(type_signature.inputs), comptime util.dataTypeSizes(type_signature.outputs));

        // Get sample buffers
        var sample_buffers: SampleBuffers(type_signature) = undefined;
        inline for (type_signature.inputs, 0..) |input_type, i| {
            const buffer = self.getInputBufferFn(self.ptr, i);
            sample_buffers.inputs[i] = @alignCast(std.mem.bytesAsSlice(input_type, buffer[0 .. min_samples_available * @sizeOf(type_signature.inputs[i])]));
        }
        inline for (type_signature.outputs, 0..) |output_type, i| {
            const buffer = self.getOutputBufferFn(self.ptr, i);
            sample_buffers.outputs[i] = @alignCast(std.mem.bytesAsSlice(output_type, buffer[0..std.mem.alignBackward(usize, buffer.len, @sizeOf(type_signature.outputs[i]))]));
        }

        // Return typed input and output buffers
        return sample_buffers;
    }

    pub fn update(self: *SampleMux, comptime type_signature: ComptimeTypeSignature, process_result: ProcessResult) void {
        // Update sample buffers
        inline for (type_signature.inputs, 0..) |_, i| {
            self.updateInputBufferFn(self.ptr, i, process_result.samples_consumed[i] * @sizeOf(type_signature.inputs[i]));
        }
        inline for (type_signature.outputs, 0..) |_, i| {
            self.updateOutputBufferFn(self.ptr, i, process_result.samples_produced[i] * @sizeOf(type_signature.outputs[i]));
        }
    }

    pub fn setEOF(self: *SampleMux) void {
        self.setEOFFn(self.ptr);
    }
};

////////////////////////////////////////////////////////////////////////////////
// ThreadSafeRingBufferSampleMux
////////////////////////////////////////////////////////////////////////////////

pub fn ThreadSafeRingBufferSampleMux(comptime RingBuffer: type) type {
    return struct {
        const Self = @This();

        readers: std.ArrayList(RingBuffer.Reader),
        writers: std.ArrayList(RingBuffer.Writer),

        pub fn init(allocator: std.mem.Allocator, inputs: []const *ThreadSafeRingBuffer, outputs: []const *ThreadSafeRingBuffer) !Self {
            var readers = std.ArrayList(RingBuffer.Reader).init(allocator);
            for (inputs) |ring_buffer| try readers.append(ring_buffer.reader());

            var writers = std.ArrayList(RingBuffer.Writer).init(allocator);
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

        pub fn waitAvailable(self: *Self, input_element_sizes: []const usize, output_element_sizes: []const usize) error{EndOfFile}!usize {
            // Sanity checks
            std.debug.assert(input_element_sizes.len == self.readers.items.len);
            std.debug.assert(output_element_sizes.len == self.writers.items.len);

            var input_samples_available: [8]usize = undefined;
            var output_samples_available: [8]usize = undefined;
            var min_samples_available: usize = 0;

            while (min_samples_available == 0) {
                // Get input and output samples available across all inputs and outputs
                for (self.readers.items, 0..) |*reader, i| {
                    input_samples_available[i] = try reader.getAvailable() / input_element_sizes[i];
                }
                for (self.writers.items, 0..) |*writer, i| {
                    output_samples_available[i] = writer.getAvailable() / output_element_sizes[i];
                }

                // Compute minimum input and output samples available
                const min_input_samples_index = if (input_element_sizes.len != 0) std.mem.indexOfMin(usize, input_samples_available[0..input_element_sizes.len]) else 0;
                const min_output_samples_index = if (output_element_sizes.len != 0) std.mem.indexOfMin(usize, output_samples_available[0..output_element_sizes.len]) else 0;
                const min_input_samples = if (input_element_sizes.len != 0) input_samples_available[min_input_samples_index] else null;
                const min_output_samples = if (output_element_sizes.len != 0) output_samples_available[min_output_samples_index] else null;

                if (min_input_samples != null and min_input_samples.? == 0) {
                    // No input samples available for at least one input
                    try self.readers.items[min_input_samples_index].wait(input_element_sizes[min_input_samples_index]);
                } else if (min_input_samples != null and min_output_samples != null and min_output_samples.? < min_input_samples.?) {
                    // Insufficient output samples available for at least one output
                    self.writers.items[min_output_samples_index].wait(min_input_samples.? * output_element_sizes[min_output_samples_index]);
                } else if (min_output_samples != null and min_output_samples.? == 0) {
                    // No output samples available for at least one output
                    self.writers.items[min_output_samples_index].wait(output_element_sizes[min_output_samples_index]);
                } else {
                    min_samples_available = min_input_samples orelse min_output_samples orelse unreachable;
                }
            }

            return min_samples_available;
        }

        pub fn getInputBuffer(self: *Self, index: usize) []const u8 {
            std.debug.assert(index < self.readers.items.len);
            return self.readers.items[index].getBuffer();
        }

        pub fn getOutputBuffer(self: *Self, index: usize) []u8 {
            std.debug.assert(index < self.writers.items.len);
            return self.writers.items[index].getBuffer();
        }

        pub fn updateInputBuffer(self: *Self, index: usize, count: usize) void {
            std.debug.assert(index < self.readers.items.len);
            self.readers.items[index].update(count);
        }

        pub fn updateOutputBuffer(self: *Self, index: usize, count: usize) void {
            std.debug.assert(index < self.writers.items.len);
            self.writers.items[index].update(count);
        }

        pub fn setEOF(self: *Self) void {
            for (self.writers.items) |*writer| {
                writer.setEOF();
            }
        }

        pub fn sampleMux(self: *Self) SampleMux {
            return SampleMux.init(self, waitAvailable, getInputBuffer, getOutputBuffer, updateInputBuffer, updateOutputBuffer, setEOF);
        }
    };
}

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
        eof: bool = false,

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

        pub fn waitAvailable(self: *Self, input_element_sizes: []const usize, output_element_sizes: []const usize) error{EndOfFile}!usize {
            if (self.eof) {
                return error.EndOfFile;
            }

            var input_samples_available: [input_data_types.len]usize = undefined;
            var output_samples_available: [output_data_types.len]usize = undefined;

            for (self.input_buffer_indices, 0..) |_, i| {
                if (self.input_buffer_indices[i] == self.input_buffers[i].len) {
                    return error.EndOfFile;
                } else if (self.options.single_input_samples) {
                    input_samples_available[i] = @min(1, (self.input_buffers[i].len - self.input_buffer_indices[i]) / input_element_sizes[i]);
                } else {
                    input_samples_available[i] = (self.input_buffers[i].len - self.input_buffer_indices[i]) / input_element_sizes[i];
                }
            }

            for (self.output_buffer_indices, 0..) |_, i| {
                if (self.options.single_output_samples) {
                    output_samples_available[i] = @min(1, (self.output_buffers[i].len - self.output_buffer_indices[i]) / output_element_sizes[i]);
                } else {
                    output_samples_available[i] = (self.output_buffers[i].len - self.output_buffer_indices[i]) / output_element_sizes[i];
                }
            }

            return if (input_data_types.len != 0) std.mem.min(usize, input_samples_available[0..]) else std.mem.min(usize, output_samples_available[0..]);
        }

        pub fn getInputBuffer(self: *Self, index: usize) []const u8 {
            if (input_data_types.len == 0) return &.{};

            if (self.options.single_input_samples) {
                const input_element_sizes = comptime util.dataTypeSizes(input_data_types);
                return self.input_buffers[index][self.input_buffer_indices[index] .. self.input_buffer_indices[index] + input_element_sizes[index]];
            } else {
                return self.input_buffers[index][self.input_buffer_indices[index]..];
            }
        }

        pub fn getOutputBuffer(self: *Self, index: usize) []u8 {
            if (output_data_types.len == 0) return &.{};

            if (self.options.single_output_samples) {
                const output_element_sizes = comptime util.dataTypeSizes(output_data_types);
                return self.output_buffers[index][self.output_buffer_indices[index] .. self.output_buffer_indices[index] + output_element_sizes[index]];
            } else {
                return self.output_buffers[index][self.output_buffer_indices[index]..];
            }
        }

        pub fn updateInputBuffer(self: *Self, index: usize, count: usize) void {
            if (input_data_types.len == 0) return;
            self.input_buffer_indices[index] += count;
        }

        pub fn updateOutputBuffer(self: *Self, index: usize, count: usize) void {
            if (output_data_types.len == 0) return;
            self.output_buffer_indices[index] += count;
        }

        pub fn setEOF(self: *Self) void {
            self.eof = true;
        }

        pub fn sampleMux(self: *Self) SampleMux {
            return SampleMux.init(self, waitAvailable, getInputBuffer, getOutputBuffer, updateInputBuffer, updateOutputBuffer, setEOF);
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

    sample_mux.update(ts, ProcessResult.init(&[2]usize{ 1, 1 }, &[1]usize{4}));

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

    sample_mux.update(ts, ProcessResult.init(&[2]usize{ 1, 0 }, &[1]usize{4}));

    try std.testing.expectEqualSlices(u16, &[_]u16{ 0x99aa, 0xbbcc, 0xddee, 0xff00 }, test_sample_mux.getOutputVector(u16, 0)[4..]);

    try std.testing.expectError(error.EndOfFile, sample_mux.get(ts));
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

    sample_mux.update(ts, ProcessResult.init(&[2]usize{ 1, 1 }, &[1]usize{0}));

    buffers = try sample_mux.get(ts);

    try std.testing.expectEqual(@as(usize, 2), buffers.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), buffers.inputs[0].len);
    try std.testing.expectEqual(@as(usize, 1), buffers.inputs[1].len);
    try std.testing.expectEqual(@as(usize, 1), buffers.outputs.len);
    try std.testing.expect(buffers.outputs[0].len > 4);

    try std.testing.expectEqual(std.mem.bigToNative(u32, 0xabcdeeff), buffers.inputs[0][0]);
    try std.testing.expectEqual(std.mem.bigToNative(u32, 0x55667788), buffers.inputs[1][0]);

    sample_mux.update(ts, ProcessResult.init(&[2]usize{ 1, 1 }, &[1]usize{0}));

    try std.testing.expectError(error.EndOfFile, sample_mux.get(ts));
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

    sample_mux.update(ts, ProcessResult.init(&[0]usize{}, &[1]usize{1}));

    buffers = try sample_mux.get(ts);

    try std.testing.expectEqual(@as(usize, 0), buffers.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), buffers.outputs.len);
    try std.testing.expect(buffers.outputs[0].len == 1);
}

test "TestSampleMux eof" {
    const ibuf1: [8]u8 = .{ 0xaa, 0xbb, 0xcc, 0xdd, 0xab, 0xcd, 0xee, 0xff };
    const ibuf2: [8]u8 = .{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };

    const ts = ComptimeTypeSignature.fromTypes(&[2]type{ u32, u32 }, &[1]type{u16});

    var test_sample_mux = try TestSampleMux(ts.inputs, ts.outputs).init([2][]const u8{ &ibuf1, &ibuf2 }, .{});
    defer test_sample_mux.deinit();

    var sample_mux = test_sample_mux.sampleMux();

    const buffers = try sample_mux.get(ts);

    try std.testing.expectEqual(@as(usize, 2), buffers.inputs.len);
    try std.testing.expectEqual(@as(usize, 2), buffers.inputs[0].len);
    try std.testing.expectEqual(@as(usize, 2), buffers.inputs[1].len);
    try std.testing.expectEqual(@as(usize, 1), buffers.outputs.len);
    try std.testing.expect(buffers.outputs[0].len > 4);

    sample_mux.update(ts, ProcessResult.init(&[2]usize{ 1, 1 }, &[1]usize{0}));

    sample_mux.setEOF();

    try std.testing.expectError(error.EndOfFile, sample_mux.get(ts));
}

test "ThreadSafeRingBufferSampleMux single input, single output" {
    const ts = ComptimeTypeSignature.fromTypes(&[1]type{u16}, &[1]type{u32});

    // Create ring buffers
    var input_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer input_ring_buffer.deinit();
    var output_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer output_ring_buffer.deinit();

    // Get ring buffer reader/write interfaces
    var input_writer = input_ring_buffer.writer();
    var output_reader = output_ring_buffer.reader();

    // Create ring buffer sample mux
    var ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux(ThreadSafeRingBuffer).init(std.testing.allocator, &[_]*ThreadSafeRingBuffer{&input_ring_buffer}, &[1]*ThreadSafeRingBuffer{&output_ring_buffer});
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
    sample_mux.update(ts, ProcessResult.init(&[1]usize{3}, &[1]usize{3}));

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
    sample_mux.update(ts, ProcessResult.init(&[1]usize{1}, &[1]usize{2}));

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
    sample_mux.update(ts, ProcessResult.init(&[1]usize{2}, &[1]usize{1}));

    // Verify ring buffer state
    try std.testing.expectEqual(@as(usize, 0), input_ring_buffer.impl.getReadAvailable(0));
    try std.testing.expectEqual(@as(usize, 4), output_ring_buffer.impl.getReadAvailable(0));

    // Verify written samples
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x33, 0x33, 0x33, 0x33 }, output_reader.read(b[0..]));
}

test "ThreadSafeRingBufferSampleMux multiple input, multiple output" {
    const ts = ComptimeTypeSignature.fromTypes(&[2]type{ u16, u8 }, &[2]type{ u32, u8 });

    // Create ring buffers
    var input1_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer input1_ring_buffer.deinit();
    var input2_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer input2_ring_buffer.deinit();
    var output1_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer output1_ring_buffer.deinit();
    var output2_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer output2_ring_buffer.deinit();

    // Get ring buffer reader/write interfaces
    var input1_writer = input1_ring_buffer.writer();
    var input2_writer = input2_ring_buffer.writer();
    var output1_reader = output1_ring_buffer.reader();
    var output2_reader = output2_ring_buffer.reader();

    // Create ring buffer sample mux
    var ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux(ThreadSafeRingBuffer).init(std.testing.allocator, &[2]*ThreadSafeRingBuffer{ &input1_ring_buffer, &input2_ring_buffer }, &[2]*ThreadSafeRingBuffer{ &output1_ring_buffer, &output2_ring_buffer });
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
    sample_mux.update(ts, ProcessResult.init(&[2]usize{ 1, 2 }, &[2]usize{ 2, 3 }));

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
    var input1_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer input1_ring_buffer.deinit();
    var input2_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer input2_ring_buffer.deinit();

    // Get ring buffer reader/write interfaces
    var input1_writer = input1_ring_buffer.writer();
    var input2_writer = input2_ring_buffer.writer();

    // Create ring buffer sample mux
    var ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux(ThreadSafeRingBuffer).init(std.testing.allocator, &[2]*ThreadSafeRingBuffer{ &input1_ring_buffer, &input2_ring_buffer }, &[0]*ThreadSafeRingBuffer{});
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
    sample_mux.update(ts, ProcessResult.init(&[2]usize{ 2, 3 }, &[0]usize{}));

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
    var output1_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer output1_ring_buffer.deinit();
    var output2_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer output2_ring_buffer.deinit();

    // Get ring buffer reader/write interfaces
    var output1_reader = output1_ring_buffer.reader();
    var output2_reader = output2_ring_buffer.reader();

    // Create ring buffer sample mux
    var ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux(ThreadSafeRingBuffer).init(std.testing.allocator, &[0]*ThreadSafeRingBuffer{}, &[2]*ThreadSafeRingBuffer{ &output1_ring_buffer, &output2_ring_buffer });
    defer ring_buffer_sample_mux.deinit();
    var sample_mux = ring_buffer_sample_mux.sampleMux();

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
    sample_mux.update(ts, ProcessResult.init(&[0]usize{}, &[2]usize{ 2, 3 }));

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

test "ThreadSafeRingBufferSampleMux read eof" {
    const ts = ComptimeTypeSignature.fromTypes(&[2]type{ u16, u8 }, &[1]type{u32});

    // Create ring buffers
    var input1_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer input1_ring_buffer.deinit();
    var input2_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer input2_ring_buffer.deinit();
    var output1_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer output1_ring_buffer.deinit();

    // Get ring buffer reader/write interfaces
    var input1_writer = input1_ring_buffer.writer();
    var input2_writer = input2_ring_buffer.writer();
    var output1_reader = output1_ring_buffer.reader();

    // Create ring buffer sample mux
    var ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux(ThreadSafeRingBuffer).init(std.testing.allocator, &[2]*ThreadSafeRingBuffer{ &input1_ring_buffer, &input2_ring_buffer }, &[1]*ThreadSafeRingBuffer{&output1_ring_buffer});
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
    sample_mux.update(ts, ProcessResult.init(&[2]usize{ 1, 1 }, &[1]usize{1}));

    // Verify ring buffer state
    try std.testing.expectEqual(@as(usize, 4), input1_ring_buffer.impl.getReadAvailable(0));
    try std.testing.expectEqual(@as(usize, 2), input2_ring_buffer.impl.getReadAvailable(0));
    try std.testing.expectEqual(@as(usize, 4), output1_ring_buffer.impl.getReadAvailable(0));

    // Verify written samples
    var b: [4]u8 = .{0x00} ** 4;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xaa, 0xaa, 0xaa, 0xaa }, output1_reader.read(b[0..]));

    // Set EOF on input 2
    input2_writer.setEOF();

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

    // Update sample mux to consume remaining sample
    sample_mux.update(ts, ProcessResult.init(&[2]usize{ 2, 2 }, &[1]usize{2}));

    // Get sample buffers should return EOF
    try std.testing.expectError(error.EndOfFile, sample_mux.get(ts));
}

test "ThreadSafeRingBufferSampleMux write eof" {
    const ts = ComptimeTypeSignature.fromTypes(&[1]type{u16}, &[1]type{u32});

    // Create ring buffers
    var input_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer input_ring_buffer.deinit();
    var output_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer output_ring_buffer.deinit();

    // Get ring buffer reader/write interfaces
    var input_writer = input_ring_buffer.writer();
    var output_reader = output_ring_buffer.reader();

    // Create ring buffer sample mux
    var ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux(ThreadSafeRingBuffer).init(std.testing.allocator, &[1]*ThreadSafeRingBuffer{&input_ring_buffer}, &[1]*ThreadSafeRingBuffer{&output_ring_buffer});
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
    sample_mux.update(ts, ProcessResult.init(&[1]usize{3}, &[1]usize{3}));

    // Set write EOF
    sample_mux.setEOF();

    // Verify ring buffer state
    try std.testing.expectEqual(@as(usize, 0), input_ring_buffer.impl.getReadAvailable(0));
    try std.testing.expectEqual(@as(usize, 12), output_ring_buffer.impl.getReadAvailable(0));

    // Verify written samples
    var b: [4]u8 = .{0x00} ** 4;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xaa, 0xaa, 0xaa, 0xaa }, output_reader.read(b[0..]));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xbb, 0xbb, 0xbb, 0xbb }, output_reader.read(b[0..]));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xcc, 0xcc, 0xcc, 0xcc }, output_reader.read(b[0..]));

    // Verify output reader now gets EOF
    try std.testing.expectError(error.EndOfFile, output_reader.getAvailable());
}

test "ThreadSafeRingBufferSampleMux blocking read" {
    // This test requires spawning threads
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    const ts = ComptimeTypeSignature.fromTypes(&[2]type{ u16, u8 }, &[2]type{ u32, u8 });

    // Create ring buffers
    var input1_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer input1_ring_buffer.deinit();
    var input2_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer input2_ring_buffer.deinit();
    var output1_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer output1_ring_buffer.deinit();
    var output2_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer output2_ring_buffer.deinit();

    // Get ring buffer reader/write interfaces
    var input1_writer = input1_ring_buffer.writer();
    var input2_writer = input2_ring_buffer.writer();

    // Create ring buffer sample mux
    var ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux(ThreadSafeRingBuffer).init(std.testing.allocator, &[2]*ThreadSafeRingBuffer{ &input1_ring_buffer, &input2_ring_buffer }, &[2]*ThreadSafeRingBuffer{ &output1_ring_buffer, &output2_ring_buffer });
    defer ring_buffer_sample_mux.deinit();
    var sample_mux = ring_buffer_sample_mux.sampleMux();

    // Load 3 samples into input 1 ring buffer
    input1_writer.write(&[_]u8{0xaa} ** 2);
    input1_writer.write(&[_]u8{0xbb} ** 2);
    input1_writer.write(&[_]u8{0xcc} ** 2);

    // Leave input 2 ring buffer empty

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
    sample_mux.update(ts, ProcessResult.init(&[2]usize{ 1, 2 }, &[2]usize{ 2, 3 }));

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
    var input1_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer input1_ring_buffer.deinit();
    var input2_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer input2_ring_buffer.deinit();
    var output1_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer output1_ring_buffer.deinit();
    var output2_ring_buffer = try ThreadSafeRingBuffer.init(std.testing.allocator, std.mem.page_size);
    defer output2_ring_buffer.deinit();

    // Get ring buffer reader/write interfaces
    var input1_writer = input1_ring_buffer.writer();
    var input2_writer = input2_ring_buffer.writer();
    var output2_reader = output2_ring_buffer.reader();
    var output2_writer = output2_ring_buffer.writer();

    // Create ring buffer sample mux
    var ring_buffer_sample_mux = try ThreadSafeRingBufferSampleMux(ThreadSafeRingBuffer).init(std.testing.allocator, &[2]*ThreadSafeRingBuffer{ &input1_ring_buffer, &input2_ring_buffer }, &[2]*ThreadSafeRingBuffer{ &output1_ring_buffer, &output2_ring_buffer });
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

    // Prewrite output 2 ring buffer to saturate it, leaving 2 samples available
    output2_writer.write(&[_]u8{0x11} ** (std.mem.page_size - 3));
    try std.testing.expectEqual(@as(usize, 2), output2_writer.getAvailable());

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

    // Consume 1 sample from output 2 ring buffer
    output2_reader.update(1);

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
    sample_mux.update(ts, ProcessResult.init(&[2]usize{ 1, 2 }, &[2]usize{ 2, 3 }));

    // Verify ring buffer state
    try std.testing.expectEqual(@as(usize, 4), input1_ring_buffer.impl.getReadAvailable(0));
    try std.testing.expectEqual(@as(usize, 1), input2_ring_buffer.impl.getReadAvailable(0));
    try std.testing.expectEqual(@as(usize, 8), output1_ring_buffer.impl.getReadAvailable(0));
    try std.testing.expectEqual(@as(usize, std.mem.page_size - 1), output2_ring_buffer.impl.getReadAvailable(0));
}
