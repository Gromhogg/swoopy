// Voice changer, Natural mode (see VoiceChanger.h and notes/voice-changer-plan.md, "Natural mode").
//
// analyse (before Rubber Band), per mic sample:
//   - keeps the original in a delay line (for the sibilance keep in post),
//   - low-passes and thins it to about 16 kHz (/3 at 48 kHz, /6 at 96 kHz, none at 16 kHz),
//   - every 10 ms: YIN pitch tracker on the last ~43 ms (25 ms window, 55-600 Hz, threshold 0.12, parabolic
//     interpolation); voiced = aperiodicity < 0.25 and level > noise floor + 10 dB and > -50 dBFS (3.4: a voice
//     already going on may fade to floor + 6 dB and -58 dBFS; the noise floor is the 10th percentile of the levels of
//     the last ~5 s of frames that were not voiced: before 3.4 voiced frames counted too, so a hum or a held note
//     longer than ~4.6 s became "noise" and lost its pitch),
//   - octave errors (YIN sometimes reads half or double the pitch for a frame or two, mostly where a sound starts or
//     ends): each voiced frame's pitch may be its YIN value, half or double it; a small running path search picks
//     the one that moves least from frame to frame (1 point per half-step), with a cost for taking half (4.5) or
//     double (3.5) and, once the speaker's median is known, for going more than 10 half-steps from it (0.5 per
//     half-step); a frame's choice is settled one frame later, when the next frame is in. A real fall to the bottom
//     of the voice is gradual, so it is kept (the old median-based fix doubled it: the "cracks" at the ends of
//     words); a lasting real octave drop (creak) is taken after ~4 frames. Then a median of 3 frames (so each
//     decision is one frame late),
//   - pitch mapping toward the voice's median pitch: off = 12 log2(target / speaker's median),
//     P = strength * (off + (intonation - 1) * deviation) + extra, limited to +-15 half-steps, smoothed 25 ms,
//     held through unvoiced and creaky frames (creak: < 70 Hz, < 0.62 x median, zig-zag jitter > 8 % over 3 frames,
//     or aperiodicity 0.25-0.45 just after voice); the speaker's median (4 s) starts from a guess (the median an
//     earlier chain measured, voicechanger_set_speaker, or else assumedInputHz, worth 1 s of voice; each learned frame
//     takes 0.25 frames off it, or 10 if it is more than 7 half-steps from the guess, so a guess that doesn't fit the
//     speaker is gone after ~0.1 s of voice) and learns from voiced frames and from smooth low ones (>= 0.5 x median,
//     not rough), so a deep voice finds its real median; for the first 0.5 s of voice every smooth frame counts and
//     only < 70 Hz is creak (the guess may be far off);
//     the median is read between the histogram's quarter-step bins (so it moves smoothly, not in steps), and the
//     median in use moves at most 0.3 half-steps per 10 ms while it is finding the speaker, 0.05 once it knows them,
//   - held notes (3.1.1): a voiced stretch (gaps up to 80 ms) whose slow pitch line (the mean of its last 16 voiced
//     frames, so vibrato averages out) stays within 1 half-step for 0.4 s is a held note: neither median learns from
//     it, and neither moves while it lasts. A stretch's frames are learned once it is over (1.5 s late at most), so
//     the start of a note is not learned either (before 3.1.1 the median slid toward a held note, and the mapping
//     turned that into a slide of the note: up to 17 half-steps when a man sang high after talking),
//   - the pitch the AI voice follows (Realistic mode, frameHz): the tracked pitch x the mapping; through creak it
//     moves with a gradual fall or rise (not below 0.62 x median, mapped) and holds through a sudden drop or rough
//     frames; an aperiodic moment up to 80 ms after voice holds it (never starts it); then it is eased into 9 (at
//     most 11) half-steps above and 6 (at most 9) below the voice's own median, and moves at most 2 half-steps per
//     10 ms while it sings (gaps up to 30 ms count as singing); 3.2: the AI pitch has no +-15 half-step limit (that
//     pinned a third of a deep man's voice to one pitch for Woman), only the band and 60-880 Hz (aiClampMode 0 = the
//     old limit; Natural keeps it either way); the AI voice maps from its own median (aiMedianMode
//     1): the same frames teach it (held notes left out), and once it knows the speaker (300 frames) it moves at
//     most 0.01 half-steps per frame, so a long note is not pulled back toward the voice's pitch while it is held,
//   - sung passages (3.4): when more than 45 % of the last 200 voiced frames are note-like (the last 15 voiced frames
//     within 1 half-step; speech stays below 38 % on every set tried, songs and hummed tunes go above), and until it
//     falls below 30 %: the AI voice keeps the tune's steps as sung (intonation 1 instead of the voice's livelier one,
//     gliding over 0.5 s), a passage sung more than 5 half-steps above the speaker's median (its 1 s mean) moves down
//     as a whole instead of having its top squashed by the band, and the medians don't learn from it,
//   - voice shape (formants): formant ^ (strength * |off| / |12 log2(target / assumedInputHz)|, limited to 1),
//     gliding over 150 ms; Rubber Band gets shape / pitch.
// post (after Rubber Band), per output sample, all plain filters (no added delay):
//   - sibilance (Man): between voiced sounds the top above 4.5 kHz crossfades toward the original's top,
//   - tone EQ: the output's long-term spectrum of voiced sound (21 third-octave bands, ~6 s) against the voice's
//     `ltas`, both normalised over 500 Hz - 2 kHz, smoothed over neighbouring bands, x eqAmount, limited +-6 dB, on
//     8 octave peaking filters 125 Hz - 16 kHz (Q 1.41), moved at most 0.05 dB per 256 samples,
//   - presence: a peak at 3 kHz (Q 0.9),
//   - breath: noise in 4 bands (1.5-2.5, 2.5-4, 4-6, 6-9 kHz), each following the output's own loudness in that
//     band (5 ms up, 30 ms down), only while voiced.
// Everything that depends on the strength is scaled by the strength in use, so at strength 0 the sound is untouched
// (apart from Rubber Band). The strength glides (0.15 s for the whole range).
//
// Inner tuning keys (voicechanger_tune), defaults in Tuning below: yinThreshold, voicedAp, voicedAboveFloorDb,
// voicedMinDb, creakHz, creakRatio, creakJitter, creakApLow, creakApHigh, smoothMs, formantGlideMs, strengthGlideS,
// maxSemitones, medianSeconds, seedFrames, seedFarSt, seedFarFade, eqMaxDb, eqStepDb, eqSeconds, eqStartSeconds, presenceHz, presenceQ,
// sibilanceHz, breathAttackMs, breathReleaseMs, octUpCost, octDownCost, jumpCost, rangeSt, rangeCost, contFrames,
// gapFrames, warmFrames, medianGlideSt, aiBandSt, aiMaxSt, aiBandLowSt, aiMinSt, aiHoldFrames, aiSlewSt, aiMedianMode,
// aiSteadyFrames, aiSteadySt, aiMedianGlideSt, aiMedianWarmFrames, heldMode, heldFrames, heldSt, heldLineFrames,
// heldGapFrames, learnDelayFrames, medianSlowSt, aiClampMode (+ "ai32" 0 = aiClampMode 0, as 3.1.1), 3.4: floorMode,
// floorVoiceS, floorGapFrames, voicedKeepDb, voicedKeepFloorDb, singMode, singNoteFrames, singNoteSt, singWindow,
// singOnShare, singOffShare, singGlideFrames, singTopSt, singResetFrames (+ "hum34" 0 = all of 3.4's off, as 3.3).
#include "VoiceChanger.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <new>

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr int kBands = VOICECHANGER_LTAS_BANDS;  // tone measurement bands
constexpr int kBandsPadded = 24;                 // so the band loop runs in whole vector steps
constexpr int kEq = 8;                           // octave EQ filters, 125 Hz ... 16 kHz
constexpr int kBreath = 4;
constexpr int kPitchBins = 48 * 6;               // quarter half-steps from 40 Hz, 6 octaves
constexpr float kBinLowHz = 40;
constexpr int kLevelBins = 141;                  // 1 dB from -140 to 0 dBFS
constexpr int kFlagFrames = 128;                 // voiced/creak decisions kept for post (1.28 s)
constexpr int kEqBlock = 256;                    // tone EQ measuring/updating block

