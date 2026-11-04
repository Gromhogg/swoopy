// Advanced processing engine (see AdvancedChain.h). Ported from the research test bench (dspchain, recipe "balanced3").
//
// How it is built:
// - A "chain" is the whole recipe for ONE fixed amount N: band filters, 1-3 Rubber Band shifters, the air band and
//   an EQ. Every path inside a chain is read at the same fixed total delay, so the paths stay lined up exactly.
// - Rubber Band's delay is only known exactly for a fresh shifter (research round 3: after setPitchScale on a running
//   shifter its delay moves by up to 31 ms, depending on its history). So a new N never retunes a running chain:
//   a NEW chain is started with fresh shifters, fed the last part of the input from a history buffer (faster than
//   real time, but a bounded amount per call), and once it has caught up it is faded in over 80 ms.
// - Fresh shifters come from a pool made in advanced_new. Rubber Band's reset() makes memory, so used shifters are
//   reset by a small helper thread, never by the sound thread. They are handed over with atomic flags (no locks).
//   On the Mac the helper sleeps until a shifter is let go of; elsewhere it looks every 2 ms.
// - The EQ looks at the long-term spectrum. Its analysis (two big FFTs and a fit) is cut into 8 slices, one slice per
//   256 samples, so no single call has to do all of it.
// - The FFT: on the Mac, Apple's Accelerate (vDSP). Elsewhere (Windows), a small FFT written here (RealFFT below) that
//   gives the same numbers as vDSP up to rounding. ADVANCED_PORTABLE_FFT uses the portable one on the Mac too (checks).
#if defined(_MSC_VER) && !defined(_USE_MATH_DEFINES)
#define _USE_MATH_DEFINES  // M_PI and M_SQRT1_2 on Windows
#endif
#include "AdvancedChain.h"
#include "AdvancedTuning.h"
#include <rubberband/RubberBandStretcher.h>
#if defined(__APPLE__) && !defined(ADVANCED_PORTABLE_FFT)
#define ADVANCED_VDSP 1
#include <Accelerate/Accelerate.h>
#else
#define ADVANCED_VDSP 0
#endif
#if defined(__APPLE__)
#include <dispatch/dispatch.h>
#endif
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <complex>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <thread>
#include <vector>

using RubberBand::RubberBandStretcher;

namespace {

const int MAXCH = 2;     // channels
const int MAXPATHS = 3;  // shifted paths in one chain
const int NEQ = 10;      // EQ filters (an even number: they are run two at a time)
static_assert(NEQ % 2 == 0, "the EQ runs its filters in pairs");
const int RBOPTS = RubberBandStretcher::OptionProcessRealTime | RubberBandStretcher::OptionEngineFiner |
                   RubberBandStretcher::OptionChannelsTogether;  // the app's normal settings

// ------------------------------------------------------------------------------------------------- filters

// One second-order filter (transposed direct form II, double precision), designs from the RBJ audio EQ cookbook.
struct Biquad {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0;
    inline float run(float x) { double y = b0 * x + z1; z1 = b1 * x - a1 * y + z2; z2 = b2 * x - a2 * y; return (float)y; }
    inline double runD(double x) { double y = b0 * x + z1; z1 = b1 * x - a1 * y + z2; z2 = b2 * x - a2 * y; return y; }
    void clear() { z1 = z2 = 0; }
    void set(double B0, double B1, double B2, double A0, double A1, double A2) {
        b0 = B0 / A0; b1 = B1 / A0; b2 = B2 / A0; a1 = A1 / A0; a2 = A2 / A0;
    }
    void copyCoefs(const Biquad &o) { b0 = o.b0; b1 = o.b1; b2 = o.b2; a1 = o.a1; a2 = o.a2; }
    void lowpass(double f, double q, double sr) {
        double w = 2 * M_PI * f / sr, al = sin(w) / (2 * q), c = cos(w);
        set((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + al, -2 * c, 1 - al);
    }
    void highpass(double f, double q, double sr) {
        double w = 2 * M_PI * f / sr, al = sin(w) / (2 * q), c = cos(w);
        set((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + al, -2 * c, 1 - al);
    }
    void allpass(double f, double q, double sr) {  // gain 1 at every frequency, only the phase turns
        double w = 2 * M_PI * f / sr, al = sin(w) / (2 * q), c = cos(w);
        set(1 - al, -2 * c, 1 + al, 1 + al, -2 * c, 1 - al);
    }
    void peaking(double f, double q, double gdb, double sr) {
        double A = pow(10, gdb / 40), w = 2 * M_PI * f / sr, al = sin(w) / (2 * q), c = cos(w);
        set(1 + al * A, -2 * c, 1 - al * A, 1 + al / A, -2 * c, 1 - al / A);
    }
    void lowshelf(double f, double gdb, double sr) {
        double A = pow(10, gdb / 40), w = 2 * M_PI * f / sr, c = cos(w), al = sin(w) / 2 * sqrt(2.0), sA = 2 * sqrt(A) * al;
        set(A * ((A + 1) - (A - 1) * c + sA), 2 * A * ((A - 1) - (A + 1) * c), A * ((A + 1) - (A - 1) * c - sA),
            (A + 1) + (A - 1) * c + sA, -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - sA);
    }
    void highshelf(double f, double gdb, double sr) {
        double A = pow(10, gdb / 40), w = 2 * M_PI * f / sr, c = cos(w), al = sin(w) / 2 * sqrt(2.0), sA = 2 * sqrt(A) * al;
        set(A * ((A + 1) + (A - 1) * c + sA), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - sA),
            (A + 1) - (A - 1) * c + sA, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - sA);
    }
    double magDb(double f, double sr) const {  // gain at frequency f
        std::complex<double> z = std::polar(1.0, -2 * M_PI * f / sr), zz = z * z;
        return 20 * log10(std::abs((b0 + b1 * z + b2 * zz) / (1.0 + a1 * z + a2 * zz)));
    }
};

// Two second-order filters in a row. Usually a Linkwitz-Riley 4th order filter (two identical Butterworth stages: its
// low and high outputs are in phase and add up flat). The fold floor uses two of them for one steep 8th order
// Butterworth filter, or as a 4th order all-pass (see FilterKind).
// Butterworth 8 stage Qs: 1 / (2 sin((2k-1) pi / 16)); Butterworth 4: 1 / (2 sin((2k-1) pi / 8)).
const double BW8Q[4] = {0.50979558, 2.56291545, 0.60134489, 0.89997622}, BW4Q[2] = {0.54119610, 1.30656296};
struct LR4 {
    Biquad s1, s2;
    void lowpass(double f, double sr) { s1.lowpass(f, M_SQRT1_2, sr); s2 = s1; clear(); }
    void highpass(double f, double sr) { s1.highpass(f, M_SQRT1_2, sr); s2 = s1; clear(); }
    void bw8(bool high, int half, double f, double sr) {  // half 0 or 1 of a Butterworth 8th order filter
        if (high) { s1.highpass(f, BW8Q[2 * half], sr); s2.highpass(f, BW8Q[2 * half + 1], sr); }
        else { s1.lowpass(f, BW8Q[2 * half], sr); s2.lowpass(f, BW8Q[2 * half + 1], sr); }
        clear();
    }
    // All-pass with the phase of a Butterworth 8 split at f (exactly that of an LR8 split, within ~0.3 dB of a B8 one
    // where it matters), so a band that skipped the split stays in phase with one that went through it.
    void allpass8(double f, double sr) { s1.allpass(f, BW4Q[0], sr); s2.allpass(f, BW4Q[1], sr); clear(); }
    // Butterworth 4th order: its low and high sides add up to full power (for two halves that don't add in phase)
    void bw4(bool high, double f, double sr) {
        if (high) { s1.highpass(f, BW4Q[0], sr); s2.highpass(f, BW4Q[1], sr); }
        else { s1.lowpass(f, BW4Q[0], sr); s2.lowpass(f, BW4Q[1], sr); }
        clear();
    }
    void clear() { s1.clear(); s2.clear(); }
    inline float run(float x) { return s2.run(s1.run(x)); }
};
// One second-order filter for two channels side by side (the same filter on both), written so the compiler can run
// the two at once (SIMD). Double precision all the way.
struct Biquad2 {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1[2] = {0, 0}, z2[2] = {0, 0};
    void from(const Biquad &q) { b0 = q.b0; b1 = q.b1; b2 = q.b2; a1 = q.a1; a2 = q.a2; clear(); }
    void clear() { z1[0] = z1[1] = z2[0] = z2[1] = 0; }
    inline void run(double *v) {
        double y0 = b0 * v[0] + z1[0], y1 = b0 * v[1] + z1[1];
        z1[0] = b1 * v[0] - a1 * y0 + z2[0]; z1[1] = b1 * v[1] - a1 * y1 + z2[1];
        z2[0] = b2 * v[0] - a2 * y0; z2[1] = b2 * v[1] - a2 * y1;
        v[0] = y0; v[1] = y1;
    }
};

inline double lrLP(double f, double fc) { double x = f / fc; x *= x; x *= x; return 1.0 / (1.0 + x); }  // |LR4 low-pass|
inline double lrHP(double f, double fc) { double x = f / fc; x *= x; x *= x; return x / (1.0 + x); }    // |LR4 high-pass|
inline double bwLP8(double f, double fc) { double x = f / fc; x *= x; x *= x; x *= x; return 1.0 / sqrt(1.0 + x * x); }  // |Butterworth 8 low-pass|
inline double bwHP8(double f, double fc) { double x = f / fc; x *= x; x *= x; x *= x; return x / sqrt(1.0 + x * x); }    // |Butterworth 8 high-pass|
inline double bwLP4(double f, double fc) { double x = f / fc; x *= x; x *= x; return 1.0 / sqrt(1.0 + x * x); }  // |Butterworth 4 low-pass|
inline double bwHP4(double f, double fc) { double x = f / fc; x *= x; x *= x; return x / sqrt(1.0 + x * x); }    // |Butterworth 4 high-pass|

// One channel of sound kept by absolute sample number (power-of-two size, so the index wraps with a mask).
struct Ring {
    std::vector<float> d;
    int64_t mask = 0;
    void init(size_t n) { size_t s = 1; while (s < n) s <<= 1; d.assign(s, 0.0f); mask = (int64_t)s - 1; }
    inline float &operator[](int64_t i) { return d[(size_t)(i & mask)]; }
    void clear() { std::fill(d.begin(), d.end(), 0.0f); }
};

size_t pow2above(size_t n) { size_t s = 1; while (s < n) s <<= 1; return s; }

// ------------------------------------------------------------------------------------------------- portable FFT

#if !ADVANCED_VDSP
// FFT of n real samples (n a power of two) for the EQ's analysis, where Apple's Accelerate isn't there (Windows).
// The result is laid out like vDSP_fft_zrip's: re[k], im[k] (k = 1 .. n/2-1) hold 2 x the spectrum at bin k,
// re[0] holds 2 x bin 0 and im[0] holds 2 x bin n/2. Works in double precision. All tables are made in init, so
// forward makes no memory.
// How: the n real samples are read as n/2 complex ones (even samples real, odd samples imaginary), go through a plain
// radix-2 FFT, and the result is untangled into the spectrum of the real samples.
struct RealFFT {
    int n = 0, m = 0;               // real size, complex size (n/2)
    std::vector<int> rev;           // bit-reversed order for the m-point FFT
    std::vector<double> wr, wi;     // e^(-2 pi i j/m), j < m/2
    std::vector<double> ur, ui;     // e^(-2 pi i k/n), k < m (for untangling)
    std::vector<double> zr, zi;     // work space

    void init(int size) {
        n = size; m = size / 2;
        int bits = 0;
        while ((1 << bits) < m) bits++;
        rev.assign(m, 0);
        for (int i = 0; i < m; i++) {
            int r = 0;
            for (int b = 0; b < bits; b++) if (i & (1 << b)) r |= 1 << (bits - 1 - b);
            rev[i] = r;
        }
        wr.assign(m / 2, 0.0); wi.assign(m / 2, 0.0);
        for (int j = 0; j < m / 2; j++) { wr[j] = cos(2 * M_PI * j / m); wi[j] = -sin(2 * M_PI * j / m); }
        ur.assign(m, 0.0); ui.assign(m, 0.0);
        for (int k = 0; k < m; k++) { ur[k] = cos(2 * M_PI * k / n); ui[k] = -sin(2 * M_PI * k / n); }
        zr.assign(m, 0.0); zi.assign(m, 0.0);
    }

