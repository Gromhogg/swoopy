// Voice changer, Realistic mode (see VoiceModel.h): an RVC v2 voice run with Core ML on its own worker thread.
// Objective-C++ with ARC. Apple silicon only; Intel Macs keep the stubs at the bottom for good.
//
// How the sound flows (live):
//   sound thread                         worker thread ("Pitch Shift AI voice", user-interactive)
//   push: mic --> ring `in` (chain rate) --> libsamplerate --> ring `in16` (16 kHz)
//         pitch frames --> ring `pitch`      every hop (H frames of 10 ms) once the window [E-T, E) is there:
//                                             ContentVec (Core ML) -> features
//                                             pitch per 10 ms frame (from A1's tracker, nearest frame) -> 1..255
//                                             NSF source (float64 phase, carried across hops) + fixed noise
//                                             generator (Core ML) -> the last DEC frames at the voice's rate (48, 40 or 32 kHz)
//                                             drop the left margin -> SOLA crossfade -> loudness = the mic's
//                                             -> (resample to the chain rate) -> ring `out` (+ a provisional tail)
//   pull: out <-- ring `out` at a fixed delay, or Natural's sound delayed to the same delay (10 ms crossfades)
// Every ring is indexed by the absolute sample position, so the AI voice, the mic and Natural's sound line up.
// libsamplerate keeps output sample i exactly at input time i / ratio; it only hands it over a little later (its
// "lag", measured once), which the fixed delay includes.
//
// Look-ahead (models in the "ahead" shape): the window still ends at the newest sound, but the piece that is made
// comes from LA frames earlier, so the speech reader hears LA frames of what comes after it (no more guessing at a
// cut-off word; adds LA to the delay). The ring index of piece k stays k * hop, so changing LA never moves where the
// sound thread reads: only what the next pieces hold (the switch waits for a quiet moment, so nothing is heard twice,
// or 1.2 s at most).
// The pitch the AI follows is smoothed over the frames on both sides of each frame (they are known by then).
// A new stream plays at its fixed delay from the start (as in 3.0.0): Natural's sound fills in, delayed to the same
// point, and the AI voice takes over with its first piece (10 ms crossfade), or as soon as its models are given.
// (3.1.0 played Natural with no delay until a quiet moment: in a noisy room the AI voice then never came in.)
//
// 3.2 (each behind a voicestream_tune key, see VoiceModel.h; "ai32=0" gives 3.1.1 exactly):
//   - the time kept in hand for a slow piece (reserve) grows with the slider: above 150 ms of look-ahead asked for,
//     part of it is kept as reserve instead (at most 400 ms is real look-ahead); the total delay stays the same. The
//     read point then moves with the look-ahead switch (crossfaded, at the same quiet moment);
//   - a warm CPU copy of the voice generator: when pieces run late on the GPU (a game), the next ones are made on
//     the CPU; back to the GPU only after 30 s and only if the CPU runs late too;
//   - a late piece plays on into the last piece's tail for up to 20 ms before Natural fills in;
//   - joins: the crossfade keeps the loudness when the two pieces differ, and each piece keeps its own loudness;
//     loudness windows reach before a piece's start;
//   - no sung tone on noise or hiss; the loudness match lifts the AI voice only as far as the mic is above the
//     room's noise; a peak limiter (0.6) on each finished piece, so the app's soft limiter never bends it.
//
// Model files (made by research/voicechanger/pack_voices.sh, look-ahead shape by convert_generator.py --ahead):
//   encoder  in "audio" Float32 [1, T*160] (16 kHz) -> out "features" Float32 [1, T/2, 768]
//   voice    in "features" [1, T/2, 768], "pitch" Int32 [1, T], "source" Float32 [1, 1, DEC*upp],
//            "noise" Float32 [1, 192, FLOW] -> out "audio" Float32 [1, DEC*upp]
//            look-ahead shape: also "pick" Int32 [DEC] (the window frames to decode); FLOW = T
//   metadata: rate, upp, window_frames (T), dec_frames, flow_frames, hop_ms, context_ms (+ xfade_ms, sola_ms,
//   margin_ms on newer files; + right_ms, max_ahead_ms, pick_frames in the look-ahead shape).
#include "VoiceModel.h"
#include "SoundGate.h"

#include <cstdio>
#include <cstring>

namespace {
void say(char *err, int errSize, const char *text) {
    if (err && errSize > 0) std::snprintf(err, (size_t)errSize, "%s", text);
}
}  // namespace

#if __arm64__

#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>
#include <Accelerate/Accelerate.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <mach/thread_act.h>
#include <mach/thread_policy.h>
#include <pthread.h>
#include <samplerate.h>
#include <time.h>
#include <unistd.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <string>
#include <vector>

namespace {

const int kRate16 = 16000;
const int kFrame16 = 160;      // samples in a 10 ms frame at 16 kHz
const int kFeatureDim = 768;
const int kNoiseChannels = 192;
const int kZpFrames = 4096;    // fixed z-noise table: 192 x 4096
const int kSourceNoise = 1 << 18;
const int kPitchSlots = 2048;  // 20 s of 10 ms pitch frames
const int kEdgeFrames = 5;     // less look-ahead than this (10 ms frames): the pieces are made at the window's end

double nowMs() {
    static mach_timebase_info_data_t tb = [] { mach_timebase_info_data_t t; mach_timebase_info(&t); return t; }();
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

double threadCpuMs() {
    struct timespec ts;
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

int64_t pow2AtLeast(int64_t n) {
    int64_t p = 1;
    while (p < n) p <<= 1;
    return p;
}

// Mono sound kept by absolute position (slot = position mod size). One thread writes, another reads.
struct Ring {
    std::vector<float> buf;
    int64_t mask = 0;
    void init(int64_t minSize) {
        buf.assign((size_t)pow2AtLeast(std::max<int64_t>(minSize, 2)), 0.0f);
        mask = (int64_t)buf.size() - 1;
    }
    int64_t size() const { return mask + 1; }
    void put(int64_t pos, const float *x, int n) {
        for (int i = 0; i < n; i++) buf[(size_t)((pos + i) & mask)] = x[i];
    }
    float at(int64_t pos) const { return buf[(size_t)(pos & mask)]; }
    // Positions below `valid` read as silence (nothing was there yet).
    void get(int64_t pos, float *x, int n, int64_t valid = INT64_MIN) const {
        for (int i = 0; i < n; i++) x[i] = pos + i < valid ? 0.0f : buf[(size_t)((pos + i) & mask)];
    }
};

// Deterministic Gaussian numbers (xorshift + Box-Muller), so every run makes the same noise.
struct Gauss {
    uint64_t s;
    explicit Gauss(uint64_t seed) : s(seed ? seed : 0x9E3779B97F4A7C15ull) {}
    double uniform() {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17;
        return ((s >> 11) + 0.5) * (1.0 / 9007199254740992.0);
    }
    float next() {
        double u1 = uniform(), u2 = uniform();
        return (float)(std::sqrt(-2.0 * std::log(u1)) * std::cos(2 * M_PI * u2));
    }
};

// Mono libsamplerate converter (sinc, medium quality). Identity ratio: no converter, no lag.
class Resampler {
public:
    ~Resampler() { if (state_) src_delete(state_); }
    bool init(double ratio, int maxIn) {
        if (state_) { src_delete(state_); state_ = nullptr; }
        ratio_ = ratio;
        identity_ = std::fabs(ratio - 1.0) < 1e-12;
        outCap_ = (int)std::ceil(maxIn * ratio) + 64;
        out_.assign((size_t)outCap_, 0.0f);
        if (identity_) return true;
        int err = 0;
        state_ = src_new(SRC_SINC_MEDIUM_QUALITY, 1, &err);
        return state_ != nullptr;
    }
    void reset() { if (state_) src_reset(state_); }
    bool identity() const { return identity_; }
    double ratio() const { return ratio_; }

    // The most the output count can trail input * ratio (output samples), measured once with tiny pieces.
    static double lag(double ratio) {
        if (std::fabs(ratio - 1.0) < 1e-12) return 0;
        int err = 0;
        SRC_STATE *s = src_new(SRC_SINC_MEDIUM_QUALITY, 1, &err);
        if (!s) return 0;
        std::vector<float> in(7, 0.0f), out(256);
        double worst = 0;
        long fed = 0, made = 0;
        for (int k = 0; k < 6000; k++) {
            SRC_DATA d{};
            d.data_in = in.data(); d.input_frames = 7; d.data_out = out.data(); d.output_frames = 256; d.src_ratio = ratio;
            src_process(s, &d);
            fed += d.input_frames_used; made += d.output_frames_gen;
            worst = std::max(worst, fed * ratio - made);
        }
        src_delete(s);
        return worst;
    }

    // Feeds n samples (n <= maxIn); hands each piece made to sink(ptr, count).
    template <class Sink> void run(const float *x, int n, Sink &&sink) { run(state_, x, n, sink); }

    // The same with a throw-away copy of the state (for the provisional tail, which must not move the real one).
    template <class Sink> void runCopy(const float *x, int n, Sink &&sink) {
        if (identity_) { sink(x, n); return; }
        int err = 0;
        SRC_STATE *c = src_clone(state_, &err);
        if (!c) return;
        run(c, x, n, sink);
        src_delete(c);
    }

private:
    template <class Sink> void run(SRC_STATE *st, const float *x, int n, Sink &&sink) {
        if (identity_) { sink(x, n); return; }
        long used = 0;
        while (used < n) {
            SRC_DATA d{};
            d.data_in = x + used; d.input_frames = n - used;
            d.data_out = out_.data(); d.output_frames = outCap_; d.src_ratio = ratio_;
            if (src_process(st, &d) != 0) return;
            used += d.input_frames_used;
            if (d.output_frames_gen > 0) sink(out_.data(), (int)d.output_frames_gen);
            if (d.input_frames_used == 0 && d.output_frames_gen == 0) return;
        }
    }
    SRC_STATE *state_ = nullptr;
    double ratio_ = 1;
    bool identity_ = true;
    int outCap_ = 0;
    std::vector<float> out_;
};

MLComputeUnits unitsFor(int u) {
    switch (u) {
        case VOICEMODEL_COMPUTE_CPU: return MLComputeUnitsCPUOnly;
        case VOICEMODEL_COMPUTE_GPU: return MLComputeUnitsCPUAndGPU;
        case VOICEMODEL_COMPUTE_ANE: return MLComputeUnitsCPUAndNeuralEngine;
        default: return MLComputeUnitsAll;
    }
}

const char *unitsName(int u) {
    switch (u) {
        case VOICEMODEL_COMPUTE_CPU: return "CPU";
        case VOICEMODEL_COMPUTE_GPU: return "GPU";
        case VOICEMODEL_COMPUTE_ANE: return "Neural Engine";
        default: return "all";
    }
}

int metaInt(NSDictionary *meta, NSString *key, int fallback) {
    id v = meta[key];
    if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) return [v intValue];
    return fallback;
}

// Our own memory, wrapped as an MLMultiArray (C order).
struct Buffer {
    std::vector<uint8_t> bytes;
    MLMultiArray *array = nil;
    size_t count = 0;
    bool make(NSArray<NSNumber *> *shape, MLMultiArrayDataType type) {
        count = 1;
        for (NSNumber *d in shape) count *= (size_t)d.integerValue;
        size_t each = type == MLMultiArrayDataTypeInt32 || type == MLMultiArrayDataTypeFloat32 ? 4 : 2;
        bytes.assign(count * each, 0);
        NSMutableArray<NSNumber *> *strides = [NSMutableArray array];
        NSInteger st = 1;
        for (NSInteger i = (NSInteger)shape.count - 1; i >= 0; i--) { [strides insertObject:@(st) atIndex:0]; st *= shape[i].integerValue; }
        NSError *why = nil;
        array = [[MLMultiArray alloc] initWithDataPointer:bytes.data() shape:shape dataType:type strides:strides deallocator:nil error:&why];
        return array != nil;
    }
    float *f() { return (float *)bytes.data(); }
    int32_t *i() { return (int32_t *)bytes.data(); }
    // If Core ML handed back its own array instead of writing into ours, copy it in.
    bool take(MLMultiArray *o) {
        if (!o) return false;
        if (o == array) return true;
        if ((size_t)o.count != count || o.dataType != array.dataType) return false;
        uint8_t *dst = bytes.data();
        size_t want = bytes.size();
        [o getBytesWithHandler:^(const void *b, NSInteger size) {
            if (b != dst) std::memcpy(dst, b, std::min<size_t>((size_t)size, want));
        }];
        return true;
    }
};

}  // namespace

// The loaded models. Shared by streams; free it only after every stream using it is deleted.
struct VoiceModel {
    MLModel *encoder = nil;
    MLModel *voice = nil;
    MLModel *voiceCPU = nil;       // 3.2: a warm CPU-only copy of the voice generator (when `voice` runs elsewhere)
    double cpuProbeHopMs = 0;      // ... its time per hop at load
    int unitsEncoder = 0, unitsVoice = 0;
    bool cpuOnly = false;          // fell back to the CPU (or asked for it): needs the bigger reserve
    int encoderSamples = 0;        // the encoder's window * 160 (T * 160, or more: then the voice gets the newest part)
    int featureFrames = 0;         // the encoder's window / 2
    int T = 0;                     // pitch frames (10 ms)
    int decSamples = 0;            // DEC * upp
    int flowFrames = 0;            // FLOW
    int rate = 48000, upp = 480;
    int hopMs = 160, contextMs = 0, decFrames = 0, xfadeMs = 40, solaMs = 10, marginMs = 60;
    bool picks = false;            // look-ahead shape: the "pick" input says which window frames to decode
    int rightMs = 0;               // ... frames decoded after each piece and dropped (the decoder hears past its end)
    int maxAheadMs = 0;            // ... the most look-ahead it can use
    double loadMs = 0, warmMs = 0, probeHopMs = 0;
    std::string describe;
};

namespace {

// Everything a stream needs for one model (made off the sound thread, then handed to the worker).
struct Runner {
    VoiceModel *model = nullptr;
    Buffer audio16, features, pitch, source, noise, audioOut, pick, voiceFeatures;
    id<MLFeatureProvider> encoderIn = nil, voiceIn = nil;
    MLPredictionOptions *encoderOptions = nil, *voiceOptions = nil;
    std::vector<float> sourceNoise;   // kSourceNoise values
    std::vector<float> zp;            // kNoiseChannels x kZpFrames
    std::vector<double> f0;           // T values, Hz
    std::vector<float> st, level;     // T values: pitch in half-steps (0 = not voiced), input loudness (dB)
    std::vector<uint8_t> known;       // T values: 1 = the pitch tracker has decided this frame
    std::vector<float> y, block, tail, sola, fadeIn, fadeOut, gains;
    std::vector<float> prevTail;      // research trace only
    std::vector<float> limH, limHist; // 3.2 peak limiter: the gain each sample needs (min over 5 ms ahead), last ones
    std::vector<int> limQ;            // ... its sliding-minimum queue
};

bool predict(MLModel *m, id<MLFeatureProvider> in, MLPredictionOptions *opt, NSString *outName, Buffer &out) {
    @autoreleasepool {
        NSError *why = nil;
        id<MLFeatureProvider> r = [m predictionFromFeatures:in options:opt error:&why];
        if (!r) return false;
        return out.take([r featureValueForName:outName].multiArrayValue);
    }
}

bool makeRunner(VoiceModel *m, Runner &r) {
    r.model = m;
    NSError *why = nil;
    if (!r.audio16.make(@[@1, @(m->encoderSamples)], MLMultiArrayDataTypeFloat32)) return false;
    if (!r.features.make(@[@1, @(m->featureFrames), @(kFeatureDim)], MLMultiArrayDataTypeFloat32)) return false;
    // an encoder with a longer window than the voice (a voice made for a shorter one): the voice gets its newest part
    const bool longer = m->featureFrames > m->T / 2;
    if (longer && !r.voiceFeatures.make(@[@1, @(m->T / 2), @(kFeatureDim)], MLMultiArrayDataTypeFloat32)) return false;
    if (!r.pitch.make(@[@1, @(m->T)], MLMultiArrayDataTypeInt32)) return false;
    if (!r.source.make(@[@1, @1, @(m->decSamples)], MLMultiArrayDataTypeFloat32)) return false;
    if (!r.noise.make(@[@1, @(kNoiseChannels), @(m->flowFrames)], MLMultiArrayDataTypeFloat32)) return false;
    if (!r.audioOut.make(@[@1, @(m->decSamples)], MLMultiArrayDataTypeFloat32)) return false;
    if (m->picks && !r.pick.make(@[@(m->decFrames)], MLMultiArrayDataTypeInt32)) return false;
    r.encoderIn = [[MLDictionaryFeatureProvider alloc] initWithDictionary:@{@"audio" : [MLFeatureValue featureValueWithMultiArray:r.audio16.array]} error:&why];
    NSMutableDictionary *voiceInputs = [@{
        @"features" : [MLFeatureValue featureValueWithMultiArray:(longer ? r.voiceFeatures : r.features).array],
        @"pitch" : [MLFeatureValue featureValueWithMultiArray:r.pitch.array],
        @"source" : [MLFeatureValue featureValueWithMultiArray:r.source.array],
        @"noise" : [MLFeatureValue featureValueWithMultiArray:r.noise.array],
    } mutableCopy];
    if (m->picks) {
        for (int i = 0; i < m->decFrames; i++) r.pick.i()[i] = m->T - m->decFrames + i;  // (no look-ahead until a hop says)
        voiceInputs[@"pick"] = [MLFeatureValue featureValueWithMultiArray:r.pick.array];
    }
    r.voiceIn = [[MLDictionaryFeatureProvider alloc] initWithDictionary:voiceInputs error:&why];
    if (!r.encoderIn || !r.voiceIn) return false;
    r.encoderOptions = [MLPredictionOptions new];
    r.encoderOptions.outputBackings = @{@"features" : r.features.array};
    r.voiceOptions = [MLPredictionOptions new];
    r.voiceOptions.outputBackings = @{@"audio" : r.audioOut.array};
    Gauss g(1234);
    r.sourceNoise.resize(kSourceNoise);
    for (auto &v : r.sourceNoise) v = g.next();
    Gauss gz(4321);
    r.zp.resize((size_t)kNoiseChannels * kZpFrames);
    for (auto &v : r.zp) v = gz.next();
    r.f0.assign((size_t)m->T, 0.0);
    r.st.assign((size_t)m->T, 0.0f);
    r.level.assign((size_t)m->T, -120.0f);
    r.known.assign((size_t)m->T, 0);
    r.y.assign((size_t)m->decSamples, 0.0f);
    return true;
}

// The fixed delay (chain samples) for a stream with these piece sizes; the same sum for voicestream_new and the
// window's delay line. hop/xfade/sola/reserve/lookahead in ms.
int latencyFrames(double rate, int maxFrames, bool offline, int hopMs, int xfadeMs, int solaMs, int reserveMs, int lookaheadMs,
                  double inLag16, double outLag) {
    const int lags = (int)std::ceil(inLag16 * rate / kRate16) + (int)std::ceil(outLag);
    if (offline) return (int)std::llround((hopMs + xfadeMs + solaMs + lookaheadMs) * rate / 1000) + lags + 64;
    return (int)std::llround((hopMs + xfadeMs + solaMs + reserveMs + lookaheadMs) * rate / 1000) + lags
         + std::min(maxFrames, (int)(rate * 0.011));
}

}  // namespace

struct VoiceStream {
    // fixed at creation
    double rate = 48000;
    int maxFrames = 512;
    bool offline = false;
    int H = 16, X = 4, S = 1;      // hop, crossfade, search (10 ms frames)
    int reserveMs = 60;
    int baseBack = 0;              // chain samples from "now" back to the converted index being played (no look-ahead part)
    double inLag16 = 0;            // 16 kHz samples the input resampler holds back
    double outLag = 0;             // chain samples the output resampler holds back
    int outRate = 48000;           // the model rate outLag (part of the fixed delay) was measured for
    int rampLen = 480;             // 10 ms crossfade between the AI voice and Natural
    int modelRate = 48000;

