# Voice "buzz" in Natural style: plan

Owner's report: "In the natural voice, my voice sounds 'buzzy' or 'fuzzy' like I'm saying Z with every word."
Natural = formants kept (Rubber Band live shifter, `FormantPreserved`). Cartoon = formants shifted (check it too).

## Likely causes (to check, most likely first)
1. **Rubber Band's formant keeping with the short window.** The live shifter with `WindowShort` looks at very
   short pieces of sound (about 10–20 ms). That is too short to see the separate harmonics of a low voice, so the
   "voice shape" (formant envelope) it measures wobbles from piece to piece. The wobble repeats at the shifter's
   step rate (about 100–400 times a second), which is exactly what a buzz or "z" sounds like.
2. **Our own code** around the shifter: the block/ring buffer hand-off, the ring start, the mono mix,
   clamping to ±1 (clipping would add buzz on loud words), and the reset when coming back from 0.
3. **Something in the live chain** (sample rate mismatch, drift correction, dropouts). Less likely: these would
   also hurt Cartoon and the plain tone test.

## Tests
- Speech from `say -o` (a male and a female voice, sentences with lots of voiced sounds and "z"/"s"),
  plus a made-up steady vowel (known pitch, so harmonics are easy to measure).
- Offline Swift test program (`scratchpad/voice-fix/`), same settings as `VoiceChain`:
  +3, −3 and +5 half steps, Natural and Cartoon.
- Rule out our code: live shifter called directly vs the same sound through a copy of our `render`/ring logic
  with callback sizes 512, 480, 1024 and odd sizes (333, 17, 1); the outputs should match sample for sample
  (after the one-block ring delay). Also check clamping (how often the output goes past ±1), stereo mixing,
  and the reset path.

## How to measure "buzz"
On voiced parts only (where the original has a clear pitch):
- **Noise between harmonics**: we know the pitch of the original at every moment, so we know where the shifted
  harmonics should be. Energy between the harmonics vs energy on them (in dB, lower is cleaner), 100 Hz–4 kHz.
- **Hiss/fizz**: 3–8 kHz energy compared to the original.
- **Step-rate wobble**: how much the loudness in bands wobbles at the shifter's block/step rates
  (e.g. 93.75, 187.5, 375 Hz) compared to the original.
- Also a "clean" offline reference (Rubber Band R3 offline, long window) to see what good looks like.