    void forward(const float *in, float *re, float *im) {
        for (int i = 0; i < m; i++) { zr[rev[i]] = in[2 * i]; zi[rev[i]] = in[2 * i + 1]; }
        for (int len = 2; len <= m; len <<= 1) {
            int half = len / 2, step = m / len;
            for (int s = 0; s < m; s += len)
                for (int j = 0; j < half; j++) {
                    double cr = wr[j * step], ci = wi[j * step];
                    int a = s + j, b = a + half;
                    double tr = zr[b] * cr - zi[b] * ci, ti = zr[b] * ci + zi[b] * cr;
                    zr[b] = zr[a] - tr; zi[b] = zi[a] - ti;
                    zr[a] += tr; zi[a] += ti;
                }
        }
        // Untangle: X[k] = E + e^(-2 pi i k/n) O, with E = (Z[k] + conj Z[m-k]) / 2 and O = (Z[k] - conj Z[m-k]) / 2i.
        re[0] = (float)(2 * (zr[0] + zi[0]));
        im[0] = (float)(2 * (zr[0] - zi[0]));
        for (int k = 1; k < m; k++) {
            double ar = zr[k], ai = zi[k], br = zr[m - k], bi = -zi[m - k];
            double er = 0.5 * (ar + br), ei = 0.5 * (ai + bi);
            double orr = 0.5 * (ai - bi), oi = -0.5 * (ar - br);
            re[k] = (float)(2 * (er + ur[k] * orr - ui[k] * oi));
            im[k] = (float)(2 * (ei + ur[k] * oi + ui[k] * orr));
        }
    }
};
#endif

// ------------------------------------------------------------------------------------------------- recipe

// What feeds a path: a sum of up to 3 "terms"; each term is the input through up to 3 filter pairs, times a gain.
// Example (balanced3 at +8): main = HP150(x) + LP35'(LP300(x)) (the fold floor's sub bass), fold = HP35'(LP300(x)).
const int MAXTERMS = 3, MAXF = 3;
// LR4: one Linkwitz-Riley 4th order filter. BW8A + BW8B: the two halves of one Butterworth 8th order filter (BW8A
// carries its whole gain in mag()). AP8: the all-pass of LR4::allpass8 (gain 1).
enum FilterKind { LR4F = 0, BW8A = 1, BW8B = 2, AP8 = 3 };
struct Term {
    float gain = 1;
    int nf = 0;                 // filters in the cascade (0 = the input itself)
    double fc[MAXF] = {};       // corner (Hz)
    bool hp[MAXF] = {};         // high-pass (else low-pass)
    int kind[MAXF] = {};        // FilterKind
    double mag(double f) const {
        double m = gain;
        for (int i = 0; i < nf; i++) {
            if (kind[i] == LR4F) m *= hp[i] ? lrHP(f, fc[i]) : lrLP(f, fc[i]);
            else if (kind[i] == BW8A) m *= hp[i] ? bwHP8(f, fc[i]) : bwLP8(f, fc[i]);
        }
        return m;
    }
};

struct PathSpec {
    double shift = 0;           // half-steps; 0 = not shifted (just delayed)
    float outW = 1;             // level at the output
    int nt = 0;
    Term t[MAXTERMS];
    bool coherent = false;      // terms are in phase (LR4 pair at one corner): they add as amplitudes, else as powers
    double outHP = 0;           // 8th-order high-pass on the path's output (Hz), 0 = none (balanced3: 30 Hz on the +4..+6 fold)
    double subHP = 0;           // 4th-order high-pass on the path's output (Hz), 0 = none (recipe 5: up to 40 Hz going down)
    Term &add(float gain) { Term &x = t[nt++]; x.gain = gain; return x; }
};
inline Term &filt(Term &x, double f, bool high, int kind) { x.fc[x.nf] = f; x.hp[x.nf] = high; x.kind[x.nf++] = kind; return x; }
inline Term &lp(Term &x, double f) { return filt(x, f, false, LR4F); }
inline Term &hp(Term &x, double f) { return filt(x, f, true, LR4F); }
inline Term &lp8(Term &x, double f) { return filt(filt(x, f, false, BW8A), f, false, BW8B); }  // steep Butterworth 8
inline Term &hp8(Term &x, double f) { return filt(filt(x, f, true, BW8A), f, true, BW8B); }
inline Term &ap8(Term &x, double f) { return filt(x, f, false, AP8); }

struct Spec {           // the recipe for one amount N
    double N = 0;
    int n = 0;          // paths (0 = the unprocessed input)
    PathSpec p[MAXPATHS];
    double air = 0;     // pitch-down: above this (Hz) the output is the unshifted input; 0 = none
    bool airBW = false; // the air split is a Butterworth 4 (flat power) instead of a Linkwitz-Riley 4 (-3 dB at the split)
};

// ------------------------------------------------------------------------------------------------- shifter pool

enum { SH_FRESH = 0, SH_IN_USE = 1, SH_DIRTY = 2 };
struct Shifter {
    std::unique_ptr<RubberBandStretcher> rb;
    std::atomic<int> state{SH_FRESH};
};

// ------------------------------------------------------------------------------------------------- chain

enum { C_FREE, C_WARMING, C_PREROLL, C_FADE_IN, C_ACTIVE };

struct Path {
    PathSpec spec;
    Shifter *sh = nullptr;   // null: not shifted (a plain delay)
    int64_t lag = 0;         // where the shifter puts input sample i in its output stream: i + lag (fresh shifter)
    int64_t produced = 0;    // samples in its output stream so far
    Ring ring[MAXCH];        // its output stream
    LR4 filt[MAXTERMS][MAXF][MAXCH];   // input filters, one set per term
    Biquad outF[4][MAXCH];             // output high-pass (4 Butterworth sections)
    Biquad subF[2][MAXCH];             // sub high-pass (2 Butterworth sections)
};

struct Chain {
    int state = C_FREE;
    Spec spec;
    Path path[MAXPATHS];
    LR4 airLP[MAXCH], airHP[MAXCH];
    // EQ filters with their gains (dB): applied now, moving toward target in small steps
    Biquad eq[MAXCH][NEQ];
    double eqApplied[NEQ] = {}, eqInc[NEQ] = {};
    int eqSteps = 0, eqCount = 0;
    bool eqFresh = true;
    int64_t h0 = 0;          // first input sample this chain was fed
    int64_t p = 0;           // next input sample to feed
    int64_t V = 0;           // its output is right for input samples >= h0 + V (shifters need a moment to start)
    int64_t phase = 0;       // samples spent in PREROLL or FADE_IN
    bool dry() const { return spec.n == 0; }
};

// ------------------------------------------------------------------------------------------------- tonal EQ

// Slow, gentle EQ that steers the output's long-term 1/3-octave spectrum toward the input's (hybrid mode of the
// research): the target compares the input with a PREDICTED output spectrum (input moved by the chain's shifts,
// with its bands and air), plus a slow correction (+-3 dB, 12 s) from the measured output for what the prediction
// misses. 10 minimum-phase filters, fitted by least squares. Zero delay.
// Recipe 5 makes it pitch-aware: per-direction target offsets and limits (the knobs below; all off for recipes 2-4).
const int NKNOT = 10;    // offset knots, one per octave: 25, 50, 100 .. 12800 Hz
const double OFF = -99;  // "knob off" for the limits below
struct TonalEQ {
    double sr = 48000, tau = 4, boost = 9, cut = 9, alpha = 1, lowcap = 6, midcap = 6, shelfLo = 44;
    double loF = 100, loCut = 15;        // balanced3: below 100 Hz the target is not smoothed and may cut up to 15 dB
    bool loUp = false;                   // ... also going up (recipe 3 = 2.0.0). Off: going up, the bass is treated like
                                         // the rest (smoothed over +-1 band, cuts up to 9 dB), so the EQ doesn't cut
                                         // bass notes just because the shift moved them to a band the original had empty
    // recipe 5 (see AdvancedTuning.h): predict counts edge bins like bandPowers; target offsets (dB) per knot for each
    // direction, full from |N| >= offN; going down, the largest boost below 70 Hz and the deepest cut of the 250 Hz
    // filter; going up, the deepest cut of the 500 Hz - 2 kHz filters and of everything from 7 kHz up.
    bool edgefix = false, offOn = false;
    double offUp[NKNOT] = {}, offDn[NKNOT] = {}, offN = 8;
    double lowcapDn = OFF, midcutDn = OFF, midcutUp = OFF, topcutUp = OFF;
    int smooth = 1, N = 16384, period = 2048;
#if ADVANCED_VDSP
    FFTSetup setup = nullptr; int log2n = 14;
#else
    RealFFT fft; int log2n = 14;
#endif
    std::vector<float> hann, tmp, re, im;
    std::vector<double> fcs, rbin, pref, pcur, pr, pc, pq, pqs, pcs, T, S, g, e;
    std::vector<double> D;               // checks only: the change each band wanted at the last fit, before any limits
    std::vector<int> b0, b1, bandOf, bandOf2;  // bandOf2: the second band of a bin on a band edge (else -1)
    std::vector<int> knotI; std::vector<double> knotF;  // per band: offset knot below it and how far toward the next
    std::vector<std::vector<double>> M;  // least-squares fit matrix (filters x bands)
    double eqf[NEQ];
    int64_t blocks = 0, blocks2 = 0;     // analyses so far; analyses since the slow correction was reset
    double a = 0;
    int gen = -1;                        // which chain the current prediction is for (see Engine::targetGen)
    // predict's weights depend only on the chain, not on the sound, so each bin's are worked out once per chain:
    // per path the weight, and the air band's gain; wGen = the chain (gen) they belong to, -1 = none yet.
    std::vector<double> wPath[MAXPATHS], wAir;
    std::vector<int> wGen;

    void setFilter(Biquad &b, int k, double gdb) const {
        if (k == 0) b.lowshelf(shelfLo, gdb, sr);
        else if (k == 9) b.highshelf(11300.0, gdb, sr);
        else b.peaking(eqf[k], 1.41, gdb, sr);
    }

    void init(double rate) {
        sr = rate;
        N = rate > 64000 ? 32768 : 16384;
        log2n = (int)lround(log2(N));
#if ADVANCED_VDSP
        setup = vDSP_create_fftsetup(log2n, kFFTRadix2);
#else
        fft.init(N);
#endif
        hann.resize(N); tmp.resize(N); re.resize(N / 2); im.resize(N / 2);
        for (int i = 0; i < N; i++) hann[i] = (float)(0.5 * (1 - cos(2 * M_PI * i / N)));
        for (int k = -16; k <= 12; k++) {
            double fc = 1000.0 * pow(10.0, k / 10.0); fcs.push_back(fc);
            b0.push_back(std::max(1, (int)floor(fc * pow(2, -1.0 / 6) * N / sr)));
            b1.push_back(std::max(b0.back() + 1, (int)ceil(fc * pow(2, 1.0 / 6) * N / sr)));
        }
        size_t nb = fcs.size();
        bandOf.assign(N / 2, -1);  // FFT bin -> 1/3-octave band (first match, as the test bench)
        bandOf2.assign(N / 2, -1);
        for (int i = 0; i < N / 2; i++)
            for (size_t j = 0; j < nb; j++)
                if (i >= b0[j] && i < b1[j]) { if (bandOf[i] < 0) bandOf[i] = (int)j; else { bandOf2[i] = (int)j; break; } }
        knotI.assign(nb, 0); knotF.assign(nb, 0.0);
        for (size_t j = 0; j < nb; j++) {  // knots at 25 x 2^i Hz: interpolate on a log scale, flat past the ends
            double x = std::max(0.0, std::min((double)NKNOT - 1, log2(fcs[j] / 25.0)));
            knotI[j] = std::min(NKNOT - 2, (int)x); knotF[j] = x - knotI[j];
        }
        rbin.assign(N / 2, 0.0);
        for (auto &w : wPath) w.assign(N / 2, 0.0);
        wAir.assign(N / 2, 0.0); wGen.assign(N / 2, -1);
        for (auto *v : {&pref, &pcur, &pr, &pc, &pq, &pqs, &pcs, &T, &S, &e, &D}) v->assign(nb, 0.0);
        g.assign(NEQ, 0.0);
        for (int k = 0; k < NEQ; k++) eqf[k] = 31.25 * pow(2.0, k);
        // how each filter at 12 dB shows up in each band; M = (A^T A + 0.05 I)^-1 A^T
        std::vector<std::vector<double>> A(nb, std::vector<double>(NEQ));
        for (int k = 0; k < NEQ; k++) { Biquad b; setFilter(b, k, 12.0); for (size_t j = 0; j < nb; j++) A[j][k] = b.magDb(fcs[j], sr) / 12.0; }
        std::vector<std::vector<double>> AtA(NEQ, std::vector<double>(NEQ, 0.0)), inv(NEQ, std::vector<double>(NEQ, 0.0));
        for (int x = 0; x < NEQ; x++) for (int y = 0; y < NEQ; y++) {
            for (size_t j = 0; j < nb; j++) AtA[x][y] += A[j][x] * A[j][y];
            if (x == y) AtA[x][y] += 0.05;
        }
        for (int i = 0; i < NEQ; i++) inv[i][i] = 1;
        for (int i = 0; i < NEQ; i++) {  // Gauss-Jordan
            int p = i; for (int r = i + 1; r < NEQ; r++) if (fabs(AtA[r][i]) > fabs(AtA[p][i])) p = r;
            std::swap(AtA[i], AtA[p]); std::swap(inv[i], inv[p]);
            double d = AtA[i][i]; for (int c = 0; c < NEQ; c++) { AtA[i][c] /= d; inv[i][c] /= d; }
            for (int r = 0; r < NEQ; r++) if (r != i) { double f = AtA[r][i]; for (int c = 0; c < NEQ; c++) { AtA[r][c] -= f * AtA[i][c]; inv[r][c] -= f * inv[i][c]; } }
        }
        M.assign(NEQ, std::vector<double>(nb, 0.0));
        for (int x = 0; x < NEQ; x++) for (size_t j = 0; j < nb; j++) for (int y = 0; y < NEQ; y++) M[x][j] += inv[x][y] * A[j][y];
    }
#if ADVANCED_VDSP
    ~TonalEQ() { if (setup) vDSP_destroy_fftsetup(setup); }
#endif

    void reset() {
        std::fill(rbin.begin(), rbin.end(), 0.0);
        for (auto *v : {&pref, &pcur, &pqs, &pcs}) std::fill(v->begin(), v->end(), 0.0);
        blocks = blocks2 = 0; gen = -1;
    }
    void resetCorrection() { std::fill(pqs.begin(), pqs.end(), 0.0); std::fill(pcs.begin(), pcs.end(), 0.0); blocks2 = 0; }