    // sound thread -> worker
    Ring in;
    std::atomic<int64_t> inEnd{0};
    std::vector<int64_t> pitchPos;
    std::vector<float> pitchHz;
    std::atomic<int64_t> pitchEnd{0};
    std::atomic<int64_t> wakeAt{0};

    // worker -> sound thread
    Ring out;
    std::atomic<int64_t> outFinal{0};  // converted samples final up to here
    std::atomic<int64_t> outProv{0};   // ... plus a provisional tail up to here (late hops fade out on it)
    std::atomic<int64_t> outStart{INT64_MAX};  // first converted index ever written (after a model is attached)
    // Look-ahead switches (and the first start of the AI voice): from converted index `junctionAt` on, the sound is
    // `junctionLatency` behind the mic (Natural's fill-in must line up with that from there on).
    std::atomic<int64_t> junctionAt{INT64_MIN};
    std::atomic<int> junctionLatency{0};
    std::atomic<int> junctionBack{0};  // 3.2: ... and the sound thread reads converted index (now - this)

    // any thread -> worker
    std::atomic<int> laWant{0};    // look-ahead asked for (10 ms frames)
    std::atomic<int> laShown{0};   // worker -> stats: the look-ahead in use

    // worker state
    std::atomic<VoiceModel *> pending{nullptr};
    Runner *run = nullptr;
    Resampler toModel, toChain;
    Ring in16;
    int64_t in16End = 0;
    int64_t inUsed = 0;
    int64_t hop = -1;              // next hop to make (E = (hop + 1) * H)
    int64_t written = 0;           // converted samples written (chain rate)
    int64_t phaseAt = INT64_MIN;   // model-rate sample where `phase` applies
    double phase = 0;
    float lastGain = 0;
    int lastO = 0;                 // the last piece's crossfade offset (samples)
    int laNow = 0;                 // look-ahead the pieces are made with now (10 ms frames)
    int exNow = 0;                 // 3.2: extra reserve in use (10 ms frames; part of the look-ahead asked for)
    bool onCPU = false;            // 3.2: the voice generator runs on the model's CPU copy
    double chipSinceMs = 0;        // ... since (or since the start)
    double cpuHoldMs = 30000;      // ... stays on the CPU at least this long (doubles after a failed try, up to 4 min)
    uint32_t lateBits = 0, tightBits = 0;  // ... the last 10 pieces: late / ready less than 15 ms before needed
    bool rtSet = false;            // 3.2: real-time thread policy set
    float limG = 1;                // 3.2: the peak limiter's gain at the end of the last piece
    float liftDb = 0;              // 3.4: how much louder the speech reader hears a steady note now (dB)
    bool started = false;          // the AI voice has been switched in (live: at a quiet moment)
    int64_t askedAtHop = -1;       // hop when the look-ahead asked for first differed from the one in use
    static constexpr double kSwitchWaitS = 1.2;  // a look-ahead switch waits this long for a quiet moment at most
                                                 // (plus up to two pieces: heard within 1.5 s of the ask)
    std::vector<float> levels = std::vector<float>(500, -120.0f), sorted;  // input frame levels, last 5 s (dB)
    int64_t levelsAt = 0;
    float floorDb = -120;
    std::vector<float> scratch, scratch16;
    pthread_t thread{};
    bool threadStarted = false;
    std::atomic<bool> quit{false};
    dispatch_semaphore_t wake = nullptr;
    double attachWallMs = 0, attachCpuMs = 0;

    // sound thread state
    Ring natural;
    int64_t pulled = 0;
    float mix = 0;                 // 1 = the AI voice, 0 = Natural
    bool playing = false;          // the AI voice has played (so a fall back counts as a miss)
    bool lateNow = false;
    int playLatency = 0;           // Natural's fill-in lines up with this delay
    int64_t junctionSeen = INT64_MIN;
    int64_t jumpFrom = 0;          // 3.2: the read point moved (a reserve change): crossfade from the old one ...
    int jumpLeft = 0;              // ... for this many more samples
    bool graceRead = false;        // 3.2: the last callback played on into the provisional tail (a late piece)
    int64_t graceFin = 0;          // ... which ended at this converted index
    int landLeft = 0;              // ... the late piece landed: crossfade from its tail into it for this many samples
    Ring tailRing;                 // 3.2: a copy of each provisional tail (the final block overwrites it in `out`)
    std::atomic<int64_t> pulledA{0};  // 3.2: sound thread -> worker: `pulled` ...
    std::atomic<int> baseBackA{0};    // ... and `baseBack` (where the sound thread reads), for the late-piece rule

