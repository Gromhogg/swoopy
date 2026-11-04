// Test-only settings for Super Advanced (used by the test programs, not by the app).
// Call right after heavy_new, before the first heavy_process or heavy_set_semis.
#ifndef HEAVY_TUNING_H
#define HEAVY_TUNING_H
#include "HeavyChain.h"
#ifdef __cplusplus
extern "C" {
#endif

// Keys and defaults: the Settings at the top of HeavyChain.cpp, by their lower-case names ("fadems", "jumpminms",
// "jumpmaxms", "matchms", "tolerancems", "holdms", "guardms", "matchlowhz", "matchhighhz", "sensitivity", "latems",
// "heldminms", "heldfadems", "downjumpmaxms", "downheldminms", "downheldfadems", "cuthz", "limlookms",
// "limreleasems", and "split": 0 keeps everything on the tape).
// Returns 0 if the key is unknown.
int heavy_tune(HeavyChain *chain, const char *key, double value);

// What the chain has done so far. jumpsAt: if not NULL, the output frames of the first `capacity` jumps.
typedef struct {
    long long jumps;     // all jumps
    long long forced;    // jumps the safety limit forced, with no match
    double meanLikeness; // how alike the sound was at the jumps, 0-1
} HeavyInfo;
void heavy_get_info(const HeavyChain *chain, HeavyInfo *info, long long *jumpsAt, int capacity);

#ifdef __cplusplus
}
#endif
#endif
