// Voice changer, "Natural" mode: turns a voice into the chosen voice (Woman, Man, ...) without AI.
// It works next to the voice's Rubber Band shifter (VoiceShifter.swift):
//   mic -> voicechanger_analyse (pitch tracker, pitch mapping, creak) -> sets Rubber Band's pitch + formant scale
//       -> Rubber Band -> waiting sound (VoiceRing) -> voicechanger_post (sibilance, tone EQ, presence, breath) -> out.
// Analysis runs next to the sound and post uses only filters that work sample by sample, so it adds no delay.
//
// Plain C API (C++17 inside, no Apple APIs), so Swift can call it through the bridging header.
// Threading: create, set up (tune) and delete from one thread; analyse, post, set, reset and get_stats from the sound
// thread. Real-time safe: analyse, post, set, reset and get_stats make no memory, take no locks and do no file or
// console I/O. Everything is made in voicechanger_new.
#ifndef VOICE_CHANGER_H
#define VOICE_CHANGER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VOICECHANGER_LTAS_BANDS 21   // third-octave bands, centres 125 * 2^(k/3) Hz (125 Hz ... 12.7 kHz)
#define VOICECHANGER_MAX_PITCH_FRAMES 64

// One voice's settings (the "natural" block of a voice.json). Woman/Man start values are in voices/*.json.
typedef struct VoiceChangerVoice {
    float targetHz;        // the voice's median pitch (Woman 200, Man 112)
    float assumedInputHz;  // the usual pitch of someone who picks this voice (Woman 120, Man 205); seeds the median
    float intonation;      // how far the pitch moves around its median: 1 = as spoken, 1.2 = livelier, 0.85 = flatter
    float formant;         // voice shape (formant) scale at full strength (Woman 1.21, Man 0.85)
    float breathDb;        // breath noise next to the voice, dB (-30 = a little; -90 or lower = off)
    float presenceDb;      // the "smile" lift at 3 kHz, dB
    float sibilanceKeep;   // 0..1: how much of the original "s" sounds (above 4.5 kHz) is kept between voiced sounds
    float eqAmount;        // 0..1: how far the tone EQ moves the sound toward `ltas`
    float ltas[VOICECHANGER_LTAS_BANDS];  // the voice's long-term spectrum of voiced speech, dB per band
} VoiceChangerVoice;

// What analyse decided, for the Rubber Band shifter and (later) Realistic mode.
typedef struct VoiceChangerPitch {
    float pitchScale;      // Rubber Band pitch scale to use now (includes extraSemitones)
    float formantScale;    // Rubber Band formant scale to use now (already divided by the pitch scale)
    int voiced;            // 1 if the newest 10 ms frame was voiced
    float f0In;            // newest tracked pitch, Hz (0 = not voiced)
    float f0Target;        // the pitch the AI voice follows, Hz (0 = not voiced; creak holds or follows smoothly)
    int newFrames;         // 10 ms frames finished during this call (0 ... VOICECHANGER_MAX_PITCH_FRAMES)
    float frameHz[VOICECHANGER_MAX_PITCH_FRAMES];     // each new frame's pitch for the AI voice, Hz (0 = not voiced)
    int64_t framePos[VOICECHANGER_MAX_PITCH_FRAMES];  // each new frame's centre, in input samples since the last reset
} VoiceChangerPitch;

// For --changer-stats and the window.
typedef struct VoiceChangerStats {
    float strength;        // strength in use now (glides toward the one set)
    float medianHz;        // the speaker's median pitch as measured (seeded by assumedInputHz)
    float semitones;       // pitch change in use now, half-steps (with extraSemitones)
    float formant;         // voice shape scale in use now (before dividing by the pitch)
    float voicedShare;     // voiced 10 ms frames / all frames since the last reset
    float creakShare;      // creak frames / voiced frames since the last reset
    float eqDb[8];         // tone EQ gains in use, 125 Hz ... 16 kHz (octaves)
    int64_t frames;        // 10 ms frames analysed since the last reset
    double analyseMs;      // time spent in analyse + post per 10 ms of sound: average ...
    double worstMs;        // ... and the worst single call (scaled to 10 ms of sound)
    int64_t learnedFrames; // 10 ms frames the speaker's median has learned from (since voicechanger_new)
} VoiceChangerStats;

typedef struct VoiceChanger VoiceChanger;

// sampleRate: the chain's rate (16000 ... 192000). maxFrames: the largest `frames` passed to analyse/post.
// Returns NULL if it can't be made.
VoiceChanger *voicechanger_new(double sampleRate, int maxFrames);
void voicechanger_delete(VoiceChanger *changer);

// The voice to change into (copied), or NULL to fade the changer out; strength 0 ... 1. The strength glides to the
// new value (0.15 s for the whole range). Cheap: may be called on every callback.
void voicechanger_set(VoiceChanger *changer, const VoiceChangerVoice *voice, float strength);

// Starts over (new chain or the shifter started fresh): forgets the sound, keeps the voice and the measured median.
void voicechanger_reset(VoiceChanger *changer);

// The speaker's median pitch measured earlier (by a changer that ran before, see VoiceChangerStats medianHz and
// learnedFrames), as the first guess instead of the voice's assumedInputHz; weightFrames: how many 10 ms frames it
// counts for. Call it after voicechanger_new, before the first analyse (same thread as create). 0 = forget it.
void voicechanger_set_speaker(VoiceChanger *changer, float medianHz, float weightFrames);

// Takes the next `frames` mic samples (before Rubber Band) and says which pitch and formant scale to use.
// extraSemitones: pitch-only shift added on top ("Deeper when slow"), half-steps.
void voicechanger_analyse(VoiceChanger *changer, const float *in, int frames, float extraSemitones, VoiceChangerPitch *out);

// Works on the shifted sound on its way out, in place. delayFrames: how far this sound lags behind the mic samples
// last given to analyse (Rubber Band + waiting sound), so the original can be lined up with it.
void voicechanger_post(VoiceChanger *changer, float *io, int frames, int delayFrames);

// Changes a setting by name (for tuning: --changer-tune "key=value,..."); it stays changed across voicechanger_set.
// Keys: the VoiceChangerVoice fields (targetHz, assumedInputHz, intonation, formant, breathDb, presenceDb,
// sibilanceKeep, eqAmount) and inner ones listed in VoiceChanger.cpp. Returns 1 if the key is known, else 0.
int voicechanger_tune(VoiceChanger *changer, const char *key, float value);

void voicechanger_get_stats(const VoiceChanger *changer, VoiceChangerStats *out);

#ifdef __cplusplus
}
#endif

#endif