    // tuning (tests)
    std::atomic<int> slowMs{0}, slowEvery{1};
    std::atomic<int> slowChip{0};       // 3.2 test: aiSlowMs only while the generator runs on its own chip (a busy GPU)
    std::atomic<float> gainMaxDb{18};
    std::atomic<int> smoothFrames{1};   // pitch smoothing half-width (frames on each side)
    std::atomic<int> slowFrames{7};     // the melody line's half-width (frames on each side)
    std::atomic<float> intonation{0};   // the voice's intonation in use (0 = don't reshape the pitch line)
    std::atomic<int> gapFrames{5};      // short unvoiced gaps bridged inside a loud sound (a voiced consonant, a flicker;
                                        // 8 before 3.2)
    std::atomic<int> onsetFrames{3};    // unvoiced frames just before a vowel that take its first pitch (1 put less
                                        // tone over consonants but cost 1-2 points of words: kept at 3)
    std::atomic<int> solaMode{-1};      // -1 = by look-ahead: with it the pieces line up already, so the crossfade keeps
                                        // the timing (a search would skip or repeat bits of sound); without, it searches
                                        // 0 = search the whole range, 1 = keep the timing, 2 = search near the last one
    std::atomic<int> gainMs{120};       // loudness match window (ms; 20 before 3.1: it pumped the AI voice's own loudness;
                                        // 50 in 3.1: 120 halves the sudden sound changes and is steadier in a noisy room)
    std::atomic<float> quietDb{-45};    // a frame this quiet (dBFS) counts as a pause (for look-ahead switches)
    // 3.2 (the value in brackets gives 3.1.1's sound; see VoiceModel.h)
    std::atomic<int> split{1};          // [0] above 150 ms part of the look-ahead becomes extra reserve ...
    std::atomic<int> aheadMax{400};     // ... so that at most this much is real look-ahead (ms; picked by measurement:
                                        // 400-600 ms all within noise of 700 in words, quality and joins)
    std::atomic<int> autoChip{1};       // [0] switch the voice generator to its CPU copy when pieces run late
    std::atomic<int> startChip{0};      // 1 = start on the CPU copy
    std::atomic<int> graceMs{20};       // [0] a late piece plays on into the last tail this long before Natural
    std::atomic<int> realtime{0};       // real-time thread policy for the worker
    std::atomic<int> leftMs{50};        // [-1] the decoder's left margin (ms; -1 = the model's own, 60): 50 ms (the
                                        // right one gets 50 too) made the joins most alike (40 and 60 less so)
    std::atomic<int> fadeAdapt{1};      // [0] crossfade by how alike the pieces are (equal gain ... equal power)
    std::atomic<int> joinGains{1};      // [0] each piece keeps its own loudness gains across the crossfade
    std::atomic<int> gainTwoSided{1};   // [0] loudness windows reach before a piece's start
    std::atomic<float> nearMs{1.5f};    // aiSolaMode 3: search this far around a fixed point (ms)
    std::atomic<int> bridgeStrict{1};   // [0] bridge gaps only over smooth sound 12 dB above the room's noise
    std::atomic<int> shortRunMs{40};    // [0] voiced bits shorter than this, alone in a pause, get no tone
    std::atomic<float> hissCross{0.3f}; // [0] frames whose zero crossings per sample exceed this get no tone
    std::atomic<int> gainCap{1};        // [0] the loudness match lifts the AI voice only as far as the mic is above the noise
    std::atomic<float> pauseDb{-10};    // ... and in a pause (the mic within 3 dB of the room's noise) at most this
    std::atomic<float> limitAt{0.6f};   // [0] peak limiter on each finished piece (5 ms look-ahead, 80 ms release)
    std::atomic<float> humLiftDb{24};   // 3.4 [0]: a steady note (a hum) is heard by the speech reader lifted toward
    std::atomic<float> humLevelDb{-20}; // humLevelDb, by at most this much (the trained voices lose the tone of a
                                        // long, quiet hum); speech is never steady enough, so it is not changed
    FILE *trace = nullptr;              // research: per-piece trace (offline only, PITCHSHIFT_AI_TRACE)
    // 3.4: sounds that are not a voice (claps, clicks, whistles) are heard as the original mic sound (SoundGate.h)
    SoundGate *gate = nullptr;
    std::atomic<int> gateOn{1};         // "aiSounds" 1 [0: the AI voice for every sound, as before 3.4]
    std::vector<float> gateW;           // sound thread: the gate's weights for one callback
    int gateFit = -1;                   // ... and the delay it was fitted to (samples)

    // stats
    std::atomic<int> loaded{0};
    std::atomic<int> aiNow{0};     // sound thread: 1 = the AI voice is what played in the last callback
    std::atomic<int64_t> hops{0}, misses{0}, fallbackFrames{0}, skipped{0}, switches{0};
    std::atomic<int64_t> chipSwitches{0}, lateHops{0}, tightHops{0}, graceSaves{0}, loudSamples{0}, samplesOut{0};
    std::atomic<int> onCPUShown{0}, exShown{0};
    std::atomic<double> sumHopMs{0}, worstHopMs{0}, cpuShare{0};

    int maxAhead() const { return run ? run->model->maxAheadMs / 10 : 0; }

    int latencyFor(int la, int ex = 0) const {  // la: look-ahead, ex: extra reserve (10 ms frames)
        return latencyFrames(rate, maxFrames, offline, H * 10, X * 10, S * 10, reserveMs + ex * 10, la * 10, inLag16, outLag);
    }

    // Where the sound thread reads (chain samples back from now) with this much extra reserve.
    int backFor(int ex) const { return latencyFor(0, ex) - (int)std::llround((X + S) * rate / 100); }

    // 3.2: the look-ahead asked for (L, 10 ms frames) as real look-ahead + extra reserve (same total): nothing changes
    // up to 150 ms; above, k = (700 - aheadMax) / 550 of the rest is kept in hand (aheadMax 400: L 700 -> 400 + 300).
    void splitFor(int L, int &la, int &ex) const {
        la = L;
        ex = 0;
        if (!split.load()) return;
        const int most = std::clamp(aheadMax.load() / 10, 15, 70);
        if (most >= 70) return;
        ex = (int)std::lround((70.0 - most) / 55.0 * std::max(0, L - 15));
        la = L - ex;
    }

    // The split for the look-ahead asked for now, as the stream would use it (before a model: up to 1 s).
    void splitWanted(int &la, int &ex) const {
        const VoiceModel *m = run ? run->model : pending.load();
        const int L = std::clamp(laWant.load(), 0, m ? m->maxAheadMs / 10 : 100);
        splitFor(L, la, ex);
    }

    // Before any sound (tune keys come right after voicestream_new): the read point and the fill-in's delay again.
    void resplit() {
        if (inEnd.load() != 0) return;
        int la = 0, ex = 0;
        splitWanted(la, ex);
        baseBack = backFor(ex);
        baseBackA.store(baseBack, std::memory_order_relaxed);
        playLatency = latencyFor(la, ex);
    }

    // ------------------------------------------------------------------------------------------- worker side
    // Moves new mic sound through the 16 kHz resampler.
    void resampleNew() {
        int64_t end = inEnd.load(std::memory_order_acquire);
        if (end - inUsed > in.size() - 4096) inUsed = end - (in.size() - 4096);  // fell far behind: skip
        while (inUsed < end) {
            int n = (int)std::min<int64_t>(end - inUsed, (int64_t)scratch.size());
            in.get(inUsed, scratch.data(), n);
            inUsed += n;
            toModel.run(scratch.data(), n, [&](const float *p, int m) {
                in16.put(in16End, p, m);
                in16End += m;
            });
        }
    }

    // Target pitch (Hz) at chain-sample position c, from A1's tracker frames (nearest one; newer than the newest
    // frame: hold the newest, and say it is not known yet).
    double pitchAt(double c, int64_t pend, int64_t &cursor, bool &isKnown) const {
        isKnown = false;
        if (pend <= 0) return 0;
        int64_t oldest = std::max<int64_t>(0, pend - kPitchSlots + 8);
        if (cursor < oldest) cursor = oldest;
        while (cursor + 1 < pend && pitchPos[(size_t)((cursor + 1) % kPitchSlots)] <= c) cursor++;
        int64_t a = cursor, b = std::min(cursor + 1, pend - 1);
        double pa = (double)pitchPos[(size_t)(a % kPitchSlots)], pb = (double)pitchPos[(size_t)(b % kPitchSlots)];
        isKnown = c <= pb + rate * 0.005;
        if (c >= pb) return pitchHz[(size_t)(b % kPitchSlots)];  // the newest frames lack look-ahead: hold
        if (c < pa - rate * 0.02) return 0;
        return std::fabs(c - pa) <= std::fabs(pb - c) ? pitchHz[(size_t)(a % kPitchSlots)] : pitchHz[(size_t)(b % kPitchSlots)];
    }

    static int coarse(double f) {
        if (f <= 0) return 1;
        const double melMin = 1127 * std::log(1 + 50.0 / 700), melMax = 1127 * std::log(1 + 1100.0 / 700);
        double m = (1127 * std::log(1 + f / 700) - melMin) * 254 / (melMax - melMin) + 1;
        m = std::max(1.0, std::min(255.0, m));
        return (int)std::lrint(m);
    }

    // Input loudness of 16 kHz frame a (dBFS, 20 ms around its centre).
    float levelAt(int64_t a) const {
        double e = 0;
        for (int i = -kFrame16 / 2; i < kFrame16 * 3 / 2; i++) {
            int64_t p = a * kFrame16 + i;
            float v = p < 0 ? 0 : in16.at(p);
            e += v * v;
        }
        return (float)(10 * std::log10(e / (2 * kFrame16) + 1e-12));
    }

    // Zero crossings per sample of 16 kHz frame a (hiss like "s" crosses often, a voice seldom).
    float crossingsAt(int64_t a) const {
        int n = 0;
        float prev = a * kFrame16 > 0 ? in16.at(a * kFrame16 - 1) : 0.0f;
        for (int i = 0; i < kFrame16; i++) {
            const int64_t p = a * kFrame16 + i;
            const float v = p < 0 ? 0 : in16.at(p);
            if ((v >= 0) != (prev >= 0)) n++;
            prev = v;
        }
        return (float)n / kFrame16;
    }

    // Is the input quiet over 16 kHz frames [a, b)? Quiet = below quietDb, or within 6 dB of the room's own noise
    // (the 10th percentile of the last 5 s, so a noisy room has pauses too). Frames before the stream started count.
    bool quiet(int64_t a, int64_t b) {
        noteLevels();
        const float q = std::max(quietDb.load(), floorDb + 6);
        for (int64_t f = std::max<int64_t>(a, 0); f < b; f++)
            if (levelAt(f) > q) return false;
        return true;
    }

    // The room's noise level (worker thread, before a quiet check).
    void noteLevels() {
        const int64_t newest = in16End / kFrame16 - 2;
        if (levelsAt < newest - (int64_t)levels.size()) levelsAt = newest - (int64_t)levels.size();
        for (; levelsAt < newest; levelsAt++) levels[(size_t)(levelsAt % (int64_t)levels.size())] = levelAt(levelsAt);
        const size_t have = (size_t)std::min<int64_t>(levelsAt, (int64_t)levels.size());
        if (have < 50) { floorDb = -120; return; }
        sorted.assign(levels.begin(), levels.begin() + (long)have);
        std::nth_element(sorted.begin(), sorted.begin() + (long)(have / 10), sorted.end());
        floorDb = sorted[have / 10];
    }

