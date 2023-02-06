const std = @import("std");

const Block = @import("../../radio.zig").Block;
const ProcessResult = @import("../../radio.zig").ProcessResult;

const zero = @import("../../radio.zig").utils.math.zero;
const sub = @import("../../radio.zig").utils.math.sub;
const scalarDiv = @import("../../radio.zig").utils.math.scalarDiv;
const innerProduct = @import("../../radio.zig").utils.math.innerProduct;

////////////////////////////////////////////////////////////////////////////////
// IIR Filter Block
////////////////////////////////////////////////////////////////////////////////

pub fn _IIRFilterBlock(comptime T: type, comptime N: comptime_int, comptime M: comptime_int, comptime Context: type) type {
    if (M < 1) {
        @compileLog("Feedback taps length must be at least 1");
    }

    return struct {
        const Self = @This();

        block: Block,
        context: Context,
        b_taps: [N]f32 = [_]f32{0} ** N,
        a_taps: [M]f32 = [_]f32{0} ** M,
        input_state: [N]T = [_]T{zero(T)} ** N,
        output_state: [M - 1]T = [_]T{zero(T)} ** (M - 1),

        pub fn init(context: Context) Self {
            return .{ .block = Block.init(@This()), .context = context };
        }

        pub fn initialize(self: *Self, allocator: std.mem.Allocator) !void {
            for (self.input_state) |*e| e.* = zero(T);
            for (self.output_state) |*e| e.* = zero(T);

            if (Context != void) {
                return Context.initialize(self, allocator);
            }
        }

        pub fn process(self: *Self, x: []const T, y: []T) !ProcessResult {
            for (x) |_, i| {
                // Shift the input state samples down
                for (self.input_state[1..]) |_, j| self.input_state[N - 1 - j] = self.input_state[N - 2 - j];
                // Insert input sample into input state
                self.input_state[0] = x[i];

                // y[n] = (b[0]*x[n] + b[1]*x[n-1] + b[2]*x[n-2] + ...  - a[1]*y[n-1] - a[2]*y[n-2] - ...) / a[0]
                y[i] = scalarDiv(T, sub(T, innerProduct(T, &self.input_state, &self.b_taps), innerProduct(T, &self.output_state, self.a_taps[1..])), self.a_taps[0]);

                // Shift the output state samples down
                for (self.output_state[1..]) |_, j| self.output_state[M - 2 - j] = self.output_state[M - 3 - j];
                // Insert output sample into output state
                self.output_state[0] = y[i];
            }

            return ProcessResult.init(&[1]usize{x.len}, &[1]usize{x.len});
        }
    };
}

