const std = @import("std");

// @python
// def process(tau, x):
//     tau = 1/(2*2*numpy.tan(1/(2*2*tau)))
//     b_taps = [1 / (1 + 2*2*tau), 1 / (1 + 2*2*tau)]
//     a_taps = [1, (1 - 2*2*tau) / (1 + 2*2*tau)]
//     return scipy.signal.lfilter(b_taps, a_taps, x).astype(numpy.float32)
//
// x = random_float32(64)
// vector("input_float32", x)
// vector("output_tau_5em6", process(5e-6, x))
// vector("output_tau_1em6", process(1e-6, x))
// @python

////////////////////////////////////////////////////////////////////////////////
// Auto-generated code below, do not edit!
////////////////////////////////////////////////////////////////////////////////

// @autogenerated

pub const input_float32 = [64]f32{ -0.73127151, 0.69486749, 0.52754927, -0.48986191, -0.00912983, -0.10101787, 0.30318594, 0.57744670, -0.81228077, -0.94330502, 0.67153019, -0.13446586, 0.52456015, -0.99578792, -0.10922561, 0.44308007, -0.54247558, 0.89054137, 0.80285490, -0.93882000, -0.94910830, 0.08282494, 0.87829834, -0.23759152, -0.56680119, -0.15576684, -0.94191837, -0.55661666, -0.12422481, -0.00837552, -0.53383112, -0.53826690, -0.56243795, -0.08079307, -0.42043677, -0.95702058, 0.67515594, 0.11290865, 0.28458872, -0.62818748, 0.98508680, 0.71989304, -0.75822008, -0.33460963, 0.44296879, 0.42238355, 0.87288117, -0.15578599, 0.66007137, 0.34061113, -0.39326301, 0.17516121, 0.76495802, 0.69239485, 0.01056764, 0.17800452, -0.93094832, -0.51452005, 0.59480852, -0.17137200, -0.65398520, 0.09759752, 0.40608153, 0.34897169 };
pub const output_tau_5em6 = [64]f32{ -0.71842599, 0.65742165, 0.56661868, -0.50968683, 0.00155408, -0.10971232, 0.30447468, 0.57138556, -0.78202057, -0.97020054, 0.66911459, -0.11797695, 0.49707407, -0.94256097, -0.17615595, 0.49795720, -0.57811248, 0.89975381, 0.79550642, -0.90113539, -0.98528826, 0.09960687, 0.84813267, -0.18888389, -0.60801470, -0.12322147, -0.95951080, -0.54641050, -0.14166780, 0.00641965, -0.53887635, -0.53332102, -0.56678551, -0.08505886, -0.41035464, -0.95732284, 0.64677674, 0.15016730, 0.24562331, -0.57455713, 0.90500176, 0.80182290, -0.81130701, -0.29082891, 0.38706720, 0.47668278, 0.81257612, -0.07952999, 0.57216305, 0.43104273, -0.46762630, 0.23692702, 0.69500178, 0.76116800, -0.04381239, 0.22753286, -0.95925671, -0.49452117, 0.55602574, -0.12049298, -0.69459915, 0.12358227, 0.37559083, 0.37939438 };
pub const output_tau_1em6 = [64]f32{ -0.67111915, 0.52730089, 0.68131191, -0.53463900, -0.01126291, -0.09167726, 0.26213333, 0.58918566, -0.70777339, -1.01984167, 0.60264367, -0.01061320, 0.36687341, -0.73898333, -0.39670828, 0.63783658, -0.62412280, 0.84088045, 0.85155869, -0.83624601, -1.03396106, 0.06883428, 0.82455391, -0.10089885, -0.65392607, -0.11678579, -0.90981984, -0.61512834, -0.11090648, -0.02903223, -0.47335023, -0.58843291, -0.51853669, -0.15709068, -0.32875305, -0.98948312, 0.56801963, 0.24866837, 0.15704150, -0.44654119, 0.70062053, 0.97937459, -0.85342777, -0.28990999, 0.34166148, 0.50871766, 0.76369363, 0.02005392, 0.44604951, 0.54570121, -0.50424641, 0.22112924, 0.67803735, 0.77098465, 0.00099219, 0.17223178, -0.83490592, -0.62901628, 0.59921825, -0.11203238, -0.66386420, 0.04402817, 0.42546290, 0.33747652 };