    // The pitch the AI voice follows, for the window's T frames (window frame t = 16 kHz frame E - T + t):
    // A1's tracker frames (nearest), each voiced frame smoothed with its voiced neighbours on both sides (the frames
    // after it are known by the time it is made, at least with look-ahead), short unvoiced gaps inside a loud sound
    // bridged, frames newer than the tracker holding the newest.
    void windowPitch(int64_t E, Runner &r, bool shapeIt) {
        const int T = r.model->T;
        int64_t pend = pitchEnd.load(std::memory_order_acquire), cursor = 0;
        const double toChain16 = rate / kRate16;
        for (int t = 0; t < T; t++) {
            int64_t j = E - T + t;
            bool k = false;
            double f = j < 0 ? 0 : pitchAt((kFrame16 * (double)j + kFrame16 / 2) * toChain16, pend, cursor, k);
            r.f0[(size_t)t] = f;
            r.known[(size_t)t] = j < 0 || k;
            r.st[(size_t)t] = f > 0 ? (float)(12 * std::log2(f / 100.0)) + 1000 : 0;  // + 1000: 0 stays "not voiced"
        }
        // 3.2: a voiced bit too short for speech with a pause on both sides (the tracker hearing a voice in noise):
        // no tone (known frames only)
        const int shortRun = shapeIt ? (shortRunMs.load() + 9) / 10 : 0;
        if (shortRun > 0) {
            const int side = 10;  // 100 ms unvoiced on each side
            for (int t = 0; t < T;) {
                if (r.st[(size_t)t] == 0) { t++; continue; }
                int e = t;
                while (e < T && r.st[(size_t)e] != 0) e++;
                if (e - t < shortRun && t >= side && e + side <= T) {
                    bool alone = true;
                    for (int u = t - side; u < e + side && alone; u++)
                        if (!r.known[(size_t)u] || (r.st[(size_t)u] != 0 && (u < t || u >= e))) alone = false;
                    if (alone) for (int u = t; u < e; u++) { r.st[(size_t)u] = 0; r.f0[(size_t)u] = 0; }
                }
                t = e;
            }
        }
        const int gap = shapeIt ? gapFrames.load() : 0;
        const bool strict = bridgeStrict.load() != 0;
        if (gap > 0) {
            for (int t = 0; t < T; t++) r.level[(size_t)t] = levelAt(E - T + t);
            for (int t = 1; t < T; t++) {
                if (r.st[(size_t)t] != 0 || r.st[(size_t)(t - 1)] == 0 || !r.known[(size_t)t]) continue;
                int e = t;
                while (e < T && r.st[(size_t)e] == 0 && e - t < gap) e++;
                if (e >= T || r.st[(size_t)e] == 0 || !r.known[(size_t)e]) continue;  // too long, or not known yet
                const float edge = std::min(r.level[(size_t)(t - 1)], r.level[(size_t)e]);
                bool loud = true;
                for (int u = t; u < e; u++) if (r.level[(size_t)u] < edge - 9) loud = false;  // a stop or a pause: keep it
                if (!loud) continue;
                if (strict) {  // 3.2: only over smooth sound well above the room's noise (not over an "s" or noise)
                    bool smooth = true;
                    for (int u = t; u < e; u++)
                        if (crossingsAt(E - T + u) >= 0.15f || r.level[(size_t)u] < floorDb + 12) smooth = false;
                    if (!smooth) continue;
                }
                const float a = r.st[(size_t)(t - 1)], b = r.st[(size_t)e];
                for (int u = t; u < e; u++) r.st[(size_t)u] = a + (b - a) * (float)(u - t + 1) / (float)(e - t + 1);
                t = e;
            }
        }
        // the start of a vowel: the tracker needs a few frames to call it voiced, and in them the AI voice would
        // breathe a little "h" (heard as "its" for "a"); a loud, smooth (not hissy) lead-in takes the vowel's first pitch
        const int onset = shapeIt ? onsetFrames.load() : 0;
        if (onset > 0) {
            for (int t = 1; t < T; t++) {
                if (r.st[(size_t)t] == 0 || r.st[(size_t)(t - 1)] != 0 || !r.known[(size_t)t]) continue;
                const float lv = levelAt(E - T + t);
                for (int u = t - 1; u >= std::max(0, t - onset); u--) {
                    if (r.st[(size_t)u] != 0 || !r.known[(size_t)u]) break;
                    if (levelAt(E - T + u) < lv - 6 || crossingsAt(E - T + u) > 0.25f) break;
                    r.st[(size_t)u] = r.st[(size_t)t];
                }
            }
        }
        // 3.2: hissy frames ("s", "sh", "f", noise) never get a tone, whatever the tracker or the hold said
        const float hiss = hissCross.load();
        if (hiss > 0)
            for (int t = 0; t < T; t++)
                if (r.st[(size_t)t] != 0 && crossingsAt(E - T + t) > hiss) { r.st[(size_t)t] = 0; r.f0[(size_t)t] = 0; }
        // Two smoothed lines over the voiced, known frames: a light one (±w frames: tracker noise out) and a slow one
        // (±ws: the speaker's melody). The voice's intonation made every move `into` times bigger, small fast ones
        // too (the wobble of a held note, the little dips at consonants); those go back to the speaker's own size.
        const int w = shapeIt ? smoothFrames.load() : 0, ws = slowFrames.load();
        const float into = intonation.load();
        const bool shape = shapeIt && into > 0.05f && ws > 0 && std::fabs(into - 1) > 1e-3f;
        auto line = [&](int t, int half) -> double {
            double sum = 0, wsum = 0;
            for (int d = -half; d <= half; d++) {
                int u = t + d;
                if (u < 0 || u >= T || r.st[(size_t)u] == 0 || !r.known[(size_t)u]) continue;
                double wt = half + 1 - std::abs(d);
                sum += wt * r.st[(size_t)u];
                wsum += wt;
            }
            return wsum > 0 ? sum / wsum : (double)r.st[(size_t)t];
        };
        for (int t = 0; t < T; t++) {
            const float v = r.st[(size_t)t];
            if (v != 0 && (w > 0 || shape) && r.known[(size_t)t]) {
                double s = w > 0 ? line(t, w) : v;
                if (shape) {
                    const double slow = line(t, ws);
                    s = slow + (s - slow) / into;
                }
                r.f0[(size_t)t] = 100.0 * std::exp2((s - 1000) / 12);
            } else if (v != 0 && !(r.f0[(size_t)t] > 0)) {  // a bridged gap
                r.f0[(size_t)t] = 100.0 * std::exp2((v - 1000) / 12);
            }
            r.pitch.i()[t] = coarse(r.f0[(size_t)t]);
        }
    }

    // One hop: the window is frames [E - T, E); this hop's sound comes from frames [A, A + H + X + S) with
    // A = E - LA - H - X - S. Returns false if the models failed.
    bool makeHop(int64_t E) {
        Runner &r = *run;
        VoiceModel &m = *r.model;
        const int T = m.T, upp = m.upp, DEC = m.decFrames, FLOW = m.flowFrames;
        const int LA = laNow;
        const int64_t A = E - LA - H - X - S;
        const int left = leftMs.load() >= 0 ? std::clamp(leftMs.load() / 10, 0, DEC - H - X - S) : m.marginMs / 10;
        int64_t d0 = A - (m.picks ? left : DEC - H - X - S);              // first decoded frame
        if (d0 + DEC > E) d0 = E - DEC;                                   // (look-ahead shorter than the right frames)
        const int M = (int)(A - d0);                                      // this hop's sound starts here in the block
        double t0 = nowMs();
        // 3.2: how much AI sound is ready ahead of where the sound thread reads (for the late-piece rule)
        double readyMs = 1e9;
        if (!offline) {
            const int64_t readAt = pulledA.load(std::memory_order_acquire) - baseBackA.load(std::memory_order_relaxed);
            if (readAt >= outStart.load(std::memory_order_relaxed)) readyMs = (double)(written - readAt) * 1000 / rate;
        }
        if (gainCap.load() || bridgeStrict.load()) noteLevels();  // 3.2: the room's noise level, every piece
        // 1. the window at 16 kHz (the encoder's: T frames, or more for a voice made for a shorter window)
        const int64_t encFrames = m.encoderSamples / kFrame16;
        in16.get((E - encFrames) * kFrame16, r.audio16.f(), (int)encFrames * kFrame16, 0);
        // 2. pitch for every frame (frame j's centre is 16 kHz sample 160 j + 80); with (almost) no look-ahead the
        // pieces are made at the window's newest end, where the frames are still being decided: no smoothing then
        // (it would differ from one piece to the next) and the crossfade searches for the best fit, as before
        const bool atEdge = LA < kEdgeFrames;
        windowPitch(E, r, !atEdge);
        if (humLiftDb.load() > 0) humLift(E, A, r, (int)encFrames * kFrame16);
        if (m.picks) for (int i = 0; i < DEC; i++) r.pick.i()[i] = (int32_t)(d0 - (E - T)) + i;
        // 3. NSF source for the decoded frames at the model rate (phase in double, carried across hops)
        const int64_t decStart = d0 * (int64_t)upp;
        double ph = phaseAt == decStart ? phase : 0.0;
        const int64_t keep = decStart + (int64_t)H * upp;
        float *src = r.source.f();
        for (int t = 0; t < DEC; t++) {
            const double f = r.f0[(size_t)(d0 - (E - T) + t)];
            const double inc = f / modelRate;
            for (int i = 0; i < upp; i++) {
                const int64_t s = decStart + (int64_t)t * upp + i;
                if (s == keep) { phaseAt = keep; phase = ph; }
                const float n = r.sourceNoise[(size_t)(((s % kSourceNoise) + kSourceNoise) % kSourceNoise)];
                src[t * upp + i] = f > 0 ? (float)(0.1 * std::sin(2 * M_PI * ph)) + 0.003f * n : 0.1f / 3 * n;
                ph += inc;
                if (ph >= 1) ph -= std::floor(ph);
            }
        }
        // 4. fixed z noise for the last FLOW frames
        float *zn = r.noise.f();
        for (int c = 0; c < kNoiseChannels; c++)
            for (int t = 0; t < FLOW; t++) {
                int64_t a = E - FLOW + t;
                zn[(size_t)c * FLOW + t] = r.zp[(size_t)c * kZpFrames + (size_t)(((a % kZpFrames) + kZpFrames) % kZpFrames)];
            }
        // 5. the models
        if (!predict(m.encoder, r.encoderIn, r.encoderOptions, @"features", r.features)) return false;
        if (r.voiceFeatures.count) {  // the voice's (shorter) window is the newest part of the encoder's
            const size_t keep = r.voiceFeatures.count, skip = r.features.count - keep;
            std::memcpy(r.voiceFeatures.f(), r.features.f() + skip, sizeof(float) * keep);
        }
        if (!predict(onCPU && m.voiceCPU ? m.voiceCPU : m.voice, r.voiceIn, r.voiceOptions, @"audio", r.audioOut)) return false;
        const int slow = slowMs.load();
        if (slow > 0 && slowEvery.load() > 0 && (hop % slowEvery.load()) == 0 && !(slowChip.load() && onCPU))
            usleep((useconds_t)slow * 1000);
        // 6. drop the left margin; SOLA: the best offset o in [0, S*upp] against the last tail, crossfade X*upp
        const float *y = r.audioOut.f() + (size_t)M * upp;
        const int hopN = H * upp, xN = X * upp, sN = S * upp;
        int o = 0;
        const int mode = solaMode.load() >= 0 ? solaMode.load() : (atEdge ? 0 : 1);
        const int nearN = std::clamp((int)std::lround(nearMs.load() * modelRate / 1000), 0, sN / 2);  // (mode 3)
        if (hops.load() > 0 && xN > 0 && sN > 0) {
            if (mode == 1) {
                o = std::clamp(lastO, 0, sN);  // the pieces line up already: keep the timing
            } else {
                int lo = mode == 2 ? std::max(0, lastO - upp / 10) : 0, hi = mode == 2 ? std::min(sN, lastO + upp / 10) : sN;
                if (mode == 3) { lo = 0; hi = 2 * nearN; }  // 3.2: near a fixed point (no drift)
                double best = -1e30;
                float energy = 0;
                vDSP_svesq(y + lo, 1, &energy, (vDSP_Length)xN);
                o = lo;
                for (int k = lo; k <= hi; k++) {
                    float dot = 0;
                    vDSP_dotpr(y + k, 1, r.sola.data(), 1, &dot, (vDSP_Length)xN);
                    double score = dot / std::sqrt((double)energy + 1e-8);
                    if (score > best) { best = score; o = k; }
                    if (k < hi) energy += y[k + xN] * y[k + xN] - y[k] * y[k];
                }
            }
        }
        if (mode == 3 && hops.load() == 0) o = nearN;  // (the first piece starts at the fixed point)
        lastO = o;
        // 7. loudness: follow the mic's own loudness, 10 ms by 10 ms (RVC's "rms mix" at 0), up to +gainMaxDb (3.2:
        // at most as far as the mic is above the room's noise: 0 dB at 6 dB above it, the full lift from 20 dB above,
        // and down to aiPauseDb (-10) at 3 dB above it and below, so the model's own hum in a pause is never lifted)
        const float gmax = std::pow(10.0f, gainMaxDb.load() / 20);
        const bool cap = gainCap.load() != 0;
        const int frames = H + X;
        const int hw16 = gainMs.load() * kRate16 / 2000, hwOut = gainMs.load() * modelRate / 2000;  // half windows
        const int lowest = gainTwoSided.load() ? -M * upp : 0;  // 3.2: the decoded left margin is there before o
        for (int f = 0; f < frames; f++) {
            const int64_t a = A + f;  // the 16 kHz frame this output frame came from
            double ein = 0;
            for (int i = kFrame16 / 2 - hw16; i < kFrame16 / 2 + hw16; i++) {
                int64_t p = a * kFrame16 + i;
                float v = p < 0 ? 0 : in16.at(p);
                ein += v * v;
            }
            double rin = std::sqrt(ein / (2 * hw16));
            double eout = 0;
            int cnt = 0;
            for (int i = upp / 2 - hwOut; i < upp / 2 + hwOut; i++) {
                int p = o + f * upp + i;
                if (p < lowest || p >= (int)(r.audioOut.count - (size_t)M * upp)) continue;
                eout += (double)y[p] * y[p];
                cnt++;
            }
            double rout = std::max(1e-3, std::sqrt(eout / std::max(1, cnt)));
            float gm = gmax;
            if (cap) {
                const float lv = (float)(20 * std::log10(rin + 1e-9));
                float capDb = gainMaxDb.load() * std::clamp((lv - floorDb - 6) / 14, 0.0f, 1.0f);
                if (lv < floorDb + 6)  // (a ramp, not a step: a step pumped the voice in a noisy room)
                    capDb = pauseDb.load() * std::clamp((floorDb + 6 - lv) / 3, 0.0f, 1.0f);
                gm = std::min(gm, std::pow(10.0f, capDb / 20));
            }
            r.gains[(size_t)f] = (float)std::min<double>(gm, rin / rout);
        }
        float *blk = r.block.data();
        float g0 = lastGain;
        if (!fadeAdapt.load() && !joinGains.load()) {  // (3.1.1) crossfade the raw pieces, then this piece's gains on all
            std::memcpy(blk, y + o, sizeof(float) * (size_t)hopN);
            for (int i = 0; i < xN; i++) blk[i] = blk[i] * r.fadeIn[(size_t)i] + r.sola[(size_t)i] * r.fadeOut[(size_t)i];
            if (trace && hops.load() > 0) r.prevTail = r.sola;
            std::memcpy(r.sola.data(), y + o + hopN, sizeof(float) * (size_t)xN);
            std::memcpy(r.tail.data(), r.sola.data(), sizeof(float) * (size_t)xN);
            for (int f = 0; f < H; f++) {  // ramp from the last frame's gain to this frame's, sample by sample
                float g1 = r.gains[(size_t)f];
                for (int i = 0; i < upp; i++) blk[f * upp + i] *= g0 + (g1 - g0) * (i + 1) / upp;
                g0 = g1;
            }
        } else {
            // 3.2: how alike the two pieces are where they meet (1 = the same sound): alike -> equal gain (the old
            // fades), unlike -> equal power, so the join doesn't dip; each piece keeps its own gains (the old tail
            // already has its piece's gains in r.tail)
            double like = 1;
            if (fadeAdapt.load() && hops.load() > 0 && xN > 0) {
                float d = 0, e1 = 0, e2 = 0;
                vDSP_dotpr(y + o, 1, r.sola.data(), 1, &d, (vDSP_Length)xN);
                vDSP_svesq(y + o, 1, &e1, (vDSP_Length)xN);
                vDSP_svesq(r.sola.data(), 1, &e2, (vDSP_Length)xN);
                like = e1 > 1e-9f && e2 > 1e-9f ? std::clamp(d / std::sqrt((double)e1 * e2), 0.0, 1.0) : 1.0;
            }
            const bool own = joinGains.load() != 0;
            if (trace && hops.load() > 0) r.prevTail = r.sola;
            for (int f = 0; f < H; f++) {
                const float g1 = r.gains[(size_t)f];
                for (int i = 0; i < upp; i++) {
                    const int k = f * upp + i;
                    const float g = g0 + (g1 - g0) * (i + 1) / upp;
                    float v = y[o + k] * g;
                    if (k < xN) {
                        const double w = r.fadeIn[(size_t)k];
                        const double den = like >= 1 ? 1.0 : std::sqrt(w * w + (1 - w) * (1 - w) + 2 * like * w * (1 - w));
                        const float a = (float)(w / den), b = (float)((1 - w) / den);
                        const float old = own ? r.tail[(size_t)k] : r.sola[(size_t)k] * g;
                        v = v * a + old * b;
                    }
                    blk[k] = v;
                }
                g0 = g1;
            }
            std::memcpy(r.sola.data(), y + o + hopN, sizeof(float) * (size_t)xN);
            std::memcpy(r.tail.data(), r.sola.data(), sizeof(float) * (size_t)xN);
        }
        const float gEnd = g0;
        for (int f = 0; f < X; f++) {
            float g1 = r.gains[(size_t)(H + f)];
            for (int i = 0; i < upp; i++) r.tail[(size_t)(f * upp + i)] *= g0 + (g1 - g0) * (i + 1) / upp;
            g0 = g1;
        }
        lastGain = gEnd;
        // 3.2: headroom: a peak limiter on the finished piece (it is ready before it plays, so it can look 5 ms ahead,
        // into the tail the next piece crossfades from); the app's soft limiter then never bends the AI voice
        if (limitAt.load() > 0) limit(r, blk, hopN, xN, limitAt.load());
        if (trace) {  // research: how alike the two pieces are where they are crossfaded (1 = the same sound)
            float ey = 0, et = 0;
            vDSP_svesq(y + o, 1, &ey, (vDSP_Length)xN);
            double ncc = 0;
            if (!r.prevTail.empty()) {
                float d2 = 0, e2 = 0;
                vDSP_dotpr(y + o, 1, r.prevTail.data(), 1, &d2, (vDSP_Length)xN);
                vDSP_svesq(r.prevTail.data(), 1, &e2, (vDSP_Length)xN);
                ncc = d2 / std::sqrt((double)ey * e2 + 1e-12);
                et = e2;
            }
            std::fprintf(trace, "hop %lld E %lld A %lld la %d M %d o %d ncc %.3f lev %.1f", (long long)hop, (long long)E, (long long)A,
                         LA, M, o, ncc, 10 * std::log10(et / std::max(1, xN) + 1e-12));
            std::fprintf(trace, " | f0");
            for (int t = 0; t < H + X + S; t++) std::fprintf(trace, " %.1f", r.f0[(size_t)(A - (E - T) + t)]);
            std::fprintf(trace, " | gain");
            for (int f = 0; f < frames; f++) std::fprintf(trace, " %.3f", r.gains[(size_t)f]);
            std::fprintf(trace, "\n");
        }
        // 8. into the output ring (chain rate): the final block, then the provisional tail after it
        toChain.run(blk, hopN, [&](const float *p, int n) {
            out.put(written, p, n);
            written += n;
        });
        int64_t prov = written;
        toChain.runCopy(r.tail.data(), xN, [&](const float *p, int n) {
            out.put(prov, p, n);
            tailRing.put(prov, p, n);  // (3.2: a copy the final block won't overwrite, for a late piece's grace)
            prov += n;
        });
        outFinal.store(written, std::memory_order_release);
        outProv.store(std::max(prov, written), std::memory_order_release);
        // 9. stats
        double ms = nowMs() - t0;
        hops.fetch_add(1);
        sumHopMs.store(sumHopMs.load() + ms);
        if (ms > worstHopMs.load()) worstHopMs.store(ms);
        double wall = nowMs() - attachWallMs;
        if (wall > 0) cpuShare.store((threadCpuMs() - attachCpuMs) / wall);
        if (readyMs < 1e8) chooseChip(readyMs - ms);
        return true;
    }

