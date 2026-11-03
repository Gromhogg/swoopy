# Swoopy 3.2: an AI voice without stutters or buzz (toward "absolute realism"), plus "Higher when fast"

## Context

Swoopy 3.1.1 (installed, main = f7757c3) has an AI voice changer ("Faster ↔ More real" slider). The owner says it
**still stutters even at the most-real end (about 1 s of delay) and sounds buzzy even at the highest levels**. The goal
is absolute realism, free, on this Mac (M3 Pro, 18 GB). Discord, a game and a browser usually run at the same time.
The card does **not** say "backup voice" when it stutters, so the joins between pieces and the pitch feed are part of
it; the game's GPU load means late pieces happen too. Total delay at the most-real end must stay about 1 s.

Owner's decisions (2026-10-18): keep ~1 s at max; include all four big bets as research gates (full-precision model
files, a neural pitch tracker, mic noise cleanup, training real voices on Kaggle); also make "Deeper when slow" go
higher when talking fast, with a slider.

## What the code does today (verified; file:line are current)

AI stream `Sources/Voice/VoiceModel.mm`:
- A piece = 160 ms of new sound; crossfade 40 ms; search 10 ms; decoder margins 60 ms left / 40 ms right (dropped);
  1.92 s window. **The time kept in hand for a slow piece ("reserve") is a fixed 70 ms at every slider position**
  (`voicestream_delay_ms` 1104, `voicestream_new` 1114-1123, `makeHop` 627-636, read offset `baseBack` 1130). Look-ahead
  (0-700 ms) adds delay but no safety margin. Pieces take 49 ms average / 55-58 ms worst idle, **80-110 ms when the Mac
  is busy**; GPU 80 % busy: 228 late pieces in 75 s; on the CPU: 0 late (49 ms per piece, 31 % of a core).
- Encoder on CPU+Neural Engine, generator on CPU+GPU (`voicemodel_load` 974); CPU only if loading fails (983-987).
  **No switch to the CPU while running.** Worker thread = user-interactive QoS (1154).
- A late piece swaps in the Natural voice (a different-sounding voice) with 10 ms fades (`pull` 918-961).
- Joins (679-708, fades `adopt` 827-831): above 50 ms look-ahead **no search at all** (`solaMode` −1 = keep timing);
  equal-gain sin²/1−sin² crossfade (dips on unlike sound), on raw pieces; the new piece's loudness gains are applied to
  the old tail too (705, 733-745); loudness windows one-sided at a piece's start (726). Residual joins at 700 ms: 7 bad /
  41 poor of 899 (≈ one poor join every 2.7 s); regression31 slider 1: 16 / 89 of 1754; sudden changes / pitch jumps /
  voice breaks 20 / 13 / 8.
- Loudness match (709-745): gain = mic ÷ AI loudness per 10 ms over 50 ms windows, up to **+18 dB**; then `softLimit`
  (`VoiceShifter.swift:252`, tanh above 0.7) bends the AI output too.
- Pitch: the app's YIN tracker (`Sources/Voice/VoiceChanger.cpp` 631-734) → target pitch per 10 ms frame (`mapFrame`
  836-845, `aiPitch` 524-544; ±15 st clamp on the band centre 830-831 and `aiTotal` 749-752). Stream `windowPitch`
  549-623: unvoiced gaps ≤ 80 ms inside loud sound **bridged with a sung pitch**, 3 lead-in frames take the vowel's pitch,
  fast moves 0.66×. The app builds the sine excitation (646-662; phase continued across pieces, fixed noise tables).
  Measured: **tone over consonants 2.85 → 5.19 s per 100 s**; **30-70 % of noise-only moments come out as a hum**
  (every AI version); no noise cleanup before the model.
- Models: RVC v2 base `f0G48k.pth` (MIT), **not fine-tuned**, speaker = rescaled average of 8 VCTK speakers
  (`research/voicechanger/pretrained/make_blend.py`; Woman US = p294 p299 p300 p318 p333 p339 p341 p330). Converted
  fp16 compute + **8-bit weights** (`research/voicechanger/convert/convert_contentvec.py:23-40`; `--quant none` exists);
  ContentVec_ahead was quantised twice. Core ML vs PyTorch 29-36 dB SNR. Files = release assets (`voices/models.txt`).
