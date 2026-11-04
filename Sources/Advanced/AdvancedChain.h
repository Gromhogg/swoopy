// Advanced processing engine for "What you hear": pitch shifting that keeps the music balanced at big shifts.
// Recipe ("balanced3", from the research rounds 2-4, with the bass fix and the tone fix made after 2.0.0): the bass is
// moved down an octave ("fold") for pitch-up, the original's top end ("air") is kept for pitch-down, and a gentle
// adaptive EQ steers the long-term tone back toward the original (going up, it no longer cuts bass notes that the fold
// moved; it knows which way the pitch went: going down it trims the deep bass, going up it keeps more of the top).
// Rubber Band (R3, real-time) does the shifting. A safety peak limiter at the very end keeps the output at or below
// -0.3 dBFS (it does nothing while the sound stays under that).
//
// Plain C API, so Swift can call it through the bridging header.
// Threading: create, use and delete from one thread at a time (the engine also runs one helper thread of its own
// that tidies up spare Rubber Band shifters; it never touches the sound).
// Real-time safe: advanced_process, advanced_set_semis, advanced_set_tone, advanced_set_auto_eq,
// advanced_get_auto_eq and advanced_reset make no memory, take no locks and do no file or console I/O. Everything is
// set up in advanced_new. advanced_get_auto_eq may also be called from another thread.
#ifndef ADVANCED_CHAIN_H
#define ADVANCED_CHAIN_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AdvancedChain AdvancedChain;

// Flags for advanced_new.
enum {
    ADVANCED_RANGE_12 = 1,  // only -12..+12 half-steps (larger amounts are clamped); lowers the delay to about 138 ms
};

// sampleRate: 44100, 48000, 96000 (others work too). channels: 1 or 2. maxFrames: the largest `frames` you will
// pass to advanced_process (e.g. 4096). Returns NULL if it can't be made.
AdvancedChain *advanced_new(double sampleRate, int channels, int maxFrames, int flags);
void advanced_delete(AdvancedChain *chain);

// The amount in half-steps (-24..+24, 0.01 steps). Call any time on the processing thread. The new amount is heard
// about 0.2-0.3 s later, faded in over 80 ms; quick repeated changes always end at the latest amount.
// At 0 the output is the delayed input, untouched.
void advanced_set_semis(AdvancedChain *chain, double semis);

// Bass and treble in dB (-12..+12 each, default 0): a low shelf at 150 Hz and a high shelf at 5 kHz on the finished
// sound, at every amount (0 too). Call any time on the processing thread. The gains glide 0.25 dB per 32 samples
// (about 16 ms for 6 dB), so moving them doesn't click; set before the first advanced_process, the glide is over
// before any sound comes out. At 0 and 0 the sound is exactly as without it.
void advanced_set_tone(AdvancedChain *chain, double bassDb, double trebleDb);

// Auto EQ: five sections, Sub (20-80 Hz), Bass (80-250), Mids (250-2k), Highs (2k-8k) and Air (8k and up), whose
// levels are adjusted as the song plays so each stays near the original song's balance, whatever the amount (it looks
// at loudness only; the overall loudness stays). Automatic gains are within +-8 dB; they follow a section that is too
// loud within about 0.3 s and one that is too quiet within about 1.5 s. On the finished sound, before the bass and
// treble. No added delay.
// on: 1 = automatic, 0 = not. offsetsDb: 5 manual offsets (-12..+12 dB, Sub first), added to the automatic gains
// (the sum is held within +-15 dB); NULL = all 0. They glide 0.25 dB per 32 samples. Call any time on the processing
// thread. Switching on or off fades over 50 ms. Off with all offsets 0 (the default): the sound is exactly as without
// it, once that fade is done.
void advanced_set_auto_eq(AdvancedChain *chain, int on, const double offsetsDb[5]);

// Auto EQ's live values, Sub first, updated every 256 samples (512 above 64 kHz): autoDb = the automatic gain now
// (dB, without the offsets); levelDb = each section's level coming out (dBFS over the last second, a full-scale sine
// = 0, after its gain; -120 while Auto EQ is off). Either may be NULL. Safe to call from any thread at any time, also
// while advanced_process runs: it never makes the processing wait.
void advanced_get_auto_eq(const AdvancedChain *chain, double autoDb[5], double levelDb[5]);

// Forget all sound (for example after a pause). Keeps the amount, the bass and treble and the Auto EQ settings.
void advanced_reset(AdvancedChain *chain);

// in: `channels` pointers to `frames` samples. keep: NULL, or `channels` pointers to a part of `in` that must stay
// unshifted (it is taken out, the rest is processed, and it is added back with the same delay).
// When keep starts (after being NULL or all zeros for 0.25 s) it is faded in over 30 ms, so switching it on mid-song
// doesn't click. Switching it off is up to the caller: going straight to NULL mid-sound is a hard step, so fade the
// keep signal to zero first (or keep passing it).
// out: `channels` pointers, gets exactly `frames` samples: the processed sound delayed by advanced_latency_frames().
// frames: 1..maxFrames. out may be the same memory as in.
void advanced_process(AdvancedChain *chain, const float *const *in, const float *const *keep, float *const *out, int frames);

// The delay in frames. It never changes during the engine's life, whatever the amount.
int advanced_latency_frames(const AdvancedChain *chain);

// For checks and the app's status line.
typedef struct {
    double heardSemis;     // the amount being heard now (the newest one once its fade is done)
    int changing;          // 1 while a new amount is getting ready or fading in
    long long underruns;   // times a shifter's sound was not ready in time (should stay 0)
    long long switches;    // amount changes that have been faded in
    int shiftersRunning;   // Rubber Band shifters in use right now (0-6)
} AdvancedInfo;
void advanced_get_info(const AdvancedChain *chain, AdvancedInfo *info);

// Bass and treble and Auto EQ on their own, for the app's normal mode (pitch shifting without Advanced processing): the
// same stages as advanced_set_tone and advanced_set_auto_eq (same ranges, glides and fades), then a smooth safety
// limiter (it looks 10 ms ahead and lets go over 300 ms, so it doesn't distort bass), which only works while bass,
// treble or Auto EQ is in use. With both untouched (0 dB, Auto EQ off with all offsets 0: the default) the output is
// exactly the input, delayed by tonechain_latency_frames (the limiter's 10 ms look-ahead); there is no other delay.
// Same threading and real-time rules as the engine: tonechain_set_tone, tonechain_set_auto_eq and tonechain_process
// make no memory; tonechain_get_auto_eq may be called from any thread.
typedef struct ToneChain ToneChain;
ToneChain *tonechain_new(double sampleRate, int channels);  // channels: 1 or 2; NULL if it can't be made
void tonechain_delete(ToneChain *chain);
void tonechain_set_tone(ToneChain *chain, double bassDb, double trebleDb);
void tonechain_set_auto_eq(ToneChain *chain, int on, const double offsetsDb[5]);
void tonechain_get_auto_eq(const ToneChain *chain, double autoDb[5], double levelDb[5]);
// io: `channels` pointers to `frames` samples, changed in place (and delayed by tonechain_latency_frames). ref: the
// original sound at the same moment as io (mono, `frames` samples), which Auto EQ keeps the balance of; NULL = io's own.
void tonechain_process(ToneChain *chain, float *const *io, const float *ref, int frames);
int tonechain_latency_frames(const ToneChain *chain);

#ifdef __cplusplus
}
#endif

#endif