    // 3.2: margin = how long before the sound thread needed it this piece was ready (ms; < 0: late). On the GPU, 2
    // late or 4 tight (< 15 ms) pieces of the last 10 move the voice generator to its warm CPU copy (a game is using
    // the GPU); back to the GPU only after 30 s, and only if the CPU runs late too (2 late or 8 tight of the last 10:
    // no blind tries). A try that fails (a late piece on the GPU within 10 s) goes straight back and doubles the wait,
    // up to 4 minutes.
    void chooseChip(double margin) {
        const bool late = margin < 0, tight = margin < 15;
        if (late) lateHops.fetch_add(1);
        if (tight) tightHops.fetch_add(1);
        if (!autoChip.load() || !run->model->voiceCPU) return;
        lateBits = ((lateBits << 1) | (late ? 1u : 0u)) & 0x3FFu;
        tightBits = ((tightBits << 1) | (tight ? 1u : 0u)) & 0x3FFu;
        const int nLate = __builtin_popcount(lateBits), nTight = __builtin_popcount(tightBits);
        const double now = nowMs();
        if (onCPU) {
            if (now - chipSinceMs < cpuHoldMs || (nLate < 2 && nTight < 8)) return;
        } else {
            // (just back from the CPU: one late piece is enough to say the GPU is still busy)
            const bool trying = chipSwitches.load() > 0 && now - chipSinceMs < 10000;
            if (nLate < (trying ? 1 : 2) && nTight < 4) return;
            // back on the GPU for less than 10 s: that try failed, wait longer next time
            cpuHoldMs = now - chipSinceMs < 10000 && chipSwitches.load() > 0 ? std::min(cpuHoldMs * 2, 240000.0) : 30000.0;
        }
        onCPU = !onCPU;
        chipSinceMs = now;
        lateBits = tightBits = 0;
        chipSwitches.fetch_add(1);
        onCPUShown.store(onCPU ? 1 : 0, std::memory_order_relaxed);
    }

    // 3.4 (aiHumLiftDb, aiHumLevelDb): the trained voices lose the tone of a long, quiet hum (they waver, drop an
    // octave or whisper), less so when it is louder. When the sound around this piece (+-0.4 s of known frames) is a
    // steady note - at least 30 voiced frames, 80 % of them within 0.75 half-steps of their median - the speech reader
    // hears the window lifted toward humLevelDb (the voiced frames' mean power), by at most humLiftDb, moving 2 dB per
    // piece (and never taking the window's peak over 0.9). Only the encoder's copy changes: the output still follows
    // the mic's loudness (step 7 reads in16), and speech, never that steady, is untouched.
    void humLift(int64_t E, int64_t A, Runner &r, int samples) {
        const int T = r.model->T;
        const int a = (int)std::max<int64_t>(0, A - 40 - (E - T)), b = (int)std::min<int64_t>(T, A + H + 40 - (E - T));
        float st[128];
        int n = 0, span = 0;
        double e = 0;
        for (int t = a; t < b; t++) {
            if (!r.known[(size_t)t]) continue;
            span++;
            if (r.st[(size_t)t] == 0 || n >= 128) continue;
            st[n++] = r.st[(size_t)t];
            e += std::pow(10.0, levelAt(E - T + t) / 10);
        }
        float want = 0;
        if (n >= 30 && n * 10 >= span * 7) {
            std::nth_element(st, st + n / 2, st + n);
            const float mid = st[n / 2];
            int near = 0;
            for (int k = 0; k < n; k++) if (std::fabs(st[k] - mid) <= 0.75f) near++;
            if (near * 10 >= n * 8)
                want = std::clamp(humLevelDb.load() - (float)(10 * std::log10(e / n + 1e-12)), 0.0f, humLiftDb.load());
        }
        liftDb += std::clamp(want - liftDb, -2.0f, 2.0f);
        if (liftDb <= 0.01f) return;
        float peak = 0;
        vDSP_maxmgv(r.audio16.f(), 1, &peak, (vDSP_Length)samples);
        const float g = std::min(std::pow(10.0f, liftDb / 20), peak > 0 ? 0.9f / peak : 1e9f);
        if (g > 1) vDSP_vsmul(r.audio16.f(), 1, &g, r.audio16.f(), 1, (vDSP_Length)samples);
    }

    // 3.2: peak limiter, threshold thr: each sample's gain is the smallest any sample in the next 5 ms needs, averaged
    // over 5 ms (so it is never above what that sample needs and turns down smoothly before a peak), coming back up
    // over 80 ms. Works at the model's rate on the final block and gives the tail the gain it ended with.
    void limit(Runner &r, float *blk, int n, int nt, float thr) {
        const int L = std::max(1, modelRate / 200);
        const int ext = n + std::min(L, nt);
        auto need = [&](int j) -> float {
            const float v = std::fabs(j < n ? blk[j] : r.tail[(size_t)(j - n)]);
            return v > thr ? thr / v : 1.0f;
        };
        if ((int)r.limHist.size() != L - 1) r.limHist.assign((size_t)(L - 1), 1.0f);
        r.limH.resize((size_t)n);
        r.limQ.resize((size_t)ext + 1);
        int qh = 0, qt = 0;  // queue of indices with rising needs (sliding minimum over [i, i + L))
        int next = 0;
        for (int i = 0; i < n; i++) {
            const int until = std::min(ext, i + L);
            for (; next < until; next++) {
                const float v = need(next);
                while (qt > qh && need(r.limQ[(size_t)(qt - 1)]) >= v) qt--;
                r.limQ[(size_t)qt++] = next;
            }
            while (r.limQ[(size_t)qh] < i) qh++;
            r.limH[(size_t)i] = need(r.limQ[(size_t)qh]);
        }
        const double rel = 1 - std::exp(-1.0 / (0.08 * modelRate));
        double sum = 0;
        for (float v : r.limHist) sum += v;
        auto hAt = [&](int k) -> float { return k < 0 ? r.limHist[(size_t)(k + L - 1)] : r.limH[(size_t)k]; };
        float g = limG;
        for (int i = 0; i < n; i++) {
            sum += r.limH[(size_t)i];
            const float avg = (float)(sum / L);
            sum -= hAt(i - L + 1);
            g = std::min(avg, (float)(g + (1 - g) * rel));
            if (g < 1) blk[i] *= g;
        }
        for (int k = 0; k < L - 1; k++) r.limHist[(size_t)k] = hAt(n - (L - 1) + k);
        limG = g;
        if (g < 1) for (int j = 0; j < nt; j++) r.tail[(size_t)j] *= g;
    }

