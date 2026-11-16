"""check_cordic_mod.py - checks cordic_mod simulation output.

Usage:
  python check_cordic_mod.py cordic_mod_out.txt            (tb_cordic_mod)
  python check_cordic_mod.py --stress cordic_mod_stress.txt (tb_cordic_mod_stress)

Directed tests (tb_cordic_mod):
  * bit-exact: the RTL must match `ModModel` (a line-by-line integer model)
    sample for sample;
  * maths: the output is compared with ideal floating-point FM/PM/AM, in DAC LSBs;
  * spectrum: sideband levels vs theory (Bessel J_k(beta) for FM/PM, mu/4 for
    AM) and the worst unexpected spur.
Stress test (tb_cordic_mod_stress): random parameters changed on any clock,
irregular ticks (some while busy) and mid-sample resets; every output must
match the bit-exact model.
"""
import math
import sys

import numpy as np

N = 4096
MASK32 = 0xFFFFFFFF
ATAN = [131072, 77376, 40884, 20753, 10417, 5213, 2607, 1304,
        652, 326, 163, 81, 41, 20, 10, 5]
K = 1.0
for _i in range(16):
    K *= math.sqrt(1 + 2.0 ** (-2 * _i))

# cordic_mod constants (keep in sync with the RTL)
TONE_X0, AMP_X0_PER_PCT, PM_K, AM_K, AM_BETA_MAX = 636751, 6352, 1043, 6554, 10
FM_LIMIT = 0x6000_0000
XY_LIMIT = 1 << 21                      # 22-bit signed CORDIC X/Y
A_FULL = AMP_X0_PER_PCT * K / 512       # output peak per % amplitude, in DAC counts


# ----------------------------------------------------------------------------
# Bit-exact model
# ----------------------------------------------------------------------------
def cordic(x0, angle):
    """cordic_core: returns (cos, sin). Python >> on ints = Verilog >>>."""
    quad, z = angle >> 18, angle & 0x3FFFF
    x, y = x0, 0
    for i in range(16):
        if z < 0:
            x, y, z = x + (y >> i), y - (x >> i), z + ATAN[i]
        else:
            x, y, z = x - (y >> i), y + (x >> i), z - ATAN[i]
        assert -XY_LIMIT <= x < XY_LIMIT and -XY_LIMIT <= y < XY_LIMIT, "X/Y overflow"
    return [(x, y), (-y, x), (-x, -y), (y, -x)][quad]


class ModModel:
    """cordic_mod, one call to step() per accepted tick."""

    def __init__(self):
        self.acc = self.tph = 0

    def step(self, mode, fc, fm, dev, beta, amp):
        _, m = cordic(TONE_X0, self.tph >> 12)
        self.tph = (self.tph + fm) & MASK32
        if mode == 0:                                   # FM, limited
            inc = max(-FM_LIMIT, min(FM_LIMIT, fc + ((dev * m) >> 20))) & MASK32
        else:
            inc = fc
        pm_term = ((beta * PM_K * m) >> 4) & MASK32
        am_q = (min(beta, AM_BETA_MAX) * AM_K * m) >> 20
        env = max(0, min(65536, (65536 + am_q) >> 1))
        x0 = (amp * AMP_X0_PER_PCT * env) >> 16 if mode == 2 else amp * AMP_X0_PER_PCT
        angle = ((self.acc + pm_term) & MASK32) >> 12 if mode == 1 else self.acc >> 12
        self.acc = (self.acc + inc) & MASK32
        _, s = cordic(x0, angle)
        return max(-2047, min(2047, (s + 256) >> 9))


# ----------------------------------------------------------------------------
# Ideal floating-point maths
# ----------------------------------------------------------------------------
class IdealModel:
    def __init__(self):
        self.acc, self.tph = 0.0, 0

    def step(self, mode, fc, fm, dev, beta, amp):
        two32 = 2.0 ** 32
        m = math.sin(2 * math.pi * (self.tph >> 12) / 2 ** 20)
        self.tph = (self.tph + fm) & MASK32
        theta = self.acc + ((beta / 10) * m * two32 / (2 * math.pi) if mode == 1 else 0)
        s = math.sin(2 * math.pi * math.floor(theta % two32 / 4096) / 2 ** 20)
        A = A_FULL * amp
        if mode == 2:
            out = A * (1 + min(beta / 10, 1.0) * m) / 2 * s
        else:
            out = A * s
        inc = max(-FM_LIMIT, min(FM_LIMIT, fc + dev * m)) if mode == 0 else fc
        self.acc = (self.acc + inc) % two32
        return out