## Fixes to compare (and the delay each adds)
- Live shifter `WindowShort` vs `WindowMedium`.
- Formant scale tweaks (`rubberband_live_set_formant_scale`).
- Full R3 real-time stretcher (`rubberband_new` with RealTime | EngineFiner | FormantPreserved, and window options).
- R2 real-time stretcher (`EngineFaster`) with FormantPreserved.
- Aim: clean sound with total delay about 120 ms or less (it's for voice calls).

## How to verify
- Listening samples in `~/Downloads/Pitch Shift voice samples/`.
- After the fix: `--test-voice --file speech.aiff --steps 3 --out …` before/after through the real Swoopy Mic,
  run the same buzz measures on those recordings; `--test-voice --tone 440 --steps 3` must still read ≈523.3 Hz
  (and a Cartoon tone); measure the delay (tone start → first sound); `--test-button` still works.
- Keep: Natural/Cartoon switch while running, bypass at 0, live amount changes, no memory made on the sound
  thread, start only when an app listens.

## Results (2026-10-13)

Owner's saved setting at the time: +15 half steps (later +10). Mic: G522 LIGHTSPEED (USB, 48 kHz).

### Cause 1 (the buzz): Rubber Band's live shifter stops keeping formants at about 10 kHz
- Our own code was not the problem: the copy of `render`/ring gave exactly the same samples as calling the live
  shifter directly (callback sizes 512, 480, 1024, odd sizes), never clipped, and a live recording through Swoopy
  Mic matched the offline output sample for sample (match 0.9998) once cause 2 was fixed.
- Harmonics, noise between harmonics and wobble were all fine (as good as Rubber Band's best offline mode).
- But above ~10 kHz the live shifter does not correct formants in Natural: everything up there is moved up exactly like
  Cartoon (there is a visible seam at ~9.6 kHz). So every voiced word gets a hiss band above 10 kHz that the real
  voice doesn't have, which sounds like a "z". The more the amount goes up, the louder it gets.
- Energy above 10 kHz on voiced parts, vs the whole voice (male TTS voice; original −46 dB):

  | amount | live shifter (before) | new (after) |
  |---|---|---|
  | +3 | −31 dB | −45 dB |
  | +5 | −30 dB | −44 dB |
  | +10 | −30 dB | −45 dB |
  | +15 | −32 dB | −50 dB |

  Female voice (original −44.5 dB): +3 −30 → −43, +5 −27 → −43, +15 −27 → −48. Down shifts (−3) were fine
  before and after (nothing above 10 kHz). Same numbers through the real Swoopy Mic recordings.
- Rubber Band's R3 real-time stretcher with `PitchHighSpeed` has the same seam; `PitchHighConsistency` /
  `PitchHighQuality` don't. `WindowMedium` live shifter and formant scale tweaks don't help (same −32 dB at +15).
  R2 (`EngineFaster`) fixes the top band but is rougher (HNR 2–10 dB worse on vowels).

### Cause 2 (cut-outs): the voice chain restarted itself every few seconds
- Creating or closing our private combined device fires the "device list changed" listener, which rebuilt the
  chain, which fired it again. Gaps of 130–150 ms every 0.7 s at first, then every ~3.5 s, and the shifter
  started over each time. Fixed: rebuild only when the mic, Swoopy Mic, or a sample rate really changed.

### The fix
- Voice now uses `rubberband_new(rate, 1, RealTime | EngineFiner | WindowShort | PitchHighConsistency |
  FormantPreserved (Natural) or FormantShifted (Cartoon), 1.0, 2^(steps/12))`, `rubberband_set_max_process_size(4096)`.
  Live changes: `rubberband_set_pitch_scale`, `rubberband_set_formant_option`; `rubberband_reset` when leaving 0.
- Each callback: process the callback's samples, retrieve everything available into a ring. Start sending once the
  ring holds one callback + 20 ms (trim any overshoot the very first time); if it runs dry, wait for that again;
  every 0.5 s, if the ring never dipped below 20 ms + 5 ms, skip the extra. Checked offline at 16/24/44.1/48/96 kHz,
  amounts −24…+24, callbacks 1…4096 samples: no dry-outs or skips in steady use (only right after big amount jumps).
  (Replaced on 2026-10-14 by the smaller wait described under "Delay work" below.)
- Sound quality otherwise unchanged (HNR, noise between harmonics, wobble within ~1 dB on speech). On steady
  made-up vowels at +10/+15 the standard window is a bit smoother between harmonics, but costs 20–60 ms more delay
  (−3: 112 ms processing alone), so the short window was kept. Sample 7 lets the owner compare.

### Delay (as of 2026-10-13; newer numbers under "Delay work" at the end)
- Processing only (offline, 512-sample callbacks): before 58–83 ms, after 56–85 ms
  (+3: 59 → 66, −3: 60 → 76, +5: 62 → 60, +10: 73 → 62, +15: 83 → 60, −12: 74 → 85).
- Mic to Swoopy Mic, measured live with `--test-voice --tone 440` (same measuring code on both):
  +3: 87 → 92 ms, −3: 86 → 103 ms, +15: 99 → 79 ms.
- R3 standard window would be +3: 94 ms, −3: 112 ms, −12: 144 ms processing alone (too slow for calls).

### Checks done
- Tone pitch through the real chain (before the owner's call started): +3 Natural 523.5 Hz (expected 523.3),
  +3 Cartoon 523.5, +15 1046.5 (1046.5), −12 220.0, +2.37 504.5 (504.6). Speech recordings through Swoopy Mic
  at +3/+15 (male/female): no gaps, top band fixed, other numbers same as offline.
- Not run (owner was in a Discord call): `--test-button` and repeat device checks; see the report for commands.

### Listening samples
`~/Downloads/Pitch Shift voice samples/` (male voice; 2/5 are the old sound, 3/6 the fix, 7 the slower option,
9 a real recording from Swoopy Mic of the app as it was, with the cut-outs).

### Tools (scratchpad, not in the repo)
`rbtest.swift` (offline shifter variants), `sim.swift` (the new chain logic), `cushion.swift`, `buzz.py` (measures),
`lts.py`, `wavalign.py`, `gaps.py`, `final.py`.

## Delay work (2026-10-14, branch v2-voice-delay)

Owner: "The voice pitch filter causes a lot of delay." Measured with `--test-voice --mic "MacBook Pro Microphone"
--tone 440 --watch --seconds 60`: a made-up tone replaces the mic sound at the start of the chain, plays half of every
second, and the time from each tone start (the mic's own time stamp) to it arriving in Swoopy Mic is measured.
The mic's own hardware delay is not in these numbers (the MacBook mic reports 30 ms on top).

### Where the delay came from (+3, before)
| part | ms | can it shrink? |
|---|---|---|
| callbacks of 512 samples: one on the way in, one on the way out (+ 1.5 ms safety) | ~22 | yes: 128 samples → ~6 |
| Rubber Band itself (R3 short window: it needs ~53 ms of sound before it can hand back the middle of it) | ~50 | no, not without changing the sound |
| sound waiting in the ring ("one callback + 20 ms cushion"; the lowest point sat at ~16 ms) | ~16 | yes: ~2 |
| total, mic → Swoopy Mic | **88** | |
| (not measured above) the MacBook mic's own delay | 30 | no |

- It did **not** grow: 60 s at +3, −5 and +7, the delay stayed within ±2 ms, no dry-outs, no skips.
- Rubber Band's own part depends on the amount: +3 50 ms, −5 65 ms, +7 46 ms, +12 41 ms, −12 84 ms
  (`getStartDelay` − `getPreferredStartPad` + the most it ever holds back). It is the same at any callback size and
  at any sample rate (its window is a fixed length in time).
- Handing Rubber Band pieces of up to 4096 samples did not add delay: the callbacks were 512 samples, so it got 512
  at a time anyway, and everything it had ready was taken out right away.
- No sample-rate conversion in the chain: Swoopy Mic runs at the mic's rate; only the tiny clock correction.
- Rubber Band's "high quality" pitch option would cut 16 ms at −5 and 43 ms at −12 (up shifts unchanged), but it
  changes the Natural sound a lot (some bands differ by 15–29 dB, a hole around 6–10 kHz), so it was not used.
- Bluetooth headsets in call mode add their own 150–300 ms (handled on `v2-bluetooth-mic`), and the call app
  (Discord, FaceTime, a browser) adds its own on top. Neither is measured here.

### What changed
- Callbacks of 128 samples (256 above 48 kHz) instead of the usual 512 for the voice's private combined device.
  Other apps using the same mic keep theirs (checked: a second app recording the mic saw no change, no gaps).
- `VoiceRing.swift` (new): the waiting sound. It still starts at one callback + 20 ms (safe), but once the lowest
  point has been steady for 2 s it drops everything beyond a 2 ms margin, with a 5 ms crossfade (never a hard jump).
  If the sound left over gets very low (Rubber Band slowly falling behind, which happens at 16 kHz −1), it replays a
  few ms with a crossfade instead of running dry, and keeps a bigger margin. If it ever runs dry it fades out and back
  in (no click). When the amount changes, or "Deeper when slow" slides the pitch, Rubber Band can pause for a moment
  (most of all when the pitch leaves exactly 0), so the waiting sound is topped up to 12 ms at the start of a change
  (crossfaded) and only trimmed back after 6 s with no change; dips in that time don't grow the margin.
- The shifter itself is unchanged: `--render-voice` output is byte-identical to before (male/female, +3, +3
  Cartoon, +3 middle style, −5, +7, +7 Cartoon).
- `--test-voice --watch` prints the delay parts at the start and, once a second, the waiting sound, dry-outs,
  trims, replays, overloads and the measured delay. `--buffer N` asks for another callback size.

### Offline model (the app's own VoiceRing.swift + real Rubber Band, speech, 60 s)
- 48 kHz, 16 amounts × 6 callback sizes: no dry-outs; one trim at ~2 s; 4 runs needed small replays (big callbacks
  or ±1 near-unity amounts). Rubber Band + waiting at 128 samples: +3 52 ms (was 66 at 512), −5 66 (80), +7 47 (62),
  +12 42, −12 84, +24 36.
- 16/24/44.1/96 kHz: 9 dry-outs in 384 runs, all in the first 0.1 s at −12/−24 (the old logic has the same ones)
  or with 1024-sample callbacks.
- Amount changes while talking: one-step changes are smooth; only huge jumps (24+ half-steps at once) can still run
  dry once (faded), like before.
- "Deeper when slow" (pitch sliding 5 or 8 half-steps down and back every 2.5 s, from +3, 0, ±0.5, +1, +7, −5):
  no dry-outs, about one top-up and one trim a minute, delay at most 63–81 ms while sliding (old ring: 72–84 ms).
  Without the 12 ms top-up it ran dry up to 11 times a minute when the set amount was 0.
- The ring adds no clicks: same peak and same largest sample-to-sample step as Rubber Band's own output.

### Before / after (mic → Swoopy Mic, built-in mic, 48 kHz)
| amount | before: delay | before: Rubber Band + waiting | after: delay | after: Rubber Band + waiting |
|---|---|---|---|---|
| +3 Natural | 88 ms (87–89 over 60 s) | 66 ms | **57–58 ms** (live, 60 s) | 52 ms |
| −5 | 98 ms (96–100) | 80 ms | ≈72 ms (model) | 66 ms (model) |
| +7 | 82 ms (81–84) | 62 ms | ≈53 ms (model) | 47 ms (model) |
| +3 Cartoon / middle style | 88–90 ms | 66 ms | same as +3 (style doesn't change timing) | 52 ms |

- Before: callbacks of 512, 0 dry-outs and 0 skips in 60 s at +3/−5/+7, no growth.
- After (live, +3, 60 s): callbacks of 128, 0 dry-outs, 1 overload at start-up only, one trim at 2 s, no growth, pitch
  523.5 Hz (expected 523.3). The "model" numbers are Rubber Band + waiting from the offline model (the app's own
  VoiceRing.swift with the real Rubber Band) plus the ~6 ms of 128-sample callbacks measured live.
- Not re-run live after the merge with 2.0.1 (the Swoopy app stayed open, so the new test guard refused for 15
  minutes): −5, +7, Cartoon, middle style, the 220 Hz pitch check, speech through Swoopy Mic vs the offline
  render, and `--test-button`.

### Test safety (2026-10-14 call echo)
- During earlier voice tests the owner, in a browser call (Firefox, MacBook mic, Sony headphones in call mode),
  heard their own voice echo. The system log showed the tests did not change any default device, sample rate or
  another app's settings, Firefox never opened Swoopy Mic, and Firefox's mic stream ran unbroken through the
  tests after the call had started. Another test's `--test-button` did play two 5 s test-tone recordings into the
  headphones during the call. Firefox restarted its echo canceller about 10 times in 8 s at the start of the call
  (switching between the headphones' mic and the MacBook mic): the most likely source, along with the far end.
- Now the device tests (`--test`, `--test-voice`, `--test-button`, `--test-sounds`, `--test-default-mic`) refuse to
  start while Swoopy Mic, the built-in mic or any Bluetooth mic is in use by another app, or while the Swoopy
  app is open (with "Your voice" on it would wake on the real mic as soon as a test reads Swoopy Mic).
  `--list` marks devices in use.

## Second check: "it still sounds buzzy" (2026-10-14 evening, branch `v2-voice-buzz`)

Owner: "The audio still sounds buzzy. Is there a way to increase the sampling rate in a way that would help, or would
BlackHole limit the sampling rate?" Result:
- **No Rubber Band option and no higher sample rate makes it measurably better**, so the Rubber Band options stay as
  they are. Part of what is left is how Rubber Band works (all its modes, even its best offline one), and it grows
  with bigger shifts.
- **One real fault was found and fixed:** in Natural, going up, Rubber Band's short window (the low-delay mode we use)
  makes the voice louder than its own standard window and offline mode do: +1.6 dB on average, up to +4.9 dB (real
  voices, +3 … +15), peaks up to +8.7 dB on a high voice. With a mic peaking at −6 dBFS, loud words then went past full
  scale and were cut off hard (harsh, "fuzzy/buzzy"). Now the output is turned down by 0.25 dB per half-step the
  formants are moved (`voiceLevelGain`), and the shifted voice's loudest moments are eased (`softLimit`) instead of cut.
  Details in "The level fault" below.

### How it was tested (offline, no devices)
- Voices: the Mac's `say` voices (Samantha, Daniel, Flo, Reed), each also through 16 kHz and back (like a Bluetooth
  headset mic) and with −40 dBFS pink noise (room); 4 real recorded voices from Apple Loops "Vox Melodics" (Zane,
  Cole = male rap; Zoe, Ruby = female), which also have the top band (above 10 kHz) that the Mac voices lack; and two
  made-up voices (male, female: vocal-fold pulses with breath noise through moving formants) whose **perfect** shifted
  version can be made (same synthesis at the new pitch), so "how far from perfect" can be measured.
- Amounts +3, +5, +7, +10, +12, +15, −4; styles Natural (0), middle (0.5), Cartoon (1).
- A test program with the voice chain's own logic (512-sample callbacks, the ring with one callback + 20 ms cushion,
  dry-out and skip counters). With the current settings its output is sample-identical to `--render-voice`.
- Measures (voiced parts only): HNR (harmonics vs noise, 70–5000 Hz and 1.5–5 kHz); 3–8 kHz level and flatness
  (hiss/fizz); energy above 10 kHz (the old "Z"); a sharp wobble line at Rubber Band's frame rate in the 2–6 kHz
  loudness (a fixed-rate buzz would show up there); roughness (20–150 Hz loudness wobble); pitch error and jitter;
  "pulse clarity" (how much the 1–5 kHz loudness jumps once per vocal-fold pulse, which a phase-vocoder smears);
  and, for the made-up voices, the frame-by-frame spectrum shape error against the perfect result.
- Which measure fits which word: "Z on every word" = energy above 10 kHz (the old live shifter); "buzzy" = a
  frame-rate wobble line or more roughness; "metallic/phasey/too tonal" = HNR and flatness above what a perfect
  shift has, and lower pulse clarity.

### Results
Real recorded voices, Natural, +3/+5/+7/−4 (change vs the original voice; delay = processing only in the chain):

| setting | delay | HNR | 3–8 kHz flatness | above 10 kHz | frame-rate line | roughness | pitch error | CPU |
|---|---|---|---|---|---|---|---|---|
| **now** (R3, short window, HighConsistency) | 66 ms | +2.3 dB | −1.6 dB | −2.5 dB | 3.3 dB (noise level) | −0.8 dB | 1.0 cent | 2.2% |
| R3 standard window | 97 ms | +2.1 | −1.4 | −1.1 | 3.7 | −0.4 | 0.7 | 4.6% |
| R3 at 96 kHz (libsamplerate around it) | 69 ms | +2.4 | −1.9 | −2.8 | 2.2 | −0.9 | 0.7 | 7.2% |
| PitchHighQuality | 62 ms | +2.4 | −1.6 | −2.6 | 3.1 | −0.9 | 0.7 | 2.2% |
| PitchHighSpeed | 76 ms | +1.5 | −1.4 | −0.4 | 3.1 | −1.1 | 1.0 | 1.8% |
| R2 (EngineFaster), standard | 92 ms | +0.1 | +1.4 | −1.6 | – | +0.7 | 0.6 | 1.6% |
| R2 short window + PhaseIndependent | 57 ms | +1.5 | +0.9 | −2.9 | – | +0.1 | 0.7 | 1.4% |
| old live shifter (not allowed) | 60 ms | +1.4 | −1.4 | −0.4 (+4.5 at +10; now −3.2) | – | −1.2 | 0.9 | 2.3% |
| R3 offline, best (reference, not live) | – | +1.9 | +1.1 | −1.1 | – | 0.0 | 1.0 | 3.5% |

Made-up voices, Natural, +5/+10/−4 (difference from the perfect shifted voice):

| setting | shape error | 3–8 kHz level | HNR | flatness | pulse clarity (perfect 67%) | roughness |
|---|---|---|---|---|---|---|
| **now** | 2.98 dB | −2.5 dB | +2.1 dB | −2.4 dB | 46% | −0.9 dB |
| R3 standard window | 2.97 | −1.4 | +2.2 | −1.9 | 46% | −0.9 |
| R3 at 96 kHz | 3.01 | −2.5 | +2.5 | −2.7 | 46% | −1.1 |
| R3 offline, best | 2.98 | −1.5 | +2.2 | −1.8 | 46% | −0.8 |
| R2 standard | 3.77 | −1.0 | +0.7 | +0.5 | 51% | −0.7 |
| R2 short + PhaseIndependent | 3.96 | −1.4 | −0.2 | +0.2 | 68% | −0.1 |
| old live shifter | 2.78 | −1.5 | +1.7 | −2.3 | 46% | −2.2 |

- **There is no fixed-rate buzz.** Rubber Band's frames land at 48000/inhop Hz (with the short window and
  HighConsistency: about 112 Hz at +3, 125 at +5, 141 at +7, 86 at −4; the short window doubles the hop to 512, so it is
  not 256/187 Hz). The wobble line there is 2–4 dB above its neighbours, the same as the original voice shows at that
  frequency, with a depth of about 2% (input 4%). The standard window does show a real line at big shifts
  (12–15 dB at +12/+15, ~290 Hz), so it would be worse there.
- **Nothing is ≥ 3 dB better.** Every R3 option, 96 kHz included, is within about 0.5 dB of now on every measure.
  `OptionSmoothingOn` and `OptionChannelsTogether` give byte-identical output (R3 ignores smoothing; one channel has
  nothing to keep together); `FormantShifted` at Cartoon is byte-identical to Preserved + scale 1; feeding Rubber Band
  in pieces of 512 or 4096 gives the same samples. PitchHighQuality is identical to now when going up and can't change
  pitch smoothly ("Deeper when slow", the slider); PitchHighSpeed brings back the top-band seam (above 10 kHz: −0.4 vs
  −2.5 dB). R2 short + PhaseIndependent keeps the vocal-fold pulses and the breath noise (closest to perfect there) but
  gets the voice's shape wrong by more (+1 dB error, 3–8 kHz 3.5 dB duller on real voices, more noise between
  harmonics), is rougher than now on real voices, and R2 has no formant scale, so the Natural ↔ Cartoon slider could only
  do its two ends. Not a clear win, so not used.
- **What is left is how Rubber Band (a phase vocoder) works**, the same in its best offline mode: (1) the breath noise
  in the upper voice gets turned into "tone": HNR (1.5–5 kHz) above a perfect shift by +2 dB at +3, +3 at +5, +4 at +7,
  +5 at +10, +6 at +12/+15, with the 3–8 kHz band 1–6 dB "peakier" (a buzzy, reedy sound that grows with the amount);
  (2) the crisp once-per-pulse attack of the voice is smeared (pulse clarity 46% vs 67% perfect; going down −4: 42% vs
  84%). No Rubber Band option changes these by more than ~0.5 dB. Only a different kind of voice shifter (time-domain,
  PSOLA-style, which moves whole vocal-fold pulses) would keep them; that would be a new engine, not tried.
- Pitch is exact everywhere (≤ 1 cent median); no extra roughness or jitter.
- The ring: 0 dry-outs and 0 skips in every run (all voices, amounts −4 … +15, all styles), at 48 kHz with 512-sample
  callbacks (the MacBook mic's buffer) and at 16 kHz with 320 (the Bluetooth mic's buffer). Not a buzz source in steady use.
- Peaks: on the Mac's `say` voices the shifted voice's peak is at most +2.2 dB above the original's. On recorded
  voices it is much more in Natural; see the next section.

### The level fault (found and fixed)
- On the 4 recorded voices, Natural going up made the voice louder than the original with the short window, and more
  than Rubber Band's standard window and offline mode (level of loud parts, vs the original):

  | | +3 | +5 | +7 | +10 | +12 | +15 |
  |---|---|---|---|---|---|---|
  | short window (before), extra vs standard window | +0.8 | +1.2 | +1.7 | +2.6 | +3.1 | +3.9 dB |
  | short window (before), high female voice vs original | +2.2 | +3.9 | +5.2 | +6.1 | +5.5 | +3.1 dB |

  Fit over all voices, amounts and the middle style: **+0.256 dB per half-step the formants are moved back down**
  (formant move = pitch × (1 − style)), spread ±0.5 dB. Cartoon (formants not moved): the same level in all modes.
  Going down: the short window is slightly quieter (−0.7 dB at −4), which can't clip, so it is left alone.
- Where it comes from: R3's formant step (`analyseFormant`/`adjustFormant` in `R3Stretcher.cpp`) as run in the
  single-window mode. Moving only the formants down by 10 half-steps with no pitch change (formant scale 0.56) gives
  short +6.0 / +5.6 / +1.6 dB vs standard +2.8 / +1.4 / −1.2 vs offline +1.7 / +1.3 / −2.7 (high female recording /
  made-up female / male recording); moving them up does not make the short window louder. In that mode the envelope
  is taken from a Hann-windowed 2048 frame (standard mode: Niemitalo window), everything is rebuilt from that one FFT,
  and it has its own phase-lock bands (`Guide.h`, single-window: 1-bin locking below 1600 Hz). The exact line wasn't
  pinned; Rubber Band comes from Homebrew's static library, so it is corrected after Rubber Band instead.
- Made-up voices, Natural +10, level vs original: short +5.5 / 0.0 dB, standard +1.3 / −2.2 dB (female / male).
- Clipping: with the chain's hard cut at ±1, mic peaks of −12, −9, −6, −3 dBFS (Natural, +3 … +15, 4 voices):

  | | −12 | −9 | −6 | −3 dBFS |
  |---|---|---|---|---|
  | before: settings that clip / 100 ms moments cut | 0 / 0 | 0 / 0 | 3 / 16 | 6 / 93 |
  | after the level fix | 0 / 0 | 0 / 0 | 1 / 1 | 3 / 23 |
  | standard window, for reference | 0 / 0 | 0 / 0 | 0 / 0 | 3 / 7 |

  After the fix the level matches the standard window: +0.0 dB on average (−1.6 … +1.2), before +1.6 (up to +4.9).
- **The fix** (`VoiceShifter.swift`):
  - `voiceLevelGain(halfSteps:cartoon:)`: −0.25 dB per half-step of formant move, 0 dB in Cartoon and going down.
  - `VoiceStretcher.retrieve` applies it to what comes out of Rubber Band; it glides (30 ms) when the amount, the style
    or "Deeper when slow" changes. Largest change in 10 ms while the style slider moves: 0.17 dB.
  - `VoiceChain.render`: the shifted voice goes through `softLimit` (unchanged up to 0.7, eased to at most 0.95)
    instead of the hard cut at ±1; the voice at 0 (not shifted) still uses the plain ±1 cut.
  - `--render-voice … --voice-preset old` renders without the level fix: sample-identical to before (checked at
    +5/+10/−4, styles 0/0.5/1, two voices). The new output is exactly the old one times the gain; Cartoon and going
    down are byte-identical to before. HNR, flatness, roughness, frame-rate line, pitch: unchanged (a constant gain).
  - Delay and CPU: unchanged.
  - Windows: not changed (its voice engine is separate C++).

### Sample rates (answer to the owner's question)
- Swoopy Mic (BlackHole) supports 8, 16, 24, 44.1, 48, 88.2, 96, 176.4, 192, 352.8, 384, 705.6 and 768 kHz
  (`kSampleRates` in driver/BlackHole.c). **BlackHole does not limit anything.** Both of its sides share one rate.
- The voice chain runs at the **mic's** rate (`VoiceChain.init`: rate = `nominalRate(mic)`; Swoopy Mic is set to
  match; the app never changes the real mic). `--list` on this Mac: MacBook Pro Microphone 48 kHz (supports 44.1, 48,
  88.2, 96), Headphonez V3 (Bluetooth) mic 16 kHz only, G522 48 kHz only, iPhone mic 48 kHz only. So with the built-in
  mic everything is 48 kHz end to end; with a Bluetooth headset mic, Swoopy Mic itself drops to 16 kHz.
- Rubber Band scales its window with the rate (2048 samples at 48 kHz, 4096 at 96 kHz: both 43 ms), so at 96 kHz it
  "sees" the voice the same way; only its frames come twice as often (the hop stays 512 samples). Measured: no better
  (table above), +3 ms delay on average (+8 ms at +5), 3× the CPU. A voice has nothing above 20 kHz and Discord/Zoom
  send at most 20 kHz, so a higher rate can't add anything. **A higher rate would not help; a lower one hurts:** a 16 kHz
  Bluetooth mic loses everything above 8 kHz (thin), adds its own call-mode codec, and makes our chain 20 ms slower
  (87 vs 67 ms processing), and the headphones' own sound drops to call quality while their mic is open.

### Delay (unchanged)
- Processing in the chain now (512-sample callbacks): +3 66 ms, +5 60, +7 63, +10 61, +12 61, +15 59, −4 75 ms.
  The device path adds about 25 ms (the live tone test measured 87–103 ms end to end).
- Note: in real-time mode `rubberband_get_start_delay` is not where the sound lines up. Dropping it (as `--render-voice`
  does) leaves the output 20–34 ms early against the input; the real line-up is within ±6 ms of no shift at all.
  This only matters when comparing `--render-voice` output with its input.

### Not tested
- A device test (`--test-voice --mic "MacBook Pro Microphone"`): the MacBook mic and Swoopy Mic were in use the
  whole time (the owner was in a call), checked every 30 s for 10 min; after the fix the G522 headset mic was in use
  for another 10 min. So the live chain with the fix (softLimit included), the drift correction on the hidden feed (its
  quality is left at Core Audio's default) and real-time overloads under heavy load (this Mac had 9 GB of swap in use)
  were not measured.
- What call apps do to the voice afterwards (noise suppression such as Discord's Krisp, echo cancellation, automatic
  gain). These are made for natural voices and can chop or "buzz" a shifted one.

### What the owner can try
1. Use the MacBook mic (or a USB/wired mic), not a Bluetooth headset mic.
2. In Discord (Voice & Video) / Zoom: turn noise suppression off (or "None"), and try echo cancellation and automatic
   gain off.
3. Press Test in Swoopy: if the replay sounds clean but the call sounds buzzy, it is the call app's filters.
4. Smaller amounts sound cleaner (the "tone" effect grows with the amount); the style slider changes it little.
5. Keep the mic's input level moderate (System Settings → Sound → Input): loud words at big Natural amounts were the
   ones that got cut off before the fix.

### Tools (scratchpad `buzz/`, not in the repo)
`bench.cpp` (the chain's logic with any Rubber Band option, 96 kHz via libsamplerate, R2, live shifter, offline),
`measure.py` + `run.py` (measures), `synth.py` + `ideal.py` (made-up voices and their perfect shifts), `lagtest.py`
(true line-up), `same.py` (byte-identical checks), `rates.swift` (each device's supported rates and "running somewhere"),
`tables.py`, `clip.py` (clipping at mic levels), `lvl.py`/`lvl.sh` (formant-only vs pitch-only level), `check_fix.py`
(old preset = old code, new = old × gain), `glide_check.py` (gain glide when the style moves).

## Third check: "the non-AI voice changer sounds super buzzy" (2026-10-15 evening, branch `v2-voice-buzz2`)

Owner, after trying the test build: "the non ai voice changer sounds super buzzy, it just sounds like a pitch shift
up and on the natural voice." In the blind set they marked exactly the plain shift (+10 / -8) and Natural clips as
buzzy; none of the AI clips, originals or real recordings. Levels were fine (2.0.2's level fix holds).

### What the buzz is
- **Rubber Band smears the voice's pulses.** A voice is a train of vocal-fold pulses; at each one the upper
  harmonics line up for a moment (a crisp tick, 100-200 times a second). A phase vocoder (Rubber Band, every mode)
  loses that line-up at big moves and turns the ticks into a steady, reedy tone: the buzz.
- **The buzz number:** pulse clarity, % = how strongly the 1-5 kHz loudness jumps once per pulse (depth of the
  1-5 kHz envelope at the pitch and twice the pitch, voiced frames, median). On the owner's blind set it splits
  Rubber Band from everything else with no overlap: the 12 Rubber Band clips (plain and Natural) 32-50, all 8 the
  owner marked among them; originals, real recordings and AI clips 63-100.
- **Not the cause** (buzz number on the same 6 clips; Rubber Band now 41-43): standard window 39-43, high-quality
  pitch 41-43, high-speed 38, Rubber Band's offline mode (whole file) 37, R2 engine 39, R2 short + phase
  independent 43, callbacks of 128 or 4096 40, two shifters in a row 38-44, formants not kept 36, formant scale 1 41,
  pitch held still per 0.5 s 40, no changer post-filters 42. It is how a phase vocoder works, not an option.
- **What fixes it:** moving whole pulses (pitch-synchronous overlap-add, "PSOLA"). Praat's offline version on the
  same clips: buzz 111, quality (Distill-MOS) 4.16 / 3.95 plain and 3.94 / 4.06 Natural, vs Rubber Band's
  3.47 / 3.35 and 3.44 / 3.42.

### The fix: our own pulse shifter (`Sources/Voice/PulseShifter.{h,cpp}`)
- A pitch tracker (2 kHz low-pass, ~12 kHz, YIN-style, 25 ms window, every 5 ms), one mark per pulse (the first on
  the strongest pulse, the next ones by matching one period on), and two-period pieces laid down at the new pitch,
  squeezed or stretched to move the voice shape. Unvoiced sound is only reshaped, never repeated; creak or unclear
  frames right after voicing keep the last good period. Fixed delay 40 ms (`pulseLatencyMs`: at 35 ms 0.2 % of
  pieces have to guess the next pulse, at 30 ms 2 %, at 40 ms 0.03 %); 60 ms scored exactly the same.
- Used by the voice changer's Natural mode (the shape move made 1.4x bigger in log terms, `pulseShapePow`: whole
  pulses keep more of the speaker's own voice, so 1.21 alone was judged a woman on 88 % of VCTK men vs Rubber
  Band's 95 %) and by the plain shift from a set amount of 6 half-steps up or down. Below 6 with the changer off
  nothing changed (45 of 45 renders from -5 to +5, all styles and "Deeper when slow", byte-identical).
  `--changer-tune naturalEngine=0` gives the old Rubber Band output exactly.
- Cost: 0.025 ms per 10 ms of sound (Rubber Band 0.14-0.24), worst 128-sample callback 0.17 ms (Rubber Band
  0.9-1.6 ms); Intel half under Rosetta 0.035 ms (worst 0.55). Intel output matches Apple silicon (-96 dB).

### Numbers (offline; nobody has listened yet)
Natural, held-out VCTK and `say` sets, after 8 s of the same speaker (r3 = the values on `v2-voice-changer`):

| | judged target | voice print beats plain (old / new plain) | quality | word errors | pitch | creak | buzz |
|---|---|---|---|---|---|---|---|
| VCTK men -> Woman, r3 | 95 % | 92 % | 3.48 | 5.7 % | 189 Hz | 0.055 | 42 |
| VCTK men -> Woman, pulse | 100 % | 92 % / 100 % | 3.56 | 5.3 % | 193 Hz | 0.035 | 79 |
| VCTK women -> Man, r3 | 100 % | 90 % | 3.11 | 8.1 % | 111 Hz | 0.069 | 42 |
| VCTK women -> Man, pulse | 100 % | 80 % / 98 % | 3.72 | 6.3 % | 113 Hz | 0.026 | 99 |
| `say` men -> Woman, r3 | 71 % | 87 % | 1.92 | 23.5 % | 189 Hz | 0.034 | 55 |
| `say` men -> Woman, pulse | 100 % | 67 % / 91 % | 1.94 | 17.8 % | 191 Hz | 0.032 | 109 |
| `say` women -> Man, r3 | 94 % | 83 % | 2.21 | 19.4 % | 111 Hz | 0.023 | 51 |
| `say` women -> Man, pulse | 100 % | 87 % / 96 % | 2.86 | 7.6 % | 111 Hz | 0.007 | 127 |

- "old / new plain": compared with the plain shift as it was (Rubber Band, comparable to r3) and as it is now
  (pulse shifter at +10 / -8). Women -> Man now passes every pass mark on both sets (a first for Natural); men ->
  Woman passes all but word errors (as before).
- One `say` voice scores lower for Woman: Daniel 3.31 -> 3.06 (any shape boost, 3.15 at none; his pitch is tracked
  right on every frame); Reed and Rocko go up (1.81 -> 1.97, 1.66 -> 1.91). On the small "testing testing" set
  (Daniel, Reed) Woman 2.74 -> 2.50, Man 2.43 -> 2.66, plain +10 2.52 -> 2.77, plain -8 2.37 -> 2.81.
- The plain shift with the pulse shifter, vs Rubber Band: VCTK men +10 quality 3.44 -> 3.82, word errors 6.1 ->
  4.5 %; women -8 3.24 -> 3.72, 8.1 -> 7.7 %; `say` men +10 1.93 -> 2.07, 18.7 -> 13.2 %; women -8 2.33 -> 2.90,
  16.8 -> 11.1 %. It keeps more of the speaker (similarity to the source 0.50 -> 0.77 and 0.37 -> 0.66): with the
  shape kept it now sounds like the same person, higher or lower; Rubber Band's smearing had blurred that.
- The one step back: the voice print (ECAPA) compared with the old Rubber Band plain shift, VCTK Man 80 % (90) and
  `say` Woman 67 % (87). Rubber Band's smearing hides the speaker a little; whole pulses keep more of them (similarity
  to the source speaker, Woman 0.19 / 0.32 = Rubber Band's 0.20 / 0.32; Man 0.24 / 0.35 vs 0.17 / 0.29). A bigger
  shape move doesn't change the `say` number (71 % at 1.6, 69 % at 1.8); shorter pieces (`pulseWindow` 0.6) do
  (73 %, VCTK 100 %) but lower quality (VCTK 3.42), so they're not used. Real voices' buzz numbers are 63-100; the
  women -> Man pulses come out a bit crisper than real men on VCTK (99 vs 84).
- Delay, mic to Swoopy Mic minus the devices (128-sample callbacks, sound lined up): Natural Woman 51 -> 45 ms,
  Man 80 -> 45 ms; plain +3 52 ms (unchanged), +10 50 -> 45, -8 73 -> 45, -12 84 -> 44. The app's offline live
  chain (`--live-sim`, 60 s): 0 dry-outs in every case. Switching shifters (changer on/off, amount crossing 6)
  starts fresh: 60-75 ms quiet, like leaving 0.
- Rubber Band options with more delay were not better (VCTK, Natural): standard window 75 / 129 ms (Woman / Man)
  quality 3.50 / 3.33, more creak for Woman; two shifters in a row 99 / 124 ms, 3.28 / 3.02; high quality (Man only differs)
  45 ms, 3.06, word errors 12 %.
- No higher-delay setting helps the pulse shifter; a future speed-vs-realism control belongs to Realistic (AI) mode.

### Tools (`research/voicechanger/buzz2/`, git-ignored; results tables and per-clip buzz numbers there too)
`tools/bz.py` (buzz number), `t3/rbx3.cpp` (bench: the chain's logic with Rubber Band options or the pulse shifter,
with the app's changer), `t3/quick.py` (judged / voice print / quality / creak / word errors with the harness's
models), `t3/tune3.sh` (full measuring round with any build), `t3/sw/main.swift` (switching test with the app's own
`VoiceStretcher` and `VoiceRing`), `t3/timing.cpp`, `t3/praat_psola.py`.