    // FFT of the last N samples of a ring ending at `end`; band powers into out (FFT left in re/im)
    void bandPowers(Ring &r, int64_t end, std::vector<double> &out) {
        // the ring holds at least N samples; they are read in two pieces where it wraps around
        const float *d = r.d.data(), *w = hann.data();
        float *x = tmp.data();
        size_t start = (size_t)((end - N) & r.mask), first = std::min((size_t)N, r.d.size() - start);
        for (size_t i = 0; i < first; i++) x[i] = d[start + i] * w[i];
        for (size_t i = first; i < (size_t)N; i++) x[i] = d[i - first] * w[i];
#if ADVANCED_VDSP
        DSPSplitComplex s{re.data(), im.data()};
        vDSP_ctoz((const DSPComplex *)tmp.data(), 2, &s, 1, N / 2);
        vDSP_fft_zrip(setup, &s, 1, log2n, FFT_FORWARD);
#else
        fft.forward(tmp.data(), re.data(), im.data());
#endif
        for (size_t j = 0; j < fcs.size(); j++) {
            double sum = 0;
            for (int k = b0[j]; k < b1[j] && k < N / 2; k++) sum += (double)re[k] * re[k] + (double)im[k] * im[k];
            out[j] = sum;
        }
    }
    inline void addAt(double fo, double p) {
        double kb = fo * N / sr;
        if (kb < 0 || kb >= N / 2) return;
        if (edgefix) {  // as bandPowers measures it: shared by the two nearest bins, an edge bin counts in both bands
            int i = (int)kb; double fr = kb - i;
            addBin(i, p * (1 - fr));
            if (i + 1 < N / 2) addBin(i + 1, p * fr);
            return;
        }
        int j = bandOf[(int)kb];
        if (j >= 0) pq[j] += p;
    }
    inline void addBin(int i, double p) {
        if (bandOf[i] >= 0) pq[bandOf[i]] += p;
        if (bandOf2[i] >= 0) pq[bandOf2[i]] += p;
    }
    // recipe 5: target offset (dB) for band j at amount N
    double offsetAt(int j, double N) const {
        const double *k = N > 0 ? offUp : offDn;
        double s = std::min(1.0, fabs(N) / offN);
        return s * (k[knotI[j]] * (1 - knotF[j]) + k[knotI[j] + 1] * knotF[j]);
    }
    // predicted output band powers of chain spec s (chain gen), bins [k0, k1): each input bin is moved by each path's
    // shift, weighted by that path's input filters (and output high-pass, and the air band's crossover)
    void predict(const Spec &s, int chainGen, int k0, int k1) {
        double ratio[MAXPATHS];
        for (int q = 0; q < s.n; q++) ratio[q] = pow(2.0, s.p[q].shift / 12.0);
        for (int k = std::max(1, k0); k < k1; k++) {
            double P = rbin[k];
            if (P <= 0) continue;
            double f = (double)k * sr / N;
            if (wGen[k] != chainGen) { weigh(s, ratio, k, f); wGen[k] = chainGen; }
            for (int q = 0; q < s.n; q++) addAt(f * ratio[q], P * wPath[q][k]);
            if (s.air > 0) addAt(f, P * wAir[k] * wAir[k]);
        }
    }
    void weigh(const Spec &s, const double *ratio, int k, double f) {
        for (int q = 0; q < s.n; q++) {
            const PathSpec &p = s.p[q];
            double pw = 0, amp = 0;
            for (int i = 0; i < p.nt; i++) { double m = p.t[i].mag(f); amp += m; pw += m * m; }
            if (p.coherent) pw = amp * amp;
            pw *= (double)p.outW * p.outW;
            double fo = f * ratio[q];
            if (s.air > 0) { double ga = s.airBW ? bwLP4(fo, s.air) : lrLP(fo, s.air); pw *= ga * ga; }
            if (p.outHP > 0) { double h = lrHP(fo, p.outHP); pw *= h * h * h * h; }  // 8th order = |LR4|^2
            if (p.subHP > 0) { double h = lrHP(fo, p.subHP); pw *= h * h; }          // 4th order = |LR4|
            wPath[q][k] = pw;
        }
        if (s.air > 0) wAir[k] = s.airBW ? bwHP4(f, s.air) : lrHP(f, s.air);
    }
};

// ------------------------------------------------------------------------------------------------- safety limiter

// Peak limiter at the very end, so the output never goes over the ceiling (-0.3 dBFS). Both channels get the same gain.
// It looks D samples (2 ms) ahead: the sound is delayed by D, and the gain for each sample is the average of the last
// D+1 "held" gains. Every one of those held values is <= the gain the delayed sample needs (each hold window contains
// that sample), so their average is too: no overs, and the gain slides down over 2 ms instead of jumping.
// Release: the held gain climbs back toward 1 with a 120 ms time constant (recipe 5: 25 ms after a short over of less
// than 5 ms, so single peaks don't pull the whole mix down for long). Under the ceiling it does nothing at all
// (gain exactly 1, the output is the input delayed by D).
struct Limiter {
    int nch = 2, D = 96, R = 97, pos = 0;
    double ceiling = 0.966, relCoef = 0.9998, r = 1, sum = 97;
    int64_t sinceOver = 1 << 30;
    // Optional faster release after a short over (a single peak): fastCoef after episodes shorter than fastMax frames.
    double sr = 48000, fastMs = 0, fastCoef = 0.9998;
    int64_t fastMax = 240, episode = 0;   // frames the current (or last) episode of overs lasted
    std::vector<float> delay[MAXCH];
    std::vector<double> need, held;   // gain each sample needs; held (released) gain, last D+1 of each
    bool enabled = true;
    double minGain = 1; long long limited = 0, limited01 = 0, total = 0, clamps = 0;  // for checks (limited01: > 0.1 dB)

    void init(double rate, int channels) {
        sr = rate; nch = channels;
        D = std::max(1, (int)lround(0.002 * sr)); R = D + 1;
        relCoef = exp(-1.0 / (0.120 * sr));
        fastMax = (int64_t)lround(0.005 * sr);
        setFast(fastMs);
        for (int c = 0; c < nch; c++) delay[c].assign(R, 0.0f);
        need.assign(R, 1.0); held.assign(R, 1.0);
        reset();
    }
    void setFast(double ms) { fastMs = ms; fastCoef = ms > 0 ? exp(-1.0 / (ms * 0.001 * sr)) : relCoef; }
    void reset() {
        for (int c = 0; c < nch; c++) std::fill(delay[c].begin(), delay[c].end(), 0.0f);
        std::fill(need.begin(), need.end(), 1.0); std::fill(held.begin(), held.end(), 1.0);
        r = 1; sum = R; pos = 0; sinceOver = 1 << 30; episode = 0;
    }
    // v: one sample per channel, replaced by the limited sample from D samples ago
    inline void run(float *v) {
        double peak = 0;
        for (int c = 0; c < nch; c++) peak = std::max(peak, (double)fabsf(v[c]));
        // aim a hair (0.00003 dB) under the ceiling, so float rounding of the result never lands above it
        double g = (enabled && peak > ceiling) ? ceiling * (1.0 - 4e-6) / peak : 1.0;
        need[pos] = g;
        if (g < 1.0 && sinceOver > D) episode = 0;  // a new episode of overs starts
        sinceOver = g < 1.0 ? 0 : sinceOver + 1;
        double m = 1.0;  // lowest need in the last D+1 samples (only searched while an over is in the window)
        if (sinceOver <= D) { for (int k = 0; k < R; k++) m = std::min(m, need[k]); episode++; }
        if (m < r) r = m;                    // drops at once (the averaging below makes it a 2 ms slide)
        else {
            r = m - (m - r) * (episode < fastMax ? fastCoef : relCoef);  // climbs back slowly (faster after a short over)
            if (m == 1.0 && r > 1.0 - 1e-7) r = 1.0;
        }
        sum += r - held[pos]; held[pos] = r;
        double gain = std::min(1.0, sum / R);
        int out = pos + 1 == R ? 0 : pos + 1;  // the oldest slot holds the sample from D samples ago
        for (int c = 0; c < nch; c++) {
            delay[c][pos] = v[c];
            float y = delay[c][out];
            if (gain < 1.0) {
                y = (float)(y * gain);
                if (y > ceiling || y < -ceiling) { y = y > 0 ? (float)ceiling : (float)-ceiling; clamps++; }  // rounding guard
            }
            v[c] = y;
        }
        total++;
        if (gain < 1.0) { limited++; minGain = std::min(minGain, gain); if (gain < 0.98855) limited01++; }
        if (++pos == R) {  // re-add the held gains exactly once per lap, so rounding never builds up
            pos = 0;
            sum = 0; for (int k = 0; k < R; k++) sum += held[k];
        }
    }
};

// ------------------------------------------------------------------------------------------------- bass / treble

// The app's bass and treble setting (advanced_set_tone): a low shelf at 150 Hz and a high shelf at 5 kHz on each
// channel, on the finished sound just before the safety limiter. The gains glide 0.25 dB per 32 samples, so moving
// them doesn't click. While both are 0 and staying there it is skipped, so the sound is exactly as without it.
struct ToneStage {
    double sr = 48000, loHz = 150, hiHz = 5000;
    double wantB = 0, wantT = 0, curB = 0, curT = 0;  // bass, treble (dB): asked for, applied now
    int nch = 2, count = 0;                           // count: samples into the current 32-sample step
    int64_t idle = 0, idleLimit = 1;                  // samples run flat since both reached 0; then it stops
    Biquad lo[MAXCH], hi[MAXCH];

    void init(double rate, int channels) {
        sr = rate; nch = channels;
        hiHz = std::min(5000.0, 0.45 * rate);
        idleLimit = idle = (int64_t)(0.05 * rate);  // 50 ms: the filters' last ring-out has died away
        setFilters();
    }
    void setFilters() { for (int c = 0; c < nch; c++) { lo[c].lowshelf(loHz, curB, sr); hi[c].highshelf(hiHz, curT, sr); } }
    void clear() { for (int c = 0; c < nch; c++) { lo[c].clear(); hi[c].clear(); } count = 0; }
    bool flat() const { return wantB == 0 && wantT == 0 && curB == 0 && curT == 0; }
    static double toward(double cur, double want) { return fabs(want - cur) <= 0.25 ? want : cur + (want > cur ? 0.25 : -0.25); }

    void run(std::vector<float> *x, int m) {
        if (flat() && idle >= idleLimit) return;
        int i = 0;
        while (i < m) {
            if (count == 0 && (curB != wantB || curT != wantT)) {
                curB = toward(curB, wantB); curT = toward(curT, wantT);
                setFilters();
            }
            int n = std::min(m - i, 32 - count);
            for (int c = 0; c < nch; c++) {
                float *s = x[c].data() + i;
                for (int k = 0; k < n; k++) s[k] = hi[c].run(lo[c].run(s[k]));
            }
            count = (count + n) & 31;
            i += n;
        }
        if (!flat()) idle = 0;
        else if ((idle += m) >= idleLimit) clear();
    }
};

// ------------------------------------------------------------------------------------------------- auto EQ

// "Auto EQ" (advanced_set_auto_eq): five sections, Sub (20-80 Hz), Bass (80-250), Mids (250-2k), Highs (2k-8k) and
// Air (8k and up), whose levels follow the ORIGINAL song's balance as the song plays, whatever the amount. It only
// looks at loudness: a section that comes out too loud is pulled down, one that comes out too quiet is lifted.
// - Split: Linkwitz-Riley 4th order crossovers in a tree. The lower sections go through the all-pass of each higher
//   crossover, so all five stay in phase and add back up flat (only the phase turns, like one more filter). Done as
//   y = AP4(AP3(AP2(g1 b1) + g2 b2) + g3 b3) + g4 b4 + g5 b5, so 3 all-passes instead of 6. IIR only: no delay.
// - Measuring, every SB samples: each section's level over the last `window` (1 s) of the sound coming in
//   (mono mix) and of the ORIGINAL input at the same moment (the history ring, read at the chain's delay L).
// - Target per section: the original's share (section minus total, dB) applied to this sound's total. The totals are
//   weighted like a loudness meter (K-weighting at each section's middle), so the loudness heard stays and only the
//   balance moves; the common level is solved again after the +-range limit. A section quiet in both (below `floor`)
//   goes to 0 dB.
// - Moves: a cut follows within `attack` (300 ms), a lift within `release` (1.5 s), smoothed in dB once per SB block;
//   the gain itself ramps sample by sample across the next block, so it never steps. The manual offsets (-12..+12 dB)
//   glide 0.25 dB per 32 samples, are added on top, and the sum is held within +-15 dB.
// - On / off: fades between the untouched sound and the stage's output over 50 ms (the split turns the phase, so a
//   hard switch would click). Off with all offsets 0 (the default) and that fade done, it is skipped: the output is
//   exactly as without it.
// - Readout (advanced_get_auto_eq): written once per SB block through a sequence lock of atomics, so another thread
//   can read it without the sound thread ever waiting.
const int AEQB = 5;            // sections
const double AEQ_NONE = -120;  // readout level while the stage is off, or for a silent section (dBFS)
const double AEQ_MAX = 15;     // largest gain, automatic + offset (dB)

struct AeqReadout {
    std::atomic<uint32_t> seq{0};
    std::atomic<double> autoDb[AEQB], levelDb[AEQB];
    AeqReadout() { for (int k = 0; k < AEQB; k++) { autoDb[k].store(0.0); levelDb[k].store(AEQ_NONE); } }
    // sound thread only
    void write(const double *a, const double *l) {
        uint32_t s = seq.load(std::memory_order_relaxed);
        seq.store(s + 1, std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_release);
        for (int k = 0; k < AEQB; k++) {
            autoDb[k].store(a[k], std::memory_order_relaxed);
            levelDb[k].store(l[k], std::memory_order_relaxed);
        }
        seq.store(s + 2, std::memory_order_release);
    }
    // any thread; retries while a write is halfway (a write takes nanoseconds, so it gives up after a few tries)
    void read(double *a, double *l) const {
        double ra[AEQB], rl[AEQB];
        for (int tries = 0; tries < 100; tries++) {
            uint32_t s1 = seq.load(std::memory_order_acquire);
            for (int k = 0; k < AEQB; k++) {
                ra[k] = autoDb[k].load(std::memory_order_relaxed);
                rl[k] = levelDb[k].load(std::memory_order_relaxed);
            }
            std::atomic_thread_fence(std::memory_order_acquire);
            if (!(s1 & 1) && seq.load(std::memory_order_relaxed) == s1) break;
        }
        for (int k = 0; k < AEQB; k++) { if (a) a[k] = ra[k]; if (l) l[k] = rl[k]; }
    }
};

struct AutoEQ5 {
    double sr = 48000; int nch = 2, SB = 256;
    // settings (advanced_set_auto_eq, advanced_tune)
    bool on = false;
    double want[AEQB] = {};                         // manual offsets asked for (dB)
    double range = 8, attackMs = 300, releaseMs = 1500, windowMs = 1000, floorDb = -60;
    double fc[AEQB - 1] = {80, 250, 2000, 8000};    // crossovers (Hz)
    bool weighted = true;                           // totals weighted like a loudness meter (else plain power)
    // the split: the sound (per channel) and the original (mono, measured only)
    // Each crossover: low = LR4 low-pass (two Butterworth sections), high = all-pass - low (an LR4 pair adds up to
    // that all-pass exactly, so this is the LR4 high-pass for one filter instead of two). Both channels side by side.
    Biquad2 lo1[AEQB - 1], lo2[AEQB - 1], xap[AEQB - 1];
    Biquad2 ap[AEQB - 1];                           // all-pass of crossovers 2..4 on the lower sections (0 unused)
    Biquad refLo1[AEQB - 1], refLo2[AEQB - 1], refAp[AEQB - 1];  // the same split for the original (mono)
    double lowHz = 20;                              // Sub is measured from here up (what is below can't be heard)
    Biquad subIn, subOut;                           // that high-pass, on the measured Sub only (original, sound)
    double weight[AEQB] = {1, 1, 1, 1, 1};          // loudness weight of each section (power)
    double aAtt = 0, aRel = 0;                      // smoothing per block
    // state
    bool running = false;
    double mix = 0, mixStep = 1;                    // 0 = the untouched sound, 1 = the stage's output
    double autoDb[AEQB] = {}, offDb[AEQB] = {};     // automatic gain and manual offset now (dB)
    double balDb[AEQB] = {};                        // the automatic gain before its level is taken back out (dB)
    double keepDb = 0;                              // that level (dB, smoothed)
    bool keep = true;                               // take that level back out (tune "aeqkeep")
    double g[AEQB] = {}, gTo[AEQB] = {}, gInc[AEQB] = {};  // gain applied (linear), where it ramps to, step per sample
    int rampLeft = 0;
    double eIn[AEQB] = {}, eOut[AEQB] = {}; int eN = 0;    // this block: sums of squares, samples
    std::vector<double> wIn[AEQB], wOut[AEQB];      // mean square of each of the last blocks (a ring)
    double sIn[AEQB] = {}, sOut[AEQB] = {};         // their sums
    int nWin = 75, head = 0, filled = 0;
    double pIn[AEQB] = {}, pOut[AEQB] = {};         // window means at the last analysis
    AeqReadout readout;