# ----------------------------------------------------------------------------
# Directed tests (must match tb_cordic_mod.v)
# ----------------------------------------------------------------------------
FC, FMT, DEV24 = 512 << 20, 43 << 20, 108213043        # bin 512, bin 43, 2.4*fm
FC_BIN, FM_BIN = 512, 43
#      id: name,                         mode, fc,       fm,   dev,        beta, amp
TESTS = {
    0: ("bypass ~1 kHz",                 3, 89523224, FMT, DEV24,       24, 100),
    1: ("PM beta 2.4",                   1, FC,       FMT, DEV24,       24, 100),
    2: ("FM beta 2.4",                   0, FC,       FMT, DEV24,       24, 100),
    3: ("AM mu 0.5, amp 60",             2, FC,       FMT, DEV24,        5,  60),
    4: ("AM beta 2.0 -> mu capped 1",    2, FC,       FMT, DEV24,       20, 100),
    5: ("FM max deviation (limiter)",    0, FC,       FMT, 0x7FFFFFFF,  24, 100),
    6: ("PM beta 20, amp 50",            1, FC,       FMT, DEV24,      200,  50),
    7: ("amp 0 (silence)",               0, FC,       FMT, DEV24,       24,   0),
    8: ("change mid-sample FM->PM",      0, FC,       FMT, DEV24,       24, 100),
}
# test 8 switches to these parameters part-way through sample CHANGE_AT
CHANGE_AT = 2048
TEST8_B = (1, 300 << 20, 20 << 20, 0, 10, 80)


def jv(k, x, terms=40):
    """Bessel function of the first kind J_k(x)."""
    return sum((-1) ** s * (x / 2) ** (2 * s + k) / (math.factorial(s) * math.factorial(s + k))
               for s in range(terms))


def db(v):
    return 20 * math.log10(max(v, 1e-12))


def directed(path):
    data = {}
    with open(path) as f:
        for line in f:
            t, n, v = map(int, line.split())
            data.setdefault(t, []).append(v)

    ok = True
    for t, (name, *p) in TESTS.items():
        got = np.array(data[t][:N], dtype=float) - 2048
        ex, idl = ModModel(), IdealModel()
        exp, ref = np.zeros(N), np.zeros(N)
        for n in range(N):
            params = TEST8_B if (t == 8 and n >= CHANGE_AT + 1) else p
            exp[n], ref[n] = ex.step(*params), idl.step(*params)
        mism = int(np.sum(got != exp))
        err = got - ref
        emax, erms = np.abs(err).max(), np.sqrt(np.mean(err ** 2))
        line = (f"[{t}] {name:30s} bit-exact mismatches {mism:3d} | "
                f"vs ideal maths: max {emax:4.2f} LSB, rms {erms:4.2f}")
        # At very large deviation tiny phase rounding is magnified; bound rms there.
        test_ok = mism == 0 and (emax <= 1.5 if t != 5 else erms <= 2.0)

        mode, beta, amp = p[0], p[4], p[5]
        if t in (1, 2, 3, 4):
            X = np.abs(np.fft.rfft(got)) / (N / 2) / (A_FULL * amp)
            if mode == 2:
                mu = min(beta / 10, 1.0)
                expect = {0: 0.5, 1: mu / 4}
            else:
                expect = {k: abs(jv(k, beta / 10)) for k in range(6)}
            parts = []
            for k, e in expect.items():
                for sgn in ((1,) if k == 0 else (1, -1)):
                    b = FC_BIN + sgn * k * FM_BIN
                    d = db(X[b]) - db(e)
                    tag = "c" if k == 0 else ("+" if sgn > 0 else "-") + str(k)
                    parts.append(f"{tag}:{db(X[b]):6.1f}({d:+.1f})")
                    if e > 0.01 and abs(d) > 0.3:        # skip the carrier null
                        test_ok = False
            mask = np.ones(len(X), bool)
            for k in range(-12, 13):
                mask[FC_BIN + k * FM_BIN] = False
            mask[0] = False
            spur = db(X[mask].max())
            test_ok &= spur < -70
            line += "\n      dB rel. A (delta vs theory): " + " ".join(parts) + f"\n      worst spur {spur:.1f} dBc"
        if t == 7:
            test_ok &= bool(np.all(got == 0))
        print(line, "  OK" if test_ok else "  ** FAIL **")
        ok &= test_ok
    return ok


def stress(path):
    model, pend = ModModel(), None
    n_t = n_o = n_b = n_r = mism = 0
    first = []
    for line in open(path):
        p = line.split()
        if p[0] == "R":
            model, pend = ModModel(), None
            n_r += 1
        elif p[0] == "B":
            n_b += 1
        elif p[0] == "T":
            n_t += 1
            pend = model.step(*map(int, p[1:])) + 2048
        elif p[0] == "O":
            n_o += 1
            if pend is None or int(p[1]) != pend:
                mism += 1
                if len(first) < 5:
                    first.append((n_o, p[1], pend))
            pend = None
    print(f"stress: ticks accepted {n_t}, ticks while busy {n_b}, outputs {n_o}, "
          f"reset cycles {n_r}, mismatches {mism}", first if first else "")
    return mism == 0 and n_o > 0


if __name__ == "__main__":
    if sys.argv[1] == "--stress":
        good = stress(sys.argv[2])
    else:
        good = directed(sys.argv[1])
    print("ALL PASS" if good else "SOME CHECKS FAILED")
    sys.exit(0 if good else 1)
