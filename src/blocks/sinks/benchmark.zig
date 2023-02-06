const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

////////////////////////////////////////////////////////////////////////////////
// Benchmark Sink
////////////////////////////////////////////////////////////////////////////////

pub fn BenchmarkSink(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Options = struct {
            title: []const u8 = "BenchmarkSink",
            report_period_ms: usize = 3000,
        };

        block: Block,
        options: Options,
        count: usize = 0,
        tic_ms: u64 = 0,

        pub fn init(options: Options) Self {
            return .{ .block = Block.init(@This()), .options = options };
        }

        pub fn initialize(self: *Self, _: std.mem.Allocator) !void {
            self.count = 0;
            self.tic_ms = @intCast(u64, std.time.milliTimestamp());
        }

        fn normalize(amount: f32) std.meta.Tuple(&[2]type{ f32, []const u8 }) {
            if (amount > 1e9) {
                return .{ amount / 1e9, "G" };
            } else if (amount > 1e6) {
                return .{ amount / 1e6, "M" };
            } else if (amount > 1e3) {
                return .{ amount / 1e3, "K" };
            } else {
                return .{ amount, "" };
            }
        }

        pub fn process(self: *Self, x: []const T) !ProcessResult {
            self.count += x.len;

            const toc_ms = @intCast(u64, std.time.milliTimestamp());

            if (toc_ms - self.tic_ms > self.options.report_period_ms) {
                // Compute rate
                const sps = @intToFloat(f32, 1000 * self.count) / @intToFloat(f32, toc_ms - self.tic_ms);
                const bps = sps * @sizeOf(T);

                // Normalize rates with unit prefix
                const normalized_sps = normalize(sps);
                const normalized_bps = normalize(bps);

                // Print report string
                std.debug.print("[{s}] {d:.2} {s}S/s ({d:.2} {s}B/s)\n", .{ self.options.title, normalized_sps[0], normalized_sps[1], normalized_bps[0], normalized_bps[1] });

                // Reset tic and count
                self.tic_ms = toc_ms;
                self.count = 0;
            }

            return ProcessResult.init(&[1]usize{x.len}, &[0]usize{});
        }
    };
}