// One second-order filter (Robert Bristow-Johnson's audio EQ cookbook), transposed direct form II, in double.
struct Biquad {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    double z1 = 0, z2 = 0;
    inline double run(double x) {
        const double y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return y;
    }
    void clear() { z1 = z2 = 0; }
    void flush() {  // tiny numbers are slow on Intel Macs
        if (std::fabs(z1) < 1e-30) z1 = 0;
        if (std::fabs(z2) < 1e-30) z2 = 0;
    }
    void set(double c0, double c1, double c2, double d0, double d1, double d2) {
        b0 = c0 / d0; b1 = c1 / d0; b2 = c2 / d0; a1 = d1 / d0; a2 = d2 / d0;
    }
    void lowPass(double f, double q, double rate) {
        const double w = 2 * kPi * f / rate, c = std::cos(w), alpha = std::sin(w) / (2 * q);
        set((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + alpha, -2 * c, 1 - alpha);
    }
    void highPass(double f, double q, double rate) {
        const double w = 2 * kPi * f / rate, c = std::cos(w), alpha = std::sin(w) / (2 * q);
        set((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha);
    }
    void bandPass(double f, double q, double rate) {  // 0 dB at the centre
        const double w = 2 * kPi * f / rate, c = std::cos(w), alpha = std::sin(w) / (2 * q);
        set(alpha, 0, -alpha, 1 + alpha, -2 * c, 1 - alpha);
    }
    void peak(double f, double q, double db, double rate) {
        const double w = 2 * kPi * f / rate, c = std::cos(w), alpha = std::sin(w) / (2 * q);
        const double a = std::pow(10.0, db / 40);
        set(1 + alpha * a, -2 * c, 1 - alpha * a, 1 + alpha / a, -2 * c, 1 - alpha / a);
    }
};

struct Tuning {
    float yinThreshold = 0.12f;
    float voicedAp = 0.25f;
    float voicedAboveFloorDb = 10;
    float voicedMinDb = -50;
    float creakHz = 70;
    float creakRatio = 0.62f;
    float creakJitter = 0.08f;
    float creakApLow = 0.25f;
    float creakApHigh = 0.45f;
    float smoothMs = 25;
    float formantGlideMs = 150;
    float strengthGlideS = 0.15f;
    float maxSemitones = 15;
    float medianSeconds = 4;
    float seedFrames = 100;          // weight of the first guess of the speaker's median (10 ms frames)
    float seedFarSt = 7;             // a learned frame further than this from the guess ...
    float seedFarFade = 10;          // ... takes this much weight off it (a near one 0.25)
    float eqMaxDb = 6;
    float eqStepDb = 0.05f;
    float eqSeconds = 6;
    float eqStartSeconds = 1;
    float presenceHz = 3000;
    float presenceQ = 0.9f;
    float sibilanceHz = 4500;
    float breathAttackMs = 5;
    float breathReleaseMs = 30;
    // octave errors (see the top of this file)
    float octUpCost = 3.5f;          // cost of taking double the YIN pitch (YIN read half)
    float octDownCost = 4.5f;        // cost of taking half the YIN pitch (YIN read double)
    float jumpCost = 1;              // cost per half-step moved from the frame before
    float rangeSt = 10;              // once the median is known: more than this from it ...
    float rangeCost = 0.5f;          // ... costs this per half-step
    float contFrames = 3;            // a gap up to this many frames keeps the full move cost (and the AI's speed limit)
    float gapFrames = 20;            // ... longer gaps weaken it, past this the next sound starts afresh
    float warmFrames = 50;           // learned frames before the median is trusted for creak decisions
    float medianGlideSt = 0.3f;      // the median in use moves at most this per frame
    // the pitch handed to the AI voice
    float aiBandSt = 9;              // up to this above the voice's median it is left alone ...
    float aiMaxSt = 11;              // ... beyond it eased so it never goes further than this (12 before 3.1.1: on a
                                     // note held that high, Woman's voice dropped an octave; 11 keeps it whole)
    float aiBandLowSt = 6;           // the same below the voice's median (a voice model sounds strained low)
    float aiMinSt = 9;
    float aiHoldFrames = 8;          // an aperiodic moment this soon after voice keeps the AI voice singing
    float aiSlewSt = 2;              // the most it moves per frame inside voiced sound
    float aiClampMode = 1;           // 3.2: 1 = no +-15 half-step limit on the AI pitch (the band and 60-880 Hz only),
                                     // 0 = the limit as before (only the AI stream reads it: Natural is unchanged)
    // the AI voice's own idea of the speaker's median (Natural keeps the one above): a held note doesn't teach it,
    // and once it knows the speaker it moves slowly, so a long note stays where it was sung
    float aiMedianMode = 1;          // 0 = the same median as Natural (before 3.1), 1 = the AI's own
    float aiSteadyFrames = 30;       // heldMode 0 only (3.1.0's rule for the AI): a voiced stretch this long within
    float aiSteadySt = 0.8f;         // aiSteadySt of its own mean is a held note
    float aiMedianGlideSt = 0.01f;   // once it knows the speaker: the most it moves per frame
    float aiMedianWarmFrames = 300;  // ... after this many learned frames (before: as fast as Natural's)
    // held notes (3.1.1, see the top of this file): both medians leave them out and stand still while one is held
    float heldMode = 1;              // 0 = as 3.1.0 (frames learned at once, the AI's steady rule, whole-bin medians)
    float heldFrames = 40;           // the slow line stays within heldSt for this many voiced frames: a held note
    float heldSt = 1.0f;
    float heldLineFrames = 16;       // the slow line: the mean of this many voiced frames (one vibrato cycle)
    float heldGapFrames = 8;         // a voiced stretch goes on over unvoiced gaps up to this long
    float learnDelayFrames = 150;    // a stretch's frames are learned when it is over, or this late at most (so the
                                     // start of a held note, even a slow scoop into it, isn't learned)
    float medianSlowSt = 0.05f;      // Natural's median in use, once it knows the speaker: the most it moves per frame
    // 3.4 (hum34 0 = all of these as 3.3)
    float floorMode = 1;             // voiced frames stay out of the noise floor (0: every frame counts, as before)
    float floorVoiceS = 20;          // ... unless the voice has gone on this long without a pause (a tone in the room)
    float floorGapFrames = 30;       // ... a pause: this many unvoiced frames in a row
    float voicedKeepDb = 8;          // a voice going on stays voiced down to voicedMinDb - this ...
    float voicedKeepFloorDb = 4;     // ... and to the noise floor + voicedAboveFloorDb - this
    // sung passages (a hummed or sung tune; only the AI voice's pitch and the medians' learning change)
    float singMode = 1;              // 0 = off (as 3.3)
    float singNoteFrames = 15;       // a voiced frame is note-like when the last this many voiced frames ...
    float singNoteSt = 1;            // ... stay within this many half-steps
    float singWindow = 200;          // the share of note-like frames among the last this many voiced frames ...
    float singOnShare = 0.45f;       // ... above this: a sung passage (speech stays below 0.38 on every set tried)
    float singOffShare = 0.30f;      // ... below this: speech again
    float singGlideFrames = 50;      // the AI pitch moves between the two mappings over this many frames
    float singTopSt = 5;             // a sung passage whose slow middle is more than this above the speaker's median
                                     // is moved down as a whole (keeps the tune instead of squashing it at the top)
    float singResetFrames = 1000;    // this long without voice: start afresh
};

struct TuneKey {
    const char *name;
    float Tuning::*field;
};
const TuneKey kTuneKeys[] = {
    {"yinThreshold", &Tuning::yinThreshold}, {"voicedAp", &Tuning::voicedAp},
    {"voicedAboveFloorDb", &Tuning::voicedAboveFloorDb}, {"voicedMinDb", &Tuning::voicedMinDb},
    {"creakHz", &Tuning::creakHz}, {"creakRatio", &Tuning::creakRatio}, {"creakJitter", &Tuning::creakJitter},
    {"creakApLow", &Tuning::creakApLow}, {"creakApHigh", &Tuning::creakApHigh}, {"smoothMs", &Tuning::smoothMs},
    {"formantGlideMs", &Tuning::formantGlideMs}, {"strengthGlideS", &Tuning::strengthGlideS},
    {"maxSemitones", &Tuning::maxSemitones}, {"medianSeconds", &Tuning::medianSeconds},
    {"seedFrames", &Tuning::seedFrames}, {"eqMaxDb", &Tuning::eqMaxDb}, {"eqStepDb", &Tuning::eqStepDb},
    {"eqSeconds", &Tuning::eqSeconds}, {"eqStartSeconds", &Tuning::eqStartSeconds},
    {"presenceHz", &Tuning::presenceHz}, {"presenceQ", &Tuning::presenceQ}, {"sibilanceHz", &Tuning::sibilanceHz},
    {"breathAttackMs", &Tuning::breathAttackMs}, {"breathReleaseMs", &Tuning::breathReleaseMs},
    {"octUpCost", &Tuning::octUpCost}, {"octDownCost", &Tuning::octDownCost}, {"jumpCost", &Tuning::jumpCost},
    {"rangeSt", &Tuning::rangeSt}, {"rangeCost", &Tuning::rangeCost}, {"contFrames", &Tuning::contFrames},
    {"gapFrames", &Tuning::gapFrames}, {"warmFrames", &Tuning::warmFrames}, {"seedFarSt", &Tuning::seedFarSt},
    {"seedFarFade", &Tuning::seedFarFade},
    {"medianGlideSt", &Tuning::medianGlideSt}, {"aiBandSt", &Tuning::aiBandSt}, {"aiMaxSt", &Tuning::aiMaxSt},
    {"aiBandLowSt", &Tuning::aiBandLowSt}, {"aiMinSt", &Tuning::aiMinSt}, {"aiHoldFrames", &Tuning::aiHoldFrames},
    {"aiSlewSt", &Tuning::aiSlewSt}, {"aiMedianMode", &Tuning::aiMedianMode}, {"aiSteadyFrames", &Tuning::aiSteadyFrames},
    {"aiSteadySt", &Tuning::aiSteadySt}, {"aiMedianGlideSt", &Tuning::aiMedianGlideSt},
    {"aiMedianWarmFrames", &Tuning::aiMedianWarmFrames}, {"heldMode", &Tuning::heldMode},
    {"heldFrames", &Tuning::heldFrames}, {"heldSt", &Tuning::heldSt}, {"heldLineFrames", &Tuning::heldLineFrames},
    {"heldGapFrames", &Tuning::heldGapFrames}, {"learnDelayFrames", &Tuning::learnDelayFrames},
    {"medianSlowSt", &Tuning::medianSlowSt}, {"aiClampMode", &Tuning::aiClampMode},
    {"floorMode", &Tuning::floorMode}, {"floorVoiceS", &Tuning::floorVoiceS}, {"floorGapFrames", &Tuning::floorGapFrames},
    {"voicedKeepDb", &Tuning::voicedKeepDb}, {"voicedKeepFloorDb", &Tuning::voicedKeepFloorDb},
    {"singMode", &Tuning::singMode}, {"singNoteFrames", &Tuning::singNoteFrames}, {"singNoteSt", &Tuning::singNoteSt},
    {"singWindow", &Tuning::singWindow}, {"singOnShare", &Tuning::singOnShare}, {"singOffShare", &Tuning::singOffShare},
    {"singGlideFrames", &Tuning::singGlideFrames}, {"singTopSt", &Tuning::singTopSt},
    {"singResetFrames", &Tuning::singResetFrames},
};

struct VoiceKey {
    const char *name;
    float VoiceChangerVoice::*field;
};
const VoiceKey kVoiceKeys[] = {
    {"targetHz", &VoiceChangerVoice::targetHz}, {"assumedInputHz", &VoiceChangerVoice::assumedInputHz},
    {"intonation", &VoiceChangerVoice::intonation}, {"formant", &VoiceChangerVoice::formant},
    {"breathDb", &VoiceChangerVoice::breathDb}, {"presenceDb", &VoiceChangerVoice::presenceDb},
    {"sibilanceKeep", &VoiceChangerVoice::sibilanceKeep}, {"eqAmount", &VoiceChangerVoice::eqAmount},
};
constexpr int kVoiceKeyCount = sizeof(kVoiceKeys) / sizeof(kVoiceKeys[0]);

inline float semitones(double ratio) { return (float)(12 * std::log2(ratio)); }

inline int pitchBin(double hz) {
    if (!(hz > 0)) return 0;
    const int b = (int)std::lround(48 * std::log2(hz / kBinLowHz));
    return std::clamp(b, 0, kPitchBins - 1);
}
inline double binHz(int b) { return kBinLowHz * std::pow(2.0, b / 48.0); }

// Median of a histogram (the bin where the running count passes half), with an extra weight on one bin.
inline int medianBin(const float *bins, int seedBin, float seedWeight) {
    float total = seedWeight;
    for (int b = 0; b < kPitchBins; ++b) total += bins[b];
    if (total <= 0) return seedBin;
    const float half = total / 2;
    float run = 0;
    for (int b = 0; b < kPitchBins; ++b) {
        run += bins[b] + (b == seedBin ? seedWeight : 0);
        if (run >= half) return b;
    }
    return kPitchBins - 1;
}

// The same median read between bins (Hz): where inside the bin the running count passes half (a bin's frames are
// taken as spread evenly over it), so the median moves a little with each frame instead of a quarter step at once.
inline double medianHzBetween(const float *bins, int seedBin, float seedWeight) {
    float total = seedWeight;
    for (int b = 0; b < kPitchBins; ++b) total += bins[b];
    if (total <= 0) return binHz(seedBin);
    const float half = total / 2;
    float run = 0;
    for (int b = 0; b < kPitchBins; ++b) {
        const float here = bins[b] + (b == seedBin ? seedWeight : 0);
        if (here > 0 && run + here >= half) return kBinLowHz * std::pow(2.0, (b - 0.5 + (half - run) / here) / 48.0);
        run += here;
    }
    return binHz(kPitchBins - 1);
}

// xorshift32: the breath noise (the same every time after a reset, so offline renders repeat exactly).
inline float noise(uint32_t &state) {
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    return (float)((double)state / 2147483648.0 - 1.0);
}

double nowNs() {
    return (double)std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

}  // namespace

struct VoiceChanger {
    // Fixed at creation.
    double rate = 48000;
    int maxFrames = 0;
    int down = 3;            // thinning factor to ~16 kHz
    double analysisRate = 16000;
    int hop = 160;           // 10 ms at the analysis rate
    int hopIn = 480;         // ... at the chain rate
    int window = 400;        // YIN integration window (25 ms)
    int tauMin = 26, tauMax = 291;
    int span = 691;          // window + tauMax
    int decSize = 2048;      // analysis ring (power of two)
    int inSize = 32768;      // original delay line (power of two)
    bool bandOk[kBands] = {};    // band below 0.45 x rate
    bool eqOk[kEq] = {};
    bool breathOk[kBreath] = {};
    double eqHz[kEq] = {};

    // Buffers made in voicechanger_new.
    float *dec = nullptr;    // thinned mic, ring
    float *lin = nullptr;    // one analysis span, oldest first
    double *energy = nullptr;  // running sum of squares over `lin`
    float *diff = nullptr;   // YIN difference / normalised difference
    float *original = nullptr; // mic delay line

    // Settings.
    Tuning tuning;
    VoiceChangerVoice voice{};  // the voice in use (with tuned overrides)
    VoiceChangerVoice asSet{};  // as given to voicechanger_set
    bool hasVoice = false;
    bool overridden[kVoiceKeyCount] = {};
    float overrideValue[kVoiceKeyCount] = {};
    float strengthTarget = 0, strength = 0;

    // Analysis state.
    Biquad antiAlias[3];
    int decPhase = 0;
    int64_t decCount = 0;
    int64_t inPos = 0;          // mic samples given since the last reset
    int64_t hops = 0;
    float levelHist[kLevelBins] = {};
    uint8_t levelRing[512] = {};
    int levelCount = 0, levelAt = 0;
    // Octave errors: the last voiced frame's three choices (half, YIN, double), their path costs, and how many
    // frames ago it was.
    float octHz[3] = {};
    float octPath[3] = {};
    int octAge = 999;
    // The last three frames (for the median of 3): corrected pitch, aperiodicity, level, centre.
    float lastF0[3] = {}, lastAp[3] = {1, 1, 1}, lastLevel[3] = {-140, -140, -140};
    int64_t lastCentre[3] = {};
    // Mapping.
    float mapBins[kPitchBins] = {};
    int16_t mapRing[1024] = {};
    int mapCount = 0, mapAt = 0, mapCap = 400;
    int seedBin = 0;
    float seedWeight = 0;
    bool seeded = false;
    float speakerHz = 0;        // the speaker's median measured earlier (voicechanger_set_speaker), 0 = none
    float speakerWeight = 0;
    int64_t learned = 0;        // frames the median has learned from
    float medianUse = 0;        // the median in use (glides toward the measured one), 0 = not yet
    float prev[3] = {};
    int prevCount = 0;
    float shiftFrame = 0;       // mapped shift (half-steps, before strength), smoothed per frame
    float shiftNow = 0;         // ... gliding per callback toward shiftFrame
    bool shiftKnown = false;
    float shapePower = 1;       // the formant exponent before strength (|off| / full move, 0 ... 1)
    double shapeLogNow = 0;     // log of the voice shape in use (glides)
    float lastGoodHz = 0;
    float lastDev = 0;          // the last good frame's distance from the median (half-steps)
    int lastGoodAge = 999;
    float aiHz = 0;             // the last pitch handed to the AI voice, and how many frames ago
    int aiAge = 999;
    int voicedAge = 999;        // frames since the last voiced frame (after the median of 3)
    float medianHz = 120;
    // The AI voice's own median (aiMedianMode 1): its own histogram without held notes, and a slower glide.
    float aiBins[kPitchBins] = {};
    int16_t aiRing[1024] = {};
    int aiCount = 0, aiAt = 0;
    int64_t aiLearned = 0;
    float aiMedianUse = 0;
    int steadyRun = 0;          // heldMode 0: voiced frames in a row near their own mean (a held note)
    float steadyMean = 0;
    float aiLastDev = 0;
    // Held notes (heldMode 1): frames waiting to be learned (learnDelayFrames late), the voiced stretch going on now
    // and whether it is a held note, its last voiced pitches and its slow line.
    struct Pending { float f0; int32_t stretch; int64_t frame; };
    static constexpr int kPending = 256;
    Pending pending[kPending] = {};
    int pendAt = 0, pendCount = 0;  // oldest entry, count
    int64_t mapFrames = 0;
    int32_t stretch = 0;
    int stretchGap = 1000;          // unvoiced frames since the stretch's last voiced one
    bool held = false;              // the stretch going on is a held note
    static constexpr int kLine = 64;
    float stRing[kLine] = {};       // its voiced frames' pitches (half-steps), newest at stAt - 1
    int stAt = 0, stCount = 0;
    float lineRing[kLine] = {};     // its slow line, one value per voiced frame
    int lineAt = 0, lineCount = 0;
    int lineRejects = 0;            // frames in a row too far from the line
    int floorRun = 0, floorGap = 1000;  // 3.4: voiced frames since the last pause, unvoiced frames in a row
    // 3.4 sung passages: the last voiced pitches (half-steps), note-like flags of the last voiced frames, the passage
    // state and how far it has moved to the sung mapping (0 ... 1), the slow middle of the voice above its median
    static constexpr int kSingNotes = 64, kSingFlags = 512;
    float singSt[kSingNotes] = {};
    int singStAt = 0, singStCount = 0, singGap = 0, singQuiet = 0;
    uint8_t singFlag[kSingFlags] = {};
    int singFlagAt = 0, singFlagCount = 0, singFlagSum = 0;
    bool singOn = false;
    float sing = 0, devSlow = 0;
    // Decisions for post.
    uint8_t flagRing[kFlagFrames] = {};
    int64_t flagCentre[kFlagFrames] = {};
    int64_t flagLatest = -1;
    // Counts.
    int64_t frames = 0, voicedFrames = 0, creakFrames = 0;
    // Newest output.
    float pitchScale = 1, formantScale = 1, semitonesNow = 0;

    // Post state.
    Biquad sibTop, sibOrigTop;
    float sibKeep = 0, sibStep = 0;
    float voicedNow = 0, voicedStep = 0;
    // tone measurement bank (float, all bands side by side so the loop runs in vector steps)
    alignas(16) float bb0[kBandsPadded] = {}, bb2[kBandsPadded] = {}, ba1[kBandsPadded] = {}, ba2[kBandsPadded] = {};
    alignas(16) float bz1[kBandsPadded] = {}, bz2[kBandsPadded] = {}, bacc[kBandsPadded] = {};
    double measured[kBands] = {};     // long-term band power of voiced output
    int64_t measuredBlocks = 0;
    int blockAt = 0;
    float blockVoiced = 0;
    Biquad eq[kEq];
    float eqTarget[kEq] = {}, eqSlow[kEq] = {}, eqApplied[kEq] = {};
    Biquad presence;
    float presenceApplied = 0;
    Biquad breathBand[kBreath], breathNoise[kBreath];
    double breathNorm[kBreath] = {};
    float breathEnv[kBreath] = {};
    float breathAttack = 0, breathRelease = 0;
    uint32_t noiseState = 0x9E3779B9u;

    // Timing.
    double spentNs = 0, spentFrames = 0;
    double windowNs = 0, windowFrames = 0, worstMs = 0;

    void applyVoice() {
        voice = asSet;
        for (int k = 0; k < kVoiceKeyCount; ++k)
            if (overridden[k]) voice.*(kVoiceKeys[k].field) = overrideValue[k];
        if (!(voice.targetHz > 0)) voice.targetHz = 200;
        if (!(voice.assumedInputHz > 0)) voice.assumedInputHz = 120;
        if (!(voice.formant > 0)) voice.formant = 1;
        // The first guess of the speaker's median: measured earlier if known, else the voice's assumed input.
        seedBin = pitchBin(speakerHz > 0 ? speakerHz : voice.assumedInputHz);
        if (!seeded) {
            seedWeight = speakerHz > 0 ? speakerWeight : tuning.seedFrames;
            seeded = true;
        }
        mapCap = std::clamp((int)std::lround(tuning.medianSeconds * 100), 10, 1024);
    }

    bool warm() const { return learned >= (int64_t)tuning.warmFrames || speakerHz > 0; }
    bool heldRules() const { return tuning.heldMode >= 0.5f; }

    // Once a frame: the median in use moves toward the measured one, at most medianGlideSt (heldMode 1: once the
    // speaker is known at most medianSlowSt, and not at all while a note is held).
    void glideMedian(float measured) {
        if (!(medianUse > 0)) { medianUse = measured; return; }
        if (heldRules() && held) return;
        const float most = heldRules() && warm() ? std::min(tuning.medianGlideSt, tuning.medianSlowSt) : tuning.medianGlideSt;
        const float d = std::clamp(semitones(measured / medianUse), -most, most);
        medianUse = (float)(medianUse * std::exp2(d / 12));
    }

    // heldMode 1, once a frame (before the mapping): follows the voiced stretch going on (f0 > 0 = voiced) and
    // decides whether it is a held note; then learns the frames that waited long enough and weren't in one.
    void followStretch(float f0) {
        const int gapMax = std::clamp((int)tuning.heldGapFrames, 0, 100);
        mapFrames++;
        if (f0 > 0) {
            if (stretchGap > gapMax) {  // a new stretch
                stretch++;
                held = false;
                stCount = lineCount = lineRejects = 0;
            }
            stretchGap = 0;
            const int L = std::clamp((int)tuning.heldLineFrames, 1, kLine);
            const int need = std::clamp((int)tuning.heldFrames, 2, kLine);
            const float s = semitones(f0 / 100.0);
            float line = 0;
            const int have = std::min(stCount, L);
            for (int k = 1; k <= have; ++k) line += stRing[(stAt - k + kLine) % kLine];
            if (have > 0) line /= (float)have;
            // an octave slip or a creak frame doesn't move the line; more than 3 in a row: the line starts again there
            const bool off = have > 0 && std::fabs(s - line) >= 3;
            lineRejects = off ? lineRejects + 1 : 0;
            if (lineRejects > 3) {
                stCount = lineCount = 0;
                lineRejects = 0;
            }
            if (stCount == 0 || !off) {
                stRing[stAt] = s;
                stAt = (stAt + 1) % kLine;
                stCount = std::min(stCount + 1, kLine);
                const int n = std::min(stCount, L);
                line = 0;
                for (int k = 1; k <= n; ++k) line += stRing[(stAt - k + kLine) % kLine];
                line /= (float)n;
                lineRing[lineAt] = line;
                lineAt = (lineAt + 1) % kLine;
                lineCount = std::min(lineCount + 1, kLine);
            }
            if (!held && lineCount >= need) {
                float lo = 1e9f, hi = -1e9f;
                for (int k = 1; k <= need; ++k) {
                    const float v = lineRing[(lineAt - k + kLine) % kLine];
                    lo = std::min(lo, v);
                    hi = std::max(hi, v);
                }
                if (hi - lo <= tuning.heldSt) {  // a held note: none of this stretch is learned
                    held = true;
                    for (int k = 0; k < pendCount; ++k) {
                        Pending &p = pending[(pendAt + k) % kPending];
                        if (p.stretch == stretch) p.f0 = 0;
                    }
                }
            }
        } else if (stretchGap < 1000) {
            stretchGap++;
            if (stretchGap > gapMax) held = false;  // the note is over
        }
        // a stretch's frames are learned once it is over (and wasn't a held note), or learnDelayFrames late at most
        const int64_t delay = std::clamp((int64_t)tuning.learnDelayFrames, (int64_t)0, (int64_t)kPending - 8);
        while (pendCount > 0 && (pending[pendAt].stretch != stretch || stretchGap > gapMax ||
                                 pending[pendAt].frame <= mapFrames - delay)) {
            const float f = pending[pendAt].f0;
            pendAt = (pendAt + 1) % kPending;
            pendCount--;
            if (f > 0) learnMedian(f);
        }
    }

    // 3.4, once a frame (f0 > 0 = voiced): is this a sung passage? A frame is note-like when the last singNoteFrames
    // voiced frames (no gap over 3 frames) stay within singNoteSt; a passage is sung when more than singOnShare of
    // the last singWindow voiced frames were note-like, and speech again below singOffShare. `sing` moves toward it
    // over singGlideFrames.
    void followSinging(float f0) {
        if (tuning.singMode < 0.5f) { singOn = false; sing = 0; return; }
        const int N = std::clamp((int)tuning.singNoteFrames, 2, kSingNotes);
        const int W = std::clamp((int)tuning.singWindow, 10, kSingFlags);
        if (f0 > 0) {
            singGap = 0;
            singQuiet = 0;
            singSt[singStAt] = semitones(f0 / 100.0);
            singStAt = (singStAt + 1) % kSingNotes;
            singStCount = std::min(singStCount + 1, kSingNotes);
            bool note = false;
            if (singStCount >= N) {
                float lo = 1e9f, hi = -1e9f;
                for (int k = 1; k <= N; ++k) {
                    const float v = singSt[(singStAt - k + kSingNotes) % kSingNotes];
                    lo = std::min(lo, v);
                    hi = std::max(hi, v);
                }
                note = hi - lo < tuning.singNoteSt;
            }
            if (singFlagCount >= W) singFlagSum -= singFlag[(singFlagAt - W + kSingFlags) % kSingFlags];
            else singFlagCount++;
            singFlag[singFlagAt] = note ? 1 : 0;
            singFlagSum += note ? 1 : 0;
            singFlagAt = (singFlagAt + 1) % kSingFlags;
            const float share = singFlagCount >= W / 2 ? (float)singFlagSum / (float)singFlagCount : 0.0f;
            if (!singOn && share > tuning.singOnShare) singOn = true;
            else if (singOn && share < tuning.singOffShare) singOn = false;
        } else {
            if (++singGap > 3) singStCount = 0;
            if (++singQuiet > (int)tuning.singResetFrames) {  // a long silence: start afresh
                singOn = false;
                singFlagAt = singFlagCount = singFlagSum = 0;
                singQuiet = 0;
            }
        }
        // (not while a note is held: the change of mapping would bend it; it moves at the next note or pause)
        const float step = 1.0f / std::max(1.0f, tuning.singGlideFrames);
        if (!(heldRules() && held)) sing = std::clamp(sing + std::clamp((singOn ? 1.0f : 0.0f) - sing, -step, step), 0.0f, 1.0f);
    }

    // A frame the speaker's median may learn from: at once (heldMode 0), or learnDelayFrames later unless it turns
    // out to be part of a held note.
    void learn(float f0) {
        if (singOn) return;  // 3.4: a sung passage doesn't teach the medians (a tune isn't the speaking voice)
        if (!heldRules()) { learnMedian(f0); return; }
        if (held) return;
        if (pendCount == kPending) {  // (can't happen with the delay limited above) learn the oldest now
            const float f = pending[pendAt].f0;
            pendAt = (pendAt + 1) % kPending;
            pendCount--;
            if (f > 0) learnMedian(f);
        }
        pending[(pendAt + pendCount) % kPending] = {f0, stretch, mapFrames};
        pendCount++;
    }

    // The pitch handed to the AI voice: eased into a band around the voice's own median (what this target pitch
    // would be for the speaker's median), and moving at most aiSlewSt per frame inside voiced sound.
    float aiPitch(float hz, float bandCentre) {
        if (!(hz > 0)) {
            if (aiAge < 1000) aiAge++;
            return 0;
        }
        if (bandCentre > 0) {
            const float up = std::max(0.0f, tuning.aiBandSt), upRoom = std::max(0.01f, tuning.aiMaxSt - up);
            const float down = std::max(0.0f, tuning.aiBandLowSt), downRoom = std::max(0.01f, tuning.aiMinSt - down);
            float s = semitones(hz / bandCentre);
            // 3.4: a sung passage that sits high above the speaker's median moves down as a whole (the band below
            // would otherwise squash its top notes into one)
            if (sing > 0) s -= sing * std::max(0.0f, devSlow - tuning.singTopSt);
            if (s > up) s = up + upRoom * std::tanh((s - up) / upRoom);
            else if (s < -down) s = -down - downRoom * std::tanh((-down - s) / downRoom);
            hz = (float)(bandCentre * std::exp2(s / 12));
        }
        if (tuning.aiClampMode >= 0.5f) hz = std::clamp(hz, 60.0f, 880.0f);  // 3.2: (no +-15 half-step limit)
        if (aiHz > 0 && aiAge <= (int)tuning.contFrames && tuning.aiSlewSt > 0) {
            const float d = std::clamp(semitones(hz / aiHz), -tuning.aiSlewSt, tuning.aiSlewSt);
            hz = (float)(aiHz * std::exp2(d / 12));
        }
        aiHz = hz;
        aiAge = 0;
        return hz;
    }

    void pushMap(int bin) {
        while (mapCount >= mapCap) {  // oldest out
            const int oldest = (mapAt - mapCount + 1024) % 1024;
            mapBins[mapRing[oldest]] -= 1;
            mapCount--;
        }
        mapRing[mapAt] = (int16_t)bin;
        mapBins[bin] += 1;
        mapAt = (mapAt + 1) % 1024;
        mapCount++;
    }

    void learnMedian(float f0) {
        pushMap(pitchBin(f0));
        learned++;
        // The first guess fades as real frames come in: slowly while they fit it, fast when they are far from it (a
        // speaker the guess doesn't fit, e.g. a man using the Man voice).
        const bool far = std::fabs(semitones(f0 / binHz(seedBin))) > tuning.seedFarSt;
        seedWeight = std::max(0.0f, seedWeight - (far ? tuning.seedFarFade : 0.25f));
        learnAiMedian(f0);
    }

    // The AI's median learns the same frames, except inside a held note (so holding a note doesn't pull it there;
    // heldMode 1 leaves held notes out before this, for both medians).
    void learnAiMedian(float f0) {
        if (!heldRules()) {
            const float s = semitones(f0 / 100.0);
            if (steadyRun > 0 && std::fabs(s - steadyMean) < tuning.aiSteadySt) {
                steadyRun = std::min(steadyRun + 1, 100000);
                steadyMean += (s - steadyMean) / (float)std::min(steadyRun, 50);
            } else {
                steadyRun = 1;
                steadyMean = s;
            }
            if (steadyRun > (int)tuning.aiSteadyFrames) return;
        }
        const int bin = pitchBin(f0);
        while (aiCount >= mapCap) {
            const int oldest = (aiAt - aiCount + 1024) % 1024;
            aiBins[aiRing[oldest]] -= 1;
            aiCount--;
        }
        aiRing[aiAt] = (int16_t)bin;
        aiBins[bin] += 1;
        aiAt = (aiAt + 1) % 1024;
        aiCount++;
        aiLearned++;
    }

    // Once a frame: the AI's median in use (aiMedianMode 1) moves toward its measured one; fast while it is still
    // finding the speaker (like Natural's), then at most aiMedianGlideSt per frame.
    float aiMedianNow() {
        const float measured = heldRules() ? (float)medianHzBetween(aiBins, seedBin, seedWeight)
                                           : (float)binHz(medianBin(aiBins, seedBin, seedWeight));
        if (!(aiMedianUse > 0)) { aiMedianUse = measured; return aiMedianUse; }
        if (heldRules() && held) return aiMedianUse;  // stands still while a note is held
        const bool finding = aiLearned < (int64_t)tuning.aiMedianWarmFrames && !(speakerHz > 0);
        const float most = finding ? tuning.medianGlideSt : tuning.aiMedianGlideSt;
        const float d = std::clamp(semitones(measured / aiMedianUse), -most, most);
        aiMedianUse = (float)(aiMedianUse * std::exp2(d / 12));
        return aiMedianUse;
    }

    float noiseFloor() const {  // 10th percentile of the levels of the last ~5 s
        if (levelCount == 0) return -140;
        const float want = 0.1f * levelCount;
        float run = 0;
        for (int b = 0; b < kLevelBins; ++b) {
            run += levelHist[b];
            if (run >= want) return (float)(b - 140);
        }
        return 0;
    }

    void pushLevel(float db) {
        const int b = std::clamp((int)std::lround(db) + 140, 0, kLevelBins - 1);
        const int cap = (int)sizeof(levelRing);
        if (levelCount == cap) levelHist[levelRing[levelAt]] -= 1;
        else levelCount++;
        levelRing[levelAt] = (uint8_t)b;
        levelHist[b] += 1;
        levelAt = (levelAt + 1) % cap;
    }

    // YIN on `lin` (span samples). Returns pitch (Hz), aperiodicity and level (dBFS) of the middle. At or below
    // `quietDb` only the level is worked out (pitch 0, aperiodicity 1): the frame is too quiet for them to be used.
    void yin(float &f0, float &ap, float &levelDb, float quietDb) {
        const int W = window, T = tauMax;
        energy[0] = 0;
        for (int i = 0; i < span; ++i) energy[i + 1] = energy[i] + (double)lin[i] * lin[i];
        const int mid = T / 2;
        levelDb = (float)(10 * std::log10((energy[mid + W] - energy[mid]) / W + 1e-12));
        if (levelDb <= quietDb) {
            f0 = 0;
            ap = 1;
            return;
        }
        const double e0 = energy[W];
        diff[0] = 0;
        double sum = 0;
        for (int tau = 1; tau <= T; ++tau) {
            const float *a = lin, *b = lin + tau;
            float r = 0;
            {
#pragma clang fp reassociate(on)
                for (int i = 0; i < W; ++i) r += a[i] * b[i];
            }
            const double d = std::max(0.0, e0 + (energy[tau + W] - energy[tau]) - 2.0 * r);
            sum += d;
            diff[tau] = (float)(sum > 1e-12 ? d * tau / sum : 1.0);
        }
        int tau = -1;
        for (int t = tauMin; t < T; ++t) {
            if (diff[t] < tuning.yinThreshold) {
                while (t + 1 < T && diff[t + 1] < diff[t]) ++t;
                tau = t;
                break;
            }
        }
        if (tau < 0) {
            tau = tauMin;
            for (int t = tauMin; t < T; ++t) if (diff[t] < diff[tau]) tau = t;
        }
        double frac = 0;
        if (tau >= 1 && tau < T) {
            const double y0 = diff[tau - 1], y1 = diff[tau], y2 = diff[tau + 1];
            const double den = y0 - 2 * y1 + y2;
            if (std::fabs(den) > 1e-12) frac = std::clamp(0.5 * (y0 - y2) / den, -1.0, 1.0);
        }
        f0 = (float)(analysisRate / (tau + frac));
        ap = diff[tau];
    }

    // Every 10 ms of thinned sound: track, fix octave jumps, then decide the frame before (median of 3) and map it.
    void analyseHop(float extra, VoiceChangerPitch *out) {
        for (int i = 0; i < span; ++i) lin[i] = dec[(decCount - span + i) & (decSize - 1)];
        float f0, ap, level;
        // (at or below both lowest levels, levelOk below and frameLevelOk at the next frame, the pitch is never used)
        yin(f0, ap, level, std::min(tuning.voicedMinDb, tuning.voicedMinDb - (octAge <= 2 ? tuning.voicedKeepDb : 0.0f)));
        const bool floorVoice = tuning.floorMode >= 0.5f;  // 3.4 (0 = 3.3: every frame counts toward the noise floor)
        if (!floorVoice) pushLevel(level);
        const float floorDb = noiseFloor();
        // 3.4: a voice that is going on (voiced 1-2 frames ago) may fade a little below the levels a new one needs, so
        // the quiet end of a hummed note or a soft word doesn't drop out (voicedKeepDb, voicedKeepFloorDb; 0 = as 3.3)
        const bool going = octAge <= 2;
        const float keepAbs = going ? tuning.voicedKeepDb : 0.0f, keepFloor = going ? tuning.voicedKeepFloorDb : 0.0f;
        const bool levelOk = level > floorDb + tuning.voicedAboveFloorDb - keepFloor && level > tuning.voicedMinDb - keepAbs;
        const bool voiced = ap < tuning.voicedAp && levelOk;
        if (floorVoice) {
            // 3.4: a voice is not the room's noise. Voiced frames stay out of the noise floor (before, a hum or a held
            // note longer than ~4.6 s filled the floor's 5 s and then fell 10 dB short of it: from there on it was "not
            // voiced" and the AI voice lost its pitch). After floorVoiceS of voice with no pause of floorGapFrames they
            // count again, so a steady tone in the room that never stops still becomes the floor.
            if (voiced) { floorGap = 0; floorRun = std::min(floorRun + 1, 1 << 30); }
            else if (++floorGap > (int)tuning.floorGapFrames) { floorRun = 0; floorGap = std::min(floorGap, 1 << 20); }
            if (!voiced || floorRun > (int)(tuning.floorVoiceS * 100)) pushLevel(level);
        }
        float corrected = 0, settled = -1;  // settled: the frame before, now that this one is in (-1 = no change)
        if (voiced) {
            static constexpr float kMul[3] = {0.5f, 1, 2};
            const float stepCost[3] = {tuning.octDownCost, 0, tuning.octUpCost};
            const bool ranged = warm() && medianUse > 0;
            const bool linked = octAge <= (int)tuning.gapFrames;
            const float w = tuning.jumpCost * std::min(1.0f, std::max(1.0f, tuning.contFrames) / (float)std::max(1, octAge));
            float hz[3], path[3];
            int from[3] = {1, 1, 1};
            for (int k = 0; k < 3; ++k) {
                hz[k] = f0 * kMul[k];
                float cost = stepCost[k];
                if (!(hz[k] >= 50 && hz[k] <= 650)) cost += 1e6f;
                if (ranged) cost += tuning.rangeCost * std::max(0.0f, std::fabs(semitones(hz[k] / medianUse)) - tuning.rangeSt);
                if (linked) {
                    float best = 1e30f;
                    for (int j = 0; j < 3; ++j) {
                        const float c = octPath[j] + w * std::fabs(semitones(hz[k] / octHz[j]));
                        if (c < best) { best = c; from[k] = j; }
                    }
                    cost += best;
                }
                path[k] = cost;
            }
            int pick = 1;
            for (int k = 0; k < 3; ++k) if (path[k] < path[pick]) pick = k;
            const float low = path[pick];
            for (int k = 0; k < 3; ++k) { octPath[k] = std::min(path[k] - low, 1e6f); }
            if (linked && octAge == 1) settled = octHz[from[pick]];  // the frame before, seen from this one
            for (int k = 0; k < 3; ++k) octHz[k] = hz[k];
            octAge = 0;
            corrected = hz[pick];
        }
        if (octAge < 1000) octAge++;
        // shift the last three frames
        for (int k = 0; k < 2; ++k) {
            lastF0[k] = lastF0[k + 1]; lastAp[k] = lastAp[k + 1];
            lastLevel[k] = lastLevel[k + 1]; lastCentre[k] = lastCentre[k + 1];
        }
        if (settled > 0 && lastF0[1] > 0) lastF0[1] = settled;  // (lastF0[1] is now the frame before)
        lastF0[2] = corrected; lastAp[2] = ap; lastLevel[2] = level;
        lastCentre[2] = (decCount - span / 2) * down;
        hops++;
        if (hops < 2) return;
        // the frame before: median of 3 when all three are voiced
        float f = lastF0[1];
        if (hops >= 3 && f > 0 && lastF0[0] > 0 && lastF0[2] > 0) {
            const float a = lastF0[0], b = lastF0[1], c = lastF0[2];
            f = std::max(std::min(a, b), std::min(std::max(a, b), c));
        }
        const bool frameLevelOk = lastLevel[1] > floorDb + tuning.voicedAboveFloorDb && lastLevel[1] > tuning.voicedMinDb;
        mapFrame(f, lastAp[1], frameLevelOk, lastCentre[1], extra, out);
    }

    void mapFrame(float f0, float ap, bool levelOk, int64_t centre, float extra, VoiceChangerPitch *out) {
        followSinging(f0);
        if (heldRules()) followStretch(f0);
        const float measured = heldRules() ? (float)medianHzBetween(mapBins, seedBin, seedWeight)
                                           : (float)binHz(medianBin(mapBins, seedBin, seedWeight));
        glideMedian(measured);
        const float median = medianUse;  // moves smoothly, so learning the median never makes the pitch jump
        medianHz = median;
        const bool voiced = f0 > 0;
        voicedAge = voiced ? 0 : std::min(voicedAge + 1, 1000);
        if (!voiced && voicedAge > (int)tuning.gapFrames) steadyRun = 0;
        const bool aiOwn = tuning.aiMedianMode >= 0.5f;
        const float aiMedian = aiOwn ? aiMedianNow() : median;  // the median the AI voice's pitch is mapped from
        // the AI's pitch change for a frame this far from its median (half-steps; aiOwn only)
        const bool aiFree = tuning.aiClampMode >= 0.5f;  // 3.2: no +-15 half-step limit on the AI pitch
        // 3.4: in a sung passage the AI voice keeps the tune's steps as sung (intonation 1, not the voice's livelier one)
        const float aiInto = voice.intonation + (1 - voice.intonation) * sing;
        auto aiTotal = [&](float dev) {
            const float total = strength * (semitones(voice.targetHz / aiMedian) + (aiInto - 1) * dev) + extra;
            return aiFree ? total : std::clamp(total, -tuning.maxSemitones, tuning.maxSemitones);
        };
        // the slow middle of the voice above its median (1 s of voiced frames; a held note doesn't move it)
        if (voiced && tuning.singMode >= 0.5f && !(heldRules() && held))
            devSlow += 0.01f * (std::clamp(semitones(f0 / aiMedian), -12.0f, 18.0f) - devSlow);
        bool creak = false, rough = false;
        if (voiced) {
            if (prevCount < 3) prev[prevCount++] = f0;
            else { prev[0] = prev[1]; prev[1] = prev[2]; prev[2] = f0; }
            float jitter = 0;
            if (prevCount == 3) {  // zig-zag: the middle frame off the line through its neighbours (not a glide)
                const float mean = (prev[0] + prev[1] + prev[2]) / 3;
                jitter = std::fabs(prev[1] - 0.5f * (prev[0] + prev[2])) / mean;
            }
            rough = jitter > tuning.creakJitter;
            // Until the median is known (the first guess may be far off) only very low and rough frames are creak.
            const bool known = warm();
            creak = f0 < tuning.creakHz || (known && f0 < tuning.creakRatio * measured) || rough;
            // The speaker's median also learns from smooth low frames (a deep voice talks below 70 Hz; without them
            // its median would stay at the first guess). Rough frames and octave-low ones (fry) stay out.
            if (creak && !rough && (f0 >= 0.5f * measured || !known)) learn(f0);
        } else {
            prevCount = 0;
            creak = levelOk && ap >= tuning.creakApLow && ap <= tuning.creakApHigh && lastGoodAge <= 15;
        }
        frames++;
        float target = 0, aiWant = 0;  // aiWant: the pitch the AI voice should sing now (0 = unvoiced)
        if (voiced && !creak) {
            learn(f0);
            const float off = semitones(voice.targetHz / median);
            const float dev = std::clamp(semitones(f0 / median), -12.0f, 12.0f);
            lastDev = dev;
            const float shift = off + (voice.intonation - 1) * dev;
            const float alpha = 1 - std::exp(-10.0f / std::max(1.0f, tuning.smoothMs));
            shiftFrame = shiftKnown ? shiftFrame + alpha * (shift - shiftFrame) : shift;
            shiftKnown = true;
            const float full = std::fabs(semitones(voice.targetHz / voice.assumedInputHz));
            shapePower = full > 0.25f ? std::clamp(std::fabs(off) / full, 0.0f, 1.0f) : (std::fabs(off) > 0.25f ? 1.0f : 0.0f);
            const float total = std::clamp(strength * shiftFrame + extra, -tuning.maxSemitones, tuning.maxSemitones);
            target = f0 * std::exp2(total / 12);
            aiWant = target;
            if (aiOwn) {
                aiLastDev = std::clamp(semitones(f0 / aiMedian), -12.0f, 12.0f);
                aiWant = f0 * std::exp2(aiTotal(aiLastDev) / 12);
            }
            lastGoodHz = target;
            lastGoodAge = 0;
            voicedFrames++;
        } else {
            lastGoodAge++;
            if (creak && lastGoodHz > 0) {
                target = lastGoodHz;  // hold: the pitch stays put through creak
                creakFrames++;
                voicedFrames++;
            }
            if (creak && shiftKnown) {  // the intonation part holds; the offset still follows the median as it learns
                const float shift = semitones(voice.targetHz / median) + (voice.intonation - 1) * lastDev;
                shiftFrame += (1 - std::exp(-10.0f / std::max(1.0f, tuning.smoothMs))) * (shift - shiftFrame);
            }
            // The AI voice through creak: while it sings, it moves with a gradual fall or rise (not below
            // creakRatio x median, mapped) and holds through a sudden drop (an octave drop, creak) or rough frames;
            // a voiced sound that starts in creak starts at its own pitch (not below the floor); an aperiodic
            // moment holds only while the AI voice is still singing (it never starts from an old pitch).
            if (creak && shiftKnown) {
                // (an aperiodic frame keeps it going only up to aiHoldFrames after the last voiced frame)
                const bool going = aiHz > 0 && aiAge <= (int)tuning.contFrames && voicedAge <= (int)tuning.aiHoldFrames;
                const float total = aiOwn ? aiTotal(aiLastDev)
                                          : std::clamp(strength * shiftFrame + extra, -tuning.maxSemitones, tuning.maxSemitones);
                const float floorHz = tuning.creakRatio * aiMedian * std::exp2(total / 12);
                if (going) {
                    float ratio = 1;
                    if (voiced && !rough && prevCount >= 2) {
                        const float r = prev[prevCount - 1] / prev[prevCount - 2];
                        if (std::fabs(semitones(r)) <= 2.5f) ratio = r;
                    }
                    aiWant = std::max(aiHz * ratio, std::min(aiHz, floorHz));
                } else if (voiced) {
                    aiWant = std::max(f0 * std::exp2(total / 12), floorHz);
                }
            }
        }
        // Realistic mode's pitch: the band's centre is where the speaker's median lands.
        const float centreSt = strength * semitones(voice.targetHz / aiMedian) + extra;
        const float bandCentre = shiftKnown ? aiMedian * std::exp2((aiFree ? centreSt : std::clamp(centreSt, -tuning.maxSemitones, tuning.maxSemitones)) / 12) : 0;
        const float aiTarget = aiPitch(aiWant, bandCentre);
        const int64_t index = ++flagLatest;
        flagRing[index % kFlagFrames] = (uint8_t)(voiced || creak);
        flagCentre[index % kFlagFrames] = centre;
        if (out) {
            out->voiced = voiced ? 1 : 0;
            out->f0In = voiced ? f0 : 0;
            out->f0Target = aiTarget;
            if (out->newFrames < VOICECHANGER_MAX_PITCH_FRAMES) {
                out->frameHz[out->newFrames] = aiTarget;
                out->framePos[out->newFrames] = centre;
                out->newFrames++;
            }
        }
    }

    // Was the sound at mic position `pos` voiced (or creak)?
    bool voicedAt(int64_t pos) const {
        if (flagLatest < 0) return false;
        const int64_t latestCentre = flagCentre[flagLatest % kFlagFrames];
        if (pos >= latestCentre) return flagRing[flagLatest % kFlagFrames] != 0;
        const int64_t back = (latestCentre - pos + hopIn / 2) / hopIn;
        if (back >= kFlagFrames || back > flagLatest) return false;
        return flagRing[(flagLatest - back) % kFlagFrames] != 0;
    }

    // Tone EQ: new gains from the measured long-term spectrum (once per 256 samples).
    void updateEq() {
        const double minBlocks = tuning.eqStartSeconds * rate / kEqBlock;
        const bool ready = measuredBlocks >= std::max(1.0, minBlocks) && voice.eqAmount > 0;
        float corr[kBands] = {};
        if (ready) {
            double dbOut[kBands], tNorm = 0, mNorm = 0;
            int n = 0;
            for (int k = 0; k < kBands; ++k) dbOut[k] = 10 * std::log10(measured[k] + 1e-20);
            for (int k = 6; k <= 12; ++k) { tNorm += voice.ltas[k]; mNorm += dbOut[k]; ++n; }
            tNorm /= n; mNorm /= n;
            float raw[kBands];
            for (int k = 0; k < kBands; ++k)
                raw[k] = bandOk[k] ? (float)((voice.ltas[k] - tNorm) - (dbOut[k] - mNorm)) : 0.0f;
            for (int k = 0; k < kBands; ++k) {
                float s = 0; int c = 0;
                for (int j = std::max(0, k - 1); j <= std::min(kBands - 1, k + 1); ++j) if (bandOk[j]) { s += raw[j]; ++c; }
                corr[k] = c ? s / c : 0;
            }
        }
        for (int m = 0; m < kEq; ++m) {
            float want = 0;
            if (ready && eqOk[m]) {
                const int k = std::min(3 * m, kBands - 1);
                float s = 0; int c = 0;
                for (int j = std::max(0, k - 1); j <= std::min(kBands - 1, k + 1); ++j) if (bandOk[j]) { s += corr[j]; ++c; }
                want = c ? s / c : 0;
                want = std::clamp(want * voice.eqAmount, -tuning.eqMaxDb, tuning.eqMaxDb);
            }
            eqTarget[m] = want;
            const float step = tuning.eqStepDb;
            eqSlow[m] += std::clamp(eqTarget[m] - eqSlow[m], -step, step);
            const float applied = eqSlow[m] * strength;
            if (eqOk[m] && std::fabs(applied - eqApplied[m]) > 0.001f) {
                eq[m].peak(eqHz[m], 1.41, applied, rate);
                eqApplied[m] = applied;
            }
        }
    }

    void updatePresence() {
        const float want = voice.presenceDb * strength;
        if (std::fabs(want - presenceApplied) > 0.001f) {
            presence.peak(std::min((double)tuning.presenceHz, 0.4 * rate), tuning.presenceQ, want, rate);
            presenceApplied = want;
        }
    }

    void count(double startNs, int n) {
        const double spent = nowNs() - startNs;
        spentNs += spent;
        windowNs += spent;
        windowFrames += n;
        const double tenMs = 0.01 * rate;
        if (windowFrames >= tenMs) {
            worstMs = std::max(worstMs, windowNs * (tenMs / windowFrames) / 1e6);
            windowNs = 0;
            windowFrames = 0;
        }
    }

    void clearSound() {
        for (auto &f : antiAlias) f.clear();
        std::memset(dec, 0, sizeof(float) * (size_t)decSize);
        std::memset(original, 0, sizeof(float) * (size_t)inSize);
        decPhase = 0; decCount = 0; inPos = 0; hops = 0;
        for (int k = 0; k < 3; ++k) { lastF0[k] = 0; lastAp[k] = 1; lastLevel[k] = -140; lastCentre[k] = 0; }
        prevCount = 0;
        lastGoodAge = 999;
        for (int k = 0; k < 3; ++k) { octHz[k] = 0; octPath[k] = 0; }
        octAge = 999;
        aiHz = 0; aiAge = 999; voicedAge = 999; steadyRun = 0;
        pendAt = pendCount = 0; mapFrames = 0; stretchGap = 1000; held = false; stCount = stAt = lineCount = lineAt = lineRejects = 0;
        floorRun = 0; floorGap = 1000;
        singStAt = singStCount = singGap = singQuiet = 0;
        singFlagAt = singFlagCount = singFlagSum = 0;
        singOn = false; sing = 0; devSlow = 0;
        flagLatest = -1;
        frames = voicedFrames = creakFrames = 0;
        sibTop.clear(); sibOrigTop.clear();
        sibKeep = 0; voicedNow = 0;
        for (int k = 0; k < kBandsPadded; ++k) { bz1[k] = bz2[k] = bacc[k] = 0; }
        blockAt = 0; blockVoiced = 0;
        for (auto &f : eq) f.clear();
        presence.clear();
        for (int b = 0; b < kBreath; ++b) { breathBand[b].clear(); breathNoise[b].clear(); breathEnv[b] = 0; }
        noiseState = 0x9E3779B9u;
        spentNs = spentFrames = windowNs = windowFrames = worstMs = 0;
    }

    void flushAll() {
        for (auto &f : antiAlias) f.flush();
        sibTop.flush(); sibOrigTop.flush();
        for (auto &f : eq) f.flush();
        presence.flush();
        for (int b = 0; b < kBreath; ++b) { breathBand[b].flush(); breathNoise[b].flush(); }
        for (int k = 0; k < kBandsPadded; ++k) {
            if (std::fabs(bz1[k]) < 1e-25f) bz1[k] = 0;
            if (std::fabs(bz2[k]) < 1e-25f) bz2[k] = 0;
        }
        if (std::fabs(sibKeep) < 1e-20f) sibKeep = 0;
        if (std::fabs(voicedNow) < 1e-20f) voicedNow = 0;
        for (int b = 0; b < kBreath; ++b) if (breathEnv[b] < 1e-20f) breathEnv[b] = 0;
    }
};

extern "C" {

VoiceChanger *voicechanger_new(double sampleRate, int maxFrames) {
    if (!(sampleRate >= 8000 && sampleRate <= 768000) || maxFrames <= 0) return nullptr;
    auto *c = new (std::nothrow) VoiceChanger();
    if (!c) return nullptr;
    c->rate = sampleRate;
    c->maxFrames = maxFrames;
    c->down = std::max(1, (int)std::lround(sampleRate / 16000.0));
    c->analysisRate = sampleRate / c->down;
    c->hop = std::max(1, (int)std::lround(0.010 * c->analysisRate));
    c->hopIn = c->hop * c->down;
    c->window = (int)std::lround(0.025 * c->analysisRate);
    c->tauMax = (int)std::ceil(c->analysisRate / 55.0);
    c->tauMin = (int)std::floor(c->analysisRate / 600.0);
    c->span = c->window + c->tauMax;
    c->decSize = 1;
    while (c->decSize < c->span + c->hop + 16) c->decSize <<= 1;
    c->inSize = 1;
    while (c->inSize < (int)(0.5 * sampleRate) + maxFrames + 16) c->inSize <<= 1;
    c->dec = new (std::nothrow) float[c->decSize]();
    c->lin = new (std::nothrow) float[c->span]();
    c->energy = new (std::nothrow) double[c->span + 1]();
    c->diff = new (std::nothrow) float[c->tauMax + 2]();
    c->original = new (std::nothrow) float[c->inSize]();
    if (!c->dec || !c->lin || !c->energy || !c->diff || !c->original) {
        voicechanger_delete(c);
        return nullptr;
    }
    // Low-pass before thinning: 6th-order Butterworth at a quarter of the analysis rate (4 kHz at 16 kHz).
    if (c->down > 1) {
        const double qs[3] = {0.5176, 0.7071, 1.9319};
        for (int k = 0; k < 3; ++k) c->antiAlias[k].lowPass(0.25 * c->analysisRate, qs[k], sampleRate);
    }
    const double nyquistUse = 0.45 * sampleRate;
    for (int k = 0; k < kBands; ++k) {
        const double centre = 125.0 * std::pow(2.0, k / 3.0);
        c->bandOk[k] = centre * std::pow(2.0, 1 / 6.0) < nyquistUse;
        Biquad b;
        b.bandPass(std::min(centre, 0.45 * sampleRate), centre / (centre * (std::pow(2.0, 1 / 6.0) - std::pow(2.0, -1 / 6.0))), sampleRate);
        c->bb0[k] = (float)b.b0; c->bb2[k] = (float)b.b2; c->ba1[k] = (float)b.a1; c->ba2[k] = (float)b.a2;
    }
    for (int m = 0; m < kEq; ++m) {
        c->eqHz[m] = 125.0 * std::pow(2.0, m);
        c->eqOk[m] = c->eqHz[m] < nyquistUse;
    }
    const double breathLo[kBreath] = {1500, 2500, 4000, 6000}, breathHi[kBreath] = {2500, 4000, 6000, 9000};
    for (int b = 0; b < kBreath; ++b) {
        const double centre = std::sqrt(breathLo[b] * breathHi[b]), q = centre / (breathHi[b] - breathLo[b]);
        c->breathOk[b] = breathHi[b] < nyquistUse;
        if (!c->breathOk[b]) continue;
        c->breathBand[b].bandPass(centre, q, sampleRate);
        c->breathNoise[b].bandPass(centre, q, sampleRate);
        // Scale the band's noise so its average size (mean |x|) is 1, like the loudness it follows.
        Biquad probe = c->breathBand[b];
        probe.clear();
        double power = 0;
        for (int i = 0; i < (int)sampleRate; ++i) {
            const double h = probe.run(i == 0 ? 1.0 : 0.0);
            power += h * h;
        }
        const double sigma = std::sqrt(power / 3.0);  // uniform noise in -1 ... 1 has variance 1/3
        c->breathNorm[b] = sigma > 0 ? 1.0 / (std::sqrt(2.0 / kPi) * sigma) : 0;
    }
    c->sibTop.highPass(std::min((double)c->tuning.sibilanceHz, 0.4 * sampleRate), 0.7071, sampleRate);
    c->sibOrigTop = c->sibTop;
    c->sibStep = (float)(1 - std::exp(-1.0 / (0.005 * sampleRate)));
    c->voicedStep = (float)(1 - std::exp(-1.0 / (0.010 * sampleRate)));
    c->breathAttack = (float)(1 - std::exp(-1.0 / (c->tuning.breathAttackMs * 0.001 * sampleRate)));
    c->breathRelease = (float)(1 - std::exp(-1.0 / (c->tuning.breathReleaseMs * 0.001 * sampleRate)));
    c->clearSound();
    return c;
}

void voicechanger_delete(VoiceChanger *c) {
    if (!c) return;
    delete[] c->dec;
    delete[] c->lin;
    delete[] c->energy;
    delete[] c->diff;
    delete[] c->original;
    delete c;
}

void voicechanger_set(VoiceChanger *c, const VoiceChangerVoice *voice, float strength) {
    if (!c) return;
    if (voice) {
        const float oldTarget = c->voice.targetHz;
        if (!c->hasVoice || std::memcmp(voice, &c->asSet, sizeof(VoiceChangerVoice)) != 0) {
            c->asSet = *voice;
            c->applyVoice();
            // a new target: move the held shift with it (the next voiced frame works it out again)
            if (c->hasVoice && c->shiftKnown && oldTarget > 0) c->shiftFrame += semitones(c->voice.targetHz / oldTarget);
        }
        c->hasVoice = true;
        c->strengthTarget = std::clamp(strength, 0.0f, 1.0f);
    } else {
        c->strengthTarget = 0;  // fades out; the voice is kept for that
    }
}

void voicechanger_reset(VoiceChanger *c) {
    if (!c) return;
    c->clearSound();
    c->strength = c->strengthTarget;  // nothing old to glide from
    c->shiftNow = c->shiftFrame;
    if (c->hasVoice) {
        const double shape = std::log((double)c->voice.formant) * c->strength * c->shapePower;
        c->shapeLogNow = shape;
    }
}

void voicechanger_set_speaker(VoiceChanger *c, float medianHz, float weightFrames) {
    if (!c) return;
    const bool ok = std::isfinite(medianHz) && medianHz >= 50 && medianHz <= 500 && std::isfinite(weightFrames) && weightFrames > 0;
    c->speakerHz = ok ? medianHz : 0;
    c->speakerWeight = ok ? weightFrames : 0;
    c->seeded = false;   // the first guess is made again
    c->medianUse = 0;
    c->aiMedianUse = 0;
    if (c->hasVoice) c->applyVoice();
}

void voicechanger_analyse(VoiceChanger *c, const float *in, int frames, float extraSemitones, VoiceChangerPitch *out) {
    if (out) out->newFrames = 0;
    if (!c || !in || frames <= 0) return;
    const double start = nowNs();
    if (!c->hasVoice) {
        if (out) { out->pitchScale = std::exp2(extraSemitones / 12); out->formantScale = 1 / out->pitchScale; }
        return;
    }
    if (!c->shiftKnown) {  // before any voice: shift as if the speaker had the assumed pitch
        c->shiftFrame = semitones(c->voice.targetHz / c->voice.assumedInputHz);
        c->shiftNow = c->shiftFrame;
        c->shiftKnown = true;
        c->shapePower = 1;
    }
    const int decMask = c->decSize - 1, inMask = c->inSize - 1;
    for (int i = 0; i < frames; ++i) {
        const float x = in[i];
        c->original[c->inPos & inMask] = x;
        c->inPos++;
        double v = x;
        if (c->down > 1) {
            for (auto &f : c->antiAlias) v = f.run(v);
            if (++c->decPhase < c->down) continue;
            c->decPhase = 0;
        }
        c->dec[c->decCount & decMask] = (float)v;
        c->decCount++;
        if (c->decCount >= c->span && c->decCount % c->hop == 0) c->analyseHop(extraSemitones, out);
    }
    // Per callback: strength, shift and voice shape glide toward where they're heading.
    const float strengthStep = (float)(frames / (std::max(0.001f, c->tuning.strengthGlideS) * c->rate));
    c->strength += std::clamp(c->strengthTarget - c->strength, -strengthStep, strengthStep);
    c->shiftNow += (c->shiftFrame - c->shiftNow) * std::min(1.0f, (float)frames / c->hopIn);
    const double shapeWant = std::log((double)c->voice.formant) * c->strength * c->shapePower;
    c->shapeLogNow += (shapeWant - c->shapeLogNow) * (1 - std::exp(-frames / (c->tuning.formantGlideMs * 0.001 * c->rate)));
    const float total = std::clamp(c->strength * c->shiftNow + extraSemitones, -c->tuning.maxSemitones, c->tuning.maxSemitones);
    c->semitonesNow = total;
    c->pitchScale = std::exp2(total / 12);
    c->formantScale = (float)(std::exp(c->shapeLogNow) / c->pitchScale);
    if (out) {
        out->pitchScale = c->pitchScale;
        out->formantScale = c->formantScale;
        if (out->newFrames == 0) { out->voiced = 0; out->f0In = 0; out->f0Target = 0; }
    }
    c->flushAll();
    c->count(start, frames);
}

void voicechanger_post(VoiceChanger *c, float *io, int frames, int delayFrames) {
    if (!c || !io || frames <= 0 || !c->hasVoice) return;
    const double start = nowNs();
    const float s = c->strength;
    const VoiceChangerVoice &v = c->voice;
    c->updatePresence();
    const bool sibilance = v.sibilanceKeep > 0 || c->sibKeep > 1e-6f;
    const bool presence = v.presenceDb != 0;
    const bool breath = v.breathDb > -90 && s > 0;
    const float breathGain = breath ? std::pow(10.0f, v.breathDb / 20) * s : 0;
    const bool measure = v.eqAmount > 0;
    const int inMask = c->inSize - 1;
    const int64_t first = c->inPos - std::max(0, delayFrames) - frames;  // mic position of io[0]
    bool voiced = c->voicedAt(first);
    for (int i = 0; i < frames; ++i) {
        if ((i & 31) == 0 && i > 0) voiced = c->voicedAt(first + i);
        c->voicedNow += ((voiced ? 1.0f : 0.0f) - c->voicedNow) * c->voicedStep;
        double y = io[i];
        if (sibilance) {
            const int64_t at = first + i;
            const bool have = at >= 0 && at > c->inPos - c->inSize;
            const double x = have ? c->original[at & inMask] : 0.0;
            const double top = c->sibTop.run(y), originalTop = c->sibOrigTop.run(x);
            const float want = voiced ? 0.0f : v.sibilanceKeep * s;
            c->sibKeep += (want - c->sibKeep) * c->sibStep;
            y += c->sibKeep * (originalTop - top);
        }
        if (measure) {
            const float yf = (float)y;
#pragma clang loop vectorize(enable)
            for (int k = 0; k < kBandsPadded; ++k) {
                const float o = c->bb0[k] * yf + c->bz1[k];
                c->bz1[k] = -c->ba1[k] * o + c->bz2[k];
                c->bz2[k] = c->bb2[k] * yf - c->ba2[k] * o;
                c->bacc[k] += o * o;
            }
            c->blockVoiced += voiced ? 1.0f : 0.0f;
            if (++c->blockAt == kEqBlock) {
                if (c->blockVoiced > 0.5f * kEqBlock) {
                    c->measuredBlocks++;
                    const double a = std::max(1.0 / (double)c->measuredBlocks, kEqBlock / (c->tuning.eqSeconds * c->rate));
                    for (int k = 0; k < kBands; ++k) c->measured[k] += a * (c->bacc[k] / kEqBlock - c->measured[k]);
                }
                for (int k = 0; k < kBandsPadded; ++k) c->bacc[k] = 0;
                c->blockAt = 0;
                c->blockVoiced = 0;
                c->updateEq();
            }
        }
        if (measure) {  // always run while in use (a 0 dB peak passes the sound unchanged), so no stale state clicks
            for (int m = 0; m < kEq; ++m) if (c->eqOk[m]) y = c->eq[m].run(y);
        }
        if (presence) y = c->presence.run(y);
        if (breath) {
            double add = 0;
            const float gate = c->voicedNow;
            for (int b = 0; b < kBreath; ++b) {
                if (!c->breathOk[b]) continue;
                const float level = (float)std::fabs(c->breathBand[b].run(y));
                float &env = c->breathEnv[b];
                env += (level - env) * (level > env ? c->breathAttack : c->breathRelease);
                const double n = c->breathNoise[b].run(noise(c->noiseState)) * c->breathNorm[b];
                add += env * n;
            }
            y += add * breathGain * gate;
        }
        io[i] = (float)y;
    }
    c->flushAll();
    c->count(start, 0);
}

int voicechanger_tune(VoiceChanger *c, const char *key, float value) {
    if (!c || !key || !std::isfinite(value)) return 0;
    if (std::strcmp(key, "ai32") == 0) {  // 0: every 3.2 change off (here: the AI pitch's +-15 half-step limit back)
        c->tuning.aiClampMode = value != 0 ? 1.0f : 0.0f;
        return 1;
    }
    if (std::strcmp(key, "hum34") == 0) {  // 0: every 3.4 change off (3.3's sound exactly); 1: the 3.4 defaults
        const bool on = value != 0;
        const Tuning d;
        c->tuning.floorMode = on ? d.floorMode : 0;
        c->tuning.voicedKeepDb = on ? d.voicedKeepDb : 0;
        c->tuning.voicedKeepFloorDb = on ? d.voicedKeepFloorDb : 0;
        c->tuning.singMode = on ? d.singMode : 0;
        return 1;
    }
    for (int k = 0; k < kVoiceKeyCount; ++k) {
        if (std::strcmp(key, kVoiceKeys[k].name) == 0) {
            c->overridden[k] = true;
            c->overrideValue[k] = value;
            if (c->hasVoice) c->applyVoice();
            return 1;
        }
    }
    for (const auto &t : kTuneKeys) {
        if (std::strcmp(key, t.name) == 0) {
            c->tuning.*(t.field) = value;
            // settings that shape filters made at the start
            c->breathAttack = (float)(1 - std::exp(-1.0 / (std::max(0.1f, c->tuning.breathAttackMs) * 0.001 * c->rate)));
            c->breathRelease = (float)(1 - std::exp(-1.0 / (std::max(0.1f, c->tuning.breathReleaseMs) * 0.001 * c->rate)));
            c->sibTop.highPass(std::min((double)c->tuning.sibilanceHz, 0.4 * c->rate), 0.7071, c->rate);
            c->sibOrigTop.highPass(std::min((double)c->tuning.sibilanceHz, 0.4 * c->rate), 0.7071, c->rate);
            c->presenceApplied = 1e9f;  // made again on the next post
            if (c->hasVoice) c->applyVoice();
            return 1;
        }
    }
    return 0;
}

void voicechanger_get_stats(const VoiceChanger *c, VoiceChangerStats *out) {
    if (!out) return;
    std::memset(out, 0, sizeof(*out));
    if (!c) return;
    out->strength = c->strength;
    out->medianHz = c->medianHz;
    out->semitones = c->semitonesNow;
    out->formant = (float)std::exp(c->shapeLogNow);
    out->voicedShare = c->frames ? (float)c->voicedFrames / (float)c->frames : 0;
    out->creakShare = c->voicedFrames ? (float)c->creakFrames / (float)c->voicedFrames : 0;
    for (int m = 0; m < kEq; ++m) out->eqDb[m] = c->eqApplied[m];
    out->frames = c->frames;
    const double tenMs = 0.01 * c->rate;
    out->analyseMs = c->inPos > 0 ? c->spentNs / 1e6 * tenMs / (double)c->inPos : 0;
    out->worstMs = c->worstMs;
    out->learnedFrames = c->learned;
}

}  // extern "C"