- Toolchain: the conversion venv lived in a deleted scratchpad → recreate `research/voicechanger/venv` (Python 3.10 at
  /Library/Frameworks/Python.framework/Versions/3.10/bin/python3; pins in `tools/voice-converter/requirements`: torch
  2.7.0, coremltools 9.0, numpy 2.2.6); base model + ContentVec downloads deleted → `a1/harness/get_models.sh`,
  recipe in `research/voicechanger/results/pretrained.md`. 73 GB disk free.

Non-AI chain `Sources/VoiceShifter.swift` `VoiceChain.render` 1037-1110: mic → tracker (1084) → AI push (1090) →
pulse shifter → VoiceRing → `voicechanger_post` (Natural only) → `voicestream_pull` (1102) → Soundboard mix +
`softLimit`. Slider → look-ahead: `ChangerSettings` 94-112 (0.05..1 → 0..700 ms).

"Deeper when slow" (plain shift, Pro): `SpeakingRate` `VoiceShifter.swift:702-711`: `extra = −8 st × clamp((3 − rate)
/ (3 − 1.5))`: only ever lower; nothing above 3 syllables/s. Switch: `Window.swift` 1603/1820/2408, key
`voiceSlowDeeper` (1455); off while the voice changer is on (1530-1559).

Measuring tools to reuse (never rewrite): `research/voicechanger/smooth/` seams.py, disc.py, held.py, meas70.py
(Whisper words, Distill-MOS); `smooth/bench/stream_test.mm` (real-time bench; `--lookahead`, `--switch`, forced late
pieces via `--changer-tune aiSlowMs`) + `bench/gpuload.swift`; `regression31/` mknoisy.py, measure31.py, noisem.py;
`r311/` check1.sh (14 changer-off renders), testsim.sh (Test button), held-note tools; `buzz2/tools/bz.py` ("buzz
number"); app flags `--render-voice`, `--test-voice --watch`, `--changer-tune`, `--changer-stats`, `--compute`,
`--voices-dir`, `PITCHSHIFT_AI_TRACE`.

## Rules for every agent
- Opus 5.5 only, one agent per task, ≤ 4 at a time; branch from main f7757c3, PR to main; plain-word commits.
- Every change behind a `voicestream_tune` / `voicechanger_tune` key whose "old" value gives 3.1.1's output byte for byte.
- Changer-off renders byte-identical 14/14 (`r311/check1.sh`); Natural renders 15/15 identical to 3.1.1.
- While the owner's app is open: render with `--compute cpu`; no GPU-load tests and no live mic tests (they need `--list`
  to show Swoopy Mic and every mic not in use). Never run the app with a flag it doesn't know.

## Why paid tools (Voicemod, Supertone Shift) sound good, and what we can match

| What they do | Here |
|---|---|
| One voice actor per voice, hours of clean studio speech, a model trained on it (Voicemod: "trained with professional voice actors") | We run an untrained base model with an averaged speaker. B1 + B4 close part of the gap for free; a consenting actor's hours are not free. |
| Models built for streaming: small frames with memory, no pieces, no joins, tens of ms of delay (Supertone claims ~47 ms with its Nansy model) | Out of reach now: RVC remakes a 1.92 s window every 160 ms. Stage A fixes the joins. Later project: train a small streaming model (LLVC / Beatrice 2 style, MIT) on Kaggle with our RVC as the teacher. |
| Robust neural pitch trained on noisy speech | B2 (FCPE) |
| Noise cleanup before conversion | B3 (RNNoise "Clean mic") |
| Output polish: no clipping, steady loudness | A3 headroom + loudness cap |
| Full-precision models, steady scheduling, a dedicated GPU | B1, A1 (margin + CPU fallback) |
| Speaker adaptation (Shift listens 10 s to you) | Exists (median mapping); A3 removes the ±15 clamp |

Honest outlook: A + B get us to "good streaming RVC" at ~1 s delay. Their ~50 ms at that quality and per-actor voices
stay out of reach for free.

## Stage A — one coding agent, branch `v3-2-smooth`, no new model files