    void init(double rate, int channels, int block) {
        sr = rate; nch = channels; SB = block;
        mixStep = 1.0 / (0.050 * sr);
        size_t cap = (size_t)ceil(5.0 * sr / SB) + 1;  // room for a 5 s window
        for (int k = 0; k < AEQB; k++) { wIn[k].assign(cap, 0.0); wOut[k].assign(cap, 0.0); }
        setWindow(windowMs);
        setTimes();
        design();
        stop();
    }
    bool engaged() const {
        if (on) return true;
        for (int k = 0; k < AEQB; k++) if (want[k] != 0) return true;
        return false;
    }
    bool active() const { return running || engaged(); }

    void setTimes() {
        aAtt = exp(-SB / (std::max(1.0, attackMs) * 0.001 * sr));
        aRel = exp(-SB / (std::max(1.0, releaseMs) * 0.001 * sr));
    }
    void setWindow(double ms) {
        windowMs = std::max(1000.0 * SB / sr, std::min(5000.0, ms));
        nWin = std::max(1, std::min((int)wIn[0].size(), (int)lround(windowMs * 0.001 * sr / SB)));
        clearWindow();
    }
    void clearWindow() {
        for (int k = 0; k < AEQB; k++) {
            std::fill(wIn[k].begin(), wIn[k].end(), 0.0); std::fill(wOut[k].begin(), wOut[k].end(), 0.0);
            sIn[k] = sOut[k] = pIn[k] = pOut[k] = 0;
        }
        head = filled = 0;
    }
    void design() {
        // corners: under 0.45 x the sample rate, each at least a third of an octave above the one below
        for (int k = 0; k < AEQB - 1; k++) fc[k] = std::max(10.0, std::min(0.45 * sr, fc[k]));
        for (int k = AEQB - 2; k > 0; k--) fc[k - 1] = std::min(fc[k - 1], fc[k] / 1.26);
        for (int k = 0; k < AEQB - 1; k++) {
            Biquad l, a;
            l.lowpass(fc[k], M_SQRT1_2, sr);
            a.allpass(fc[k], M_SQRT1_2, sr);  // = LR4 low + LR4 high at this corner
            lo1[k].from(l); lo2[k].from(l); xap[k].from(a); ap[k].from(a);
            refLo1[k] = refLo2[k] = l; refAp[k] = a;
        }
        lowHz = std::max(0.0, std::min(lowHz, fc[0] / 2));
        if (lowHz > 0) { subIn.highpass(lowHz, M_SQRT1_2, sr); subOut.highpass(lowHz, M_SQRT1_2, sr); }
        else { subIn = Biquad(); subOut = Biquad(); }
        subIn.clear(); subOut.clear();
        // loudness weights: the K-weighting of BS.1770 (high shelf + high-pass) at each section's middle
        Biquad k1, k2;
        double K = tan(M_PI * 1681.974450955533 / sr), Q = 0.7071752369554196, Vh = pow(10, 3.999843853973347 / 20);
        double Vb = pow(Vh, 0.4996667741545416);
        k1.set(Vh + Vb * K / Q + K * K, 2 * (K * K - Vh), Vh - Vb * K / Q + K * K, 1 + K / Q + K * K, 2 * (K * K - 1), 1 - K / Q + K * K);
        K = tan(M_PI * 38.13547087602444 / sr); Q = 0.5003270373238773;
        k2.set(1, -2, 1, 1 + K / Q + K * K, 2 * (K * K - 1), 1 - K / Q + K * K);
        double edge[AEQB + 1] = {lowHz > 0 ? lowHz : 20, fc[0], fc[1], fc[2], fc[3], std::max(fc[3] * 1.5, std::min(16000.0, 0.45 * sr))};
        for (int k = 0; k < AEQB; k++) {
            double f = sqrt(edge[k] * edge[k + 1]);
            weight[k] = weighted ? pow(10.0, (k1.magDb(f, sr) + k2.magDb(f, sr)) / 10) : 1.0;
        }
    }
    // Back to the start (off, untouched, 0 dB); the settings stay.
    void stop() {
        running = false; mix = 0; rampLeft = 0; eN = 0; keepDb = 0;
        for (int k = 0; k < AEQB - 1; k++) {
            lo1[k].clear(); lo2[k].clear(); xap[k].clear(); ap[k].clear();
            refLo1[k].clear(); refLo2[k].clear(); refAp[k].clear();
        }
        subIn.clear(); subOut.clear();
        double none[AEQB];
        for (int k = 0; k < AEQB; k++) { autoDb[k] = balDb[k] = offDb[k] = 0; g[k] = gTo[k] = 1; gInc[k] = 0; eIn[k] = eOut[k] = 0; none[k] = AEQ_NONE; }
        clearWindow();
        readout.write(autoDb, none);
    }

    // x: the sound (per channel, m samples), changed in place. ref: the original at the same moment (mono).
    // blockEnd: this call ends an SB block (time for an analysis).
    void run(std::vector<float> *x, const float *ref, int m, bool blockEnd) {
        bool eng = engaged();
        if (!running) {
            if (!eng) return;  // off: skipped, the sound stays exactly as it was
            running = true;
        }
        bool two = nch > 1;
        float *x0 = x[0].data(), *x1 = two ? x[1].data() : nullptr;
        for (int i = 0; i < m; i++) {
            // the original's sections (measured only)
            double r[AEQB], h = ref[i];
            for (int k = 0; k < AEQB - 1; k++) { r[k] = refLo2[k].runD(refLo1[k].runD(h)); h = refAp[k].runD(h) - r[k]; }
            r[AEQB - 1] = h;
            r[0] = subIn.runD(r[0]);
            for (int k = 0; k < AEQB; k++) eIn[k] += r[k] * r[k];
            if (rampLeft > 0) {
                if (--rampLeft == 0) for (int k = 0; k < AEQB; k++) g[k] = gTo[k];
                else for (int k = 0; k < AEQB; k++) g[k] += gInc[k];
            }
            mix = eng ? std::min(1.0, mix + mixStep) : std::max(0.0, mix - mixStep);
            // the sound's sections, both channels at once
            double v[2] = {x0[i], two ? x1[i] : 0.0}, b[AEQB][2], hh[2] = {v[0], v[1]};
            for (int k = 0; k < AEQB - 1; k++) {
                double l[2] = {hh[0], hh[1]}, a[2] = {hh[0], hh[1]};
                lo1[k].run(l); lo2[k].run(l); xap[k].run(a);
                b[k][0] = l[0]; b[k][1] = l[1];
                hh[0] = a[0] - l[0]; hh[1] = a[1] - l[1];
            }
            b[AEQB - 1][0] = hh[0]; b[AEQB - 1][1] = hh[1];
            double mono[AEQB];
            for (int k = 0; k < AEQB; k++) mono[k] = two ? 0.5 * (b[k][0] + b[k][1]) : b[k][0];
            mono[0] = subOut.runD(mono[0]);
            for (int k = 0; k < AEQB; k++) eOut[k] += mono[k] * mono[k];
            // gains, the lower sections through the higher crossovers' all-passes so all five stay in phase
            double s[2] = {g[0] * b[0][0], g[0] * b[0][1]};
            for (int k = 1; k < AEQB - 1; k++) { ap[k].run(s); s[0] += g[k] * b[k][0]; s[1] += g[k] * b[k][1]; }
            s[0] += g[AEQB - 1] * b[AEQB - 1][0]; s[1] += g[AEQB - 1] * b[AEQB - 1][1];
            if (mix < 1.0) { s[0] = v[0] + mix * (s[0] - v[0]); s[1] = v[1] + mix * (s[1] - v[1]); }
            x0[i] = (float)s[0];
            if (two) x1[i] = (float)s[1];
        }
        eN += m;
        if (blockEnd) { analyze(eng); flushTiny(); }
        if (!eng && mix <= 0.0) stop();  // faded out: from now on skipped
    }

    // Filter memories that have died away to almost nothing (under 1e-20, -400 dB) are set to exactly 0, once per
    // block. In digital silence they would otherwise sink into "denormal" numbers, which Intel and AMD processors
    // handle many times slower (measured: up to 100 ms for one 512-sample call on an Intel build). A block can't take
    // them from 1e-20 down to that range, and the sound is not changed in any way that can be heard.
    static void flush(double &z) { if (std::fabs(z) < 1e-20) z = 0; }
    static void flush(Biquad &q) { flush(q.z1); flush(q.z2); }
    static void flush(Biquad2 &q) { flush(q.z1[0]); flush(q.z1[1]); flush(q.z2[0]); flush(q.z2[1]); }
    void flushTiny() {
        for (int k = 0; k < AEQB - 1; k++) {
            flush(lo1[k]); flush(lo2[k]); flush(xap[k]); flush(ap[k]);
            flush(refLo1[k]); flush(refLo2[k]); flush(refAp[k]);
        }
        flush(subIn); flush(subOut);
    }

    // the change each section needs (dB) so its share of the total is the original's (all 0 while too quiet to tell)
    void targets(double *tgt) const {
        double inDb[AEQB], outDb[AEQB], tin = 0, tout = 0, win = 0, wout = 0;
        bool act[AEQB];
        for (int k = 0; k < AEQB; k++) {
            inDb[k] = 10 * log10(pIn[k] + 1e-30) + 3.0103;  // dBFS: a full-scale sine is 0
            outDb[k] = 10 * log10(pOut[k] + 1e-30) + 3.0103;
            act[k] = inDb[k] >= floorDb || outDb[k] >= floorDb;
            tin += pIn[k]; tout += pOut[k]; win += weight[k] * pIn[k]; wout += weight[k] * pOut[k];
        }
        if (10 * log10(tin + 1e-30) + 3.0103 < floorDb || 10 * log10(tout + 1e-30) + 3.0103 < floorDb) return;
        // common level: keeps the weighted total; solved again after the limit (a few steps, never overshoots)
        double off = 10 * log10(win / wout);
        for (int it = 0; it < 4; it++) {
            double now = 0;
            for (int k = 0; k < AEQB; k++) {
                double d = act[k] ? std::max(-range, std::min(range, inDb[k] - outDb[k] - off)) : 0.0;
                now += weight[k] * pOut[k] * pow(10.0, d / 10);
            }
            off += 10 * log10(now / wout);
        }
        for (int k = 0; k < AEQB; k++) tgt[k] = act[k] ? std::max(-range, std::min(range, inDb[k] - outDb[k] - off)) : 0.0;
    }