    // Before hop `next` (E = (next + 1) * H): starts the AI voice (at once: the stream has played at its fixed
    // delay from the start, Natural filling in, so nothing is heard twice) and switches the look-ahead when another
    // one was asked for, at a quiet moment so nothing is heard twice or lost (after 1.2 s without one, it switches
    // anyway: the crossfade then joins the two). The converted index of the hop's block stays next * H either way;
    // only what it holds moves.
    void junction(int64_t next) {
        int want = 0, ex = 0;
        splitFor(std::clamp(laWant.load(), 0, maxAhead()), want, ex);
        const int64_t E = (next + 1) * H;
        const int64_t step = (int64_t)H * kFrame16;
        bool go = false;
        if (!started) {
            go = true;
        } else if (want != laNow || ex != exNow) {
            // (a reserve change also moves the read point, by the change: that much more sound must be quiet)
            const int64_t A0 = E - laNow - H - X - S, A1 = E - want - H - X - S;
            if (askedAtHop < 0) askedAtHop = next;
            go = offline || quiet(std::min(A0, A1) - 2, std::max(A0, A1) + X + 2 + std::abs(ex - exNow)) ||
                 (double)((next - askedAtHop) * step) > kSwitchWaitS * kRate16;
        }
        if (!go) return;
        laNow = want;
        exNow = ex;
        laShown.store(laNow, std::memory_order_relaxed);
        exShown.store(exNow, std::memory_order_relaxed);
        askedAtHop = -1;
        if (started) switches.fetch_add(1);
        started = true;
        // the pull side lines Natural's fill-in up with the new delay from this block on
        const int64_t at = (int64_t)std::llround(next * (double)H * run->model->upp * rate / run->model->rate);
        junctionLatency.store(latencyFor(laNow, exNow), std::memory_order_relaxed);
        junctionBack.store(backFor(exNow), std::memory_order_relaxed);
        junctionAt.store(at, std::memory_order_release);
    }

    // Starts a model on this stream (worker thread, or the caller's in offline mode).
    void adopt(VoiceModel *m) {
        Runner *r = new Runner();
        if (!makeRunner(m, *r)) { delete r; return; }
        const int upp = m->upp, xN = X * upp, hopN = H * upp;
        r->block.assign((size_t)hopN, 0.0f);
        r->tail.assign((size_t)xN, 0.0f);
        r->sola.assign((size_t)xN, 0.0f);
        r->fadeIn.resize((size_t)xN);
        r->fadeOut.resize((size_t)xN);
        for (int i = 0; i < xN; i++) {
            double s = std::sin(0.5 * M_PI * i / std::max(1, xN));
            r->fadeIn[(size_t)i] = (float)(s * s);
            r->fadeOut[(size_t)i] = 1 - r->fadeIn[(size_t)i];
        }
        r->gains.assign((size_t)(H + X), 0.0f);
        r->limH.assign((size_t)hopN, 1.0f);
        r->limQ.assign((size_t)(hopN + xN + 1), 0);
        delete run;
        run = r;
        modelRate = m->rate;
        toChain.init(rate / m->rate, hopN + xN + 64);
        // start at the newest complete hop (the window before it is history, or silence)
        resampleNew();
        hop = std::max<int64_t>(0, in16End / ((int64_t)H * kFrame16) - 1);
        const int64_t m0 = hop * (int64_t)H * upp;  // model-rate index of this hop's block
        written = (int64_t)std::llround(m0 * rate / m->rate);
        outFinal.store(written, std::memory_order_release);
        outProv.store(written, std::memory_order_release);
        outStart.store(written, std::memory_order_release);
        lastGain = 0;
        lastO = 0;
        limG = 1;
        liftDb = 0;
        phaseAt = INT64_MIN;
        laNow = std::clamp(laNow, 0, maxAhead());
        onCPU = startChip.load() && m->voiceCPU;
        onCPUShown.store(onCPU ? 1 : 0, std::memory_order_relaxed);
        chipSinceMs = nowMs();
        lateBits = tightBits = 0;
        attachWallMs = nowMs();
        attachCpuMs = threadCpuMs();
        loaded.store(1);
    }

    // Makes every hop whose window is complete.
    void work() {
        VoiceModel *m = pending.exchange(nullptr);
        if (m) adopt(m);
        resampleNew();
        if (!run) {  // no model yet: only keep the 16 kHz copy moving; look again in 100 ms
            wakeAt.store(inEnd.load(std::memory_order_relaxed) + (int64_t)(rate * 0.1), std::memory_order_release);
            return;
        }
        const int64_t step = (int64_t)H * kFrame16;
        // fell more than a second behind (a stall): jump to the newest hop; Natural covers the gap
        const int64_t newest = in16End / step - 1;
        if (newest - hop > (int64_t)(1.0 * kRate16 / step) + 1) {
            skipped.fetch_add(newest - hop);
            hop = newest;
            const int64_t m0 = hop * (int64_t)H * run->model->upp;
            toChain.reset();
            written = (int64_t)std::llround(m0 * rate / run->model->rate);
            std::fill(run->sola.begin(), run->sola.end(), 0.0f);
            std::fill(run->tail.begin(), run->tail.end(), 0.0f);
            lastGain = 0;
            outFinal.store(written, std::memory_order_release);
            outProv.store(written, std::memory_order_release);
        }
        while (!quit.load() && (hop + 1) * step <= in16End) {
            junction(hop);
            if (!makeHop((hop + 1) * H)) { hop++; break; }
            hop++;
            resampleNew();
        }
        // wake again when the next hop's sound is in (chain samples)
        wakeAt.store((int64_t)std::ceil(((hop + 1) * step + inLag16 + 1) * rate / kRate16), std::memory_order_release);
    }

    static void *threadMain(void *arg) {
        auto *s = (VoiceStream *)arg;
        pthread_setname_np("Pitch Shift AI voice");
        while (!s->quit.load()) {
            dispatch_semaphore_wait(s->wake, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC));
            if (s->quit.load()) break;
            if (s->realtime.load() && !s->rtSet) s->setRealtime();
            @autoreleasepool { s->work(); }
        }
        return nullptr;
    }

    // 3.2 (aiRealtime): the worker as a real-time thread: one piece per hop, up to half a hop of work.
    void setRealtime() {
        rtSet = true;
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        auto ticks = [&](double ms) { return (uint32_t)(ms * 1e6 * tb.denom / tb.numer); };
        thread_time_constraint_policy_data_t pol;
        pol.period = ticks(H * 10.0);
        pol.computation = ticks(std::min(H * 5.0, 50.0));
        pol.constraint = ticks(H * 9.0);
        pol.preemptible = 1;
        thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&pol,
                          THREAD_TIME_CONSTRAINT_POLICY_COUNT);
    }

    // -------------------------------------------------------------------------------------- sound thread side
    void push(const float *mic, int frames, const float *f0Hz, const int64_t *f0Pos, int n) {
        int64_t end = inEnd.load(std::memory_order_relaxed);
        if (mic) in.put(end, mic, frames);
        else for (int i = 0; i < frames; i++) in.buf[(size_t)((end + i) & in.mask)] = 0;
        if (gate && gateOn.load(std::memory_order_relaxed)) soundgate_push(gate, mic, frames);
        int64_t pe = pitchEnd.load(std::memory_order_relaxed);
        for (int k = 0; k < n && f0Hz && f0Pos; k++) {
            pitchPos[(size_t)(pe % kPitchSlots)] = f0Pos[k];
            pitchHz[(size_t)(pe % kPitchSlots)] = f0Hz[k];
            pe++;
        }
        pitchEnd.store(pe, std::memory_order_release);
        inEnd.store(end + frames, std::memory_order_release);
        if (offline) {
            @autoreleasepool { work(); }
        } else if (end + frames >= wakeAt.load(std::memory_order_acquire)) {
            dispatch_semaphore_signal(wake);
        }
    }

    // 3.4: where the gate says so, the original mic sound (lined up with what plays: playLatency behind) replaces
    // the AI voice (or Natural's fill-in), crossfaded by the gate's weights.
    void passSounds(int64_t P, float *outBuf, int frames) {
        if (playLatency != gateFit) {  // (the look-ahead it can use is the delay less one callback)
            gateFit = playLatency;
            soundgate_fit(gate, playLatency - maxFrames);
        }
        const int64_t t0 = P - playLatency;
        for (int done = 0; done < frames;) {
            const int n = std::min(frames - done, (int)gateW.size());
            if (soundgate_weights(gate, t0 + done, n, gateW.data())) {
                for (int i = 0; i < n; i++) {
                    const float w = gateW[(size_t)i];
                    if (w <= 0) continue;
                    const int64_t m = t0 + done + i;
                    const float dry = m >= 0 ? in.at(m) : 0.0f;
                    outBuf[done + i] += w * (dry - outBuf[done + i]);
                }
            }
            done += n;
        }
    }

    void pull(const float *naturalNow, int naturalDelay, float *outBuf, int frames) {
        const int64_t P = pulled;
        if (naturalNow) natural.put(P, naturalNow, frames);
        else for (int i = 0; i < frames; i++) natural.buf[(size_t)((P + i) & natural.mask)] = 0;
        const int64_t fin = outFinal.load(std::memory_order_acquire);
        const int64_t prov = outProv.load(std::memory_order_acquire);
        const int64_t first = outStart.load(std::memory_order_acquire);
        // A look-ahead switch (or the AI's first start) reached: Natural's fill-in moves to the new delay with it, and
        // (3.2) the read point moves by a reserve change, once both the old and the new one have reached it.
        const int64_t jAt = junctionAt.load(std::memory_order_acquire);
        if (jAt != junctionSeen) {
            const int back = junctionBack.load(std::memory_order_relaxed);
            if (P - std::max(baseBack, back) >= jAt) {
                junctionSeen = jAt;
                playLatency = junctionLatency.load(std::memory_order_relaxed);
                if (back != baseBack) {
                    jumpFrom = baseBack;
                    jumpLeft = rampLen;
                    baseBack = back;
                    baseBackA.store(back, std::memory_order_relaxed);
                }
            }
        }
        const int64_t q0 = P - baseBack;          // converted index for this callback's first sample
        const int64_t qEnd = q0 + frames;         // one past the last
        const int64_t natBack = std::max<int64_t>(0, playLatency - std::max(0, naturalDelay));
        // 3.2: a late piece: play on into the provisional tail for up to graceMs before Natural fills in
        const int graceN = graceMs.load() > 0
            ? std::max(0, std::min((int)std::lround(graceMs.load() * rate / 1000), (int)std::lround(X * rate / 100) - 2 * rampLen)) : 0;
        // Decide for the whole callback: play the AI voice when all of it is final and (when coming back) a ramp's
        // worth more is ready too; fall back when it is not final (a late hop: the provisional tail carries the fade).
        float target;
        bool grace = false;
        const bool isLoaded = loaded.load(std::memory_order_relaxed);
        if (isLoaded && q0 >= first && qEnd <= fin && (mix > 0 || qEnd + rampLen <= fin)) {
            target = 1;
            if (graceRead) { landLeft = rampLen; graceSaves.fetch_add(1); }  // landed while its tail played: ramp in
            graceRead = false;
        } else if (graceN > 0 && isLoaded && mix >= 1 && q0 >= first && qEnd <= prov &&
                   qEnd <= (graceRead ? graceFin : fin) + graceN) {
            target = 1;
            grace = true;
            if (!graceRead) { graceRead = true; graceFin = fin; }
        } else {
            target = 0;
            graceRead = false;
            landLeft = 0;
            if (playing && mix > 0 && !lateNow) { misses.fetch_add(1); lateNow = true; }
        }
        if (target == 1 && !grace) lateNow = false;
        const float step = 1.0f / (float)rampLen;
        int64_t loud = 0;
        for (int i = 0; i < frames; i++) {
            const int64_t pos = P + i;
            const int64_t np = pos - natBack;
            const float nat = np >= 0 ? natural.at(np) : 0.0f;  // (silence until Natural's sound reaches the delay)
            const int64_t q = q0 + i;
            float ai = 0;
            bool have = q >= first && q < prov;
            if (have) ai = graceN > 0 && q >= fin ? tailRing.at(q) : out.at(q);
            if (landLeft > 0) {  // 3.2: the late piece landed: from its tail (as it played) into it
                const float b = 1.0f - (float)landLeft / (float)rampLen;
                ai = b * ai + (1 - b) * tailRing.at(q);
                landLeft--;
            }
            if (jumpLeft > 0) {  // 3.2: the read point moved (a reserve change): from the old one into the new
                const int64_t qo = pos - jumpFrom;
                const float was = qo >= first && qo < prov ? out.at(qo) : 0.0f;
                const float b = 1.0f - (float)jumpLeft / (float)rampLen;
                ai = b * ai + (1 - b) * was;
                jumpLeft--;
            }
            if (target > mix) mix = std::min(1.0f, mix + step);
            else if (target < mix) mix = std::max(0.0f, mix - (have ? step : 4 * step));  // out of AI sound: hurry
            outBuf[i] = mix * ai + (1 - mix) * nat;
            if (std::fabs(outBuf[i]) > 0.7f) loud++;
        }
        if (gate && gateOn.load(std::memory_order_relaxed)) passSounds(P, outBuf, frames);
        if (loud) loudSamples.fetch_add(loud, std::memory_order_relaxed);
        samplesOut.fetch_add(frames, std::memory_order_relaxed);
        if (mix >= 1) playing = true;
        if (playing && mix < 1) fallbackFrames.fetch_add(frames);
        aiNow.store(mix >= 1 ? 1 : 0, std::memory_order_relaxed);
        pulled = P + frames;
        pulledA.store(pulled, std::memory_order_release);
    }
};