pub fn IIRFilterBlock(comptime T: type, comptime N: comptime_int, comptime M: comptime_int) type {
    return struct {
        pub fn init(b_taps: [N]f32, a_taps: [M]f32) _IIRFilterBlock(T, N, M, void) {
            var block = _IIRFilterBlock(T, N, M, void).init(void{});
            std.mem.copy(f32, &block.b_taps, &b_taps);
            std.mem.copy(f32, &block.a_taps, &a_taps);
            return block;
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const BlockTester = @import("radio").testing.BlockTester;

test "IIRFilterBlock" {
    // 3 feedforward taps, 3 feedback taps, ComplexFloat32
    {
        var block = IIRFilterBlock(std.math.Complex(f32), 3, 3).init([3]f32{ 0.29289323, 0.58578646, 0.29289323 }, [3]f32{ 1.00000000, -0.00000000, 0.17157288 });
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2, &[1]type{
            std.math.Complex(f32),
        }, .{&[64]std.math.Complex(f32){ .{ .re = -0.73127151, .im = 0.69486749 }, .{ .re = 0.52754927, .im = -0.48986191 }, .{ .re = -0.00912983, .im = -0.10101787 }, .{ .re = 0.30318594, .im = 0.57744670 }, .{ .re = -0.81228077, .im = -0.94330502 }, .{ .re = 0.67153019, .im = -0.13446586 }, .{ .re = 0.52456015, .im = -0.99578792 }, .{ .re = -0.10922561, .im = 0.44308007 }, .{ .re = -0.54247558, .im = 0.89054137 }, .{ .re = 0.80285490, .im = -0.93882000 }, .{ .re = -0.94910830, .im = 0.08282494 }, .{ .re = 0.87829834, .im = -0.23759152 }, .{ .re = -0.56680119, .im = -0.15576684 }, .{ .re = -0.94191837, .im = -0.55661666 }, .{ .re = -0.12422481, .im = -0.00837552 }, .{ .re = -0.53383112, .im = -0.53826690 }, .{ .re = -0.56243795, .im = -0.08079307 }, .{ .re = -0.42043677, .im = -0.95702058 }, .{ .re = 0.67515594, .im = 0.11290865 }, .{ .re = 0.28458872, .im = -0.62818748 }, .{ .re = 0.98508680, .im = 0.71989304 }, .{ .re = -0.75822008, .im = -0.33460963 }, .{ .re = 0.44296879, .im = 0.42238355 }, .{ .re = 0.87288117, .im = -0.15578599 }, .{ .re = 0.66007137, .im = 0.34061113 }, .{ .re = -0.39326301, .im = 0.17516121 }, .{ .re = 0.76495802, .im = 0.69239485 }, .{ .re = 0.01056764, .im = 0.17800452 }, .{ .re = -0.93094832, .im = -0.51452005 }, .{ .re = 0.59480852, .im = -0.17137200 }, .{ .re = -0.65398520, .im = 0.09759752 }, .{ .re = 0.40608153, .im = 0.34897169 }, .{ .re = -0.25059396, .im = -0.12207674 }, .{ .re = 0.01685298, .im = 0.55688524 }, .{ .re = 0.04187684, .im = -0.21348982 }, .{ .re = -0.02061296, .im = -0.94085008 }, .{ .re = -0.91302544, .im = 0.40676415 }, .{ .re = 0.96637541, .im = 0.18636747 }, .{ .re = -0.21280062, .im = -0.65930158 }, .{ .re = 0.00447712, .im = 0.96415329 }, .{ .re = 0.54104626, .im = 0.07923490 }, .{ .re = 0.72057962, .im = -0.53564775 }, .{ .re = 0.02754333, .im = 0.90493482 }, .{ .re = 0.15558961, .im = -0.08173654 }, .{ .re = -0.46144104, .im = 0.09599262 }, .{ .re = 0.91423255, .im = -0.98858166 }, .{ .re = 0.56731045, .im = 0.64097184 }, .{ .re = 0.77235913, .im = 0.48100683 }, .{ .re = 0.61827981, .im = 0.03735657 }, .{ .re = 0.12271573, .im = -0.14781864 }, .{ .re = -0.88775343, .im = 0.74002033 }, .{ .re = 0.13999867, .im = -0.60032117 }, .{ .re = 0.00944094, .im = -0.03014978 }, .{ .re = -0.28642008, .im = -0.30784416 }, .{ .re = 0.07695759, .im = 0.24697889 }, .{ .re = 0.22490492, .im = -0.08370640 }, .{ .re = -0.94405001, .im = -0.54078996 }, .{ .re = -0.64557749, .im = 0.16892174 }, .{ .re = 0.72201771, .im = 0.59687787 }, .{ .re = 0.59419513, .im = 0.63287473 }, .{ .re = -0.48941192, .im = 0.68348968 }, .{ .re = 0.34622705, .im = -0.83353174 }, .{ .re = -0.96661872, .im = -0.97087997 }, .{ .re = 0.51117355, .im = -0.50088155 } }}, &[1]type{
            std.math.Complex(f32),
        }, .{&[64]std.math.Complex(f32){ .{ .re = -0.21418448, .im = 0.20352198 }, .{ .re = -0.27385336, .im = 0.26356673 }, .{ .re = 0.12892093, .im = -0.14793879 }, .{ .re = 0.28495440, .im = -0.07874280 }, .{ .re = -0.08510272, .im = 0.05776766 }, .{ .re = -0.23922576, .im = -0.40931904 }, .{ .re = 0.32370317, .im = -0.65662682 }, .{ .re = 0.51302010, .im = -0.42269999 }, .{ .re = -0.12476888, .im = 0.34138367 }, .{ .re = -0.20263587, .im = 0.44899204 }, .{ .re = 0.05483368, .im = -0.32342783 }, .{ .re = -0.02880958, .im = -0.37308007 }, .{ .re = 0.06108767, .im = -0.10505064 }, .{ .re = -0.34571540, .im = -0.25985390 }, .{ .re = -0.76464087, .im = -0.35611084 }, .{ .re = -0.44569087, .im = -0.28100637 }, .{ .re = -0.38263828, .im = -0.28032735 }, .{ .re = -0.53249866, .im = -0.43707401 }, .{ .re = -0.14762148, .im = -0.50310671 }, .{ .re = 0.44707057, .im = -0.32316631 }, .{ .re = 0.67830992, .im = -0.03774227 }, .{ .re = 0.36162186, .im = 0.19515343 }, .{ .re = -0.14226684, .im = 0.14503086 }, .{ .re = 0.23102406, .im = 0.07030997 }, .{ .re = 0.85880411, .im = 0.10733529 }, .{ .re = 0.48750031, .im = 0.19313698 }, .{ .re = 0.03966582, .im = 0.38675171 }, .{ .re = 0.25237134, .im = 0.47589833 }, .{ .re = -0.04923263, .im = 0.09001486 }, .{ .re = -0.41132641, .im = -0.38110751 }, .{ .re = -0.10733852, .im = -0.23794527 }, .{ .re = -0.01936931, .im = 0.17457676 }, .{ .re = -0.00865168, .im = 0.23807806 }, .{ .re = -0.01959664, .im = 0.16385582 }, .{ .re = -0.04977519, .im = 0.18708292 }, .{ .re = 0.02679187, .im = -0.26563337 }, .{ .re = -0.25868827, .im = -0.52662688 }, .{ .re = -0.26242733, .im = 0.06286955 }, .{ .re = 0.28072667, .im = 0.12555994 }, .{ .re = 0.20472582, .im = -0.06001690 }, .{ .re = 0.05059847, .im = 0.37334764 }, .{ .re = 0.49417639, .im = 0.18221836 }, .{ .re = 0.57996047, .im = -0.08957490 }, .{ .re = 0.18797129, .im = 0.31800714 }, .{ .re = -0.13544889, .im = 0.26065332 }, .{ .re = 0.01078698, .im = -0.31181917 }, .{ .re = 0.58979285, .im = -0.40796685 }, .{ .re = 0.82446331, .im = 0.28030711 }, .{ .re = 0.69849646, .im = 0.55044115 }, .{ .re = 0.48288578, .im = 0.07137844 }, .{ .re = -0.12688485, .im = 0.04665750 }, .{ .re = -0.52593678, .im = 0.20212218 }, .{ .re = -0.15347245, .im = -0.15174890 }, .{ .re = 0.05288101, .im = -0.31833550 }, .{ .re = -0.11614375, .im = -0.09078717 }, .{ .re = 0.01799040, .im = 0.08461212 }, .{ .re = -0.10229212, .im = -0.11951274 }, .{ .re = -0.67931056, .im = -0.30634561 }, .{ .re = -0.42565173, .im = 0.13588499 }, .{ .re = 0.52444994, .im = 0.63704431 }, .{ .re = 0.48923042, .im = 0.72242630 }, .{ .re = -0.10122898, .im = 0.23230839 }, .{ .re = -0.30758506, .im = -0.69639504 }, .{ .re = -0.29773718, .im = -0.99942672 } }});
    }

    // 5 feedforward taps, 5 feedback taps, ComplexFloat32
    {
        var block = IIRFilterBlock(std.math.Complex(f32), 5, 5).init([5]f32{ 0.09398085, 0.37592340, 0.56388509, 0.37592340, 0.09398085 }, [5]f32{ 1.00000000, -0.00000000, 0.48602882, -0.00000000, 0.01766480 });
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2, &[1]type{
            std.math.Complex(f32),
        }, .{&[64]std.math.Complex(f32){ .{ .re = -0.73127151, .im = 0.69486749 }, .{ .re = 0.52754927, .im = -0.48986191 }, .{ .re = -0.00912983, .im = -0.10101787 }, .{ .re = 0.30318594, .im = 0.57744670 }, .{ .re = -0.81228077, .im = -0.94330502 }, .{ .re = 0.67153019, .im = -0.13446586 }, .{ .re = 0.52456015, .im = -0.99578792 }, .{ .re = -0.10922561, .im = 0.44308007 }, .{ .re = -0.54247558, .im = 0.89054137 }, .{ .re = 0.80285490, .im = -0.93882000 }, .{ .re = -0.94910830, .im = 0.08282494 }, .{ .re = 0.87829834, .im = -0.23759152 }, .{ .re = -0.56680119, .im = -0.15576684 }, .{ .re = -0.94191837, .im = -0.55661666 }, .{ .re = -0.12422481, .im = -0.00837552 }, .{ .re = -0.53383112, .im = -0.53826690 }, .{ .re = -0.56243795, .im = -0.08079307 }, .{ .re = -0.42043677, .im = -0.95702058 }, .{ .re = 0.67515594, .im = 0.11290865 }, .{ .re = 0.28458872, .im = -0.62818748 }, .{ .re = 0.98508680, .im = 0.71989304 }, .{ .re = -0.75822008, .im = -0.33460963 }, .{ .re = 0.44296879, .im = 0.42238355 }, .{ .re = 0.87288117, .im = -0.15578599 }, .{ .re = 0.66007137, .im = 0.34061113 }, .{ .re = -0.39326301, .im = 0.17516121 }, .{ .re = 0.76495802, .im = 0.69239485 }, .{ .re = 0.01056764, .im = 0.17800452 }, .{ .re = -0.93094832, .im = -0.51452005 }, .{ .re = 0.59480852, .im = -0.17137200 }, .{ .re = -0.65398520, .im = 0.09759752 }, .{ .re = 0.40608153, .im = 0.34897169 }, .{ .re = -0.25059396, .im = -0.12207674 }, .{ .re = 0.01685298, .im = 0.55688524 }, .{ .re = 0.04187684, .im = -0.21348982 }, .{ .re = -0.02061296, .im = -0.94085008 }, .{ .re = -0.91302544, .im = 0.40676415 }, .{ .re = 0.96637541, .im = 0.18636747 }, .{ .re = -0.21280062, .im = -0.65930158 }, .{ .re = 0.00447712, .im = 0.96415329 }, .{ .re = 0.54104626, .im = 0.07923490 }, .{ .re = 0.72057962, .im = -0.53564775 }, .{ .re = 0.02754333, .im = 0.90493482 }, .{ .re = 0.15558961, .im = -0.08173654 }, .{ .re = -0.46144104, .im = 0.09599262 }, .{ .re = 0.91423255, .im = -0.98858166 }, .{ .re = 0.56731045, .im = 0.64097184 }, .{ .re = 0.77235913, .im = 0.48100683 }, .{ .re = 0.61827981, .im = 0.03735657 }, .{ .re = 0.12271573, .im = -0.14781864 }, .{ .re = -0.88775343, .im = 0.74002033 }, .{ .re = 0.13999867, .im = -0.60032117 }, .{ .re = 0.00944094, .im = -0.03014978 }, .{ .re = -0.28642008, .im = -0.30784416 }, .{ .re = 0.07695759, .im = 0.24697889 }, .{ .re = 0.22490492, .im = -0.08370640 }, .{ .re = -0.94405001, .im = -0.54078996 }, .{ .re = -0.64557749, .im = 0.16892174 }, .{ .re = 0.72201771, .im = 0.59687787 }, .{ .re = 0.59419513, .im = 0.63287473 }, .{ .re = -0.48941192, .im = 0.68348968 }, .{ .re = 0.34622705, .im = -0.83353174 }, .{ .re = -0.96661872, .im = -0.97087997 }, .{ .re = 0.51117355, .im = -0.50088155 } }}, &[1]type{
            std.math.Complex(f32),
        }, .{&[64]std.math.Complex(f32){ .{ .re = -0.06872552, .im = 0.06530423 }, .{ .re = -0.22532254, .im = 0.21517929 }, .{ .re = -0.18149042, .im = 0.16644138 }, .{ .re = 0.15714990, .im = -0.10329829 }, .{ .re = 0.25150388, .im = -0.12943456 }, .{ .re = -0.09753403, .im = -0.07924180 }, .{ .re = -0.16220599, .im = -0.40849876 }, .{ .re = 0.33336183, .im = -0.66852516 }, .{ .re = 0.45424798, .im = -0.24962482 }, .{ .re = -0.09006210, .im = 0.43573558 }, .{ .re = -0.30295408, .im = 0.35854262 }, .{ .re = 0.00215876, .im = -0.34413415 }, .{ .re = 0.13176624, .im = -0.49633461 }, .{ .re = -0.08713408, .im = -0.14237536 }, .{ .re = -0.50309032, .im = -0.14449987 }, .{ .re = -0.71622163, .im = -0.37321106 }, .{ .re = -0.48875535, .im = -0.35954854 }, .{ .re = -0.33754373, .im = -0.29538780 }, .{ .re = -0.37766883, .im = -0.42054391 }, .{ .re = -0.04142084, .im = -0.48704138 }, .{ .re = 0.56155449, .im = -0.26143831 }, .{ .re = 0.69992262, .im = 0.07938970 }, .{ .re = 0.21624877, .im = 0.22880159 }, .{ .re = -0.12138039, .im = 0.13706642 }, .{ .re = 0.33247775, .im = 0.04690577 }, .{ .re = 0.84527630, .im = 0.11597642 }, .{ .re = 0.50061232, .im = 0.27727765 }, .{ .re = -0.01171047, .im = 0.43040094 }, .{ .re = 0.01284186, .im = 0.37125677 }, .{ .re = -0.04673927, .im = -0.04363844 }, .{ .re = -0.30202821, .im = -0.39873227 }, .{ .re = -0.19832940, .im = -0.19023278 }, .{ .re = 0.04301070, .im = 0.24920696 }, .{ .re = 0.04363475, .im = 0.31703797 }, .{ .re = -0.05541085, .im = 0.14672565 }, .{ .re = -0.05043614, .im = -0.01848242 }, .{ .re = -0.06098618, .im = -0.31368503 }, .{ .re = -0.22296122, .im = -0.38464090 }, .{ .re = -0.14475089, .im = 0.01358297 }, .{ .re = 0.22944038, .im = 0.19961822 }, .{ .re = 0.28144261, .im = 0.10535140 }, .{ .re = 0.17688519, .im = 0.20255977 }, .{ .re = 0.42601082, .im = 0.17740570 }, .{ .re = 0.54508913, .im = 0.04888281 }, .{ .re = 0.14035995, .im = 0.20657277 }, .{ .re = -0.18979029, .im = 0.15959702 }, .{ .re = 0.12213194, .im = -0.30647737 }, .{ .re = 0.72514492, .im = -0.32131284 }, .{ .re = 0.90682793, .im = 0.32846525 }, .{ .re = 0.62957740, .im = 0.57278031 }, .{ .re = 0.21210086, .im = 0.12187515 }, .{ .re = -0.26516199, .im = -0.07504360 }, .{ .re = -0.46194276, .im = 0.07168336 }, .{ .re = -0.14886510, .im = -0.08812348 }, .{ .re = 0.09485187, .im = -0.30263567 }, .{ .re = -0.01769806, .im = -0.11220691 }, .{ .re = -0.10550572, .im = 0.08424067 }, .{ .re = -0.27549827, .im = -0.11461484 }, .{ .re = -0.56578475, .im = -0.22919998 }, .{ .re = -0.23630622, .im = 0.22563672 }, .{ .re = 0.52995265, .im = 0.76130533 }, .{ .re = 0.51408482, .im = 0.66808689 }, .{ .re = -0.19301102, .im = -0.09113859 }, .{ .re = -0.49392593, .im = -0.89434326 } }});
    }

    // 3 feedforward taps, 3 feedback taps, Float32
    {
        var block = IIRFilterBlock(f32, 3, 3).init([3]f32{ 0.29289323, 0.58578646, 0.29289323 }, [3]f32{ 1.00000000, -0.00000000, 0.17157288 });
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2, &[1]type{
            f32,
        }, .{&[64]f32{ -0.24488358, -0.59217191, -0.99224871, -0.44475749, 0.19632840, 0.76332581, 0.65884250, 0.02192042, 0.97403622, -0.07683806, 0.66918695, -0.18206932, 0.48926124, 0.97518337, -0.38932681, -0.65937436, 0.24006742, 0.06191236, -0.28115594, -0.99296153, -0.22167473, -0.14826106, -0.18949586, 0.72249067, 0.16885605, 0.46766159, 0.79581833, 0.49754697, -0.01459590, 0.49153668, 0.28071079, 0.29749086, 0.25935072, -0.18600205, 0.25852406, 0.26746503, 0.87423593, 0.56494737, 0.69253606, 0.53499961, 0.63065171, 0.21092477, -0.30109984, -0.47083348, 0.41604009, 0.74788415, 0.08849352, -0.69586009, 0.66595060, -0.03091384, -0.06579474, -0.90922385, 0.02056185, 0.48949531, -0.15480438, -0.28964537, 0.31368709, -0.96051723, 0.01432719, 0.89225417, 0.38089520, -0.19615254, 0.37781647, 0.20998783 }}, &[1]type{
            f32,
        }, .{&[64]f32{ -0.07172474, -0.31689262, -0.69692791, -0.83058524, -0.37407866, 0.35081893, 0.76180148, 0.55574328, 0.36039531, 0.45914173, 0.37444416, 0.23739216, 0.16840342, 0.47817028, 0.57162583, -0.21760513, -0.52804512, 0.00297081, 0.11483109, -0.43790507, -0.74864107, -0.38897780, -0.07883190, 0.12392190, 0.43070543, 0.42623949, 0.48259908, 0.67575157, 0.43747011, 0.16520518, 0.29082078, 0.36719266, 0.28254950, 0.12157816, -0.00575330, 0.15444034, 0.48944226, 0.72942579, 0.70586044, 0.60269558, 0.57984173, 0.48449722, 0.12059528, -0.33563229, -0.26283354, 0.38244233, 0.63097000, 0.00145908, -0.29491118, 0.17698734, 0.20827143, -0.34426785, -0.58159316, -0.05182377, 0.34720662, -0.02325606, -0.18270591, -0.17842042, -0.43523747, 0.01901098, 0.71310329, 0.42374492, -0.01503117, 0.15266889 }});
    }

    // 5 feedforward taps, 5 feedback taps, ComplexFloat32
    {
        var block = IIRFilterBlock(f32, 5, 5).init([5]f32{ 0.09398085, 0.37592340, 0.56388509, 0.37592340, 0.09398085 }, [5]f32{ 1.00000000, -0.00000000, 0.48602882, -0.00000000, 0.01766480 });
        var tester = BlockTester.init(&block.block, 1e-6);
        try tester.check(2, &[1]type{
            f32,
        }, .{&[64]f32{ -0.24488358, -0.59217191, -0.99224871, -0.44475749, 0.19632840, 0.76332581, 0.65884250, 0.02192042, 0.97403622, -0.07683806, 0.66918695, -0.18206932, 0.48926124, 0.97518337, -0.38932681, -0.65937436, 0.24006742, 0.06191236, -0.28115594, -0.99296153, -0.22167473, -0.14826106, -0.18949586, 0.72249067, 0.16885605, 0.46766159, 0.79581833, 0.49754697, -0.01459590, 0.49153668, 0.28071079, 0.29749086, 0.25935072, -0.18600205, 0.25852406, 0.26746503, 0.87423593, 0.56494737, 0.69253606, 0.53499961, 0.63065171, 0.21092477, -0.30109984, -0.47083348, 0.41604009, 0.74788415, 0.08849352, -0.69586009, 0.66595060, -0.03091384, -0.06579474, -0.90922385, 0.02056185, 0.48949531, -0.15480438, -0.28964537, 0.31368709, -0.96051723, 0.01432719, 0.89225417, 0.38089520, -0.19615254, 0.37781647, 0.20998783 }}, &[1]type{
            f32,
        }, .{&[64]f32{ -0.02301437, -0.14771029, -0.44276422, -0.76899111, -0.73828083, -0.15755090, 0.56577724, 0.80232662, 0.51475334, 0.30354387, 0.39322975, 0.39764327, 0.21732314, 0.21862075, 0.48776710, 0.39509916, -0.27318048, -0.52634573, -0.02808477, 0.11301725, -0.48833853, -0.80268896, -0.36040086, 0.12454362, 0.28784010, 0.38330781, 0.46607202, 0.55251259, 0.59448296, 0.38907734, 0.16759346, 0.25306454, 0.38594812, 0.26961717, 0.04829061, 0.00738043, 0.25264880, 0.60391426, 0.77162570, 0.68931788, 0.56594181, 0.52631623, 0.38411844, -0.01912755, -0.36581236, -0.13217831, 0.48977768, 0.56632024, -0.06044041, -0.31430346, 0.12516548, 0.20009023, -0.38576776, -0.57830149, 0.01835988, 0.39042008, 0.01714047, -0.32740587, -0.31493914, -0.20944741, 0.20046136, 0.65057838, 0.42144930, -0.03430038 }});
    }
}