    void analyze(bool eng) {
        int n = std::max(1, eN);
        for (int k = 0; k < AEQB; k++) {
            double mi = eIn[k] / n, mo = eOut[k] / n;
            sIn[k] += mi - wIn[k][head]; wIn[k][head] = mi;
            sOut[k] += mo - wOut[k][head]; wOut[k][head] = mo;
            eIn[k] = eOut[k] = 0;
        }
        eN = 0;
        if (++head == nWin) {  // once per lap, add the window up again so rounding never builds up
            head = 0;
            for (int k = 0; k < AEQB; k++) {
                sIn[k] = sOut[k] = 0;
                for (int j = 0; j < nWin; j++) { sIn[k] += wIn[k][j]; sOut[k] += wOut[k][j]; }
            }
        }
        if (filled < nWin) filled++;
        for (int k = 0; k < AEQB; k++) { pIn[k] = std::max(0.0, sIn[k] / filled); pOut[k] = std::max(0.0, sOut[k] / filled); }
        double tgt[AEQB] = {};
        if (on && filled * 4 >= nWin) targets(tgt);  // a quarter of the window heard first; too quiet: all 0
        for (int k = 0; k < AEQB; k++) {
            balDb[k] = tgt[k] + (balDb[k] - tgt[k]) * (tgt[k] < balDb[k] ? aAtt : aRel);
            if (fabs(balDb[k] - tgt[k]) < 1e-4) balDb[k] = tgt[k];
        }
        // the smoothing follows cuts faster than lifts, so on its own it would turn the whole sound down: take out
        // the level change it makes (weighted like the targets, smoothed like a cut), so only the balance moves
        double c = 0;
        if (keep) {
            double now = 0, before = 0;
            for (int k = 0; k < AEQB; k++) { now += weight[k] * pOut[k] * pow(10.0, balDb[k] / 10); before += weight[k] * pOut[k]; }
            if (before > 0 && now > 0) c = 10 * log10(now / before);
        }
        keepDb = c + (keepDb - c) * aAtt;
        if (fabs(keepDb - c) < 1e-4) keepDb = c;
        double step = 0.25 * SB / 32, lv[AEQB];
        for (int k = 0; k < AEQB; k++) {
            autoDb[k] = std::max(-range, std::min(range, balDb[k] - keepDb));
            double w = eng ? want[k] : 0.0;
            offDb[k] += std::max(-step, std::min(step, w - offDb[k]));
            double db = std::max(-AEQ_MAX, std::min(AEQ_MAX, autoDb[k] + offDb[k]));
            gTo[k] = pow(10.0, db / 20);
            gInc[k] = (gTo[k] - g[k]) / SB;
            lv[k] = pOut[k] > 0 ? std::max(AEQ_NONE, 10 * log10(pOut[k]) + 3.0103 + db) : AEQ_NONE;
        }
        rampLeft = SB;
        readout.write(autoDb, lv);
    }
};

// ------------------------------------------------------------------------------------------------- engine

struct Engine {
    double sr; int nch, maxFrames, flags;
    int L = 0;            // total delay (frames), fixed
    int W2 = 2048;        // half of Rubber Band's analysis window at this rate
    int SB = 256;         // slice size for spreading the EQ work
    int PIECE = 512;      // largest piece handed to a shifter at once
    double range = 24;
    // tunables (see AdvancedTuning.h)
    int recipe = 5, fold2 = 1, floor2 = 1; double airMin = 7000; int catchup = 2; double fadeMs = 80, foldStart = 3, foldFull = 7;
    double floorHz = 45, floorEndHz = 35, floor2Hz = 35, floorOut = 30;
    double subHz = 0;     // going down: high-pass on the shifted sound (Hz), 0 = none
    bool airBW = false;   // going down: the air split is a Butterworth 4 (flat power)
    double guardMax = 0, guardDb = 0;  // headroom guard: trims the bass filters' boost while the limiter works (max dB)
    long long guardLast = 0;           // limiter frames > 0.1 dB at the last EQ fit
    int64_t fadeLen = 3840, prerollLen = 1024;

    std::vector<std::unique_ptr<Shifter>> pool;
    std::thread worker;
    std::atomic<bool> quit{false};
#if defined(__APPLE__)
    // Wakes the helper when a shifter is let go of (signalling never waits), so it sleeps the rest of the time.
    dispatch_semaphore_t tidyWake = dispatch_semaphore_create(0);
#endif

    Ring hist[MAXCH], keepR[MAXCH], cur;   // input minus keep; keep; measured output (mono, for the EQ)
    int64_t t = 0, tStart = 0;             // samples processed; where the sound history starts (after a reset)
    Chain chains[2];
    int active = 0, next = -1;             // the chain being heard, and the one getting ready (or -1)
    double wantN = 0;                      // newest amount asked for
    bool pending = false;
    bool equalPower = true;                // crossfade law for the current fade
    int targetGen = 0;                     // changes whenever the EQ's target chain changes
    TonalEQ eq;
    Limiter lim;                           // safety limiter at the very end (adds its 2 ms look-ahead to the delay)
    ToneStage tone;                        // bass / treble, just before the limiter
    AutoEQ5 aeq;                           // Auto EQ, just before bass / treble (off by default: skipped)
    long long underruns = 0, switches = 0;
    float keepG = 0, keepStep = 1;          // keep fade-in: level now, step per sample
    int64_t keepIdle = 0, keepIdleLimit = 1; // samples since keep was last non-zero; after 0.25 s it counts as off

    // scratch (made once)
    std::vector<float> xin[MAXCH], tmpT[MAXCH], pin[MAXCH], rbOut[MAXCH], acc[MAXCH], sum[MAXCH], pre[MAXCH], curMono, gain, aeqRef;

    Engine(double rate, int channels, int maxF, int fl) : sr(rate), nch(channels), maxFrames(maxF), flags(fl) {}

    // The settings of a recipe (see "recipe" in AdvancedTuning.h). Recipes 2-4 leave every recipe 5 knob off.
    void applyRecipe(int r) {
        recipe = r;
        if (r == 2) { eq.loF = 0; eq.loCut = 9; } else { eq.loF = 100; eq.loCut = 15; }
        eq.loUp = r <= 3;
        floorHz = r >= 4 ? 45 : 35;
        bool five = r >= 5;
        eq.edgefix = false;
        eq.offOn = false;
        for (int i = 0; i < NKNOT; i++) eq.offUp[i] = eq.offDn[i] = 0;
        eq.offN = 8;
        eq.lowcapDn = eq.midcutDn = eq.midcutUp = eq.topcutUp = OFF;
        subHz = 0; airBW = false; guardMax = guardDb = 0;
        lim.setFast(0);
        if (!five) return;
        // recipe 5: the pitch-aware tone fix (values from the tuning in research/advanced/tone, see AdvancedTuning.h)
        eq.edgefix = true;
        eq.lowcapDn = 3; eq.midcutDn = 9; eq.midcutUp = 8; eq.topcutUp = 3;
        eq.offDn[2] = 1; eq.offDn[3] = 0.5; eq.offDn[5] = -0.5; eq.offDn[6] = -0.5;  // 100, 200, 800, 1600 Hz
        eq.offUp[5] = -0.5; eq.offUp[6] = -0.5;                                     // 800, 1600 Hz
        eq.offOn = true;
        subHz = 40; airBW = true;
        lim.setFast(25);
    }

    bool setup() {
        applyRecipe(recipe);
        range = (flags & ADVANCED_RANGE_12) ? 12 : 24;
        bool high = sr > 64000;
        SB = high ? 512 : 256;
        PIECE = high ? 1024 : 512;
        fadeLen = (int64_t)lround(fadeMs * 0.001 * sr);
        prerollLen = (int64_t)lround(0.0213 * sr);
        keepStep = (float)(1.0 / (0.030 * sr));
        keepIdleLimit = keepIdle = (int64_t)(0.25 * sr);
        lim.init(sr, nch);
        tone.init(sr, nch);
        // two chains (the one heard and the next) of up to 3 shifters each, plus one spare while the helper resets
        // used ones. About 4.5 MB each at 48 kHz, 8 MB at 96 kHz.
        int poolSize = 2 * MAXPATHS + 1;
        for (int i = 0; i < poolSize; i++) {
            auto s = std::make_unique<Shifter>();
            s->rb.reset(new RubberBandStretcher((size_t)lround(sr), nch, RBOPTS, 1.0, 1.0));
            s->rb->setMaxProcessSize(1024);
            pool.push_back(std::move(s));
        }
        W2 = (int)pool[0]->rb->getStartDelay();  // half window at pitch 1.0 (2048 at 44.1/48 kHz, 4096 at 96 kHz)
        // Fixed delay: the worst fresh shifter over the whole range (measured with rbprobe: "fed minus retrieved" at worst,
        // plus where it places the sound; 5.09 x W2 at +-24, 3.06 x W2 at +-12), plus 1/8 W2 margin.
        L = (int)ceil((range > 12 ? 5.1 : 3.06) * W2) + W2 / 8;
        prewarm();
        size_t vmax = (size_t)(range > 12 ? 3 * W2 : W2) + (size_t)(1.5 * W2);
        size_t histSize = pow2above(std::max<size_t>(L + vmax + maxFrames + 4 * SB, 16384 * (high ? 2 : 1) + maxFrames + 4 * SB));
        if (nch > 1) refRing.init(histSize);
        for (int c = 0; c < nch; c++) {
            hist[c].init(histSize);
            keepR[c].init(L + maxFrames + 2 * SB);
            xin[c].assign(PIECE, 0.0f); pin[c].assign(PIECE, 0.0f); rbOut[c].assign(4096, 0.0f);
            tmpT[c].assign(PIECE, 0.0f);
            acc[c].assign(SB, 0.0f); sum[c].assign(SB, 0.0f); pre[c].assign(SB, 0.0f);
            for (auto &ch : chains) for (auto &p : ch.path) p.ring[c].init(L + maxFrames + 4096);
        }
        curMono.assign(SB, 0.0f); gain.assign(SB, 0.0f); aeqRef.assign(SB, 0.0f);
        aeq.init(sr, nch, SB);
        eq.init(sr);
        eq.period = 8 * SB;
        cur.init(eq.N + 2 * SB);
        chains[0].state = C_ACTIVE;  // starts with the unprocessed input (N = 0)
        worker = std::thread([this] { tidyLoop(); });
        return true;
    }

    // Run every shifter once at a pitch up and a pitch down, so any memory Rubber Band makes on first use is made now.
    void prewarm() {
        std::vector<float> z(1024);
        uint32_t seed = 1;
        for (auto &v : z) { seed = seed * 1664525u + 1013904223u; v = ((seed >> 9) / 8388608.0f - 1.0f) * 0.01f; }
        const float *ip[MAXCH] = {z.data(), z.data()};
        std::vector<float> o0(8192), o1(8192);
        float *op[MAXCH] = {o0.data(), o1.data()};
        for (auto &s : pool) {
            for (double sc : {1.5, 0.7}) {
                s->rb->setPitchScale(sc);
                for (int k = 0; k < 6; k++) { s->rb->process(ip, 1024, false); int a; while ((a = s->rb->available()) > 0) s->rb->retrieve(op, std::min(a, 8192)); }
            }
            s->rb->reset();
            s->rb->setPitchScale(1.0);
        }
    }

    // Helper thread: resets used shifters so they are fresh again. It only touches shifters marked DIRTY,
    // which the sound thread has let go of.
    void tidyLoop() {
        while (!quit.load(std::memory_order_acquire)) {
            for (auto &s : pool)
                if (s->state.load(std::memory_order_acquire) == SH_DIRTY) {
                    s->rb->reset();
                    s->state.store(SH_FRESH, std::memory_order_release);
                }
#if defined(__APPLE__)
            dispatch_semaphore_wait(tidyWake, DISPATCH_TIME_FOREVER);
#else
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
#endif
        }
    }

    ~Engine() {
        quit.store(true, std::memory_order_release);
#if defined(__APPLE__)
        dispatch_semaphore_signal(tidyWake);
#endif
        if (worker.joinable()) worker.join();
#if defined(__APPLE__)
        dispatch_release(tidyWake);
#endif
    }

    // ---------------------------------------------------------------- the rule for any N

    // The fold floor at amount N (recipe 4 and up): floorHz up to +8, then easing to floorEndHz at +11. At +9..+11 the
    // fold moves the bass down only 1-3 half-steps, so a 41 Hz bass note may fold to 37-39 Hz instead of jumping up 9-11.
    double floorAt(double N) const {
        if (recipe < 4 || N <= 8) return floorHz;
        return floorHz + (floorEndHz - floorHz) * std::min(1.0, (N - 8) / 3);
    }