extern "C" {

VoiceModel *voicemodel_load(const char *encoderPath, const char *voicePath, int computeUnits, char *err, int errSize) {
    if (!encoderPath || !voicePath) { say(err, errSize, "no model files"); return nullptr; }
    @autoreleasepool {
        double t0 = nowMs();
        auto *m = new VoiceModel();
        NSURL *encURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:encoderPath]];
        NSURL *voiceURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:voicePath]];
        int ue = computeUnits, uv = computeUnits;
        if (computeUnits == VOICEMODEL_COMPUTE_AUTO) { ue = VOICEMODEL_COMPUTE_ANE; uv = VOICEMODEL_COMPUTE_GPU; }
        auto open = [&](NSURL *url, int units) -> MLModel * {
            MLModelConfiguration *cfg = [MLModelConfiguration new];
            cfg.computeUnits = unitsFor(units);
            NSError *why = nil;
            return [MLModel modelWithContentsOfURL:url configuration:cfg error:&why];
        };
        m->encoder = open(encURL, ue);
        m->voice = open(voiceURL, uv);
        if ((!m->encoder || !m->voice) && (ue != VOICEMODEL_COMPUTE_CPU || uv != VOICEMODEL_COMPUTE_CPU)) {
            ue = uv = VOICEMODEL_COMPUTE_CPU;  // the CPU always works
            m->encoder = open(encURL, ue);
            m->voice = open(voiceURL, uv);
        }
        if (!m->encoder || !m->voice) {
            say(err, errSize, "the voice model files can't be opened");
            delete m;
            return nullptr;
        }
        m->unitsEncoder = ue;
        m->unitsVoice = uv;
        m->cpuOnly = ue == VOICEMODEL_COMPUTE_CPU && uv == VOICEMODEL_COMPUTE_CPU;
        // 3.2: a CPU-only copy of the voice generator, warmed below, for when the GPU is busy (a game): the stream
        // switches to it when pieces run late (~50 MB more)
        if (uv != VOICEMODEL_COMPUTE_CPU) m->voiceCPU = open(voiceURL, VOICEMODEL_COMPUTE_CPU);
        // shapes and names
        MLModelDescription *ed = m->encoder.modelDescription, *vd = m->voice.modelDescription;
        NSArray<NSNumber *> *ein = ed.inputDescriptionsByName[@"audio"].multiArrayConstraint.shape;
        NSArray<NSNumber *> *eout = ed.outputDescriptionsByName[@"features"].multiArrayConstraint.shape;
        NSArray<NSNumber *> *vf = vd.inputDescriptionsByName[@"features"].multiArrayConstraint.shape;
        NSArray<NSNumber *> *vp = vd.inputDescriptionsByName[@"pitch"].multiArrayConstraint.shape;
        NSArray<NSNumber *> *vs = vd.inputDescriptionsByName[@"source"].multiArrayConstraint.shape;
        NSArray<NSNumber *> *vn = vd.inputDescriptionsByName[@"noise"].multiArrayConstraint.shape;
        NSArray<NSNumber *> *va = vd.outputDescriptionsByName[@"audio"].multiArrayConstraint.shape;
        if (ein.count != 2 || eout.count != 3 || vf.count != 3 || vp.count != 2 || vs.count != 3 || vn.count != 3 || va.count != 2 ||
            eout[2].intValue != kFeatureDim || vf[2].intValue != kFeatureDim || vn[1].intValue != kNoiseChannels ||
            vf[1].intValue * 2 != vp[1].intValue || eout[1].intValue * 2 * kFrame16 != ein[1].intValue ||  // (the encoder's
            ein[1].intValue < vp[1].intValue * kFrame16 || (ein[1].intValue / kFrame16 - vp[1].intValue) % 2 ||  // window may be longer)
            vs[2].intValue != va[1].intValue ||
            vd.inputDescriptionsByName[@"pitch"].multiArrayConstraint.dataType != MLMultiArrayDataTypeInt32) {
            say(err, errSize, "the voice model files don't fit together");
            delete m;
            return nullptr;
        }
        m->encoderSamples = ein[1].intValue;
        m->featureFrames = eout[1].intValue;
        m->T = vp[1].intValue;
        m->decSamples = vs[2].intValue;
        m->flowFrames = vn[2].intValue;
        NSDictionary *meta = vd.metadata[MLModelCreatorDefinedKey];
        NSDictionary *emeta = ed.metadata[MLModelCreatorDefinedKey];
        m->rate = metaInt(meta, @"rate", 48000);
        m->upp = metaInt(meta, @"upp", m->rate / 100);
        m->hopMs = metaInt(meta, @"hop_ms", 160);
        m->contextMs = metaInt(meta, @"context_ms", metaInt(emeta, @"context_ms", 0));
        m->decFrames = metaInt(meta, @"dec_frames", m->decSamples / m->upp);
        m->xfadeMs = metaInt(meta, @"xfade_ms", 40);
        m->solaMs = metaInt(meta, @"sola_ms", 10);
        m->marginMs = metaInt(meta, @"margin_ms", m->decFrames * 10 - m->hopMs - m->xfadeMs - m->solaMs);
        if (m->contextMs <= 0) m->contextMs = m->T * 10 - m->hopMs - m->xfadeMs - m->solaMs;
        // RVC v2 voices come at 32, 40 or 48 kHz (many downloaded voices are 40 kHz); the output is resampled to
        // the chain's rate (libsamplerate, as for any mic rate).
        if (m->rate != 32000 && m->rate != 40000 && m->rate != 48000) {
            char why[96];
            std::snprintf(why, sizeof why, "the voice model's sample rate (%d Hz) isn't supported: it needs 32, 40 or 48 kHz", m->rate);
            say(err, errSize, why);
            delete m;
            return nullptr;
        }
        // the look-ahead shape: a "pick" input says which window frames to decode; the flow covers the whole window
        // (older voice files have no "pick" input: they load as before and use no look-ahead)
        if (MLFeatureDescription *pick = vd.inputDescriptionsByName[@"pick"]) {
            NSArray<NSNumber *> *ps = pick.multiArrayConstraint.shape;
            m->picks = true;
            m->rightMs = metaInt(meta, @"right_ms", 0);
            m->maxAheadMs = metaInt(meta, @"max_ahead_ms", 0);
            if (ps.count != 1 || ps[0].intValue != m->decFrames || pick.multiArrayConstraint.dataType != MLMultiArrayDataTypeInt32 ||
                m->flowFrames != m->T || m->maxAheadMs < 0 || m->maxAheadMs % 10 || m->rightMs < 0 ||
                m->decFrames * 10 != m->marginMs + m->hopMs + m->xfadeMs + m->solaMs + m->rightMs ||
                m->T * 10 < m->maxAheadMs + m->marginMs + m->hopMs + m->xfadeMs + m->solaMs) {
                say(err, errSize, "the voice model files have unexpected sizes");
                delete m;
                return nullptr;
            }
        }
        if (m->decFrames * m->upp != m->decSamples || m->flowFrames < m->decFrames || m->T < m->flowFrames ||
            m->decFrames * 10 < m->hopMs + m->xfadeMs + m->solaMs || m->upp != m->rate / 100) {
            say(err, errSize, "the voice model files have unexpected sizes");
            delete m;
            return nullptr;
        }
        m->loadMs = nowMs() - t0;
        // Warm up (macOS prepares the models for the chip on the first calls) and time a few hops.
        Runner r;
        if (!makeRunner(m, r)) { say(err, errSize, "out of memory"); delete m; return nullptr; }
        double tw = nowMs();
        for (int k = 0; k < 2; k++) {
            if (!predict(m->encoder, r.encoderIn, r.encoderOptions, @"features", r.features) ||
                !predict(m->voice, r.voiceIn, r.voiceOptions, @"audio", r.audioOut)) {
                say(err, errSize, "the voice model doesn't run");
                delete m;
                return nullptr;
            }
        }
        m->warmMs = nowMs() - tw;
        double tp = nowMs();
        for (int k = 0; k < 3; k++) {
            predict(m->encoder, r.encoderIn, r.encoderOptions, @"features", r.features);
            predict(m->voice, r.voiceIn, r.voiceOptions, @"audio", r.audioOut);
        }
        m->probeHopMs = (nowMs() - tp) / 3;
        if (m->voiceCPU) {  // warm the CPU copy too (the first calls prepare it), then time it
            bool ok = true;
            for (int k = 0; k < 2 && ok; k++) ok = predict(m->voiceCPU, r.voiceIn, r.voiceOptions, @"audio", r.audioOut);
            if (ok) {
                double tc = nowMs();
                for (int k = 0; k < 2; k++) predict(m->voiceCPU, r.voiceIn, r.voiceOptions, @"audio", r.audioOut);
                m->cpuProbeHopMs = (nowMs() - tc) / 2;
            } else {
                m->voiceCPU = nil;  // (it doesn't run: keep the one chip)
            }
        }
        char buf[256];
        std::snprintf(buf, sizeof buf, "encoder on %s, voice on %s; hop %d ms, past sound %d ms; one hop %.0f ms; ready in %.1f s",
                      unitsName(ue), unitsName(uv), m->hopMs, m->contextMs, m->probeHopMs, (nowMs() - t0) / 1000);
        if (m->rate != 48000) {  // (48 kHz, like the built-in voices, isn't mentioned)
            size_t used = std::strlen(buf);
            std::snprintf(buf + used, sizeof buf - used, "; %d kHz voice", m->rate / 1000);
        }
        m->describe = buf;
        if (m->picks) m->describe += "; look-ahead up to " + std::to_string(m->maxAheadMs) + " ms";
        if (m->voiceCPU) m->describe += "; CPU copy of the voice ready (" + std::to_string((int)std::lround(m->cpuProbeHopMs)) + " ms)";
        return m;
    }
}

void voicemodel_free(VoiceModel *model) { delete model; }

const char *voicemodel_describe(const VoiceModel *model) { return model ? model->describe.c_str() : ""; }

int voicemodel_max_lookahead_ms(const VoiceModel *model) { return model ? model->maxAheadMs : 0; }

double voicestream_delay_ms(const VoiceModel *model, double chainRate, int maxFrames, int lookaheadMs) {
    if (chainRate < 8000 || maxFrames <= 0) return 0;
    const int hop = model ? model->hopMs : 160, xf = model ? model->xfadeMs : 40, sola = model ? model->solaMs : 10;
    const int reserve = 70;  // (a CPU-only model gets 70 too)
    const int la = model ? std::clamp(lookaheadMs / 10 * 10, 0, model->maxAheadMs) : std::max(0, lookaheadMs / 10 * 10);
    const double voiceRate = model ? model->rate : 48000;  // (a 32 or 40 kHz voice's resampler holds back a bit more)
    const int frames = latencyFrames(chainRate, maxFrames, false, hop, xf, sola, reserve, la,
                                     Resampler::lag(kRate16 / chainRate), Resampler::lag(chainRate / voiceRate));
    return frames / chainRate * 1000;
}

VoiceStream *voicestream_new(VoiceModel *model, double chainRate, int maxFrames, int offline, const VoiceStreamConfig *config) {
    if (chainRate < 8000 || chainRate > 384000 || maxFrames <= 0) return nullptr;
    VoiceStreamConfig c = config ? *config : VoiceStreamConfig{160, 480, 40, 10, 70, 0};
    if (model) { c.hopMs = model->hopMs; c.crossfadeMs = model->xfadeMs; c.solaMs = model->solaMs; }
    if (c.hopMs < 10 || c.hopMs % 10 || c.crossfadeMs % 10 || c.solaMs % 10 || c.crossfadeMs < 0 || c.solaMs < 0) return nullptr;
    auto *s = new VoiceStream();
    s->rate = chainRate;
    s->maxFrames = maxFrames;
    s->offline = offline != 0;
    s->H = c.hopMs / 10; s->X = c.crossfadeMs / 10; s->S = c.solaMs / 10;
    s->reserveMs = std::max(0, c.reserveMs);
    if (model && model->cpuOnly) s->reserveMs = std::max(s->reserveMs, 70);  // the CPU's slow hops need more room
    s->rampLen = std::max(1, (int)std::lrint(chainRate * 0.01));
    s->inLag16 = Resampler::lag(kRate16 / chainRate);
    s->outRate = model ? model->rate : 48000;  // no model yet: the built-in voices' rate
    s->outLag = Resampler::lag(chainRate / s->outRate);
    // fixed delay = hop + crossfade + search + reserve + look-ahead + what the resamplers hold back + one callback;
    // the sound thread reads converted index (now - baseBack), whatever the look-ahead
    // (3.2: with part of the look-ahead kept in hand as extra reserve, the read point is that much further back)
    s->laWant.store(std::clamp(c.lookaheadMs, 0, 1000) / 10);
    if (model) s->pending.store(model);
    s->resplit();
    s->pending.store(nullptr);
    const int64_t ringSize = (int64_t)(chainRate * 4) + maxFrames;
    s->in.init(ringSize);
    s->out.init(ringSize);
    s->tailRing.init(ringSize);
    s->natural.init(s->latencyFor(100) + 4 * (int64_t)maxFrames + 64);  // room for any look-ahead (up to 1 s)
    if (s->offline) {
        if (const char *path = getenv("PITCHSHIFT_AI_TRACE")) s->trace = std::fopen(path, "w");
    }
    s->in16.init((int64_t)kRate16 * 8);
    s->gate = soundgate_new(chainRate);
    s->gateW.assign(256, 0.0f);
    if (s->gate) { s->gateFit = s->playLatency; soundgate_fit(s->gate, s->playLatency - maxFrames); }
    s->pitchPos.assign(kPitchSlots, 0);
    s->pitchHz.assign(kPitchSlots, 0.0f);
    s->scratch.assign(8192, 0.0f);
    if (!s->toModel.init(kRate16 / chainRate, 8192)) { delete s; return nullptr; }
    s->wake = dispatch_semaphore_create(0);
    if (model) s->pending.store(model);
    if (s->offline) {
        if (model) { s->pending.store(nullptr); s->adopt(model); }
        return s;
    }
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
    pthread_attr_setstacksize(&attr, 4 << 20);
    s->threadStarted = pthread_create(&s->thread, &attr, VoiceStream::threadMain, s) == 0;
    pthread_attr_destroy(&attr);
    if (!s->threadStarted) { delete s; return nullptr; }
    dispatch_semaphore_signal(s->wake);
    return s;
}