### A1. Stutters
1. **Safety margin grows with the slider; every delay number stays as today.** Split the slider's look-ahead L (0-700,
   `ChangerSettings` 104-108, unchanged) into real look-ahead LA and extra reserve R:
   `R = round10(k · max(0, L − 150))`, `LA = L − R`, `k = (700 − LAmax)/550`, `LAmax = 450` (tune `aiAheadMax`;
   `aiSplit=0` = off). Slider 1: LA 450, reserve 320; 0.86: 400/270; 0.59: 290/180; 0.32: 180/90; ≤ 0.25 unchanged
   (reserve 70). One `splitFor(L)` used by `voicestream_set_lookahead` (1193), `voicestream_new` (1131-1133),
   `voicestream_delay_ms` (1101), `voicestream_latency_frames` (1186); `latencyFor(la, extraMs)`; `baseBack` becomes
   a sound-thread value set with `junctionLatency` in `junction()` (813-814) and applied in `pull()` (929-932), so the
   read point only moves at the existing quiet-moment switch. No Swift change; the Natural ring (1137) still fits.
   **Pick LAmax first by measurement:** LA 400/450/500/600 vs 700 offline (meas70.py words/MOS, seams.py joins); keep
   the smallest within noise of 700 (words ≤ +0.6 points, MOS ≥ −0.02, poor joins ≤ +0.5 points).
2. **Warm CPU copy of the voice model, switched to when pieces run late.** `voicemodel_load` (966-1092): when the
   generator runs on the GPU, also load a CPU-only `MLModel` of the same compiled folder and warm it (~0.5 s, ~50 MB).
   `makeHop` step 5 (676) predicts with `genOnCPU ? voiceCPU : voice`. Per piece, margin = AI sound buffered ahead of
   the playhead when the piece starts (atomic copy of `pulled` written in `pull()`) − piece time. Rule (`aiAutoChip`):
   GPU → CPU after 2 late or 4 tight (< 15 ms margin) pieces in the last 10; back to the GPU only after ≥ 30 s and only
   if the CPU is tight too (no blind tries). Also measure starting on the CPU (idle: CPU 49 ms ≈ GPU 49 ms; judge by
   whole-process CPU with `ps`) and start on whichever wins. Chip in use → `VoiceStreamStats`, `--changer-stats`.
3. **Grace before Natural** (`pull` 937): the AI plays on into its provisional tail up to 20 ms (`aiGraceMs`) before
   fading to Natural; when the late piece lands, ramp into it.
4. Optional: real-time thread policy for the worker (1152-1157, `aiRealtime`); keep only if it measurably helps.

Pass marks (`stream_test --live` 75 s, 128-frame callbacks, slider 0.25 and 1): late pieces per minute with the GPU
80 % busy ≈ 182 → **≤ 1**; 8 busy CPU threads ≤ 1; idle 0; Natural ≤ 0.5 s per minute; delay at 0.05/0.25/0.59/1 within
2 ms of 3.1.1; `--switch` 150→700→0→150 loses or doubles nothing outside pauses; `testsim.sh` ≥ 4.8 s of AI in the 5 s Test.

### A2. Joins (`makeHop` 679-745, `adopt` 827-831)
1. **Balance the decoder margins without new files:** the decoder runs on the frames the app picks, so move `d0` (633);
   sweep `aiLeftMs` 60/50/40 (right margin becomes 40/50/60; needs LA ≥ right margin).
2. **Crossfade that adapts to likeness:** r = correlation of old tail and new head (code exists in the trace block
   746-756); fade-in `a = w/√(w² + (1−w)² + 2r·w(1−w))`, fade-out likewise: equal gain at r = 1, equal power at r = 0.
3. **Each piece keeps its own loudness across the join:** keep the old piece's `gains[H..H+X]` and blend
   `gOld·old·b + gNew·new·a` (today the new gains go on both, 705/734).
4. **Two-sided loudness windows** at a piece's start: allow `p ≥ −M·upp` (726).
5. **Near search** (`solaMode` 3): ±1.5 ms around a fixed centre (mode 2 drifts with `lastO`), and spend the unused
   search time on a longer crossfade (X+S−3 ms). Keep only if it helps.