    // The recipe for amount N ("balanced3", research round 4, extended to +-24 by the numbers in the engine report):
    //  N = 0      the input, untouched.
    //  N < 0      shift the whole input by N; above the air cut-off max(15 kHz x 2^(N/12), 7 kHz) use the unshifted input.
    //  0 < N <= 3 shift the whole input by N.
    //  3 < N < 7  fold ramp that splits by frequency: t = (N-3)/4; main = above 150t Hz, shifted by N;
    //             fold = below 300t Hz, shifted by N-12, with a 30 Hz high-pass on its output.
    //  7 <= N <= 15  main = above 150 Hz (N); fold = below 300 Hz (N-12; at exactly +12 not shifted, only delayed).
    //  Fold floor (folds that move down, +3 < N < +12): fold-band bass that would land below F = 45 Hz (easing to
    //             35 Hz from +8 to +11, see floorAt), i.e. below FX = F x 2^((12-N)/12) Hz, goes to the main path
    //             instead (so it is shifted up by N).
    //             The split at FX is a steep 8th order Butterworth: its two sides keep the full power between them
    //             (they end up an octave apart, so they add as powers), and a note goes almost entirely one way.
    //             The main path's band above 150t Hz goes through the all-pass of that split, so its two parts stay
    //             in phase and never cancel each other. (recipe 3 = 2.0.0: floor at 35 Hz, LR4 splits, which lost up
    //             to 3 dB of a note near the split and leaked the EDM sub bass down to 32 Hz.)
    //  15 < N < 19  second fold comes in the same way: t2 = (N-15)/4; fold2 = below 600t2 Hz shifted by N-24;
    //             fold = 300t2..300 Hz (N-12); main as before. (3 shifters only here.)
    //  19 <= N <= 24  main = above 150 Hz (N); fold2 = below 600 Hz (N-24; at +24 only delayed). Two octaves overlap,
    //             because the two paths are two octaves apart, so the output has no gap.
    //  Second-fold floor (15 < N < 24): like the fold floor (35 Hz, and the 30 Hz output high-pass during its ramp),
    //             with the sub going one level up: to the first fold while it is there, else to main.
    Spec rule(double N) const {
        Spec s; s.N = N;
        auto path = [&](double shift) -> PathSpec & { PathSpec &p = s.p[s.n++]; p = PathSpec(); p.shift = shift; return p; };
        if (N == 0) return s;
        if (N < 0) {
            PathSpec &m = path(N); m.add(1);
            if (subHz > 0) m.subHP = subHz * std::min(1.0, -N / eq.offN);  // full from -offn down
            s.air = std::max(15000.0 * pow(2.0, N / 12.0), airMin);
            if (s.air > 0.45 * sr) s.air = 0;
            s.airBW = airBW;
            return s;
        }
        if (N <= foldStart) { path(N).add(1); return s; }
        if (recipe == 2 && N < foldFull) {  // balanced2 (test only): blend ramp, the unfolded low band rides in the main shifter
            double w = (N - foldStart) / (foldFull - foldStart);
            PathSpec &m = path(N); m.coherent = true; hp(m.add(1), 150); lp(m.add((float)(1 - w)), 150);
            PathSpec &f = path(N - 12); f.outW = (float)w; lp(f.add(1), 300);
            return s;
        }
        if (N <= 15 || !fold2) {  // one fold
            double t = std::min(1.0, (N - foldStart) / (foldFull - foldStart));
            double FH = 150 * t, FL = 300 * t;
            if (recipe >= 4 && N < 12) {  // fold floor with a steep, power-keeping split
                double FX = floorAt(N) * pow(2.0, (12 - N) / 12.0);
                PathSpec &m = path(N); m.coherent = true;
                ap8(hp(m.add(1), FH), FX);   // above FH, in phase with the sub below
                lp8(lp(m.add(1), FH), FX);   // the sub below FX
                PathSpec &f = path(N - 12);
                hp8(lp(f.add(1), FL), FX);   // FX..FL is folded
                if (N < foldFull) f.outHP = floorOut;
                return s;
            }
            PathSpec &m = path(N); hp(m.add(1), FH);
            PathSpec &f = path(N - 12); Term &ft = lp(f.add(1), FL);
            if (recipe == 3 && N < 12) {  // fold floor
                double FX = floorHz * pow(2.0, (12 - N) / 12.0);
                lp(lp(m.add(1), FL), FX);
                hp(ft, FX);
                if (N < foldFull) f.outHP = floorOut;
            }
            return s;
        }
        // second fold
        double t2 = std::min(1.0, (N - 15) / (foldFull - foldStart)), x = 300 * t2;
        PathSpec &m = path(N); hp(m.add(1), 150);
        PathSpec *f1 = nullptr;
        if (t2 < 1) { f1 = &path(N - 12); hp(lp(f1->add(1), 300), x); }
        PathSpec &f2 = path(N - 24); Term &ft = lp(f2.add(1), 2 * x);
        if (floor2 && N < 24) {  // its sub bass goes one level up: to the first fold while it is there, else to main
            double FX = floor2Hz * pow(2.0, (24 - N) / 12.0);
            PathSpec &up = f1 ? *f1 : m;
            lp(lp(up.add(1), 2 * x), FX);
            hp(ft, FX);
            if (t2 < 1) f2.outHP = floorOut;
        }
        return s;
    }

    // ---------------------------------------------------------------- chains

    void retire(Chain &ch) {
        bool any = false;
        for (int q = 0; q < ch.spec.n; q++)
            if (ch.path[q].sh) { ch.path[q].sh->state.store(SH_DIRTY, std::memory_order_release); ch.path[q].sh = nullptr; any = true; }
        ch.state = C_FREE;
#if defined(__APPLE__)
        if (any) dispatch_semaphore_signal(tidyWake);
#else
        (void)any;
#endif
    }

    // Start a chain for amount N in slot `slot`. False if not enough fresh shifters yet (try again soon).
    bool start(int slot, double N) {
        Chain &ch = chains[slot];
        Spec s = rule(N);
        Shifter *got[MAXPATHS] = {};
        int needed = 0, have = 0;
        for (int q = 0; q < s.n; q++) if (s.p[q].shift != 0) needed++;
        for (auto &sh : pool) {
            if (have == needed) break;
            if (sh->state.load(std::memory_order_acquire) == SH_FRESH) got[have++] = sh.get();
        }
        if (have < needed) return false;
        ch.spec = s;
        int k = 0;
        int64_t vmax = 0;
        for (int q = 0; q < s.n; q++) {
            Path &p = ch.path[q];
            p.spec = s.p[q]; p.produced = 0; p.lag = 0; p.sh = nullptr;
            if (s.p[q].shift != 0) {
                p.sh = got[k++];
                p.sh->state.store(SH_IN_USE, std::memory_order_relaxed);
                p.sh->rb->setPitchScale(pow(2.0, s.p[q].shift / 12.0));
                p.lag = (int64_t)p.sh->rb->getStartDelay() - (int64_t)p.sh->rb->getPreferredStartPad();
                // measured with rbprobe --warm: full level from about max(0, -lag) + 60 ms after the start
                vmax = std::max(vmax, std::max<int64_t>(0, -p.lag) + (int64_t)(1.5 * W2));
            }
        }
        for (int q = 0; q < s.n; q++) {  // each path's input filters and output high-pass, fresh state
            Path &p = ch.path[q];
            for (int i = 0; i < p.spec.nt; i++)
                for (int k = 0; k < p.spec.t[i].nf; k++)
                    for (int c = 0; c < nch; c++) {
                        const Term &tm = p.spec.t[i];
                        LR4 &fl = p.filt[i][k][c];
                        if (tm.kind[k] == AP8) fl.allpass8(tm.fc[k], sr);
                        else if (tm.kind[k] == BW8A || tm.kind[k] == BW8B) fl.bw8(tm.hp[k], tm.kind[k] == BW8B, tm.fc[k], sr);
                        else if (tm.hp[k]) fl.highpass(tm.fc[k], sr);
                        else fl.lowpass(tm.fc[k], sr);
                    }
            if (p.spec.outHP > 0)
                for (int k = 0; k < 4; k++) for (int c = 0; c < nch; c++) { p.outF[k][c].highpass(p.spec.outHP, M_SQRT1_2, sr); p.outF[k][c].clear(); }
            if (p.spec.subHP > 0)
                for (int k = 0; k < 2; k++) for (int c = 0; c < nch; c++) { p.subF[k][c].highpass(p.spec.subHP, M_SQRT1_2, sr); p.subF[k][c].clear(); }
        }
        for (int c = 0; c < nch; c++) {
            if (s.air > 0 && s.airBW) { ch.airLP[c].bw4(false, s.air, sr); ch.airHP[c].bw4(true, s.air, sr); }
            else if (s.air > 0) { ch.airLP[c].lowpass(s.air, sr); ch.airHP[c].highpass(s.air, sr); }
            for (int b = 0; b < NEQ; b++) ch.eq[c][b].clear();
        }
        // EQ: start from the gains being heard, take the first gains made for this chain at once
        Chain &A = chains[active];
        for (int b = 0; b < NEQ; b++) { ch.eqApplied[b] = A.dry() ? 0.0 : A.eqApplied[b]; ch.eqInc[b] = 0; }
        ch.eqSteps = 0; ch.eqCount = 0; ch.eqFresh = true;
        setEqFilters(ch);
        // feed it from a little in the past, so it can be heard soon after it catches up
        ch.V = vmax;
        int64_t H = (L + vmax) * (catchup - 1) / catchup;
        ch.h0 = std::max(t - H, tStart);
        ch.p = ch.h0;
        ch.phase = 0;
        ch.state = C_WARMING;
        // the EQ's slow correction belongs to the old amount: start it over after a big change
        if (fabs(N - A.spec.N) > 1.0) eq.resetCorrection();
        targetGen++;
        return true;
    }

    void setEqFilters(Chain &ch) {
        for (int b = 0; b < NEQ; b++) {
            Biquad d; eq.setFilter(d, b, ch.eqApplied[b]);
            for (int c = 0; c < nch; c++) ch.eq[c][b].copyCoefs(d);
        }
    }

    // Decide what happens next: start a new chain, fade, finish a fade.
    void manage() {
        if (pending) {
            if (next >= 0 && chains[next].state != C_FADE_IN) {  // a new amount came while one was getting ready
                if (chains[next].spec.N == wantN) pending = false;
                else { retire(chains[next]); next = -1; targetGen++; }
            }
            if (pending && next < 0) {
                if (wantN == chains[active].spec.N) pending = false;  // back to what is playing
                else {
                    int slot = 1 - active;
                    if (wantN == 0) {  // the unprocessed input needs no shifters and is always ready
                        Chain &ch = chains[slot];
                        ch.spec = Spec(); ch.state = C_WARMING; ch.h0 = ch.p = t; ch.V = 0; ch.phase = 0;
                        next = slot; pending = false; targetGen++;
                    } else if (start(slot, wantN)) { next = slot; pending = false; }
                }
            }
        }
        if (next < 0) return;
        Chain &B = chains[next];
        // ready: caught up, and far enough past its start that its shifters sound right. The unprocessed input (N = 0)
        // is always ready, but waits about as long as a shifted amount would, so clicking quickly through 0 doesn't
        // flash the original pitch.
        bool ready = B.dry() ? (t - B.h0 >= dryWait() || B.h0 <= tStart)
                             : (B.p == t && (t - L >= B.h0 + B.V || B.h0 <= tStart));
        if (B.state == C_WARMING && ready) {
            if (t <= tStart + L) { switchNow(); return; }  // nothing real has come out yet: no fade needed
            B.state = B.dry() ? C_FADE_IN : C_PREROLL;
            B.phase = 0;
            equalPower = fabs(B.spec.N - chains[active].spec.N) >= 0.5;  // different pitches don't add up in phase
        }
        if (B.state == C_PREROLL && B.phase >= prerollLen) { B.state = C_FADE_IN; B.phase = 0; }
        if (B.state == C_FADE_IN && B.phase >= fadeLen) { switchNow(); switches++; }
    }

    int64_t dryWait() const { return (L + (int64_t)(1.5 * W2)) / catchup; }

    void switchNow() {
        retire(chains[active]);
        active = next; next = -1;
        chains[active].state = C_ACTIVE;
    }

    // Feed chain ch with input samples up to (not including) `upto`.
    void feed(Chain &ch, int64_t upto) {
        if (ch.dry()) { ch.p = upto; return; }
        while (ch.p < upto) {
            int q = (int)std::min<int64_t>(upto - ch.p, PIECE);
            for (int c = 0; c < nch; c++) { float *x = xin[c].data(); for (int i = 0; i < q; i++) x[i] = hist[c][ch.p + i]; }
            for (int k = 0; k < ch.spec.n; k++) {
                Path &p = ch.path[k];
                const float *src[MAXCH];
                if (p.spec.nt == 1 && p.spec.t[0].nf == 0 && p.spec.t[0].gain == 1) {  // whole input
                    for (int c = 0; c < nch; c++) src[c] = xin[c].data();
                } else {
                    for (int c = 0; c < nch; c++) { std::fill(pin[c].begin(), pin[c].begin() + q, 0.0f); src[c] = pin[c].data(); }
                    for (int i = 0; i < p.spec.nt; i++) {  // sum of terms, each = gain x (input through its LR4 filters)
                        const Term &tm = p.spec.t[i];
                        for (int c = 0; c < nch; c++) std::copy(xin[c].begin(), xin[c].begin() + q, tmpT[c].begin());
                        for (int f = 0; f < tm.nf; f++) {
                            if (nch == 2) {  // both channels in one pass, so their filters work at the same time
                                LR4 &f0 = p.filt[i][f][0], &f1 = p.filt[i][f][1];
                                float *y0 = tmpT[0].data(), *y1 = tmpT[1].data();
                                for (int j = 0; j < q; j++) { y0[j] = f0.run(y0[j]); y1[j] = f1.run(y1[j]); }
                            } else {
                                LR4 &flt = p.filt[i][f][0];
                                float *y = tmpT[0].data();
                                for (int j = 0; j < q; j++) y[j] = flt.run(y[j]);
                            }
                        }
                        for (int c = 0; c < nch; c++) {
                            float *o = pin[c].data();
                            const float *y = tmpT[c].data();
                            for (int j = 0; j < q; j++) o[j] += tm.gain * y[j];
                        }
                    }
                }
                if (p.sh) {
                    p.sh->rb->process(src, q, false);
                    drain(p);
                } else store(p, src, q);
            }
            ch.p += q;
        }
    }

    void drain(Path &p) {
        int a;
        float *op[MAXCH] = {rbOut[0].data(), nch > 1 ? rbOut[1].data() : nullptr};
        while ((a = p.sh->rb->available()) > 0) {
            size_t got = p.sh->rb->retrieve(op, std::min(a, (int)rbOut[0].size()));
            const float *src[MAXCH] = {rbOut[0].data(), nch > 1 ? rbOut[1].data() : nullptr};
            store(p, src, (int)got);
        }
    }

    // append to a path's output stream (through its output high-passes, if it has them)
    void store(Path &p, const float *const *src, int n) {
        for (int c = 0; c < nch; c++)
            for (int i = 0; i < n; i++) {
                float v = src[c][i];
                if (p.spec.outHP > 0) for (int k = 0; k < 4; k++) v = p.outF[k][c].run(v);
                if (p.spec.subHP > 0) for (int k = 0; k < 2; k++) v = p.subF[k][c].run(v);
                p.ring[c][p.produced + i] = v;
            }
        p.produced += n;
    }