int voicestream_set_model(VoiceStream *stream, VoiceModel *model) {
    if (!stream || !model) return 0;
    if (model->hopMs != stream->H * 10 || model->xfadeMs != stream->X * 10 || model->solaMs != stream->S * 10) return 0;
    if (model->cpuOnly && stream->reserveMs < 70) return 0;  // its delay would be too short for the CPU: make a new stream
    if (model->rate != stream->outRate) return 0;  // a 32 or 40 kHz voice: its resampler's delay differs, make a new stream
    if (stream->offline) { stream->adopt(model); return 1; }
    stream->pending.store(model);
    dispatch_semaphore_signal(stream->wake);
    return 1;
}

void voicestream_delete(VoiceStream *stream) {
    if (!stream) return;
    if (stream->threadStarted) {
        stream->quit.store(true);
        dispatch_semaphore_signal(stream->wake);
        pthread_join(stream->thread, nullptr);
    }
    if (stream->trace) std::fclose(stream->trace);
    soundgate_delete(stream->gate);
    delete stream->run;
    delete stream;
}

int voicestream_latency_frames(const VoiceStream *stream) {
    if (!stream) return 0;
    int la = 0, ex = 0;
    stream->splitWanted(la, ex);
    return stream->latencyFor(la, ex);
}

void voicestream_set_lookahead(VoiceStream *stream, int lookaheadMs) {
    if (!stream) return;
    stream->laWant.store(std::clamp(lookaheadMs, 0, 1000) / 10);
    if (!stream->offline) dispatch_semaphore_signal(stream->wake);
}

void voicestream_set_intonation(VoiceStream *stream, float intonation) {
    if (stream && std::isfinite(intonation)) stream->intonation.store(std::max(0.0f, intonation), std::memory_order_relaxed);
}

void voicestream_push(VoiceStream *stream, const float *mic, int frames, const float *f0Hz, const int64_t *f0Pos, int n) {
    if (stream && frames > 0) stream->push(mic, frames, f0Hz, f0Pos, n);
}

void voicestream_pull(VoiceStream *stream, const float *naturalNow, int naturalDelay, float *out, int frames) {
    if (!out || frames <= 0) return;
    if (!stream) {
        if (naturalNow && naturalNow != out) std::memcpy(out, naturalNow, sizeof(float) * (size_t)frames);
        return;
    }
    stream->pull(naturalNow, naturalDelay, out, frames);
}

int voicestream_tune(VoiceStream *stream, const char *key, float value) {
    if (!stream || !key) return 0;
    std::string k(key);
    // 3.4: other sounds heard as they are (SoundGate)
    if (k == "aiSounds") { stream->gateOn.store(value != 0); return 1; }
    if (k.rfind("sg", 0) == 0) return soundgate_tune(stream->gate, key, value);
    if (k == "aiSlowMs") { stream->slowMs.store((int)value); return 1; }
    if (k == "aiSlowEvery") { stream->slowEvery.store(std::max(1, (int)value)); return 1; }
    if (k == "aiSlowChip") { stream->slowChip.store(value != 0); return 1; }
    if (k == "aiGainMaxDb") { stream->gainMaxDb.store(value); return 1; }
    if (k == "aiSmoothFrames") { stream->smoothFrames.store(std::clamp((int)value, 0, 10)); return 1; }
    if (k == "aiGapFrames") { stream->gapFrames.store(std::clamp((int)value, 0, 10)); return 1; }
    if (k == "aiSlowFrames") { stream->slowFrames.store(std::clamp((int)value, 0, 20)); return 1; }
    if (k == "aiOnsetFrames") { stream->onsetFrames.store(std::clamp((int)value, 0, 10)); return 1; }
    if (k == "aiIntonation") { stream->intonation.store(value); return 1; }
    if (k == "aiSolaMode") { stream->solaMode.store(std::clamp((int)value, -1, 3)); return 1; }
    if (k == "aiGainMs") { stream->gainMs.store(std::clamp((int)value, 10, 200)); return 1; }
    if (k == "aiQuietDb") { stream->quietDb.store(value); return 1; }
    if (k == "aiLookaheadMs") { voicestream_set_lookahead(stream, (int)value); return 1; }
    // 3.2
    if (k == "ai32") {  // 0: every 3.2 change off (3.1.1's sound exactly); 1: the 3.2 defaults
        const bool on = value != 0;
        stream->split.store(on); stream->aheadMax.store(400); stream->autoChip.store(on); stream->startChip.store(0);
        stream->graceMs.store(on ? 20 : 0); stream->realtime.store(0); stream->leftMs.store(on ? 50 : -1);
        stream->onsetFrames.store(3);
        stream->fadeAdapt.store(on); stream->joinGains.store(on); stream->gainTwoSided.store(on);
        stream->solaMode.store(-1); stream->nearMs.store(1.5f); stream->bridgeStrict.store(on);
        stream->gapFrames.store(on ? 5 : 8); stream->shortRunMs.store(on ? 40 : 0); stream->hissCross.store(on ? 0.3f : 0);
        stream->gainCap.store(on); stream->gainMs.store(on ? 120 : 50); stream->limitAt.store(on ? 0.6f : 0);
        stream->gateOn.store(on);  // (3.4's pass-through of other sounds too, so that 0 is 3.1.1's sound exactly)
        stream->resplit();
        return 1;
    }
    if (k == "aiSplit") { stream->split.store(value != 0); stream->resplit(); return 1; }
    if (k == "aiAheadMax") { stream->aheadMax.store(std::clamp((int)value, 150, 700)); stream->resplit(); return 1; }
    if (k == "aiAutoChip") { stream->autoChip.store(value != 0); return 1; }
    if (k == "aiStartChip") { stream->startChip.store(value != 0); return 1; }
    if (k == "aiGraceMs") { stream->graceMs.store(std::clamp((int)value, 0, 30)); return 1; }
    if (k == "aiRealtime") { stream->realtime.store(value != 0); return 1; }
    if (k == "aiLeftMs") { stream->leftMs.store((int)value < 0 ? -1 : (int)value / 10 * 10); return 1; }
    if (k == "aiFadeAdapt") { stream->fadeAdapt.store(value != 0); return 1; }
    if (k == "aiJoinGains") { stream->joinGains.store(value != 0); return 1; }
    if (k == "aiGainTwoSided") { stream->gainTwoSided.store(value != 0); return 1; }
    if (k == "aiNearMs") { stream->nearMs.store(std::clamp(value, 0.0f, 5.0f)); return 1; }
    if (k == "aiBridgeStrict") { stream->bridgeStrict.store(value != 0); return 1; }
    if (k == "aiShortRunMs") { stream->shortRunMs.store(std::clamp((int)value, 0, 100)); return 1; }
    if (k == "aiHissCross") { stream->hissCross.store(std::clamp(value, 0.0f, 1.0f)); return 1; }
    if (k == "aiGainCap") { stream->gainCap.store(value != 0); return 1; }
    if (k == "aiPauseDb") { stream->pauseDb.store(std::clamp(value, -60.0f, 0.0f)); return 1; }
    if (k == "aiLimit") { stream->limitAt.store(std::clamp(value, 0.0f, 1.0f)); return 1; }
    // 3.4
    if (k == "hum34") { stream->humLiftDb.store(value != 0 ? 24 : 0); return 1; }  // 0: as 3.3 (with VoiceChanger's)
    if (k == "aiHumLiftDb") { stream->humLiftDb.store(std::clamp(value, 0.0f, 40.0f)); return 1; }
    if (k == "aiHumLevelDb") { stream->humLevelDb.store(std::clamp(value, -60.0f, 0.0f)); return 1; }
    return 0;
}

void voicestream_get_passed(const VoiceStream *stream, int64_t *sounds, int64_t *whistles, double *seconds) {
    SoundGateStats st{};
    if (stream && stream->gate) soundgate_get_stats(stream->gate, &st);
    if (sounds) *sounds = st.taps;
    if (whistles) *whistles = st.whistles;
    if (seconds) *seconds = st.passedSeconds;
}

void voicestream_get_stats(const VoiceStream *stream, VoiceStreamStats *out) {
    if (!out) return;
    std::memset(out, 0, sizeof(*out));
    if (!stream) return;
    out->loaded = stream->loaded.load() && stream->playing ? 1 : 0;
    out->hops = stream->hops.load();
    out->misses = stream->misses.load();
    out->fallbackSeconds = stream->fallbackFrames.load() / stream->rate;
    out->averageHopMs = out->hops ? stream->sumHopMs.load() / (double)out->hops : 0;
    out->worstHopMs = stream->worstHopMs.load();
    out->cpuShare = stream->cpuShare.load();
    out->lookaheadMs = stream->laShown.load(std::memory_order_relaxed) * 10;
    out->switches = stream->switches.load();
    out->aiNow = stream->aiNow.load(std::memory_order_relaxed);
    out->reserveMs = stream->reserveMs + stream->exShown.load(std::memory_order_relaxed) * 10;
    out->onCPU = stream->onCPUShown.load(std::memory_order_relaxed);
    out->chipSwitches = stream->chipSwitches.load();
    out->lateHops = stream->lateHops.load();
    out->tightHops = stream->tightHops.load();
    out->graceSaves = stream->graceSaves.load();
    out->loudSamples = stream->loudSamples.load(std::memory_order_relaxed);
    out->samplesOut = stream->samplesOut.load(std::memory_order_relaxed);
}

}  // extern "C"

#else  // Intel Macs: the AI voices need Apple silicon.

extern "C" {

VoiceModel *voicemodel_load(const char *, const char *, int, char *err, int errSize) {
    say(err, errSize, "needs Apple silicon");
    return nullptr;
}

void voicemodel_free(VoiceModel *) {}
const char *voicemodel_describe(const VoiceModel *) { return ""; }
VoiceStream *voicestream_new(VoiceModel *, double, int, int, const VoiceStreamConfig *) { return nullptr; }
int voicestream_set_model(VoiceStream *, VoiceModel *) { return 0; }
void voicestream_delete(VoiceStream *) {}
int voicestream_latency_frames(const VoiceStream *) { return 0; }
int voicemodel_max_lookahead_ms(const VoiceModel *) { return 0; }
double voicestream_delay_ms(const VoiceModel *, double, int, int) { return 0; }
void voicestream_set_lookahead(VoiceStream *, int) {}
void voicestream_set_intonation(VoiceStream *, float) {}
void voicestream_push(VoiceStream *, const float *, int, const float *, const int64_t *, int) {}

void voicestream_pull(VoiceStream *, const float *naturalNow, int, float *out, int frames) {
    if (out && naturalNow && out != naturalNow && frames > 0) std::memcpy(out, naturalNow, sizeof(float) * (size_t)frames);
}

int voicestream_tune(VoiceStream *, const char *, float) { return 0; }

void voicestream_get_stats(const VoiceStream *, VoiceStreamStats *out) {
    if (out) std::memset(out, 0, sizeof(*out));
}

void voicestream_get_passed(const VoiceStream *, int64_t *sounds, int64_t *whistles, double *seconds) {
    if (sounds) *sounds = 0;
    if (whistles) *whistles = 0;
    if (seconds) *seconds = 0;
}

}  // extern "C"

#endif