Pass marks (seams.py on p311/p334 + warm-ups; regression31 set): slider 1 poor joins ≤ 2 % (4.6 %), bad ≤ 0.3 %
(0.8 %); default poor ≤ 3 % (5.9 %); sudden changes ≤ 15 (20), pitch jumps ≤ 13, voice breaks ≤ 8; no timing jump ≥ 2 ms.

### A3. Buzz
1. **No tone on noise or hiss** (`windowPitch` 561-591): bridge a gap only if its frames are smooth (`crossingsAt`
   < 0.15) and ≥ floor + 12 dB; gap length 8 → 5 frames (sweep 3-8); drop voiced runs < 40 ms with ≥ 100 ms unvoiced on
   both sides (known frames only); any frame with hiss-like crossings (> 0.3) gets no sine (covers the `aiHoldFrames`
   hold, VoiceChanger.cpp 813).
2. **Loudness cap that follows the mic level** (709-731): `capDb = 18 · clamp((level − floor − 6)/14, 0, 1)`; below
   floor + 3 dB cap at −10 dB so the model's own hum in pauses is never lifted; `noteLevels()` every piece; sweep
   `aiGainMs` 50/80/120.
3. **Remove the ±15 st clamp on the AI path** (`aiTotal` 749-752, `bandCentre` 830-831; tune `aiClampMode`): keep the
   voice band (`aiBandSt`/`aiMaxSt`) plus an absolute 60-880 Hz range; Natural keeps ±15 (only the AI stream reads
   `frameHz`, `VoiceModelStore.swift:144`, so Natural stays byte-identical).
4. **Headroom:** a peak limiter on each finished piece in the worker at 0.6 (−4.4 dBFS), acting up to 5 ms ahead
   (the piece is ready before it plays), 80 ms release; `softLimit` then never bends the AI voice. Count samples above
   0.7 reaching `softLimit` in `--changer-stats`.
5. Report only: Woman at 235/1.7 vs 220/1.5 for buzz and strain (owner picked 235/1.7; do not change without asking).

Pass marks: hum in noise-only moments (`regression31/noisem.py` on `mknoisy.py` inputs) ≤ 10 % (30-70 %); tone over
consonants ≤ 3.0 s per 100 s (5.19) with voice breaks ≤ 8; deep-voice frames stuck at the limit 30-33 % → ≤ 2 %, share
above 400 Hz up ≤ 1 point, 0 octave flips on the `r311` held notes; samples above 0.7 into `softLimit`: 0 at normal
level, ≤ 0.1 % with the mic 10 dB louder; words (`meas70`) ≤ +0.4 points, MOS ≥ −0.02; also report `bz.py` and
3-8 kHz flatness.

Deliver: PR "3.2: fewer stutters, cleaner joins, less buzz" (version 3.2.0; models unchanged, `models.txt` stays at
v3.1.0); notes in `notes/voice-changer-plan.md` ("3.2"); listening folder `~/Downloads/Pitch Shift 3.2 compare/`
(3.1.1 vs 3.2, sliders 0.25 and 1, clean / noisy / GPU busy); `~/Desktop/PitchShift-3.2-test.pkg` + README.

## Stage B — research gates, one agent each; measure first, ship only if better

**B1. Full-precision model files.** Recreate the venv and downloads (above). Rebuild ContentVec from the **original**
weights (`convert_contentvec.py --context-ms 1710 --quant none`) and the generators with `convert_generator.py
--context-ms 1000 --ahead-ms 700 --right-ms 40 --quant none` (same shape, drop-in). `verify_coreml.py`: expect SNR
> 45 dB (int8: 29-36). In-app A/B via `--voices-dir`: int8 / fp16 generator only / fp16 both — MOS, words, joins, buzz
numbers, piece time on GPU, CPU, Neural Engine, memory. Sizes: fp16 encoder ≈ 190 MB, each voice ≈ 40 MB (pkg ≈ 139 →
≈ 280 MB with both; ≈ 170 MB with fp16 voices + int8 encoder). **Default decision: ship fp16 voices; keep the encoder
int8 unless the A/B hears a difference** (owner may override). Bigger decoder margins (100/100, +32 % decoder time) only
if A2's sweep shows the edges matter and the default position keeps ≥ 15 ms spare. Ship: new file names (e.g.
`woman_us_ahead16`) so caches and `aiVoicePrepared` keys don't clash; `voices/*.json`, `models.txt` lines (size, SHA-256,
PLACEHOLDER tag), encoder fallback name in `Sources/VoiceImport.swift`; upload to a release only with the owner's OK.
Pass: MOS +0.05 or clearly less buzz, words not worse, piece time within +5 ms.