    // One chain's output for input samples tau0..tau0+m-1 into sum (and its level before the EQ into pre).
    void chainOut(Chain &ch, int64_t tau0, int m) {
        if (ch.dry()) {
            for (int c = 0; c < nch; c++) for (int i = 0; i < m; i++) sum[c][i] = pre[c][i] = hist[c][tau0 + i];
            return;
        }
        for (int c = 0; c < nch; c++) std::fill(sum[c].begin(), sum[c].begin() + m, 0.0f);
        for (int k = 0; k < ch.spec.n; k++) {
            Path &p = ch.path[k];
            float w = p.spec.outW;
            int64_t j0 = tau0 - ch.h0 + p.lag;
            if (j0 + m > p.produced) underruns++;
            // the samples it has made (0 <= j < produced), read in pieces that don't wrap around its ring
            int i0 = (int)std::min<int64_t>(m, std::max<int64_t>(0, -j0));
            int i1 = (int)std::max<int64_t>(i0, std::min<int64_t>(m, p.produced - j0));
            for (int c = 0; c < nch; c++) {
                float *s = sum[c].data();
                const float *r = p.ring[c].d.data();
                for (int i = i0; i < i1;) {
                    size_t at = (size_t)((j0 + i) & p.ring[c].mask);
                    int n = (int)std::min<int64_t>(i1 - i, (int64_t)p.ring[c].d.size() - (int64_t)at);
                    for (int k = 0; k < n; k++) s[i + k] += w * r[at + k];
                    i += n;
                }
            }
        }
        if (ch.spec.air > 0) {  // pitch-down: above the air cut-off, the unshifted input
            if (nch == 2) {  // both channels in one pass, so their filters work at the same time
                float *s0 = sum[0].data(), *s1 = sum[1].data();
                for (int i = 0; i < m; i++) {
                    s0[i] = ch.airLP[0].run(s0[i]) + ch.airHP[0].run(hist[0][tau0 + i]);
                    s1[i] = ch.airLP[1].run(s1[i]) + ch.airHP[1].run(hist[1][tau0 + i]);
                }
            } else
                for (int i = 0; i < m; i++) sum[0][i] = ch.airLP[0].run(sum[0][i]) + ch.airHP[0].run(hist[0][tau0 + i]);
        }
        for (int c = 0; c < nch; c++) std::copy(sum[c].begin(), sum[c].begin() + m, pre[c].begin());
        // EQ, with its gains moving a small step every 32 samples. The filters run two at a time on each sample, and
        // both channels in one pass, so several work at the same time (the same sums in the same order as one by one).
        int i = 0;
        while (i < m) {
            if (ch.eqCount == 0 && ch.eqSteps > 0) {
                for (int b = 0; b < NEQ; b++) ch.eqApplied[b] += ch.eqInc[b];
                ch.eqSteps--;
                setEqFilters(ch);
            }
            int n = std::min(m - i, 32 - ch.eqCount);
            if (nch == 2) {
                float *s0 = sum[0].data() + i, *s1 = sum[1].data() + i;
                for (int b = 0; b < NEQ; b += 2) {
                    Biquad &f0 = ch.eq[0][b], &g0 = ch.eq[0][b + 1], &f1 = ch.eq[1][b], &g1 = ch.eq[1][b + 1];
                    for (int k = 0; k < n; k++) { s0[k] = g0.run(f0.run(s0[k])); s1[k] = g1.run(f1.run(s1[k])); }
                }
            } else {
                float *s = sum[0].data() + i;
                for (int b = 0; b < NEQ; b += 2) {
                    Biquad &f = ch.eq[0][b], &g = ch.eq[0][b + 1];
                    for (int k = 0; k < n; k++) s[k] = g.run(f.run(s[k]));
                }
            }
            ch.eqCount = (ch.eqCount + n) & 31;
            i += n;
        }
    }

    // ---------------------------------------------------------------- EQ analysis, one slice per SB samples

    Chain *eqTarget() { Chain *c = next >= 0 ? &chains[next] : &chains[active]; return c->dry() ? nullptr : c; }

    void eqSlice(int stage) {
        TonalEQ &E = eq;
        if (stage == 0) {
            E.blocks++;
            E.a = std::min(exp(-(double)E.period / (E.tau * sr)), 1.0 - 1.0 / E.blocks);  // running mean at first
            E.bandPowers(nch > 1 ? refRing : hist[0], t, E.pr);
            for (int k = 1; k < E.N / 2; k++) E.rbin[k] = E.a * E.rbin[k] + (1 - E.a) * ((double)E.re[k] * E.re[k] + (double)E.im[k] * E.im[k]);
            for (size_t j = 0; j < E.fcs.size(); j++) E.pref[j] = E.a * E.pref[j] + (1 - E.a) * E.pr[j];
            return;
        }
        if (E.blocks == 0) return;
        if (stage == 1 || stage == 2) {
            Chain *c = eqTarget();
            if (stage == 1) { std::fill(E.pq.begin(), E.pq.end(), 0.0); E.gen = targetGen; }
            if (c && E.gen == targetGen) E.predict(c->spec, E.gen, stage == 1 ? 1 : E.N / 4, stage == 1 ? E.N / 4 : E.N / 2);
            return;
        }
        if (stage == 3) {
            E.bandPowers(cur, t, E.pc);
            for (size_t j = 0; j < E.fcs.size(); j++) E.pcur[j] = E.a * E.pcur[j] + (1 - E.a) * E.pc[j];
            return;
        }
        if (stage != 4) return;
        if (guardMax > 0) {  // headroom guard: the limiter worked more than 1 % of the last period -> less bass boost
            double frac = (double)(lim.limited01 - guardLast) / E.period;
            guardLast = lim.limited01;
            guardDb = frac > 0.01 ? std::min(guardMax, guardDb + 0.5) : std::max(0.0, guardDb - 0.05);
        }
        Chain *c = eqTarget();
        if (!c || E.gen != targetGen) return;  // the target changed during this analysis: next time
        bool steady = next < 0;                 // the measured output belongs to this chain: update the slow correction
        if (steady) {
            E.blocks2++;
            double a2 = std::min(exp(-(double)E.period / (3 * E.tau * sr)), 1.0 - 1.0 / E.blocks2);
            for (size_t j = 0; j < E.fcs.size(); j++) { E.pqs[j] = a2 * E.pqs[j] + (1 - a2) * E.pq[j]; E.pcs[j] = a2 * E.pcs[j] + (1 - a2) * E.pcur[j]; }
        }
        double mx = *std::max_element(E.pref.begin(), E.pref.end());
        double N = c->spec.N;
        double loF = (N > 0 && !E.loUp) ? 0.0 : E.loF;  // the deeper bass cuts: going down only (see loUp)
        double ramp = std::min(1.0, (double)E.blocks2 * E.period / sr / (2 * E.tau));
        // recipe 5 limits for this direction (OFF: as recipe 4)
        double lowcap = (N < 0 && E.lowcapDn != OFF) ? E.lowcapDn : E.lowcap;
        double topcut = N > 0 ? E.topcutUp : OFF;
        size_t nb = E.fcs.size();
        for (size_t j = 0; j < nb; j++) {
            double d = 10 * log10((E.pref[j] + 1e-20) / (E.pq[j] + 1e-20));
            if (E.blocks2 > 0) d += ramp * std::max(-3.0, std::min(3.0, 10 * log10((E.pqs[j] + 1e-20) / (E.pcs[j] + 1e-20))));
            bool quiet = (E.pref[j] < mx * 1e-6 && E.pq[j] < mx * 1e-6) || (E.pref[j] < mx * 1e-6 && E.pcur[j] < mx * 1e-6);
            if (quiet) d = 0;  // both quiet: leave alone
            E.D[j] = d;
            if (E.offOn && !quiet) d += E.offsetAt((int)j, N);  // recipe 5: the per-direction target offsets
            bool lo = loF > 0 && E.fcs[j] < loF;  // balanced3: deeper cuts allowed below 100 Hz
            E.T[j] = E.alpha * std::max(lo ? -E.loCut : -E.cut, std::min(E.boost, d));
            if (E.fcs[j] < 70) E.T[j] = std::min(E.T[j], lowcap);
            if (topcut != OFF && E.fcs[j] >= 7000) E.T[j] = std::max(E.T[j], -topcut);
        }
        for (int j = 0; j < (int)nb; j++) {  // broad target only: average over +-1 band (not below loF)
            double s = 0; int n = 0;
            for (int q = std::max(0, j - E.smooth); q <= std::min((int)nb - 1, j + E.smooth); q++) { s += E.T[q]; n++; }
            E.S[j] = (loF > 0 && E.fcs[j] < loF) ? E.T[j] : s / n;
        }
        // least squares, then two correction passes on the true filter response
        for (int k = 0; k < NEQ; k++) { E.g[k] = 0; for (size_t j = 0; j < nb; j++) E.g[k] += E.M[k][j] * E.S[j]; }
        for (int it = 0; it < 2; it++) {
            Biquad tb[NEQ];
            for (int k = 0; k < NEQ; k++) E.setFilter(tb[k], k, E.g[k]);
            for (size_t j = 0; j < nb; j++) { double r = 0; for (int k = 0; k < NEQ; k++) r += tb[k].magDb(E.fcs[j], sr); E.e[j] = E.S[j] - r; }
            for (int k = 0; k < NEQ; k++) for (size_t j = 0; j < nb; j++) E.g[k] += E.M[k][j] * E.e[j];
        }
        int steps = E.period / 32;
        for (int k = 0; k < NEQ; k++) {
            double cutk = (loF > 0 && E.eqf[k] < loF) ? E.loCut : E.cut;  // the 44 Hz shelf and 62 Hz filter: deeper cut
            double gk = std::max(-cutk - 3, std::min((k <= 1 ? std::min(E.boost, lowcap) : E.boost) + 3, E.g[k]));
            if (k >= 3 && k <= 7) {
                double mcut = E.midcap;  // recipe 5: deeper mid cuts (going down at 250 Hz, going up at 500 Hz - 2 kHz)
                if (N < 0 && k == 3 && E.midcutDn != OFF) mcut = E.midcutDn;
                if (N > 0 && k >= 4 && k <= 6 && E.midcutUp != OFF) mcut = E.midcutUp;
                gk = std::max(-mcut, std::min(E.midcap, gk));
            }
            if (topcut != OFF && k >= 8) gk = std::max(gk, -topcut - 1);
            if (guardDb > 0 && k <= 2 && gk > 0) gk = std::max(0.0, gk - guardDb);  // never adds a cut
            if (c->eqFresh) { c->eqApplied[k] = gk; c->eqInc[k] = 0; }
            else c->eqInc[k] = (gk - c->eqApplied[k]) / steps;
        }
        if (c->eqFresh) { c->eqFresh = false; c->eqSteps = 0; setEqFilters(*c); }
        else c->eqSteps = steps;
    }

    Ring refRing;  // stereo only: mono mix of the history, the EQ's reference

    // ---------------------------------------------------------------- process

    void process(const float *const *in, const float *const *keep, float *const *out, int frames) {
        int done = 0;
        while (done < frames) {
            int m = (int)std::min<int64_t>(frames - done, SB - (t % SB));
            // keep: taken out of the input here, added back (same delay) in render(). When keep starts (it was NULL or
            // all zeros for a while) it is faded in over 30 ms, so the drums don't jump from the shifted path to the
            // unshifted one in one sample (that would click).
            for (int i = 0; i < m; i++) {
                bool any = false;
                if (keep) for (int c = 0; c < nch; c++) if (keep[c][done + i] != 0.0f) any = true;
                keepIdle = any ? 0 : std::min<int64_t>(keepIdle + 1, keepIdleLimit);
                keepG = keepIdle >= keepIdleLimit ? 0.0f : std::min(1.0f, keepG + keepStep);
                for (int c = 0; c < nch; c++) {
                    float k = keep ? keepG * keep[c][done + i] : 0.0f;
                    hist[c][t + i] = in[c][done + i] - k;
                    keepR[c][t + i] = k;
                }
            }
            if (nch > 1) for (int i = 0; i < m; i++) refRing[t + i] = 0.5f * (hist[0][t + i] + hist[1][t + i]);
            manage();
            // feed: chains that are caught up get this slice; one that is catching up gets up to `catchup` x more
            for (int s = 0; s < 2; s++) {
                Chain &ch = chains[s];
                if (ch.state == C_FREE) continue;
                if (ch.state == C_WARMING) feed(ch, std::min<int64_t>(t + m, ch.p + (int64_t)catchup * m));
                else feed(ch, t + m);
            }
            render(out, done, m);
            t += m; done += m;
            if (next >= 0 && (chains[next].state == C_PREROLL || chains[next].state == C_FADE_IN)) chains[next].phase += m;
            if (t % SB == 0) eqSlice((int)((t / SB) % 8));
        }
    }

    void render(float *const *out, int off, int m) {
        int64_t tau0 = t - L;
        for (int c = 0; c < nch; c++) std::fill(acc[c].begin(), acc[c].begin() + m, 0.0f);
        std::fill(curMono.begin(), curMono.begin() + m, 0.0f);
        Chain &A = chains[active];
        Chain *B = next >= 0 && (chains[next].state == C_PREROLL || chains[next].state == C_FADE_IN) ? &chains[next] : nullptr;
        bool fading = B && B->state == C_FADE_IN;
        for (int which = 0; which < (B ? 2 : 1); which++) {
            Chain &ch = which == 0 ? A : *B;
            chainOut(ch, tau0, m);
            for (int i = 0; i < m; i++) {
                float g = 1.0f;
                if (fading) {
                    double x = std::min(1.0, (double)(B->phase + i) / fadeLen);
                    double gi = equalPower ? sin(0.5 * M_PI * x) : x, go = equalPower ? cos(0.5 * M_PI * x) : 1 - x;
                    g = (float)(which == 0 ? go : gi);
                } else if (which == 1) g = 0.0f;  // pre-roll: warms its filters, not heard yet
                gain[i] = g;
            }
            for (int c = 0; c < nch; c++)
                for (int i = 0; i < m; i++) { acc[c][i] += gain[i] * sum[c][i]; curMono[i] += gain[i] * pre[c][i] / nch; }
        }
        for (int c = 0; c < nch; c++)
            for (int i = 0; i < m; i++) acc[c][i] += keepR[c][tau0 + i];
        // Auto EQ: before bass / treble, so it measures (and keeps) the song's balance and the Bass <-> Treble setting
        // still tilts the sound on top of it. Its reference is the original input at the same moment (mono).
        if (aeq.active()) {
            float *r = aeqRef.data();
            for (int i = 0; i < m; i++) {
                float s = 0;
                for (int c = 0; c < nch; c++) s += hist[c][tau0 + i] + keepR[c][tau0 + i];
                r[i] = s / nch;
            }
            aeq.run(acc, r, m, (t + m) % SB == 0);
        }
        tone.run(acc, m);
        for (int i = 0; i < m; i++) {  // safety limiter, both channels together
            float v[MAXCH];
            for (int c = 0; c < nch; c++) v[c] = acc[c][i];
            lim.run(v);
            for (int c = 0; c < nch; c++) out[c][off + i] = v[c];
        }
        for (int i = 0; i < m; i++) cur[t + i] = curMono[i];
    }

