# Plan: "Voice changer" — a third card that turns a man's voice into a woman's and a woman's into a man's

## Context
The owner wants one more widget in Swoopy: a **Voice changer** with two voices first — **Woman** (for a man's voice) and **Man** (for a woman's voice) — that sound **real**, work **live** in calls, keep the **48 kHz** path, cost **nothing** to anyone (no paid services, no cloud), may use **AI** if it is local, free and convincing, and are **expandable** so more voices can be added later. Built by a workflow of **at most 5 Opus agents** (research → plan → implement).

Decisions the owner made (2026-10-14/15): a **third card in the main window**; **AI "Realistic" mode on Apple silicon, non-AI mode as the Intel fallback and the default**; the **user chooses the delay/quality trade-off** ("let the user choose, do all"); part of the **free app** (committed locally, then pushed as a PR like the other features); AI voices **bundled in the installer** (a big installer is fine).

What exploration found (two read-only agents, Oct 2026):
- The voice engine already separates pitch and formants (Rubber Band R3's formant scale is applied on top of the pitch change: envelope ratio F with pitch ratio P = `set_formant_scale(F/P)`), glides values click-free (`VoiceStretcher`), and has an offline twin (`--render-voice`) that shares the same code — so a non-AI "Natural" changer is an extension of `Sources/VoiceShifter.swift`, not a new engine. At 0 half-steps the chain bypasses Rubber Band; a changer must force it on.
- Research says pitch AND formants must move together (≈82 % perceived-sex flip), with a **target median pitch** (≈190–210 Hz for Woman, ≈105–120 Hz for Man) rather than a fixed shift, formants ×1.15–1.20 / ×0.85, breathiness, a small "smile" lift above ~1.5 kHz, intonation range ×1.1–1.3 / ×0.8–0.9, creak (vocal fry) smoothing, and an automatic tone EQ toward a target-gender spectrum. The DSP ceiling: usually heard as the other sex, but a man rarely becomes a "real woman" — the glottal pulses survive. Only resynthesis (AI) replaces them.
- Free, bundleable AI that fits: **RVC v2** (MIT code and base weights trained on VCTK CC BY 4.0; a 48 kHz generator exists; pitch is an explicit input so our pitch mapping plugs in; one model per voice — we train our own Woman and Man voices on CC BY 4.0 data, multi-speaker so no real person is cloned; content encoder ContentVec, MIT; run through **Core ML** on a worker thread, a pattern already proven in this repo). Expected ~200–300 ms end to end, Apple silicon only. Prototype voice available now: `KoeAI/llvc_models f_8312_32k` (MIT). Out for licence reasons: Seed-VC, MeanVC, RAVE, DDSP-SVC's vocoder, so-vits, Beatrice, NISQA.
- Free realism measures: a gender classifier (MIT, 98.7 %), ECAPA speaker-embedding distance (Apache), Distill-MOS (MIT) for ranking, Praat statistics, Whisper word-error rate, and a blind listening set for the owner. Pitch alone fools classifiers, so several measures are used together.
- The window code assumes exactly two cards (`measure/allowed/bestScale/arrange`); a third card needs new layout rules; `ShiftCard` always builds a big number and − 0 +; previews are hidden and focus-free.

## Queued while in plan mode (not part of the Voice changer; done right after approval)
- **Soundboard: drag and drop.** Dragging audio files from Finder onto the Soundboard window adds them (same copy-into-Application-Support path as the + button; several files at once; a highlight while hovering; non-audio files refused). Goes to the Soundboard agent on `v2-voice-tweaks` with its three leftover steps (commit the popover fix, device tests when the mic is free, detach).
- Resume the paused agents: `v2-voice-delay` (rebuild, live checks, commit, push, PR), `v2-voice-buzz` (confirm the Natural-mode level rise/clipping lead, fix in `VoiceStretcher`, commit), the Auto EQ workflow (engine commit → tune → app; local only).

## Order of work
1. **First finish 2.0.2** (the paused branches above → PRs → merge → release). The changer hooks into exactly the code those branches rewrite (`VoiceChain.render/shift`, `pushParams`, the voice card), so starting earlier means doing it twice.
2. **Start A2's AI research right away** (it lives in `research/voicechanger/`, not in the app) and the voice training, which takes hours.
3. After 2.0.2 is on main: Step 0, then A1 + A3 in parallel, then A4.

**Owner must provide:** either ~15 GB of free disk for overnight training on this Mac (only ~5 GB free now) or a Kaggle sign-in for a free GPU (3–5 h per voice, press "Run all").

## Design

### Files
- New `Sources/Voice/VoiceChanger.{h,cpp}` — Natural mode DSP, plain C++17 with a C API, no Apple APIs (not under `Sources/Advanced/`, so no Windows CI). New `Sources/Voice/VoiceModel.{h,mm}` — Realistic mode, Core ML, Objective-C++; real code under `#if __arm64__`, x86_64 gets stubs that say "needs Apple silicon". New `Sources/VoiceLibrary.swift` — voice manifests (built-in + user folder) and `VoiceModelStore` (loads/frees models in the background). `voices/woman.json`, `voices/man.json`, `voices/CREDITS.txt` → `Contents/Resources/Voices/`.
- Changed: `VoiceShifter.swift` (VoiceParams, VoiceStretcher, VoiceChain, VoiceShifter, renderVoiceFile), `Window.swift`, `main.swift`, `Bridging.h`, `build.sh` (per-arch loop: compile `Sources/Voice/*.cpp` and `*.mm -fobjc-arc`, link `-framework CoreML`, copy the voices), README credits.

### Natural mode (DSP, every Mac, default)
Order in `render()`: mic → `voicechanger_analyse` (pitch tracker, pitch mapping, creak) sets Rubber Band's pitch + formant scale → Rubber Band R3 (forced on) → ring → `voicechanger_post` (sibilance → tone EQ → presence → breath) → silent/Soundboard mix/clamp → Swoopy Mic. Analysis runs alongside the sound and post uses only IIR filters: **adds no delay** (acceptance: = plain voice ± 2 ms). All buffers made in `voicechanger_new`; analyse/post allocate nothing and take no locks.
- **C API (fixed at Step 0):** `VoiceChangerVoice {targetHz, assumedInputHz, intonation, formant, breathDb, presenceDb, sibilanceKeep, eqAmount, ltas[21]}`; `VoiceChangerPitch {pitchScale, formantScale, voiced, f0In, f0Target, newFrames, frameHz[64], framePos[64]}`; `voicechanger_new/delete/set(voice|NULL, strength)/reset/analyse(in, frames, extraSemitones, out)/post(io, frames, delayFrames)/tune(key, value)/get_stats`.
- **Pitch tracker:** YIN on a ÷3 downsampled copy (÷6 at 96 kHz, none at 16 kHz), 32 ms window, 10 ms hop, 55–600 Hz, threshold 0.12, parabolic interpolation, octave-jump rejection against the running median, median of 3; ~0.1 ms per hop on the sound thread. Voiced = aperiodicity < 0.25 and level > floor + 10 dB and > −50 dBFS.
- **Pitch mapping (target median, like Praat):** median from a 4 s histogram of voiced frames (¼-semitone bins, seeded by `assumedInputHz`); `off = 12·log2(targetHz/median)`; `dev = clamp(st(f0) − st(median), ±12)`; `P_st = s·(off + (intonation − 1)·dev) + extraSemitones`, limited to ±15; smoothed 25 ms, held through unvoiced frames.
- **Creak:** f0 < 70 Hz, or < 0.62 × median, or jitter > 8 % over 3 frames, or aperiodicity 0.25–0.45 → hold the last good pitch, count `creakShare` (the fry itself survives in Natural; Realistic removes it).
- **Formants:** `Feff = formant^(s·clamp(|off|/|12·log2(targetHz/assumedInputHz)|, 0, 1))` (a woman choosing Woman gets almost no formant change), 150 ms glide; Rubber Band formant scale = `Feff / 2^(P_st/12)`.
- **Sibilance (Man):** split at 4.5 kHz; in unvoiced frames crossfade the top band toward the original's top band from a delay line at `delayFrames` by `sibilanceKeep·s`.
- **Tone EQ:** output long-term spectrum (6 s) vs the voice's 21-band `ltas` (from VCTK, `research/voicechanger/make_ltas.py`), normalised over 500 Hz–2 kHz, smoothed ±1 band, × `eqAmount·s`, limited ±6 dB; 8 octave peaking filters 125 Hz–16 kHz (Q 1.41), updated every 256 samples, ≤ 0.05 dB per step.
- **Presence ("smile"):** +`presenceDb·s` peak at 3 kHz, Q 0.9. **Breath:** noise in 4 bands (1.5–2.5, 2.5–4, 4–6, 6–9 kHz), each following the output's own band loudness (5/30 ms), × 10^(breathDb/20)·s, only when voiced.
- **Start values:** Woman {200 Hz, assumed 120, intonation 1.2, formant 1.18, breath −30 dB, presence +2.5, sibilanceKeep 0, eq 0.5}; Man {112 Hz, assumed 205, 0.85, 0.85, off, 0, 0.7, 0.5}.
- **Swift wiring:** `VoiceParams` gets `changer: UnsafePointer<VoiceChangerVoice>?` (points into VoiceLibrary's app-lifetime table) and `strength`; `VoiceStretcher.running = halfSteps != 0 || slowDeeper || changerActive`, `set(changer:)`, `set(changerPitch:formantScale:)` every callback, strength glides 0.15 s on/off; `VoiceChain` owns the `VoiceChanger*` and passes `stretcher.extra` (Deeper when slow) as `extraSemitones`; `VoiceShifter.changer {on, voiceID, strength, realistic}`, sent only when the voice switch and the changer are on (the Soundboard-only pass-through never runs it); `changerState` for the window: off / natural / loading / realistic / fallback(misses) / unavailable(reason); `renderVoiceFile(..., changer:)` uses the same classes.
- **With a voice on (changed 2026-10-15 evening, the owner's rule "only one at a time"):** turning a voice on sets the amount to 0 and "Deeper when slow" off (saved); the number and − 0 + still work and a non-zero amount turns the changer off (tooltip says so); "Deeper when slow" is greyed out and turning it on also turns the changer off; the Natural↔Cartoon slider is ignored and dimmed; the engine never sends an amount or "Deeper when slow" with a voice on; the Soundboard mixes in after the changer; Test plays back the changed voice.

### Realistic mode (AI, Apple silicon only)
- **Model:** RVC v2 style — one shared ContentVec encoder (768-dim, layer 12, 50 frames/s at 16 kHz) + one 48 kHz NSF-HiFiGAN generator per voice; pitch is an explicit input driven by our mapping (creak held at a normal pitch → the model sings through it: fry gone).
- **Runtime: Core ML** on its own pthread (QOS user-interactive), preallocated MLMultiArrays/outputBackings, rings indexed by sample position, libsamplerate resampling (the DrumKeeper pattern on `v2-advanced3-ai`). audio.cpp is plan B if conversion fails. Conversion: move the NSF sine/noise source out of the model (full-precision phase computed in C++), fixed seeded noise, fixed shapes, 8-bit weights, macOS 14 target, no faiss index.
- **API:** `voicemodel_load(encoderPath, voicePath, computeUnits, err)` / `voicemodel_free`; `voicestream_new(model, chainRate, maxFrames, offline, config{hopMs 160, contextMs 480, crossfadeMs 40, solaMs 10, reserveMs 60})` / `delete` / `latency_frames` (fixed) / `push(mic, frames, f0Hz, f0Pos, n)` (sound thread, copies only) / `pull(naturalNow, naturalDelay, out, frames)` / `get_stats`.
- **Per hop (worker):** resample to 16 kHz → ContentVec on context + hop → ×2 frame rate → align pitch → generator renders hop + crossfade + search + ~60 ms margin → resample back → SOLA crossfade → output ring. **Delay ≈ 275 ms fixed** (a 100 ms hop gives ≈ 215 ms at ~1.6× compute; A2 picks the hop so 99 % of hops finish within 60 % of the hop time).
- **Fallback, never silence and never the raw mic:** Natural keeps running, delayed to the same fixed latency, crossfaded in (10 ms) while loading, on a late hop, or on error; misses counted; the card shows it.
- **Compute units:** A2 measures CPU / GPU / Neural Engine / all and defaults to the steadiest within budget (`--compute` overrides). ~300 MB memory while on; `VoiceModelStore` loads once in the background, frees when off; switching voice/quality rebuilds the chain once loaded (0.1–0.3 s, Natural meanwhile). A 16 kHz Bluetooth mic works (worse).
- **Model files — bundled in the installer (owner's choice):** `Contents/Resources/Voices/{contentvec, woman, man}.mlmodelc` (~95 + 28 + 28 MB, 8-bit) + CREDITS; the pkg grows to ~160 MB; no download code. Intel Macs carry the files unused.
- **Adding voices later:** a folder with `voice.json` {id, name, version, natural{…}, realistic{model, encoder, rate, eqAmount}, credits} in `Resources/Voices/` (built-in) or `~/Library/Application Support/Pitch Shift/Voices/<id>/`; a voice with only a `natural` block works on every Mac; bad folders are skipped and listed by `--list-voices`.
- **Training our two voices:** VCTK 0.92 (CC BY 4.0, 48 kHz): Woman = 8 female speakers with median pitch 185–220 Hz, Man = 8 male at 100–125 Hz, mixed accents, ~20 min each, pooled under one speaker id (a blend, nobody cloned), 4 + 4 speakers held out for tests; files fetched one by one. Base: RVC v2 pretrained 48 kHz (MIT), ~200 epochs. Scripts (git-ignored) in `research/voicechanger/`: `train/{pick_speakers.py, prep_vctk.py, train_rvc.sh, kaggle.ipynb}`, `convert/{convert_contentvec.py, convert_generator.py, verify_coreml.py}`, `pack_voices.sh`. Credits (README + CREDITS): VCTK (CSTR, University of Edinburgh, CC BY 4.0), RVC (MIT), ContentVec (MIT). Research only, never shipped: single-speaker base models, LLVC f_8312_32k.

### The third card, "Voice changer"
- `ShiftCard.init(title:extraRows:showsAmount: Bool = true)`: with `false` no big number and no − 0 + (`keyViews = [toggle, picker]`, `spread()` adjusts, `show(on:active:)` overload); `show(…, amountActive:)` dims only the voice card's number and buttons while a voice is on.
- Contents: header "Voice changer" + switch; picker Woman, Man, then added voices (no "Off" item — the switch does that); Strength `GradientSlider(left: "Light", right: "Full")` default 1; `switchRow("Realistic", …)` hidden on Intel (Natural = that switch off; tooltip shows fallback). Turning the changer on also turns "Your voice" on; turning the voice off dims the changer card.
- **Realistic alert** (Advanced-style, first time only unless `hideChangerAlert`): "Realistic voices add delay" / "Your voice reaches the call about a quarter second later." Buttons Turn On / Cancel / Don't show again (saved only on Turn On). No alert when turning off or restoring at launch.
- **Settings (per user):** `changerOn` false, `changerVoice` "woman", `changerStrength` 1, `changerQuality` "natural"|"realistic", `hideChangerAlert` false. Previews never write.
- **Layout:** replace `minSide/minStacked/stacked` with `enum Layout { row, split, stack }`: row = three side by side (min 870×369); split = What you hear left full height, Your voice with Voice changer under it on the right (min 588×575); stack = one column (min 306×844). `measure()`: contentMin (306, 369), contentMax (1300, max(640, stack height + 96)) limited to the screen; if stack doesn't fit the screen, drop it and require ≥ 588 wide. `allowed(size)` accepts any layout's minimum, else grows to the closest (prefer the current). `bestScale(size, layout)`: row width (W−72)/3, height max(h1,h2,h3); split width (W−56)/2, height max(h1, h2+16+h3); stack width W−40, height h1+h2+h3+32. `arrange()` picks the largest scale, keeps the current layout unless another beats it by 0.05; `settle()` animates voice and changer cards. An old 588×369 window opens as 588×575.
- `menuNeedsUpdate`: three branches (hear / mic / changer → `rebuildChangerMenu()` rescans the voice folders). Tab order: `… + changerCard.keyViews + [strength, realisticSwitch]`. `refresh()`: changer card active when `changerOn && voiceOn && installed && hasMic`. Preview states: `changer`, `changer-man`, `changer-realistic`, `changer-alert`, `changer-fallback`, `changer-intel` (work with `light`, `resize`, `--size`).

### Command line and measurement
- Flags: `--voice Woman|Man|<id>`, `--strength S`, `--quality natural|realistic`, `--compute cpu|gpu|ane|all`, `--voices-dir DIR`, `--changer-tune "k=v,…"`, `--changer-stats`, `--list-voices`. `--render-voice … --voice Woman --quality realistic` runs the model inline (never misses) and prints per-second stats; `--test-voice … --voice Woman [--quality realistic] [--watch] [--seconds 60]` prints delay, dropouts, overloads, AI misses/fallback time, CPU (measure delay with a speech file that starts after 1 s of silence, not a sine).
- Harness in `research/voicechanger/` (own venv): `make_set.py` (`say` voices: female Samantha, Karen, Moira, Tessa, Flo, Shelley, Sandy; male Daniel, Fred, Ralph, Eddy, Reed, Rocko, Grandpa; 10 Harvard sentences each; the held-out VCTK speakers = the main set; Apple Loops "Vox Melodics" sung clips for listening only; everything in the scratchpad, deleted after), `render_all.sh` (original, plain shift +10/−8, Natural Woman/Man, Realistic Woman/Man), `measure.py` (JaesungHuh gender classifier MIT; SpeechBrain ECAPA similarity to source and to target/source-gender averages; Distill-MOS; Whisper base.en WER; Parselmouth: median pitch, range, F1–F3, H1–H2, CPP, creak share, jitter) → CSV + `results/*.md`.
- **Pass marks (each mode and direction):** ≥ 80 % of clips judged the target gender AND ECAPA margin toward the target gender beats the plain shift on ≥ 80 % of clips AND Distill-MOS ≤ 0.3 below the plain shift AND WER ≤ original + 2 points; median pitch within ±10 % of target; creak share ≤ original (Realistic: ≤ half). Never judge by the classifier alone.
- **Blind listening set** `~/Downloads/Pitch Shift voice changer samples/`: 6 held-out VCTK clips (3 men, 3 women) × {original, plain shift, Natural, Realistic} + 4 genuine recordings, shuffled `01.m4a`…`28.m4a` (< 30 MB), `rate.txt` ("man or woman", "sounds real 1–5"), answers in a separate folder. Pass: ≥ 80 % target gender and "real" within 1 point of the genuine recordings.

## The workflow (Opus; 4 agents + an optional 5th, within the owner's "no more than 5")
**Step 0 (main session, no agent, after 2.0.2 merges):** branch `v2-voice-changer` from main; commit the contract (both headers with do-nothing stubs, `voices/*.json` start values, `VoiceParams` fields + VoiceShifter stubs, build.sh changes, this plan as `notes/voice-changer-plan.md`); check the build is byte-identical with the changer off.

| Agent | Delivers | Hand-off gate | Sessions |
|---|---|---|---|
| **A2 AI** (starts now, in `research/voicechanger/`; later `VoiceModel.mm`) | Gate 1: a research-only prototype (f_8312 / base RVC) converted to Core ML and running offline + live through the VoiceModel API; timings per compute unit; if Core ML fails try audio.cpp; if neither fits, stop and report (Natural ships alone). Gate 2: our Woman and Man trained, converted to 8-bit, checked against PyTorch; `results/realistic.md`; the `.mlmodelc` files for `Resources/Voices/`; `VoiceModelStore` | delay fixed ≤ 300 ms; 99 % of hops within 60 % of hop time; 60 s live with no misses after loading; forced misses (`aiSlowMs=200`) fall back with no frame at the speaker's own pitch; pass marks met or the shortfall in numbers | 3–4 (+ training running) |
| **A1 DSP + CLI + harness** (after Step 0) | `VoiceChanger.cpp`, Swift wiring, flags, `make_ltas.py` + tables, harness, `results/natural.md` (plain shift vs Natural) | changer off byte-identical; Natural delay = plain ± 2 ms; analyse + post ≤ 0.2 ms per 10 ms of audio (never > 0.5); 60 s no dropouts; no allocation/locks on the sound thread (reviewed) | 2 |
| **A3 card + layout + voice library** (parallel with A1) | section "The third card", manifests, `--list-voices` | hidden screenshots of every changer preview at 870×369, 588×575, 306×844, 1300×640 and light; resizing through all three layouts without jumps; nothing activates; Intel preview hides Realistic | 1.5 |
| **A4 integration + tuning + samples + checks** | merges dsp → ui → ai; connects card ↔ engine; ≤ 3 tuning rounds with `--changer-tune`, final values into voice.json; blind set; all end-to-end checks; README credits; notes; plain-words report; commit; push `v2-voice-changer`; PR to main | every check below passes or each miss is named with numbers | 1.5–2 |
| A5 (optional, owner's OK) | Intel/Rosetta hardening, installer size/packaging of the voices, docs | | ≤ 1 |

Rules for all: device tests only with the delay branch's guards (refuse while any mic is busy or the app is open), `--mic "MacBook Pro Microphone"`, hidden previews, never Apple Music or the owner's recordings, `nice -n 15`, renders in the scratchpad and deleted (stop below 3 GB free), Windows untouched, commits in plain words with the Opus co-author line, one push at the end (free app → PR).

## End-to-end checks
1. Changer off changes nothing: `--render-voice` on 3 files × {`--steps 3`; `--steps -4 --cartoon-amount 0.5`; `--steps 0 --slow-deeper`; `--steps 5 --cartoon`} + `--render-file` normal and advanced, all byte-identical to the base build; `--test-voice --tone 440 --steps 3` matches.
2. Delay: Natural = base ± 2 ms (~57 ms once the delay fix is in); Realistic fixed and ≤ 300 ms.
3. CPU (M3 Pro): Natural stage ≤ 2 % of one core; Realistic ≤ 35 % of one core (or Neural Engine equivalent).
4. 60 s runs per mode and voice: no dropouts, overloads or AI misses after loading.
5. Harness pass marks for both modes and directions; blind set delivered.
6. Intel: `lipo -info` shows both slices; the Intel slice renders Natural under Rosetta; `--quality realistic` there says "needs Apple silicon" and falls back.
7. Windows untouched: `git diff --stat main...v2-voice-changer -- windows/ Sources/Advanced/` empty.
8. No leak of the real voice: while falling back, loading or switching, no output frame at the speaker's unchanged pitch.

## Effort and risks
~8–10 agent sessions plus 5–10 hours of training running. Natural mode will fool the classifier but people may still hear "a man with a high voice" (Rubber Band keeps the speaker's own pulses); only Realistic replaces them — if Natural misses the 80 % listener mark, say so. Training needs GPU time (Kaggle sign-in or ≥ 15 GB free disk here); blended voices may sound "averaged" and need a second round; 8-bit Neural Engine models may lose quality (audio.cpp is plan B). The installer grows to ~160 MB. Neural Engine stutter on 8 GB/fanless Macs → brief switches to Natural (default to CPU if it fits, shorter-hop option, miss counter). ~250–275 ms Realistic delay feels laggy; the user chooses it, Natural stays the default. Our voices are blends, not real people; no cloning of named people.

## What was built (2026-10-15)

**For the user:** a third card "Voice changer" with a switch, a voice picker (Woman, Man, then any voices added to
`~/Library/Application Support/Pitch Shift/Voices/`), a Light…Full Strength slider and a "Realistic" switch (hidden on
Intel Macs). Turning it on also turns "Your voice" on, sets the amount to 0 and "Deeper when slow" off (only one at a
time; see "Fixes after the first listen"); the Soundboard mixes in after it. Smallest windows: three cards in a
row 870×369, two columns 588×548, one column 306×817 (the card is 163 pt tall, not the planned 190).

- **Natural mode** (every Mac, the default): `Sources/Voice/VoiceChanger.{h,cpp}`, as designed above. No added delay
  (offline: Woman 45.0 ms vs 44.6 ms for a plain shift at the same pitch, Man 71.4 vs 70.7), 0.024–0.030 ms of work
  per 10 ms of sound (worst 0.074; 0.27 under Rosetta), no memory taken and no locks while the sound runs.
- **Realistic mode** (Apple silicon): `Sources/Voice/VoiceModel.{h,mm}` + `Sources/VoiceModelStore.swift`. **No
  training was needed:** the RVC v2 48 kHz base model (MIT) already holds all 109 VCTK speakers; Woman and Man are
  blends of the same 8 + 8 speakers the plan picked for training. Core ML, 8-bit (zero-point mode), 160 ms pieces
  with 1 s of past sound. Fixed delay 275.5 ms (285.5 ms on the CPU only; 214 ms in offline renders). Default:
  speech reader on the Neural Engine, voice model on the GPU. If a piece is late, Natural fills in with 10 ms
  crossfades (never silence, never the raw mic). First load on a Mac 13–30 s (macOS prepares the models), then
  0.4–2.3 s; 4–6 % of one core; 270–330 MB while on.
- **Model files** (133 MB zipped, 145 MB unpacked) are not in git. `build.sh` takes them from `build/voices/` or
  `research/voicechanger/models/` (this or the main checkout), or downloads them from the addresses in
  `voices/models.txt`, checks their SHA-256 sums and unpacks them into `Contents/Resources/Voices/`. The release tag
  in `voices/models.txt` is still `PLACEHOLDER` (filled in when the files are uploaded at release time). Without the
  files the app builds and only Natural works.

### Final voice values (`voices/*.json`, Natural block)

| | target pitch | assumed input | intonation | formant | breath | presence | sibilance kept | tone EQ |
|---|---|---|---|---|---|---|---|---|
| Woman | 200 Hz | 120 Hz | 1.2 | **1.21** (start 1.18) | −30 dB | +2.5 dB | 0 | 0.5 |
| Man | 112 Hz | 205 Hz | **0.75** (start 0.85) | 0.85 | off | 0 | **0** (start 0.7) | 0.5 |

### How the values were picked (three rounds with `--changer-tune`, offline, warmed up with 8 s of the same speaker)

Two sets: held-out VCTK speakers (4 men, 4 women, 10 sentences each; never used for the tone tables) and the Mac's
`say` voices (7 + 7, 10 sentences each). "Voice print" = how often the ECAPA voice print moves further toward the new
sex than the plain shift does (mark 80 %). Word errors are Whisper's (mark: original + 2 points).

| men → Woman | VCTK: judged woman / voice print / word errors / creak | `say`: judged woman / voice print / word errors / creak |
|---|---|---|
| start values | 92 % / 90 % / 6.1 % / 0.056 | 67 % / 89 % / 22.9 % / 0.034 |
| **formant 1.21 (chosen)** | **95 % / 92 % / 5.7 % / 0.055** | **71 % / 87 % / 23.5 % / 0.034** |
| intonation 1.1 | 92 % / 85 % / 5.7 % / 0.048 | 67 % / 89 % / 21.9 % / 0.030 |
| plain shift +10 | 35 % / — / 6.1 % / 0.042 | 27 % / — / 18.7 % / 0.032 |
| original men | 0 % / — / 3.3 % / 0.060 | 0 % / — / 12.7 % / 0.054 |

| women → Man | VCTK: judged man / voice print / word errors / creak | `say`: judged man / voice print / word errors / creak |
|---|---|---|
| start values | 100 % / 78 % / 9.2 % / 0.074 | 96 % / 84 % / 22.2 % / 0.025 |
| sibilance kept 0 | 100 % / 90 % / 8.1 % / 0.073 | 96 % / 84 % / 18.2 % / 0.025 |
| **sibilance kept 0 + intonation 0.75 (chosen)** | **100 % / 90 % / 8.1 % / 0.069** | **94 % / 83 % / 19.4 % / 0.023** |
| plain shift −8 | 2 % / — / 8.1 % / 0.069 | 46 % / — / 16.8 % / 0.030 |
| original women | 0 % / — / 4.6 % / 0.072 | 1 % / — / 9.2 % / 0.018 |

Why: Woman formant 1.21 is best on the VCTK set and does not lower the `say` set's "judged woman" below the start
values. Man intonation 0.75 brings the creak share under the original's on VCTK (0.069 vs 0.072, the only VCTK mark
it missed) and keeps more clips inside ±10 % of the target pitch (95 % vs 88 %); on the `say` set it is one clip lower
on "judged man" and on the voice print and +1.2 points on word errors, which was not counted as clearly worse. Quality
(Distill-MOS) stays within 0.15 of the plain shift in every version above, and the median pitch lands at 189–191 Hz / 110–111 Hz.

### Realistic mode numbers (each clip rendered from a cold start; `research/voicechanger/results/realistic.md`)

| direction, set | judged target | voice print | quality vs plain | word errors (mark) | pitch | creak (mark) |
|---|---|---|---|---|---|---|
| women → Man, VCTK | 100 % | 100 % | +0.25 | 3.6 % (≤ 3.8) | 113 Hz | 0.015 (≤ 0.041): **all marks met** |
| men → Woman, VCTK | 100 % | 98 % | +0.18 | **10.2 %** (≤ 5.4) | 199 Hz | **0.029** (≤ 0.024) |
| men → Woman, `say` | 100 % | 90 % | +0.88 | **23.8 %** (≤ 14.7) | **174 Hz** (cold start) | 0.018 |
| women → Man, `say` | 100 % | 97 % | +1.20 | **21.5 %** (≤ 11.2) | 105 Hz | **0.014** (≤ 0.009) |

### End-to-end checks

| check | result |
|---|---|
| 1. Changer off changes nothing | 14/14 offline renders byte-identical to main (3 speech files × 4 voice settings + music normal and Advanced), re-run after the final values |
| Natural unchanged by the AI merge | 21/21 renders byte-identical |
| 2–4. Delay, CPU, 60 s runs (offline) | Natural adds ≤ 1 ms; Realistic fixed 275.5 ms live estimate / 214 ms offline, 0 late pieces in 75 s with the app's own code (A2's real-time test program) |
| 5. Blind listening set | made: `~/Downloads/Pitch Shift voice changer samples/` (28 clips + `rate.txt`), answers in `… - answers/` |
| 6. Intel | both halves in the app; under Rosetta `--quality realistic` says "Realistic mode: needs Apple silicon; Natural mode is used"; its Natural output matches Apple silicon's (largest difference 0.00009) |
| 7. Windows untouched | no change under `windows/`, `Sources/Advanced/`, `.github/` |
| 8. No leak of the real voice | forced late pieces: Natural filled in with 0 frames at the speaker's own pitch (A2's real-time test program) |
| Build | clean, the same compiler warnings as main |
| Live device tests | **not run yet**: the guard refused every time because the Swoopy app was open (the scripts are ready, see below) |

### Fixes after the first listen (2026-10-15 evening)

The owner tried the test build: "voice cracks on the high end for the female voice (I think at the e's it was
struggling) and sudden voice drops for the guy, at the same e soundings", in **Realistic** mode, saying "testing
testing".

**Cause (measured):** the pitch reader's octave fix compared each 10 ms frame with the median of the last 2 s of
raw pitch and doubled any frame more than 9 half-steps below it. A real fall at the end of a word ("testing",
"sweets", "these": the "i"/"ee" sounds) goes that low, so it was read an octave too high for several frames. The AI
voice follows the read pitch directly, so it jumped an octave there (Woman: a crack upward; Man: a jump out of the
low voice). Natural showed it smaller (only through the intonation part). Example, Daniel's "sweets": real pitch
95 → 67 Hz, read as 133 Hz; the Man voice's pitch went 79 → 120 Hz. A second, smaller cause: a new chain starts
the speaker's median from a guess (Woman 120 Hz, Man 205 Hz) and the median jumped to the real one after about a
second, moving the whole pitch at once.

**Fix (`Sources/Voice/VoiceChanger.cpp`, `voicechanger_analyse`):** the median-based fix is gone. Each voiced frame's
pitch may be YIN's value, half or double it; a small running path search picks the one that moves least from frame
to frame (1 point per half-step; taking double costs 3.5, half 4.5; past 10 half-steps from a known median 0.5 per
half-step), and a frame's choice is settled when the next frame is in (the same one-frame lag as before, so no
delay is added). The pitch handed to the AI voice: through creak it moves with a gradual fall (not below 0.62 × the
median) and holds through a sudden drop or rough frames; an aperiodic moment up to 80 ms after voice holds it but
never starts it; it is eased into 9 (at most 12) half-steps above and 6 (at most 9) below the voice's own pitch, and
moves at most 2 half-steps per 10 ms while singing. The speaker's median glides (0.3 half-steps per 10 ms) instead
of jumping; its first guess is still worth 1 s of voice, but frames more than 7 half-steps from it wear it off 40
times faster, so a guess that doesn't fit (a man using the Man voice) is gone after ~0.1 s (a light guess for
everyone cost Natural Man's voice print 90 → 82 %); a new chain starts from the median the last one measured
(`voicechanger_set_speaker`, so switching voices in Realistic doesn't start from a guess again). Tuning keys:
`octUpCost octDownCost jumpCost rangeSt rangeCost contFrames gapFrames warmFrames seedFarSt seedFarFade medianGlideSt
aiBandSt aiMaxSt aiBandLowSt aiMinSt aiHoldFrames aiSlewSt`.

**Numbers** (test set: "testing testing, one two three, easy peasy, see me eat these sweets, testing testing" by
Samantha, Daniel, Eddy, Shelley, Reed, Flo + 8 held-out VCTK speakers with many "e" sounds; Praat as reference;
crack = the output pitch jumps more than 6 half-steps within 30 ms while the input stays within 3 for ±30 ms):

| | before | after |
|---|---|---|
| Realistic Woman cracks (14 clips, offline, cold start) | 11 | 4 |
| Realistic Man cracks | 5 | 2 |
| Realistic, real-time test program (input looped, 20 s each) | Woman 8 in 46 s, Man 13 in 54 s | Woman 4 in 44 s, Man 1 in 53 s |
| Natural Woman / Man cracks | 5 / 5 | 1 / 3 |
| tracker octave errors vs Praat (all 14 clips, cold) | 181 (165 where Praat reads creak) | 65 (51) |
| AI pitch jumps > 6 half-steps in 30 ms, Woman / Man (cold; warmed up) | 22 / 14; 22 / 18 | 4 / 0; 2 / 3 |

What is left: Realistic still turns very creaky word ends into a short whisper (the reader calls them unvoiced;
singing them with YIN's rough pitch was tried and made it worse), a sound that starts with two misread frames glides
up for ~40 ms, and once the voice model itself rendered a low word end an octave down (the pitch it was given was
smooth). Natural's ones are the speaker's own creak passed through. Natural delay unchanged (live-sim, 3 clips × 2
voices: 44.1–71.7 ms vs 44.4–72.3 before; Man 1.8 and 3.4 ms lower on two clips), changer off 14/14 byte-identical,
Realistic offline 214 ms fixed and 0 late pieces, live test program 275.5 ms and 0 late pieces, no new compiler
warnings, the Intel half matches (Natural, largest difference 0.00006).

Natural marks after the fix (VCTK held-out set, warmed up, same measures as above):

| | judged | voice print | quality vs plain | word errors | pitch | creak |
|---|---|---|---|---|---|---|
| Woman, before → after | 95 → 95 % | 92 → 92 % | +0.03 → +0.02 | 5.7 → 6.1 % | 189 → 199 Hz | 0.055 → 0.055 |
| Man, before → after | 100 → 100 % | 90 → 88 % (one clip) | −0.13 → −0.15 | 8.1 → 8.5 % | 111 → 111 Hz | 0.069 → 0.067 |

**Only one at a time (owner's rule, same evening):** a voice from the Voice changer and a pitch change can't be on
together. Turning a voice on sets the amount to 0 and "Deeper when slow" off (saved; they stay so when the changer
goes off); a non-zero amount (− 0 + or typing) or turning "Deeper when slow" on turns the changer off (tooltips say
so; "Deeper when slow" is greyed out but still works); the engine never sends an amount or "Deeper when slow" with a
voice on; settings saved with both on: the changer wins. In Realistic mode the Light…Full slider only moves the pitch
(the AI voice always sounds like the voice), so it reads "Your pitch … Woman's pitch" there (relabelled rather than
hidden: hiding it would change the card's height and the window's layouts). Command line: `--steps` and
`--slow-deeper` are ignored with `--voice` (a note is printed). `--test-button --voice Woman [--quality realistic]
[--file F]` records and plays back the changed voice (not run: it plays sound out loud; the live tests were refused
for 15 minutes because the Swoopy app was open).

### Shortfalls, in plain words
- **Natural** fools the man/woman classifier, but a voice print still hears the same person: "a man with a
  convincing high voice". Two of the Mac's `say` men almost never pass (Ralph 0 of 10 clips, Rocko 1 of 10), which
  keeps the `say` set's Woman at 71 %; the other five `say` men pass on 48 of 50 clips.
- **Word errors** miss the mark in every version, the plain shift too: changing the pitch this far makes some words
  harder to make out.
- **Realistic Woman** slurs some words (10 % word errors vs 3.4 % for the original voices). The cause is converting
  live without hearing ahead; only more delay would fix it (1 s of past sound was the best setting measured).
- **A game using the GPU** can make Realistic fall behind; Natural then fills in and the card shows it.
- **Nobody has listened yet**, and the live microphone tests still have to run with the Swoopy app quit.

### Tools (git-ignored, in `research/voicechanger/`)
`a1/harness/` (render, measure, pass-mark tables), `a4/` (`tune.sh`, `check1.sh`, `blind.py`, `devtests.sh`,
`live_fallback.py`; tuning tables in `a4/results/r1…r3*/set_*.md`), `pretrained/` (voice blends), `convert/` (Core ML),
`bench/` (real-time test program), `results/` (A2's reports).

## No more stutters, and "Faster ↔ More real" (3.1, 2026-10-16)

**What the owner heard** (Realistic, Woman, good mic, nothing else running): "still stutters … even if I speak
clearly"; a held note "jumped up and down unnaturally … some very faint roboticness"; and on the offline Woman US
samples (A–D) all of them stuttered at "a judicial review" (the "ooh" in judicial and the "a"). So it was not GPU load.

**How it was measured** (offline, the app's own `--render-voice`, Woman US at D = 235 Hz / intonation 1.7, each clip
after ~8 s of the same speaker so the pitch median is settled; tools in `research/voicechanger/smooth/`):
- *Piece seams*: for every crossfade between two 160 ms pieces, how alike the two pieces' sound is there
  (normalised correlation of the crossfaded parts, 1 = the same sound) in the loud parts; "poor" < 0.8, "bad" < 0.5;
  and how often the crossfade's timing jumped (≥ 1 ms: a skip or a repeat of that much sound).
- *Sudden sound changes* (5 ms frames where the output's spectrum jumps > 7 dB while the input's moves < 3 dB),
  output pitch jumps (> 2 half-steps in 20 ms where the input moved < 0.7) and voice breaks (15–100 ms unvoiced in the
  output inside voiced input), on the 10 clips of the two American men of the listening folder (p311, p334).
- *Held notes*: synthetic held vowels (a VCTK man's vowel stretched to 3 s with Praat, slight vibrato and drift;
  no recordings of the owner): pitch jitter (the part of the pitch line faster than a 70 ms smooth), sudden steps,
  and drift (how far the output slides over the note beyond what the singer did).
- *Words and quality*: Whisper base.en word errors and Distill-MOS on the 70 men's clips of `woman_us.md`.

**Causes found, in order of size:**
1. **The speech reader hears a cut-off word at every piece** (the encoder's right edge). Each 160 ms piece comes
   from the newest end of the window, so the end of the next piece is guessed from sound that stops mid-word; the
   next piece then makes the same 50 ms again knowing more, and the two are crossfaded. They differ: today 53 % of the
   loud seams were poor (mean likeness 0.67, 24 % bad). In "a judicial review" (seams where the listening sample had
   them) 5 of 6 seams were poor, two of them very bad (0.17 at "di", 0.15 at "cial"), and the /dʒ/ came out as a
   squeak. → **Look-ahead**: the piece now comes from LA frames before the newest end, so the reader hears what
   follows it. One model file serves every look-ahead (the decoder runs on window frames the stream picks).
2. **The crossfade search moved the timing** at 35 % of the seams (up to 10 ms skipped or repeated). It was there to
   line up pieces made from different guesses; with look-ahead the pieces already line up, so the timing is kept
   (with no look-ahead it still searches, as before).
3. **A held note slid away**: the AI's pitch is mapped from the speaker's median, and holding a note for a second or
   two pulled the median there, so the output slid 2.5–3.7 half-steps back toward the voice's pitch in quarter-step
   stairs ("jumped up and down"). → The AI voice keeps its own median: a held note doesn't teach it, and once it
   knows the speaker it moves at most 0.01 half-steps per 10 ms (Natural keeps its own, unchanged).
4. **The intonation scaled the small fast wobbles too** (×1.7 at D: tracker noise, the little dips at consonants, a
   held note's flutter). → With look-ahead the frames on both sides are known, so the pitch line is lightly
   smoothed (±10 ms) and only the melody (a ±70 ms line) is made 1.7 times bigger; the fast part keeps the speaker's
   own size.
5. **Voice breaks**: frames the tracker calls unvoiced inside a voiced sound (a /dʒ/, a flicker in a held vowel) made
   the AI whisper for 10–60 ms. → Unvoiced gaps up to 80 ms inside a loud sound are bridged (not stops or pauses: the
   level must stay within 9 dB of both sides), only where the frames after are known (look-ahead).
6. **Loudness matching pumped**: the AI's loudness was set to the mic's every 10 ms from 20 ms windows; a 50 ms window
   keeps the speaker's loudness without pumping the AI's own (quality +0.03…0.05 Distill-MOS).
7. With the most look-ahead the 1.22 s window left only 0.3 s of past sound (words got worse past 200 ms), so the new
   files have a 1.92 s window: 1 s of past sound even at 700 ms of look-ahead, at the same speed (25 ms per piece).
   The encoder was rebuilt for it from the app's own 8-bit file (no download; same weights up to 8-bit rounding,
   features cosine 0.9997).

**Before → after** (Woman US at D; "today" = main 330be7e, the Realistic switch; default = the slider at 0.25,
150 ms look-ahead; most real = 1, 700 ms):

| measure | today | default | most real |
|---|---|---|---|
| "a judicial review": poor joins (of 6, where the listening sample had them) | 5 (0.64, 0.78, 0.17, 0.15, 0.64) | **0** (all ≥ 0.93) | **0** (all ≥ 0.98) |
| joins in loud parts, 10 clips + warm-ups: bad / poor / timing jumps / mean likeness | 207 / 490 / 335 / 0.67 of 847 | **7 / 51 / 0 / 0.94** of 867 | **7 / 41 / 0 / 0.95** of 899 |
| sudden sound changes / pitch jumps / voice breaks (10 clips) | 14 / 10 / 8 | 5 / 6 / 0 | 6 / 8 / 1 |
| held notes: jitter vs the singer's (4 notes; goal ≤ 1.3×) | 0.83 / 0.99 / 1.29 / **19.3** | 0.51 / 0.69 / 0.73 / 1.04 | 0.50 / 0.82 / 0.82 / 1.02 |
| held notes: slide over the note (half-steps) / sudden steps | −3.69 / −3.17 / −2.45 / −0.97; 6 steps | ≤ 0.10; 0 | ≤ 0.10; 0 |
| word errors, 70 men (30-clip subset) | 9.4 % (9.1 %) | 7.9 % (5.5 %) | **7.0 % (3.7 %)** |
| quality (Distill-MOS) | 3.51 | 3.64 | 3.62 |

(The listening-folder renders of `woman_us.md` were made with the research loop, without the app's loudness match: D
7.9 %, C 7.2 % words there; the app itself measured 9.4 % today on the same 70 clips.)

**The slider, position by position** (stream delay measured in real time with the app's own code: the output lined
up within 6 ms of it at 0 / 150 / 400 / 700 ms; the card adds one callback and what the mic and Swoopy Mic report,
about 20 ms on a MacBook):

| slider | look-ahead | stream delay | card shows | word errors (70 / 30) | quality |
|---|---|---|---|---|---|
| 0 (Faster) | Natural, no AI | 42 ms | about 0.08 s | (Natural) | |
| 0.05 | 0 ms | 285.5 ms | about 0.31 s | 9.8 % / 8.7 % | 3.56 |
| 0.19 | 100 ms | 385.5 ms | about 0.41 s | 7.7 % / 4.1 % | 3.64 |
| **0.25 (default)** | **150 ms** | **435.5 ms** | **about 0.46 s** | 7.9 % / 5.5 % | 3.64 |
| 0.32 | 200 ms | 485.5 ms | about 0.51 s | 7.9 % / 5.5 % | 3.64 |
| 0.59 | 400 ms | 685.5 ms | about 0.71 s | 7.4 % / 5.0 % | 3.63 |
| 0.86 | 600 ms | 885.5 ms | about 0.91 s | 7.4 % / 5.5 % | 3.62 |
| 1 (More real) | 700 ms | 985.5 ms | about 1.01 s | 7.0 % / 3.7 % | 3.62 |

**Why the default is 150 ms:** it is the first position where none of the joins in "a judicial review" is poor and
the joins reach their plateau (mean likeness 0.94; 100 ms still had one poor join at the "a" and twice the bad ones);
word errors are within noise from 100 ms on (one word = 0.2 points), so more look-ahead mainly buys a little more
clarity for the extra delay. Under 100 ms the stutter comes back (at 0 ms it is today's sound).

**Real-time checks** (the app's stream code paced in real time, 128-sample callbacks, `research/voicechanger/smooth/
bench/`): 75 s at the default and at the most-real end: 0 late pieces (pieces 47 ms on average, 55 ms worst; the time
kept in hand is now 70 ms, it was 60, so +10 ms of delay); look-ahead switches 150 → 700 → 0 → 150 ms while playing:
each made at a pause, 0 late pieces, no Natural fill-in; forced late pieces (200 ms extra every 8th piece): Natural
filled in 14 s with 0 frames at the speaker's own pitch. With a synthetic GPU load (a matrix job keeping the GPU 80 %
busy): 228 late pieces in 75 s, Natural filled in 4.3 s (6 %); the same with `--compute cpu`: 0 late (the CPU does
it in 49 ms, 31 % of a core). A game can still make the AI voice fall behind; switching to the CPU by itself when that
happens is a possible next step.

**Model files (look-ahead shape, not uploaded yet):** `contentvec_ahead` 82,964,437 B, `woman_ahead` 24,920,126 B,
`man_ahead` 24,920,084 B (in `voices/models.txt`), and `woman_us_ahead` 24,920,238 B (SHA-256 75c1816e…a3217a) for
Woman US. Made with `research/voicechanger/convert/convert_generator.py --context-ms 1000 --ahead-ms 700 --right-ms 40`
and `convert_contentvec.py --context-ms 1710` from weights rebuilt by `contentvec_from_app.py`; with `--ahead-ms 0` the
converter still makes the first shape byte for byte. Old voice files (first shape) still load: no look-ahead.

**Checks:** changer off 14/14 renders byte-identical to main; Natural (Woman and Man, 15 renders incl. `--live-sim`)
byte-identical to main; the Intel half under Rosetta says "needs Apple silicon" and its Natural render matches Apple
silicon's (largest difference 0.00005); no new compiler warnings; hidden previews of the card at 870×369, 588×575,
306×844 and 1300×640 (light and dark, Natural, first AI step, default, most real, loading, standing in, Intel). The
card is 33 pt taller (smallest windows 588×581 and 306×850; side by side 870×369 is unchanged).

**Left / not sure (3.1):** nobody has listened yet; the jitter goal was met on synthetic held notes, not a real singer;
Whisper hears the "a" of "a judicial review" as "its" in most versions (also today's), a breathy start the AI voice
adds; slider moves in a room that is never quiet switch after 3 s with a crossfade (heard as a small jump); the delay
on the card uses what Core Audio reports for the mic and Swoopy Mic (a live measurement is still to do).

## 3.1.1: the AI voice starts right away again, and held notes stay put (2026-10-16)

**What the owner heard in 3.1.0:** through the Test button, slider at the right end, noisy room: "sounds worse than
when there was no slider at all … like the intel mac fallback … super staticky"; and "the notes holding and changing
are still a problem for each mode". Cause of the first (research/voicechanger/results/regression31.md): a new 3.1.0
AI stream played Natural with no delay until it found a quiet stretch as long as the look-ahead + 0.21 s (else 6 s),
so in a noisy room the 5 s Test recording was almost all Natural, and when the AI came in up to 1 s was heard twice.

**Fixes:**
1. *Start:* a new stream plays at its fixed delay from the start, like 3.0.0 (Natural fills in, delayed to the same
   point; silence until it gets there) and the AI takes over with its first piece, or as soon as the models are given
   to a stream made while they were loading. Look-ahead changes (slider moves) still wait for a pause, 1.2 s at most
   (was 3 s), so they are made within 1.5 s of the ask.
2. *Test:* with the AI voice on, the recording goes on for the AI's fixed delay after the countdown and is played
   from that point, so the clip is the 5 s that were said, in the AI voice.
3. *Card:* "· backup voice" after the delay (and the spoken description) whenever Natural plays instead of the AI:
   loading, before the first AI piece, and for a second or two after Natural filled in for a late piece (the stream now
   reports whether the AI is what plays, `VoiceStreamStats.aiNow`).
4. *Held notes, both modes (VoiceChanger.cpp):* the speaker's middle pitch (Natural's and the AI's own) no longer
   learns from held notes or moves while one is held: a voiced stretch (gaps up to 80 ms) whose slow pitch line (mean
   of its last 16 voiced frames: vibrato averages out) stays within 1 half-step for 0.4 s is a held note; a stretch's
   frames are learned when it is over (1.5 s late at most), so the start of a note (even a slow scoop) is never
   learned; the median is read between the histogram's quarter steps (no more stairs), and once the speaker is known
   Natural's moves at most 0.05 half-steps per 10 ms. `--changer-tune heldMode=0` gives 3.1.0's behaviour exactly.
5. *AI ceiling:* the AI pitch is eased into at most 11 half-steps above the voice's median (was 12). At 12 (about
   470 Hz for Woman) a note held there came out an octave low for a second or more and then jumped up (3.1.0 too);
   11 (about 440 Hz) stays whole. On men's speech it moves 0.3 % of the AI pitch frames (by 0.7 half-steps on average).

**Test button, simulated** (the app's stream code paced in real time, 128-sample callbacks, CPU, models in memory,
two American men talking on from the first moment; seconds of AI voice in what Test plays back: 3.1.0 = its first
5 s, 3.1.1 = the 5 s from the fixed delay on):

| input | slider 0.05 | slider 0.25 | slider 1 |
|---|---|---|---|
| talking, clean room | 4.66 → 4.89 s | 4.54 → 4.89 s | 3.99 → 4.88 s |
| talking, room noise −35 dBFS | 1.40 → 4.97 s | 1.24 → 5.00 s | 0.00 → 5.00 s |
| talking, room noise −25 dBFS | 4.28 → 5.00 s | 1.56 → 5.00 s | 0.00 → 5.00 s |
| talking, distant babble −30 dBFS | 1.72 → 4.98 s | 1.38 → 5.00 s | 0.00 → 5.00 s |
| 0.6 s pauses, clean | 3.90 → 4.19 s | 3.75 → 4.19 s | 3.20 → 4.19 s |
| 0.6 s pauses, noise −35 dBFS | 4.28 → 5.00 s | 4.12 → 5.00 s | 0.00 → 5.00 s |
| noise −35, models still loading at the press | 1.40 → 4.95 s | 1.24 → 5.00 s | 0.00 → 5.00 s |

(Clean rows: the rest is silence, the pauses between sentences and the 0.3 s before the first word, where the AI is
silent too. "Loading" here is the CPU load from the cache, 0.3–0.6 s: the AI came in as soon as it was loaded.) The AI
is now first heard at the fixed delay (0.26 / 0.41 / 0.97 s), in 3.1.0 after 3.3–6.3 s in noise. Nothing is heard twice
any more (the output's lag behind the input stays at the fixed delay; 3.1.0 repeated 0.28 / 0.44 / 0.98 s at the
handover).

**Held notes** (real sung notes from VocalSet, CC BY 4.0, used only for testing, never shipped: 10 men's
notes at 127–264 Hz → Woman, 6 women's at 261–536 Hz → Man, straight, forte with vibrato and soft; each after 8 s
of talking and also cold; plus 6 synthetic notes; Praat pitch over the held part. Slide = how far the output moves
from the first to the last 0.5 s beyond what the singer did × intonation; steps = 30 ms jumps > 0.3 half-steps the
singer's moves don't explain; 3.1.0 → 3.1.1):

| | slide, mean / worst (half-steps) | steps | octave flips (frames) | jitter vs the singer (median) |
|---|---|---|---|---|
| Natural, real notes, offline (32) | 3.12 / 16.9 → **0.07 / 0.28** | 259 → 17 | 278 → 0 | 1.35 → 0.94 |
| Natural, real time, men after talking (14) | 2.40 / 15.1 → **0.09 / 0.21** | 77 → 0 | 111 → 0 | 0.99 → 0.71 |
| Natural, real time, women (8) | 0.32 / 1.92 → **0.03 / 0.08** | 8 → 1 | 0 → 0 | 1.43 → 1.34 |
| AI 0.05 / 0.25 / 1, real notes, offline (32) | 1.29 / 0.92 / 0.93 → **0.06 / 0.07 / 0.08** (worst 12.3 → 0.33) | 80 / 76 / 84 → 3 / 0 / 0 | 202 / 160 / 292 → 0 | 1.67 / 1.08 / 1.14 → 1.54 / 1.15 / 1.22 |
| AI, real time, men after talking (14) | 2.51 / 1.65 / 1.65 → **0.12 / 0.12 / 0.12** | 39 / 18 / 17 → 0 / 0 / 0 | 117 / 218 / 171 → 0 | 1.93 / 1.03 / 1.05 → 1.17 / 0.94 / 0.94 |
| AI, real time, women (8) | 0.62 / 0.60 / 0.61 → **0.05 / 0.03 / 0.04** | 16 / 20 / 22 → 11 / 16 / 12 | 0 → 0 | 2.65 / 2.27 / 2.51 → 1.85 / 1.89 / 1.71 |
| synthetic notes, offline (12): Natural / AI 0.25 | 1.45 → 0.02 / 0.06 → 0.03 | 22 → 0 / 24 → 25 | 0 | 0.96 → 0.85 / 1.29 → 1.21 |

The remaining AI steps are on one synthetic woman's flat note (our pitch tracker reads that made-up vowel 0.7
half-steps high now and then, in 3.1.0 too) and, at 0.25 in real time, during late pieces. The AI's jitter ratio is
above 1.3 on very steady notes (and at slider 0.05, where there is no look-ahead to smooth with), but the extra
wobble is about 0.01 half-steps (1 cent). Natural's remaining "steps" are at vibrato turns (its bigger vibrato lags
the singer's by ~20 ms), not stairs. At the pitch feed (no measuring noise) the tracker made 0 octave flips on these
notes and held the pitch through 21 rough frames (the same before and after).

**Speech (Natural), 3.1.0 → 3.1.1,** a4 sets warmed up with 8 s of the same speaker: VCTK men → Woman (40 clips)
judged a woman 100 → 100 %, word errors 5.3 → 5.3 %, Distill-MOS 3.49 → 3.48, pitch median 233 → 234 Hz, 5–95 %
spread 15.9 → 16.5 half-steps; VCTK women → Man (40) 100 → 100 %, 6.0 → 6.3 % (one word), 3.71 → 3.72, 112 →
113 Hz, 12.1 → 11.7; `say` men → Woman (70) 100 → 100 %, 20.5 → 19.8 %, 1.88 → 1.88, 218 → 218 Hz, 12.9 → 13.1;
`say` women → Man (70) 100 → 100 %, 7.8 → 7.4 %, 2.86 → 2.83, 111 → 111 Hz, 7.3 → 7.4. Frame by frame the output
pitch moved 0.11–0.32 half-steps on average (median 0): the middle pitch now changes when a stretch of voice ends
instead of every frame, and smoothly.

**Checks:** changer off 14/14 byte-identical to a fresh main build; with `heldMode=0,aiMaxSt=12` Natural (Woman,
Man) and the AI (0.05, 0.25) are byte-identical to 3.1.0 (6/6); forced late pieces (200 ms extra every 8th piece,
60 s at 0.25 and 1): 0 frames at the speaker's own pitch (Natural filled in 2.2–2.5 s of voice); slider moves in a
room that is never quiet: made 1.21–1.33 s after the ask (0.13 s when a pause came); 60 s runs: 0–4 late pieces a
minute in both versions, with or without slider moves (pieces of 80–110 ms while the Mac was busy: moving wallpaper,
WindowServer, kernel_task), 0 in the quieter runs; Intel half says "needs Apple silicon" (Natural matches Apple
silicon within 0.00011); 36 compiler warnings (as main); hidden previews of loading / backup voice / AI at 870×369,
588×581, 306×850 (dark and light) fine. Live microphone tests skipped (the owner's app was open). Tools:
`research/voicechanger/r311/` (git-ignored).

## 3.2: fewer stutters, cleaner joins, less buzz (Stage A of `notes/realism-3.2-plan.md`, 2026-10-18)

**What the owner heard in 3.1.1:** the AI voice still stutters at the most-real end (about 1 s of delay) and sounds
buzzy at every position; Discord, a game and a browser usually run at the same time. The card did not say "backup
voice" when it stuttered, so the joins between pieces and the pitch feed were part of it, and late pieces too.

**What changed** (all in `Sources/Voice/VoiceModel.mm`, the ±15 limit in `VoiceChanger.cpp`; every change has a
`--changer-tune` key, and `ai32=0` turns all of them off: the AI voice is then byte for byte 3.1.1's):
1. *Time in hand grows with the slider, delay unchanged* (`aiSplit`, `aiAheadMax` 400): up to 150 ms of look-ahead
   nothing changes; above, part of the look-ahead the slider asks for is kept in hand for a slow piece instead. Slider
   1: 400 ms look-ahead + 370 ms in hand (3.1.1: 700 + 70); 0.86: 350 + 320; 0.59: 260 + 210; 0.32: 170 + 100; 0.25 and
   below as before. The read point moves with the existing quiet-moment switch (both read points must have reached it;
   10 ms crossfade). The fixed delay is the same at every position (0.05 / 0.25 / 0.59 / 1: 285.5 / 435.5 / 685.5 /
   985.5 ms in both versions, so the card's number is unchanged).
2. *Warm CPU copy of the voice generator* (`aiAutoChip`): when the generator runs on the GPU, a CPU-only copy is
   loaded and warmed too (~50 MB, part of the load). Per piece the worker sees how long before the sound thread
   needed it the piece was ready; 2 late or 4 tight (< 15 ms) of the last 10 move the generator to the CPU copy. Back
   to the GPU only after 30 s and only if the CPU runs late too (2 late or 8 tight of 10); a failed try goes straight
   back on its first late piece and doubles the wait (up to 4 min). `--changer-stats` shows the chip.
3. *Grace before Natural* (`aiGraceMs` 20): a late piece plays on into the last piece's tail (a copy kept apart, so
   the final block can't change it mid-way) for up to 20 ms; if the piece lands, a 10 ms ramp goes from the tail into
   it, else Natural fills in as before.
4. *Joins:* decoder margins 50 / 50 ms instead of 60 / 40 (`aiLeftMs`); the crossfade adapts to how alike the two
   pieces are (equal gain when alike, equal power when not, `aiFadeAdapt`); each piece keeps its own loudness gains
   across the crossfade (`aiJoinGains`); loudness windows reach before a piece's start (`aiGainTwoSided`).
5. *Buzz:* gaps are bridged only over smooth sound 12 dB above the room's noise, and only up to 5 frames
   (`aiBridgeStrict`, `aiGapFrames`); voiced bits shorter than 40 ms alone in a pause get no tone (`aiShortRunMs`);
   hissy frames (> 0.3 zero crossings per sample) never get a tone (`aiHissCross`, covers the hold after a vowel);
   the loudness match looks at 120 ms instead of 50 (`aiGainMs`) and lifts the AI voice only as far as the mic is
   above the room's noise: 0 dB at 6 dB above it, the full +18 dB from 20 dB above, down to -10 dB at 3 dB above
   and below (`aiGainCap`, `aiPauseDb`; a ramp, not the plan's step, which pumped); no ±15 half-step limit on the AI
   pitch, only its band and 60-880 Hz (`aiClampMode`; Natural keeps the limit, byte-identical); a peak limiter at 0.6
   on each finished piece, 5 ms look-ahead into the tail, 80 ms release (`aiLimit`).
6. Tried and not kept: near search around a fixed point (`aiSolaMode=3`: fewer poor joins, 61 vs 75 of 1706, but
   214 timing moves of 1 ms or more and more sudden changes, 26 vs 21); one vowel lead-in frame instead of three
   (`aiOnsetFrames=1`: 0.6 s per 100 s less tone over consonants, but 1-2 points more word errors); a lower AI band
   top (`aiBandSt=8,aiMaxSt=10`: share above 400 Hz 5.6 -> 5.3 % only); a deeper pause cap (-20 dB: hum 3-4 %
   but quality in noise -0.15 to -0.3); the real-time thread policy (`aiRealtime`, built, off: it could only be
   judged under CPU load, which was not run, see below). Starting on the CPU copy (`aiStartChip`) was not measured
   (needs a GPU run).

**How it was measured** (all offline renders with the app's own `--render-voice --compute cpu`, the owner's app was
open; 3.1.1 = a build of `git archive` of main f7757c3; tools in `research/voicechanger/`, scratch in the session):
- 75 clips: the 70 men's clips of `meas70` (VCTK p258 p285 p304 p363 ×10, p311 p334 ×5, p345 p360 ×10, fetched
  again with `woman_us/fetch_clips.py`: same clips, same sentences) + `say` Daniel ×5, each after ~8 s of the same
  speaker (`smooth/mkwarm.py`), Woman at 235 Hz / 1.7. Words (Whisper base.en) and quality (Distill-MOS) on the 70
  (`regression31/measure31.py`, which also gives the buzz number); joins (`smooth/seams.py`, traces); on the
  regression31 set of 20 (p311 p334 p258 Daniel ×5): sudden changes / pitch jumps / voice breaks (`smooth/disc.py`),
  tone over consonants (`regression31/addvoice.py`), pitch mapping (`regression31/pitchmap.py`).
- Noise: `regression31/mknoisy.py` (pink room noise at -35 and -25 dBFS on p311 p334 Daniel, 15 clips each),
  `regression31/noisem.py` (hum = share of noise-only moments the output is voiced).
- Held notes: VocalSet (CC BY 4.0; the zip's offsets read 4 GiB too far by Python, corrected), 16 real notes warm +
  cold (`r311/tools/makeheld.py`, `heldaudio.py`).
- A louder mic: the 20 clips +10 dB (clipped at full scale like a real mic); samples above 0.7 counted.
- Real time: the stream code paced in real time (`smooth/bench/stream_test.mm`, 128-sample callbacks, models in
  memory, CPU compute), speech with 0.6 s pauses, 75 s. The Mac was busy the whole time with other work (pieces 52-75
  ms on average instead of 49, worst 75-160 ms), which is about the "busy Mac" case. A busy GPU was simulated by making
  every piece 60 ms slower while the generator is on its own chip (`aiSlowMs=60,aiSlowChip=1`, generator on CPU +
  Neural Engine so no GPU was used); the real GPU-load test (`gpuload.swift`) and the 8-busy-threads test were not
  run: the owner's Swoopy was recording from the G522 headset mic every time it was checked.

**Look-ahead at the most-real end, picked first** (3.2 changes off, 75 clips; "within noise of 700": words ≤ +0.6
points, MOS ≥ -0.02, poor joins ≤ +0.5 points):

| real look-ahead | words (70) | MOS (70) | poor / bad joins (75 clips) | pitch jumps (20) |
|---|---|---|---|---|
| 700 ms (3.1.1) | 7.66 % | 3.627 | 6.2 % / 1.04 % | 12 |
| 600 | 7.44 % | 3.629 | 4.5 % / 1.48 % | 15 |
| 500 | 7.22 % | 3.631 | 6.6 % / 2.22 % | 14 |
| 450 | 8.10 % | 3.630 | 5.8 % / 1.31 % | 14 |
| **400** | 7.44 % | 3.639 | 5.5 % / 1.05 % | 16 |

All four are within noise of 700 on the plan's three tests, so the smallest, 400 ms, is used: 370 ms in hand at the
right end instead of 70. (Pitch jumps were not one of the tests; 12 vs 16 on 20 clips is about noise, √14 ≈ 4.)

**Before → after, against the plan's pass marks** (3.1.1 → 3.2; slider 1 unless it says 0.25; ✓ met, ✗ missed):

| pass mark | 3.1.1 | 3.2 | |
|---|---|---|---|
| late pieces, idle (busy Mac, CPU), slider 0.25 / 1, 75 s | 14 / 81 (Natural 0.07 / 1.71 s) | **0 / 0** | ✓ |
| late pieces, busy GPU simulated (+60 ms per piece), 0.25 / 1 | 467 / 467 per 75 s (Natural 31 / 34 s) | **2-3 per 75-120 s / 0** | ✗ at 0.25 (1-2.4 a minute vs ≤ 1: 2 late pieces to notice the busy GPU, then 1 per try back to it, the tries 30 s, then 1, 2, 4 min apart; the CPU copy itself ran late now and then on this busy Mac), ✓ at 1 |
| late pieces, GPU 80 % busy (real) / 8 busy CPU threads | 228 per 75 s in 3.1 | not measured (owner's mic in use) | – |
| Natural ≤ 0.5 s a minute | see above | 0.04-0.10 s a minute (simulated busy GPU, 0.25), 0 elsewhere | ✓ |
| delay at 0.05 / 0.25 / 0.59 / 1 within 2 ms | 285.5 / 435.5 / 685.5 / 985.5 ms | the same | ✓ |
| slider moves 150 → 700 → 0 → 150 | made 1.29 / 1.29 / 0.49 s after the ask, 7 late | the same times, **0 late**, 0 Natural | ✓ late, ✗ "nothing lost or doubled": two of the three moves found no pause within 1.2 s in either version and were crossfaded |
| Test button: AI seconds in the 5 s clip (6 inputs × 0.05 / 0.25 / 1) | 5.00 (talking), 4.73 (0.6 s pauses: 0.27 s silence before the first word) | the same | ✓ (the 4.73 is silence, as in 3.1.1) |
| poor / bad joins, slider 1 (20-clip set) | 5.4 % / 0.91 % | **3.0 % / 0.18 %** | ✗ poor (≤ 2 %), ✓ bad |
| poor joins at 0.25 (20-clip set) | 7.0 % (bad 0.83 %) | 4.3 % (bad 0.24 %) | ✗ (≤ 3 %) |
| poor / bad joins, all 75 clips, slider 1 / 0.25 | 6.2 / 1.04 %, 9.7 / 1.05 % | 4.6 / 0.73 %, 6.4 / 0.77 % | – |
| sudden changes (20 clips), 1 / 0.25 | 21 / 11 | **12** / 11 | ✓ (≤ 15) |
| pitch jumps, 1 / 0.25 | 12 / 16 | 15 / 17 | ✗ (≤ 13; from the shorter look-ahead and the freed pitch rises) |
| voice breaks, 1 / 0.25 | 7 / 6 | 7 / 7 | ✓ (≤ 8) |
| timing jumps ≥ 1 ms | 0 | 0 | ✓ |
| hum in noise-only moments, -35 dBFS, 1 / 0.25 | 32 % / 40 % | **7 % / 3 %** | ✓ (≤ 10 %) |
| hum, -25 dBFS, 1 / 0.25 | 42 % / 70 % | 11 % / 16 % | ✗ (≤ 10 %) |
| tone over consonants (s per 100 s), 1 / 0.25 | 5.09 / 5.29 | 4.70 / 4.78 | ✗ (≤ 3.0; about half of what is left the model voices by itself with no pitch in its feed) |
| AI pitch frames held at the ±15 limit (p311 / p334 / Daniel) | 16 / 23 / 15 % | **0 %** | ✓ (≤ 2 %) |
| share of the voice above 400 Hz, 1 / 0.25 | 3.3 % / 3.4 % | 4.3 % / 5.6 % | ✗ (≤ +1 point; all of it from the freed rises: with the old limit kept it is 2.6 %) |
| octave flips on the held notes (32) | 0 | 0 (slide 0.07 vs 0.09 half-steps, jitter ratio 1.06-1.14 vs 1.14-1.28) | ✓ |
| samples above 0.7, normal mic / 10 dB louder | 0 / 0.91 % (peaks up to 2.0) | **0 / 0** (peak 0.600) | ✓ |
| words (70 clips), 1 / 0.25 | 7.66 % / 8.53 % | 8.10 % / 8.32 % | ✗ at 1 (+0.44, bar +0.4: 3 words of ~680), ✓ at 0.25 |
| quality (Distill-MOS, 70 clips), 1 / 0.25 | 3.627 / 3.645 | 3.635 / 3.644 | ✓ (≥ -0.02) |
| buzz number (pulse clarity, 20 clips; real voices 63-100) | 75.8 / 75.8 | 76.0 / 74.5 | – |
| 3-8 kHz flatness, 1 / 0.25 | 0.031 / 0.033 | 0.031 / 0.034 | – |

In noise: the voice stands 4-13 dB further above the room's noise (-35 dBFS: 14.5 → 19.0 dB; -25: 5.8 → 17.1 dB),
words at -25 dBFS 80 → 70 % (slider 1) and 88 → 74 % (0.25); quality at -35 dBFS 3.62 / 3.68 → 3.65 / 3.66, at -25
dBFS 2.85 / 2.80 → 2.74 / 2.68 (lower: the voice is turned down where it is barely above the noise).

**What each part did** (slider 1, 20-clip set unless noted): margins 50 / 50: poor joins 4.4 → 3.0 %, bad 0.64 →
0.18 %; the joins' crossfade and gains changes: no measurable change (sudden changes 19 vs 21, quality and words
equal; also at 0.25); 120 ms loudness window: sudden changes 20 → 12, quality -0.017, and in noise quality +0.1
to +0.24; pause cap (with 120 ms): hum at -35 dBFS 37 % (no cap) → 7 %; no ±15 limit: pitch jumps +2, share above
400 Hz 2.6 → 4.2 %; hiss rule, short-run rule, stricter bridging, limiter: each within noise on words and quality.
The time in hand alone took idle late pieces at the right end from 81 to 0 and the forced-late test (+200 ms every
8th piece) from 299 late to 0; the CPU switch took the simulated busy GPU at 0.25 from 467 late to 2-3; the grace
halved the time Natural played when pieces came a little late (2.66 → 1.41 s in 75 s).

**Report only: Woman at 235 Hz / 1.7 (the owner's pick) vs 220 / 1.5**, 3.2, 20 clips: buzz number 74.5 → 80.8
(0.25) and 76.0 → 82.7 (1) (clearer pulses, less buzz; it follows the pitch); share above 400 Hz 5.6 → 4.6 % and
4.3 → 3.1 %; words 10.5 → 8.6 % and 9.3 → 9.9 %; quality 3.80 → 3.81 and 3.77 → 3.78; median pitch 233 → 219 Hz.
Not changed (the owner's choice).

**Checks:** with `--changer-tune ai32=0` the AI voice is byte-identical to 3.1.1 (5/5: Woman 0.05 / 0.25 / 0.59 /
1, Man 0.25, CPU); Natural 15/15 identical (with and without the key, half strength, `--live-sim`); changer off 14/14
identical; 36 compiler warnings (as main); the Intel half says "Realistic mode: needs Apple silicon". Not run: live
microphone tests, the real GPU-load test, the 8-busy-threads test and the GPU-vs-CPU start comparison (the owner's
Swoopy was recording from their headset mic each time it was checked); hidden previews (no window code changed).

**Left / not sure:** nobody has listened (`~/Downloads/Pitch Shift 3.2 compare/`); the pass marks missed above
(poor joins 3.0 / 4.3 % vs 2 / 3 %, pitch jumps 15 vs 13, tone over consonants 4.7 vs 3.0, hum at -25 dBFS 11-16 %,
share above 400 Hz +1.0 / +2.2 points, words +0.44 at slider 1); the CPU copy adds ~50 MB and part of a second to
the load; `aiClampMode=0` puts the old pitch limit back if high notes sound strained; slider moves in a room that is
never quiet still crossfade, as in 3.1.1.

## 3.3: trained Woman and Man voices (2026-10-26)

**What changed:** the AI voice files only. Woman = `woman_us_t200_ahead.mlmodelc`, Man = `man_t200_ahead.mlmodelc`:
the voices trained on Kaggle (Stage B4 of `notes/realism-3.2-plan.md`: RVC v2, 200 epochs, about 40 minutes of
recordings of the same 8 VCTK speakers each, starting from the 3.1-3.2 blends; Woman 4.4 h, Man 4.8 h on a T4), then
converted exactly like the shipped `_ahead` files (`convert_generator.py --context-ms 1000 --ahead-ms 700 --right-ms
40`, 8-bit). The zips hold the converted files renamed, byte for byte the files the blind test was rendered with. New
names so the "first time" note (`aiVoicePrepared.<id>.<model>.<size>`) and Core ML's cache treat them as new. The
`natural` blocks, the pitch (Woman 235 Hz / 1.7, Man 112 Hz / 0.75) and the speech reader `contentvec_ahead` are
unchanged; the blind test was rendered with these same values. No code changed.

**Why these two** (`research/voicechanger/results/trained.md`; blind folder `~/Downloads/Pitch Shift trained voices
compare/`): the owner picked trained epoch 200 for Woman in 5 of 5 sentences and for Man in 3 of 4 (the miss: sentence
09, Man at the default slider 0.25, where they liked the blend better). By the numbers both are far above the blends in
quality (Distill-MOS +0.43 to +0.48) with no more word errors, much cleaner in a noisy room (Woman: hiss between words 12-19 dB
lower in a -35 dBFS room), Man's voice print much closer to real men; Woman's voice print slightly further from real women than the blend
and less American by the accent model (US share 0.86-0.89 → 0.63-0.64, real American women 0.59). Every trained epoch joins its
0.16 s pieces less smoothly ("poor" joins 3-7 % → 14-23 %; the audible-jump counts did not rise).

**Checks** (offline, `--compute cpu`; 3.2.0 = a build of main 501753f; both unlocked builds unless noted):
- Changer off byte-identical to 3.2.0: 14/14. Natural byte-identical (3 clips × Woman/Man × plain/Deeper when
  slow/half strength + `--live-sim`): 21/21. `--as-free` byte-identical: 6/6.
- The AI voice, 11 clips (Woman: `say` Daniel, Fred, VCTK p258 p285 p304 p363; Man: Samantha, VCTK p277 p283 p323
  p329; each from a cold start) at 0.05 / 0.25 / 1: 0 late pieces and 0 s of fill-in in all 33 renders (same for the
  blends), fixed delay 214 / 364 / 614 ms (as 3.2.0). Median pitch (Praat): Man 110 Hz at every position (blend 110);
  Woman 205-207 Hz on average (blend 211-212), within 5 Hz on 4 clips and 10-16 Hz lower on the two VCTK men
  p304 / p363 (cold 3 s clips; warm, on 70 men, trained.md has 222 Hz for both).
- Real time (`smooth/bench/stream_test.mm` built against this branch's `Sources/Voice`: 128-sample callbacks, CPU,
  60 s each, new and old voices alternating, on battery with Steam / a busy system task running). At normal priority
  (as the app): late pieces at 0.25 new Woman 0 / Man 0 (old 5 / 1), at 1 all 0. At `nice 15` (round 1, busier):
  at 0.25 new Woman 3 (0.24 s filled in), old Woman 8 (0.59 s), new Man 12 (3.2 s); at 1 all 0. Pieces 48-56 ms on
  average for both. While a game (Geometry Dash) was in front, pieces on the CPU took 256-281 ms for 160 ms of sound
  with or without nice, so the AI voice falls behind then; same model shape and cost as the blends.
- Live (the guard passed: no app open, no mic in use): `--test-voice --mic "MacBook Pro Microphone" --file …
  --compute cpu`, 30 s each, with the locked build and this Mac's key: Woman at 0.25 and Man at 1: AI voice playing
  after 1.0 s, 0 late pieces, 0 s filled in, 0 dry-outs; card "about 0.47 s" / "about 1.02 s". The two
  `aiVoicePrepared` keys these tests wrote were removed again, so the owner sees the real first-time note.
- Locked build (public key + the one older key from `issued.txt`): with no key it plays exactly like `--as-free` of
  3.2.0 and 3.3.0 (5/5) and refuses the Soundboard and adding voices; with this Mac's saved key it unlocks and plays
  the AI and Natural voices byte for byte like the unlocked build; the private key and the old secret are not in the
  app; no key in the branch.
- 36 compiler warnings (as main); app and driver both chips; the Intel half says "Realistic mode: needs Apple
  silicon; Natural mode is used" and its Natural matches Apple silicon within 0.00011; 18 hidden previews (870×369,
  588×581, 306×850, light, Intel, locked) fine.
- Updating: the installer replaces the whole app ("upgrade"), so the old `woman_us_ahead` / `man_ahead` folders go
  (3.1.1 installed over 3.0.0 kept none of 3.0.0's files). Old `aiVoicePrepared` keys and Core ML cache entries stay
  behind, unused; the app has never cleaned those up. Old model folders left in a Voices folder with no json are
  ignored (checked with `--voices-dir`: the list shows only the built-in Woman and Man, with the new files).

**Left / not sure:** nobody has listened in the app yet (only the blind test files); the joins between pieces are
measurably less smooth (audibility unknown); Man at the default slider was the one blind-test miss; the Woman sounds
less American to the accent model; at release, upload `woman_us_t200_ahead.mlmodelc.zip` and
`man_t200_ahead.mlmodelc.zip` (in `research/voicechanger/models/`) and put the tag in place of PLACEHOLDER in
`voices/models.txt`.

## 3.4: steady hums stay steady, hummed tunes keep their tune (2026-10-27)

The owner: a steady, comfortable hum "sounds funny, like the voice jumps unnaturally. more obvious on longer tests";
"sighs, laughter and even humming can sound a bit unnatural (humming a tune with lips closed sometimes comes across
differently, such as using lip movement to make the notes)". Measured offline on the owner's own recording (68 s: a
10 s hum, a hummed tune, laughs, a sigh, a whistle, claps, typing; never in git), VocalSet songs and long notes
(CC BY 4.0), 18 free laugh and sigh recordings (Wikimedia Commons: CC0, CC BY, public domain) and the 3.3 speech sets.
Full report: `research/voicechanger/results/hum.md`.

**Causes, in order:**
1. **A hum longer than ~4.6 s became "room noise" (code; both voices, every slider position).** A frame is voiced only
   10 dB above the noise floor, and the floor was the quietest 10 % of the last ~5 s of *all* frames. A steady hum
   fills those 5 s, so the floor rose to the hum itself and from ~4.6 s on the AI voice was told "no pitch": it
   whispered, broke up and pumped for the rest of the hum. This is why longer tests were worse.
2. **The trained Woman voice itself wavers on a long, quiet hum (model).** Told a steady 200 Hz it stays on it only
   55 % of the owner's hum (the rest: an octave or a twelfth low, or no pitch); the 3.2 blend with the same code: 100 %.
   Louder input helps.
3. **Tunes: the Woman's livelier melody stretched the steps and squashed the top (code).** The AI pitch moves 1.7× as
   far as the speaker's (good for speech): a hummed tune's steps came out 1.5-1.7× too big, and anything high was
   pressed into the band's top (444 Hz): a man singing a song came out on one note.
4. **Soft note ends dropped out (code, quiet mic).** Nothing under -50 dBFS was voiced; the owner's hum ends and soft
   tune notes sit at -50 … -54 dBFS.
5. Laughs and sighs (not changed): mostly breathy (the tracker calls 0-47 % of a laugh voiced), squeals above 600 Hz
   are not tracked, voiced laugh peaks sit at the band's top (15-100 % of their frames), the model's laugh output is
   choppy whatever the limiter or loudness cap does; the 0.6 limiter holds loud laughs at -4.4 dBFS peak (without it
   up to +10 dBFS). "Higher when fast" is never used while a changer voice is on (one at a time).

**What changed** (`--changer-tune hum34=0` = 3.3 exactly: check1 14/14 and 10/10 renders sample-identical):
- `VoiceChanger.cpp`: the noise floor learns only from frames that are not voiced (`floorMode`; after 20 s of voice
  with no 0.3 s pause they count again, so a steady tone in the room still becomes the floor: `floorVoiceS`,
  `floorGapFrames`); a voice already going on may fade to -58 dBFS and 6 dB above the floor (`voicedKeepDb` 8,
  `voicedKeepFloorDb` 4); sung passages (`singMode`: more than 45 % of the last 200 voiced frames note-like, i.e. the
  last 15 voiced frames within 1 half-step; off below 30 %; speech stays under 38 % on every set tried): the AI pitch
  keeps the tune's steps (intonation 1, gliding over 0.5 s, never while a note is held), a passage sung more than
  5 half-steps above the speaker's median (its 1 s mean) moves down as a whole, the medians don't learn from it.
- `VoiceModel.mm`: when the sound around a piece is a steady note (≥ 30 voiced frames within ±0.4 s, 80 % within
  0.75 half-steps), the speech reader hears its window lifted toward -20 dBFS (≤ 24 dB, 2 dB per piece, peaks under
  0.9; `aiHumLiftDb`, `aiHumLevelDb`). The output still follows the mic's loudness; speech never qualifies.

**Numbers** (offline, CPU, Woman, "More real" 1 unless noted; 3.3.0 → 3.4):
- Owner's hum: output with a clear pitch 68 → 95 % (second half 42 → 92 %), pitch jumps 49 → 12 per 10 s, breaks
  51 → 9 per 10 s, level jumps 200 → 52 per 10 s; on the pitch asked for 767 of 940 frames (3.3.0: 404, it stopped
  asking after 4.7 s). Slider 0.25 the same (95 %, 11 jumps, 8 breaks).
- Owner's tune: steps 1.54× → 1.08× the sung size, AI range 141-443 → 145-374 Hz, breaks 12 → 9 per 10 s, octave
  flips 10 → 4, poor joins 28 → 15 %.
- Songs (VocalSet): men → Woman note steps 0.57× → 0.89×, voiced output 76 → 85 %, breaks 8.1 → 1.8 per 10 s;
  women → Man 0.77× → 0.97×.
- Speech (the 3.3 sets, same method as `results/trained.md`; 3.3.0 numbers reproduced exactly): MOS, voice print,
  buzz, flatness, pitch follow, joins and stutter counts equal (paired MOS +0.001…-0.008, ranges ±0.006-0.015);
  word errors +1 to +5 words of 284-457 (1-3 clips). The steady-note lift changes no man's clip (all 70
  sample-identical at both sliders) and 9-14 of the 40 women's only slightly (-35 … -46 dB, a few monotone moments).
- Real time (stream test program, 128-sample callbacks, CPU, 60 s, speech then the owner's hum + tune looped, 2
  rounds): 0 late pieces in all 8 runs (3.3.0 and 3.4, sliders 0.25 and 1); delay 435.5 / 985.5 ms as before; pieces
  36-49 ms on average, worst 50-58 ms (the Mac was busy with other renders).
- Changer off byte-identical to main 14/14; 36 warnings as main; app and driver both chips.

**Tried and left out** (numbers in the report): the crossfade searching ±2.5 ms for the best fit (`aiSolaMode=3`):
joins on the hum 20 → 10 % poor, on the tune 15 → 6 %, on speech 15.0 → 13.1 %, but sudden sound changes on speech
29 → 41: no. Lifting the speech reader's level all the time (not only on steady notes): hum on pitch 84 %, but quiet
speech MOS -0.06 (±0.04): no.

**Left:** the trained Woman still wavers on ~1 in 5 frames of a long quiet hum (model; the next training run adds
hums); a passage sung high slides down to its place over the first 1-2 s; laughs and sighs unchanged; nobody has
listened; no live mic test. Listening folder `~/Downloads/Pitch Shift 3.4 hum compare/`.