**B2. FCPE pitch tracker for the AI** (torchfcpe, MIT, 10.6M params). Mel front end in the app (vDSP: 1024 window, hop
160, 128 bands; Core ML STFT conversion is unreliable); convert the network (mel → 360 pitch bins) to Core ML on the
Neural Engine or CPU, never the GPU; decode in the app (local weighted argmax, voicing threshold ≈ 0.006). Each piece:
the newest 1.28 s ending at E. Wiring: `VoiceChangerPitch` gains per callback `aiMedianHz`, `bandCentreHz` and per frame
`frameIn` (YIN raw); move `aiTotal`/`aiPitch` into `Sources/Voice/AIPitchMap.h` (inline) shared by VoiceChanger.cpp and
VoiceModel.mm; `aiPitchSource=1` → `windowPitch` maps FCPE's pitch where it says voiced, 0 where unvoiced (replaces gap
bridging and lead-ins); YIN still drives medians, held-note rules and Natural. Budget ≤ +6 ms per piece. Pass: octave
errors vs Praat halved; hum ≤ 5 %; tone over consonants ≤ 2.5 s/100 s; voice breaks no worse than after A; `r311` held
notes slide ≤ 0.1 st, 0 flips; words not worse; late pieces unchanged.

**B3. RNNoise "Clean mic"** (BSD-3). Vendor RNNoise 0.2 into `Sources/ThirdParty/rnnoise/` (+ CREDITS); `build.sh` builds
it for both chips; 480-sample frames at 48 kHz (other rates via libsamplerate both ways). In `render()` (1069-1090), after
`callMix.muteIfNeeded`, a cleaned copy **only** for `voicestreamPush` (Natural, plain shift and YIN keep the raw mic →
byte-identical with the switch off; report the variant with YIN on the cleaned copy). Pitch positions +10 ms; AI delay
+10 ms, taken from the reserve at the top positions so max stays ~1 s. UI: "Clean mic" switch on the changer card (Pro),
key `changerCleanMic`, off by default; `--clean-mic` flag; preview state. Pass on mknoisy (−35/−25 dBFS room, −30
babble): words ≥ 20 % fewer errors (relative), hum ≤ 5 %, MOS up; clean room: words ≤ +0.4, MOS ≥ −0.03; CPU < 2 %.

**B4. Train real voices on Kaggle.** `train/speakers.json` Woman → the 8 Woman US speakers; Man unchanged. Data:
`prep_vctk.py --minutes 40` (5 min per speaker, VCTK CC BY 4.0, range requests), pitch RMVPE/harvest for training only.
`kaggle.ipynb`: fine-tune from f0G48k/f0D48k, 200 epochs, batch 12, 2× T4, save every 50; 4-8 h per voice in two
notebooks (12 h session limit, 30 GPU h/week). Owner: Kaggle account (phone verify once), import the notebook, GPU T4 ×2
+ Internet on, Save & Run All, download `woman.pth`/`man.pth` to the folder the agent names (optional `~/.kaggle/
kaggle.json` token, never in git). Convert with B1's settings; compare epochs 100/150/200 vs the blend (voice print,
judged woman %, US-accent score, words, MOS, buzz, pitch following) + blind listening folder. Pass: MOS +0.1, voice print
closer, words not worse, **and the owner prefers it blind**. Credits: "made from" → "trained on" VCTK.

Order: B1 (cheap, raises the floor) → B2 (biggest lever against robotic/buzzy pitch) → B3 → B4 (as soon as the owner
has a Kaggle sign-in, the training runs in the cloud while the other rounds go on).

## Stage C — "Higher when fast" (one small agent, branch `v3-2-fast`)

