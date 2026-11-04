// "Super Advanced" for What you hear: pitch shifting made for heavy songs. Distorted guitars are trains of sharp pulses,
// and a shifter that works on frequencies scrambles them, which makes loud songs watery and pushes their peaks over full
// scale. This one plays the sound like tape, r times faster or slower, so every waveform keeps its exact shape. To stay
// in time it jumps back or forward, by the amount that lands the next hit on time, just before that hit, at the moment
// the sound on both sides matches best. Below 600 Hz the sound goes through Rubber Band instead, because jumps there are
// heard as a wobble. A smooth safety limiter at the end keeps the output at or below -0.3 dBFS.
//
// Mac only (it uses Accelerate). Plain C API, so Swift can call it through the bridging header.
// Create, use and delete from one thread at a time. heavy_process and heavy_set_semis make no memory, take no locks and
// do no file or console I/O.
#ifndef HEAVY_CHAIN_H
#define HEAVY_CHAIN_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct HeavyChain HeavyChain;

// channels are always 2. maxFrames: the largest `frames` you will pass to heavy_process. Returns NULL if it can't be made.
HeavyChain *heavy_new(double sampleRate, int maxFrames);
void heavy_delete(HeavyChain *chain);

// The amount in half-steps (-24..+24). Call any time on the processing thread; the tape simply changes speed. At 0 the
// output is the delayed input, untouched, apart from the limiter.
void heavy_set_semis(HeavyChain *chain, double semis);

// in and out: 2 pointers to `frames` samples. out gets exactly `frames` samples, delayed by heavy_latency_frames().
// frames: 1..maxFrames. out may not be the same memory as in.
void heavy_process(HeavyChain *chain, const float *const *in, float *const *out, int frames);

// The delay in frames. It never changes during the chain's life, whatever the amount.
int heavy_latency_frames(const HeavyChain *chain);

// A quicker safety limiter on its own, for normal mode. A shift can push a very loud song well over full scale, because
// it undoes the flat tops the song's mastering left. Under -0.3 dBFS it only delays the sound, by a fixed 2 ms.
typedef struct HeavyLimiter HeavyLimiter;
HeavyLimiter *heavy_limiter_new(double sampleRate);
void heavy_limiter_delete(HeavyLimiter *limiter);
void heavy_limiter_process(HeavyLimiter *limiter, float *left, float *right, int frames);  // in place, makes no memory
void heavy_limiter_reset(HeavyLimiter *limiter);
int heavy_limiter_latency_frames(const HeavyLimiter *limiter);

#ifdef __cplusplus
}
#endif

#endif