    void reset() {
        for (auto &ch : chains) if (ch.state != C_FREE) retire(ch);
        next = -1; active = 0;
        chains[0].spec = Spec(); chains[0].state = C_ACTIVE;
        for (int c = 0; c < nch; c++) { hist[c].clear(); keepR[c].clear(); }
        if (nch > 1) refRing.clear();
        cur.clear();
        eq.reset();
        keepG = 0; keepIdle = keepIdleLimit;
        lim.reset();
        guardDb = 0; guardLast = lim.limited01;
        tone.clear();
        aeq.stop();
        tStart = t;
        pending = wantN != 0;
        targetGen++;
    }

    int shiftersInUse() const {
        int n = 0;
        for (auto &s : pool) if (s->state.load(std::memory_order_relaxed) == SH_IN_USE) n++;
        return n;
    }
};

}  // namespace

struct AdvancedChain { Engine *e; };

extern "C" {

AdvancedChain *advanced_new(double sampleRate, int channels, int maxFrames, int flags) {
    if (sampleRate < 8000 || sampleRate > 384000 || channels < 1 || channels > MAXCH || maxFrames < 1 || maxFrames > 65536) return nullptr;
    auto *e = new Engine(sampleRate, channels, maxFrames, flags);
    if (!e->setup()) { delete e; return nullptr; }
    return new AdvancedChain{e};
}

void advanced_delete(AdvancedChain *chain) {
    if (!chain) return;
    delete chain->e;
    delete chain;
}

void advanced_set_semis(AdvancedChain *chain, double semis) {
    Engine *e = chain->e;
    if (!(semis == semis)) return;  // NaN
    semis = std::max(-e->range, std::min(e->range, semis));
    semis = round(semis * 100.0) / 100.0;  // the app's 0.01 steps
    if (semis == e->wantN) return;
    e->wantN = semis;
    e->pending = true;
}

void advanced_set_tone(AdvancedChain *chain, double bassDb, double trebleDb) {
    ToneStage &s = chain->e->tone;
    if (bassDb == bassDb) s.wantB = std::max(-12.0, std::min(12.0, bassDb));  // NaN: unchanged
    if (trebleDb == trebleDb) s.wantT = std::max(-12.0, std::min(12.0, trebleDb));
}

void advanced_set_auto_eq(AdvancedChain *chain, int on, const double offsetsDb[5]) {
    AutoEQ5 &a = chain->e->aeq;
    a.on = on != 0;
    for (int k = 0; k < AEQB; k++) {
        double v = offsetsDb ? offsetsDb[k] : 0.0;
        a.want[k] = v == v ? std::max(-12.0, std::min(12.0, v)) : 0.0;  // NaN: 0
    }
}

void advanced_get_auto_eq(const AdvancedChain *chain, double autoDb[5], double levelDb[5]) {
    chain->e->aeq.readout.read(autoDb, levelDb);
}

void advanced_reset(AdvancedChain *chain) { chain->e->reset(); }

void advanced_process(AdvancedChain *chain, const float *const *in, const float *const *keep, float *const *out, int frames) {
    Engine *e = chain->e;
    // More than maxFrames is fine too: the engine works in slices of at most 512 samples anyway.
    if (frames > 0) e->process(in, keep, out, frames);
}

int advanced_latency_frames(const AdvancedChain *chain) { return chain->e->L + chain->e->lim.D; }  // shifters + limiter look-ahead

void advanced_limiter_stats(const AdvancedChain *chain, AdvancedLimiterStats *s) {
    const Limiter &l = chain->e->lim;
    s->maxReductionDb = l.minGain < 1.0 ? -20 * log10(l.minGain) : 0.0;
    s->samplesLimited = l.limited;
    s->samplesLimitedOver01dB = l.limited01;
    s->samples = l.total;
    s->roundingClamps = l.clamps;
}

void advanced_eq_gains(const AdvancedChain *chain, double g[10]) {
    const Chain &a = chain->e->chains[chain->e->active];
    for (int k = 0; k < NEQ; k++) g[k] = a.dry() ? 0.0 : a.eqApplied[k];
}

int advanced_eq_bands(const AdvancedChain *chain, double *want, double *target, int n) {
    const TonalEQ &E = chain->e->eq;
    int nb = (int)E.fcs.size();
    for (int j = 0; j < std::min(n, nb); j++) {
        if (want) want[j] = E.D[j];
        if (target) target[j] = E.S[j];
    }
    return nb;
}

void advanced_get_info(const AdvancedChain *chain, AdvancedInfo *info) {
    const Engine *e = chain->e;
    info->heardSemis = e->chains[e->active].spec.N;
    info->changing = (e->next >= 0 || e->pending) ? 1 : 0;
    info->underruns = e->underruns;
    info->switches = e->switches;
    info->shiftersRunning = e->shiftersInUse();
}

int advanced_tune(AdvancedChain *chain, const char *key, double v) {
    Engine *e = chain->e;
    std::string k(key);
    TonalEQ &q = e->eq;
    // offset knots: up25 .. up12800, dn25 .. dn12800 (25 x 2^i Hz)
    if ((k.compare(0, 2, "up") == 0 || k.compare(0, 2, "dn") == 0) && k.size() > 2) {
        double hz = atof(k.c_str() + 2);
        double *knots = k[0] == 'u' ? q.offUp : q.offDn;
        for (int i = 0; i < NKNOT; i++)
            if (hz == 25.0 * (1 << i)) {
                knots[i] = v;
                q.offOn = false;
                for (int j = 0; j < NKNOT; j++) if (q.offUp[j] != 0 || q.offDn[j] != 0) q.offOn = true;
                return 1;
            }
        return 0;
    }
    if (k == "recipe") e->applyRecipe((int)v);
    else if (k == "limiter") e->lim.enabled = v != 0;
    else if (k == "floor2") e->floor2 = (int)v;
    else if (k == "floorhz") e->floorHz = v;
    else if (k == "floor2hz") e->floor2Hz = v;
    else if (k == "floorendhz") e->floorEndHz = v;
    else if (k == "floorout") e->floorOut = v;
    else if (k == "fold2") e->fold2 = (int)v;
    else if (k == "airmin") e->airMin = v;
    else if (k == "catchup") e->catchup = std::max(1, (int)v);
    else if (k == "fadems") { e->fadeMs = v; e->fadeLen = (int64_t)lround(v * 0.001 * e->sr); }
    else if (k == "keepfadems") e->keepStep = v > 0 ? (float)(1.0 / (v * 0.001 * e->sr)) : 1.0f;
    else if (k == "foldstart") e->foldStart = v;
    else if (k == "foldfull") e->foldFull = v;
    else if (k == "lowcap") q.lowcap = v;
    else if (k == "eqalpha") q.alpha = v;
    else if (k == "edgefix") q.edgefix = v != 0;
    else if (k == "offn") q.offN = std::max(0.01, v);
    else if (k == "lowcapdn") q.lowcapDn = v < -98 ? OFF : v;
    else if (k == "midcutup") q.midcutUp = v < 0 ? OFF : v;
    else if (k == "midcutdn") q.midcutDn = v < 0 ? OFF : v;
    else if (k == "topcutup") q.topcutUp = v < 0 ? OFF : v;
    else if (k == "subhz") e->subHz = std::max(0.0, v);
    else if (k == "airbw") e->airBW = v != 0;
    else if (k == "guard") { e->guardMax = std::max(0.0, v); e->guardDb = 0; e->guardLast = e->lim.limited01; }
    else if (k == "fastrel") e->lim.setFast(std::max(0.0, v));
    else if (k == "tonelohz") { e->tone.loHz = v; e->tone.setFilters(); }
    else if (k == "tonehihz") { e->tone.hiHz = std::min(v, 0.45 * e->sr); e->tone.setFilters(); }
    else if (k == "aeqrange") e->aeq.range = std::max(0.0, std::min(AEQ_MAX, v));
    else if (k == "aeqattack") { e->aeq.attackMs = v; e->aeq.setTimes(); }
    else if (k == "aeqrelease") { e->aeq.releaseMs = v; e->aeq.setTimes(); }
    else if (k == "aeqwindow") e->aeq.setWindow(v);
    else if (k.size() == 5 && k.compare(0, 4, "aeqf") == 0 && k[4] >= '1' && k[4] <= '4') { e->aeq.fc[k[4] - '1'] = v; e->aeq.design(); }
    else if (k == "aeqfloor") e->aeq.floorDb = v;
    else if (k == "aeqlowhz") { e->aeq.lowHz = v; e->aeq.design(); }
    else if (k == "aeqkeep") e->aeq.keep = v != 0;
    else if (k == "aeqweight") { e->aeq.weighted = v != 0; e->aeq.design(); }
    else return 0;
    return 1;
}

}  // extern "C"

// ------------------------------------------------------------------------------------------------- tone on its own

// Bass / treble and Auto EQ for the app's normal mode (tonechain_*, see AdvancedChain.h): the engine's own AutoEQ5 and
// ToneStage in the same order, then the same safety limiter, which only works while one of them is in use. With both
// untouched (the default) the stages are skipped and the limiter's gain stays exactly 1, so the output is the input
// delayed by the limiter's look-ahead, bit for bit.
struct ToneChain {
    double sr = 48000;
    int nch = 2, SB = 256;
    int64_t t = 0;                     // samples processed (Auto EQ works in SB blocks, like the engine)
    AutoEQ5 aeq;
    ToneStage tone;
    Limiter lim;
    std::vector<float> x[MAXCH], ref;  // scratch (made once)

    ToneChain(double rate, int channels) : sr(rate), nch(channels) {
        SB = rate > 64000 ? 512 : 256;
        lim.init(sr, nch);
        lim.setFast(25);               // as the engine's recipe 5
        tone.init(sr, nch);
        aeq.init(sr, nch, SB);
        for (int c = 0; c < nch; c++) x[c].assign(SB, 0.0f);
        ref.assign(SB, 0.0f);
    }

    void process(float *const *io, const float *refIn, int frames) {
        int done = 0;
        while (done < frames) {
            int m = (int)std::min<int64_t>(frames - done, SB - (t % SB));
            bool toneRuns = !(tone.flat() && tone.idle >= tone.idleLimit);
            lim.enabled = aeq.active() || !tone.flat();
            if (aeq.active() || toneRuns) {
                for (int c = 0; c < nch; c++) std::copy(io[c] + done, io[c] + done + m, x[c].begin());
                if (aeq.active()) {
                    float *r = ref.data();
                    if (refIn) std::copy(refIn + done, refIn + done + m, r);
                    else for (int i = 0; i < m; i++) {  // no original given: the sound itself
                        float s = 0;
                        for (int c = 0; c < nch; c++) s += x[c][i];
                        r[i] = s / nch;
                    }
                    aeq.run(x, r, m, (t + m) % SB == 0);
                }
                tone.run(x, m);
                for (int c = 0; c < nch; c++) std::copy(x[c].begin(), x[c].begin() + m, io[c] + done);
            }
            for (int i = 0; i < m; i++) {
                float v[MAXCH];
                for (int c = 0; c < nch; c++) v[c] = io[c][done + i];
                lim.run(v);
                for (int c = 0; c < nch; c++) io[c][done + i] = v[c];
            }
            t += m;
            done += m;
        }
    }
};

extern "C" {

ToneChain *tonechain_new(double sampleRate, int channels) {
    if (sampleRate < 8000 || sampleRate > 384000 || channels < 1 || channels > MAXCH) return nullptr;
    return new ToneChain(sampleRate, channels);
}

void tonechain_delete(ToneChain *chain) { delete chain; }

void tonechain_set_tone(ToneChain *chain, double bassDb, double trebleDb) {
    ToneStage &s = chain->tone;
    if (bassDb == bassDb) s.wantB = std::max(-12.0, std::min(12.0, bassDb));  // NaN: unchanged
    if (trebleDb == trebleDb) s.wantT = std::max(-12.0, std::min(12.0, trebleDb));
}

void tonechain_set_auto_eq(ToneChain *chain, int on, const double offsetsDb[5]) {
    AutoEQ5 &a = chain->aeq;
    a.on = on != 0;
    for (int k = 0; k < AEQB; k++) {
        double v = offsetsDb ? offsetsDb[k] : 0.0;
        a.want[k] = v == v ? std::max(-12.0, std::min(12.0, v)) : 0.0;  // NaN: 0
    }
}

void tonechain_get_auto_eq(const ToneChain *chain, double autoDb[5], double levelDb[5]) {
    chain->aeq.readout.read(autoDb, levelDb);
}

void tonechain_process(ToneChain *chain, float *const *io, const float *ref, int frames) {
    if (frames > 0) chain->process(io, ref, frames);
}

int tonechain_latency_frames(const ToneChain *chain) { return chain->lim.D; }

}  // extern "C"