Mapping (`SpeakingRate`, VoiceShifter.swift 702-855): `extra = −8·slowPart + up·fastPart`,
`fastPart = clamp((used − fastStart)/(fastFull − fastStart), 0, 1)`, `up` = 0..+8 half-steps. **Calibrate first**
(nobody has measured the bump rate on real speech): `rate` on VCTK read speech, `say -r 175`, fast speech (`say -r
300-350`, VCTK sped up 1.5×); `fastStart` = 90th percentile of normal speech + 0.3, `fastFull = fastStart + 2` (guess 4.5
and 6.5 syl/s). Glide, `moveBy`, `moveAfter` unchanged; total pitch limited to ±24; engine choice (`plainWantsPulse`,
486) depends only on the set amount, so it never switches mid-word.
Wiring: `VoiceParams.fastHigher`; `VoiceShifter.fastHigher` → `pushParams` (1297, 1427-1431); `render()` sets
`speaking.up` (1073-1078), same in `--render-voice` (1882) and the simulation (1980); allow positive values in
`set(extra:)` (602); flag `--fast-higher N` (default 0 → old checks byte-identical); `SlowReading` prints both parts.
UI (Window.swift): `GradientSlider` row "Higher when fast" (Off … +8) under the "Deeper when slow" row (1820-1824),
declared near 1603; enabled only while the switch is on (2767-2770); locked/dimmed like `slowSwitch` (1758-1759, 2725);
key `voiceFastHigher` (1455; loaded 1475, 1987/1993 on unlock); `Free.fastHigher = 0` in Pro.swift; **app default +4**
(owner may change). Card height checked in hidden previews at 870×369, 588×581, 306×850.
Unchanged: the deeper part's numbers, the voice changer, the one-at-a-time rule (1530-1559), Windows, byte-identical
renders at 0. Pass: normal speech keeps extra = 0 ≥ 95 % of the time (≤ 1 move per minute); fast speech reaches the set
amount; slow speech as before.

## Agent batching (Opus 5.5 only, ≤ 4 at a time, one per task)
1. Round 1, three at once: **A** (VoiceModel.mm, VoiceChanger.cpp), **C** (VoiceShifter.swift SpeakingRate, Window.swift,
   Pro.swift, main.swift), **B1 preparation** (research only: venv, downloads, fp16 conversions, PyTorch checks).
   Overlap only in `main.swift` help text.
2. After A merges: B1 in-app A/B and ship decision; B4 agent prepares the notebook, owner starts the Kaggle run.
3. B2 (touches the pitch feed A changed).
4. B3 after C (both touch the Window.swift cards).
5. B4 conversion + measurements when the `.pth` files arrive (B1's environment).

## Verification (end to end)
- `check1.sh` 14/14 identical; Natural 15/15 identical to 3.1.1; "old" tune values reproduce 3.1.1's AI renders exactly.
- `stream_test` idle / GPU busy / CPU busy / switches; `testsim.sh`; `r311` held notes; regression31 measures; `meas70`.
- 36 compiler warnings (no new ones); the Intel half still says "needs Apple silicon"; hidden previews (C, B3).
- Live `--test-voice --watch` only with the owner's app closed; otherwise skip and say so.
- Owner's listening folder + Desktop pkg before any release; release 3.2.0 after the owner listens; B1 zips as release
  assets with SHA-256 in `models.txt`.

## Decisions taken by default (say if you want otherwise)
- LAmax 450 unless the measurement says 500 is needed; the default slider position is unchanged (reserve 70).
- B1 ships fp16 voices (+30 MB) and keeps the encoder int8 unless the A/B hears a difference (pkg ≈ 170 MB, not 280).
- "Higher when fast" default +4 half-steps.
- Kaggle: sign in by hand when B4 starts; an API token only if you want the agent to push/download for you.

## Risks
- The read point moves at a reserve change (A1): only at the existing quiet-moment switch; tested with `--switch`.
- CPU fallback: ~50 MB more memory; games can load the CPU too, so the rule works both ways.
- Stricter tone gating could whisper voiced consonants: protected by the voice-break pass mark.
- No ±15 limit: strain / octave drops on high notes: protected by the band, the absolute range and the held-note checks.
- B1 grows the download; B2's conversion and time budget are unmeasured (if FCPE misses +6 ms, run it on the CPU in
  parallel with the encoder or drop it); B3 may sound watery; B4 needs the owner's account and may sound "averaged"
  (judged by blind listening, not numbers).
