# Advanced processing: research notes

Research and build of the "Advanced processing" switch in the "What you hear" card (October 13-14, 2026).
The raw data, scripts and test sounds are in the research folder (scratchpad `advanced/`, session 8903a598):
`results/dsp.md` (no-AI work, rounds 1-4), `results/ai.md` (AI work), `results/metrics.md` (how the measures were
checked). The numbers below are copied from there.

## Summary

- **Pick: "balanced3" (no AI).** Going up, the bass is shifted an octave less so it stays bass; going down, the
  original's very top is kept; always, a slow tone control steers the long-term balance back toward the original.
- It fixes the "bracket": the tone balance error drops from 8.6 to 2.4 dB going up and from 6.8 to 3.3 dB going down
  (3 main test songs), and the deep bass going up is back (below 60 Hz: -23 dB → -1.7 dB).
- Same delay as normal mode for ±12 (about 200 ms in total on the MacBook speakers), about +15 % of one CPU core,
  no download, no AI, no license question beyond Rubber Band.
- **Runner-up: the same plus AI drum separation** (Sony X-UMXL, CC BY 4.0) that keeps drum hits unshifted. Punchier
  drums going up, but no better on the other measures, about 0.64 s total delay, ~2.5× the CPU and a 44 MB model.
  Built and tested, kept on the local branch `v2-advanced3-ai` (not pushed).

## The problem

At bigger shifts (about ±5 half-steps and more) music stops sounding right:
- some notes blur together;
- the song "falls into a bracket": squeezed high and thin when shifted up, low and muddy when shifted down;
- shifted up there is much less bass (worse on headphones with little bass); shifted down the top end goes dull.

What the measurements showed: a plain pitch shift moves the whole song's tone balance with it. At +8 the deep bass
(below 60 Hz) drops by about 23 dB, and at -8 everything above about 9 kHz is gone. No Rubber Band setting fixes this
(every option tried left the balance error at 7.7-8.7 dB going up).

Limits set by the owner: total delay with Advanced processing at most 0.8 s (sound in to ear, including the cushion and
the speakers); AI only if it is free (runs on the Mac, code and model weights may be bundled in a free
GPL-3.0-or-later app); Mac first; real time; reasonable CPU.

## How candidates were tested

- **Test songs:** 6 short songs mixed from Apple Loops: A hip hop (808 and sub bass), B funk band, C pop with female
  vocals, D rock band, E piano ballad (no bass instrument), F EDM drop (40 Hz sub bass). Because they are mixed from
  loops, every part (drums, bass, ...) is known exactly. The owner's own music was never used.
- **Shifts:** +5, +8, +12, -5, -8 (round 4 also +4 and +6; the engine also -24..+24).
- **Measures** (each compares the shifted song with the original, after matching loudness):
  - *tone balance* (tbDev): how far the long-term 1/3-octave spectrum is from the original's, in dB (0 = same);
  - *bass*: level below 60 Hz and 60-150 Hz; *bass on earbuds* (budBass/budNote): the low end as heard through a
    typical earbud that plays little below 100 Hz;
  - *top end*: level above 5 kHz, and "air" above 8 kHz;
  - *drum hits*: hit peak level (onsetPk, 0 = like the original) and smear before hits (preEcho, lower is better);
  - *note clarity*: blurF (notes smeared in pitch) and ringOn (notes ringing on), checked against a synthetic song
    whose perfect shift is known and against controlled damage (rank agreement 0.97 and 0.81). The old "chroma"
    clarity measure was dropped: it scored the perfect shift worse than today's normal mode.
  - *wrong-key leak*: sound left in the OLD key (ghost notes) when part of the song is kept unshifted
    (≤ -28 dB clean, -20 dB clearly audible; it reads known added levels back within 3 dB);
  - *pitch accuracy* (cents), *delay*, *CPU*.

## What was tried

| idea | result |
|---|---|
| Rubber Band options (R2/R3, window sizes, formants, transients, offline mode) | none fixes the balance (tbDev 7.7-8.7 dB going up vs 8.6 for normal) |
| Slow EQ toward the original balance | helps (8.6 → 6.5) but can't bring back bass that is an octave too high |
| Bass "fold": shift the bass band by N-12 so it stays bass | the big fix for going up |
| "Air": keep the original's very top when going down | fills the empty top end; leak -46 dB or lower (inaudible) |
| Keep drums unshifted with a harmonic/percussive split (no AI) | better drum hits but clear old-key ghost notes (-9 dB) |
| "Attack keeper": keep only the first 10 ms of hits unshifted | helped on 3 songs, worse on the other 3, leaks piano attacks (-25 dB); dropped |
| Headphone bass helper (added bass harmonics) | measures neutral; not needed once the fold is in |
| AI: split the song into parts and treat each part differently | see "AI" below |

## The pick: "balanced3"

How it works (for an amount of N half-steps):
- **Going up (N > +3): bass fold.** The bass band is shifted by N-12 instead of N, so the bass line stays in the bass
  range. Between +3 and +7 the fold comes in gradually by moving its crossover up (so nothing jumps by an octave and no
  bass note is doubled). A "fold floor" keeps bass that would land below 35 Hz on the normal path (EDM sub basses).
  At +12 the bass is simply the original bass. Beyond +15 a second fold (N-24) comes in the same way.
- **Going down (N < 0): air.** Above 15 kHz × 2^(N/12) (9.4 kHz at -8; never below 7 kHz) the original's top end is
  kept, so the song doesn't go dull.
- **Always: a slow tone control.** 10 gentle filters steer the long-term balance back toward the original's (within
  ±6 dB in the mids, up to 15 dB of cut below 100 Hz). It predicts the right setting from the amount, so it is right
  within about a second, and then corrects itself slowly from what it measures.
- **A safety limiter** at the end keeps the sound below full scale (the tone control can add a little level).

Results (tbDev and band levels in dB vs the original; up = mean of +5/+8/+12, down = mean of -5/-8):

| | tbDev up / down | <60 Hz up / down | air >8 kHz up / down | onsetPk up / down | preEcho up / down |
|---|---|---|---|---|---|
| normal (today), songs A-C | 8.59 / 6.80 | -23.4 / +4.1 | +1.6 / -4.7 | -1.45 / -1.10 | 2.20 / 1.48 |
| **balanced3**, songs A-C | **2.43 / 3.32** | -1.7 / -2.6 | +0.1 / -0.1 | -1.88 / -0.14 | 2.08 / 1.02 |
| normal, songs D-F | 8.97 / 8.80 | -16.0 / +10.8 | +2.0 / -6.0 | -1.29 / -1.74 | 1.42 / 0.83 |
| **balanced3**, songs D-F | **3.58 / 5.17** | +0.8 / +2.5 | 0.0 / -0.8 | -1.49 / -1.26 | 1.47 / 0.57 |

- Better than normal on tone balance in every song and shift tried (30 of 30 cases).
- Bass on earbuds stays within about 0.7 dB of the original going up (normal: 1.9 dB off on average, 2.9 dB for the
  bass notes).
- Note clarity above 300 Hz is the same as normal (within about 0.2 dB). Below that the fold moves bass notes an octave
  down on purpose, which the clarity measures count as "different"; a perfect fold scores the same way.
- No wrong-key ghosts: nothing is kept unshifted going up; the air band going down leaks -55 dB.
- Pitch accuracy: 0.1-0.7 cents (inaudible).
- Drum hits: about the same as normal (slightly softer going up, better going down).
- Weak spots left: an EDM sub bass at +8..+11 is still about 16 dB too strong at 32 Hz; on the piano song the left
  hand is partly doubled at +4..+6 and the low end is still +19 dB at -8 (normal: +25).

### In the app

- `Sources/Advanced/AdvancedChain.cpp` (C++, plain C API in `AdvancedChain.h`) does the work. The app's own
  `--render-file` output matches the research renders within 0.04 dB tone balance on all 15 test files.
- **Changing the amount while playing:** a running Rubber Band shifter changes its own delay by up to 31 ms when its
  pitch is changed, which would make the bass and the rest drift apart. So each new amount starts fresh shifters
  (from a pool of 7 made in advance), warms them up on recent sound, and crossfades over 80 ms. The new amount is
  heard about 0.2-0.3 s after the click. Tested: paths stay lined up within about 1 ms after changes, no clicks
  beyond normal, 0 underruns.
- **Delay is fixed** for the engine's life: 138 ms for amounts within ±12, 225 ms beyond (48 kHz; the app rebuilds
  the player with the bigger delay only when the amount goes past ±12). Measured live on this Mac (MacBook Pro
  speakers): about 200 ms total within ±12 (normal mode 205-217 ms), about 290 ms beyond.
- **Safety limiter:** the tone control can lift peaks a little (up to +1.7 dB over the original's peak on the test
  songs), so a 2 ms look-ahead limiter at the end keeps everything under -0.3 dBFS. It acted on 13 of 30 test files,
  at most 2 dB and about 1.4 % of the time; otherwise it leaves the sound untouched.
- **No memory is made on the sound threads:** the captured sound goes into a lock-free ring (`AudioRing.c`), a worker
  thread runs the engine, and a second ring with the usual 50-150 ms cushion feeds the speakers through an
  AVAudioSourceNode. Checked: 0 allocations inside the engine's process calls (malloc counter), 0 dropouts live.
- **CPU** (one core of the M3 Pro): the engine alone is 0.05-0.11 of real time within ±12 (0.14 at +15..+19). The whole
  app while playing at +8 (live test, other apps busy): about 42 % of one core vs 26 % in normal mode.
- **Download:** no change apart from the code (no model files).
- **Licenses:** only Rubber Band (GPL), as before.

## AI

### Free models and their licenses

| model | weights license | verdict |
|---|---|---|
| HTDemucs (Meta) | the author: "The model weights are not covered by the MIT license, and are provided only for scientific purposes." ([issue #327](https://github.com/facebookresearch/demucs/issues/327#issuecomment-1134828611), also #384, #508) | **not allowed** (quality reference only) |
| X-UMXL (Sony) | CC BY 4.0 ([Zenodo 7128659](https://zenodo.org/records/7128659)), trained on Sony's own data | allowed (credit needed) |
| MDX-Net onnx_A (KUIELab) | CC BY 4.0 ([Zenodo 5717356](https://zenodo.org/records/5717356)) | allowed by its license, but trained only on MUSDB18-HQ, whose terms say "educational purposes only" |
| Open-Unmix UMX-HQ | MIT | allowed, same MUSDB question, weaker |
| Open-Unmix UMX-L | CC BY-NC-SA (non-commercial) | not allowed |
| Spleeter (Deezer) | MIT (per the authors' paper) | allowed, not tested |

All of them can run on the Mac with Core ML (compiled when the app runs; no Xcode needed).

### What was tried with the parts
- Shift each part on its own: fixes nothing (the balance problem stays).
- Keep the whole drum part unshifted: good balance, but the AI's drum part carries some of the music, which is then
  heard in the old key (-16 to -25 dB ghosts).
- **Hybrid** (the runner-up): keep only the clearly percussive part of the AI drum part unshifted, run everything else
  through balanced3. X-UMXL put a plucked synth lead into its drum part on one song (ghosts at -11 to -14 dB); a
  "note-peak protection" (any narrow peak of the mix spectrum never stays unshifted) fixed that.

### Runner-up: balanced3 + X-UMXL drums (going up only)

Mean of the 6 songs, going up:

| | tbDev | onsetPk | preEcho | blurF >300 Hz | ringOn >300 Hz | wrong-key leak |
|---|---|---|---|---|---|---|
| balanced3 | 3.01 | -1.69 | 1.78 | -0.35 | 2.17 | (reference) |
| balanced3 + AI drums | 3.12 | **-0.64** | **1.18** | -0.04 | 2.09 | within +0.9 dB of balanced3 |

- Drum hits are clearly punchier on the funk and pop songs, a little on hip hop, rock and EDM, and not at all on the
  piano ballad. Going down there is no gain (slightly worse), so it would be used only going up.
- Tone balance and note clarity are slightly worse.
- Costs: delay about 0.64 s in total (separation 0.32 s + drum split 0.04 s on top of balanced3), CPU about 33 % of
  one core (model ~9 ms per 0.12 s on the CPU), a 44 MB model (8-bit weights), and Core ML at run time.
- Built and tested as `Sources/Separator/DrumKeeper.mm` (real-time safe: 0 allocations/locks in its process call,
  0 misses in 60 s live tests, also under load). Kept on the local branch `v2-advanced3-ai`.

## Why balanced3

- It fixes what the owner described: the bass going up, the dull top going down, and the "bracket" (tone balance
  error cut by 60-70 %), on all 6 songs, with no ghost notes.
- The AI version adds only one thing (punchier drums going up), is slightly worse on balance and clarity, does
  nothing on the piano song, triples the delay (0.64 s, close to the 0.8 s limit, more with Bluetooth headphones),
  uses 2.5× the CPU and adds a 44 MB download. Its separation also has to cope with real songs it has never seen.
- If the owner prefers the AI version by ear, it is ready on `v2-advanced3-ai`.

## Bass fix (after 2.0.0, branch `v2-bass`)

The owner: "improve low bass notes, especially at higher pitches. Target sounds that are 100 Hz or lower. The advanced
processing seems to actually balance out the sounds better, but in the meantime it removes some of those low bass
notes."

**Test set** (never the owner's music): 16 clips. 5 made-up ones (a bass line with notes from 35 to 98 Hz, a kick drum,
three long sub notes, and the bass line and sub notes mixed with chords and hi-hats), the 6 Apple Loops songs A-F, and
the bass parts of A, B, C, D and F alone. Rendered with the engine itself (same output as `--render-file`).
Measures: "lost bass" = the share of 100 ms moments where 20-100 Hz is more than 6 dB below the original (only moments
where the original has bass); the median 20-100 Hz level; the same through an earbud-like curve; per-note levels; and
the research's tone balance (tbDev) and 1/3-octave levels.

**What removed low bass notes in 2.0.0 (going up):**
1. **The tone EQ.** Since balanced3 it may cut up to 18 dB below 100 Hz, without smoothing, also going up. The fold
   and its floor move bass notes into other 1/3-octave bands, and the EQ then cut them there because the original
   had little in that band. Examples: the piano song's low notes at +8 (79 % of its bass moments more than 6 dB
   down); an 82 Hz test tone at +8 came out 7 dB quieter than it went in.
2. **The fold floor's split** (LR4 at 35 Hz × 2^((12-N)/12)). Its two sides end up an octave apart, so they add as
   powers: up to 3.5 dB lost for notes within about 4 half-steps of the split, plus up to 7 dB more from the 30 Hz
   high-pass on +4..+6. Its gentle slope also leaked the EDM song's 41 Hz sub down to 32 Hz (the +16 dB weak spot).
3. Not the cause: the peak limiter (switched off: the same within 0.2 dB), Rubber Band itself (normal mode keeps
   bass notes that stay under 100 Hz within 0.7 dB; it only "loses" them by moving them above 100 Hz).

**The fix** (engine recipe 4, now the default; `advanced_tune(chain, "recipe", 3)` gives 2.0.0's output sample for
sample, checked):
- Going up, the EQ treats the bass like the rest (target smoothed over ±1 third-octave, cuts up to 9 dB). Going down
  is unchanged.
- Fold floor: a steep 8th-order Butterworth split, whose two sides keep the full power. The main path's upper band
  goes through a matching all-pass, so the main path's two parts can't cancel (a plain steep split made a -14 dB
  notch at 60 Hz at +4).
- Floor at 45 Hz up to +8, easing to 35 Hz at +11 (at +9..+11 the fold moves bass down only 1-3 half-steps).
- Unchanged: pitch-down, +12, the delay (engine 138 ms; live at +8: 201 ms total, 0 dropouts), normal mode
  (byte-identical). CPU about +1 %.

| N | lost bass moments | median bass level | earbud: lost | tbDev, 6 songs | EDM 32 Hz vs original |
|---|---|---|---|---|---|
| +3 | 15.5 → 14.3 % | -1.2 → -0.5 dB | 0.2 → 0.2 % | 3.7 → 3.7 | |
| +4 | 15.4 → 15.8 % | -1.6 → -0.8 dB | 0.4 → 0.6 % | 3.9 → 3.8 | +4.5 → +0.2 dB |
| +5 | 17.0 → 3.2 % | -1.8 → +0.6 dB | 2.5 → 1.0 % | 3.7 → 3.8 | +7.5 → +2.0 dB |
| +6 | 12.0 → 2.4 % | -1.2 → +0.7 dB | 4.2 → 0.6 % | 3.7 → 3.8 | +6.3 → +1.1 dB |
| +8 | 11.5 → 1.7 % | -1.5 → +0.1 dB | 2.9 → 0.4 % | 3.6 → 3.7 | +16.0 → +9.2 dB |
| +9 | 8.0 → 1.3 % | -1.6 → -0.4 dB | 0.2 → 0.4 % | 3.4 → 3.6 | +16.7 → +15.6 dB |
| +10 | 3.6 → 1.2 % | -1.3 → -0.4 dB | 0.8 → 0.3 % | 2.9 → 3.0 | +12.1 → +13.6 dB |
| +11 | 0.3 → 1.0 % | -0.3 → +0.1 dB | 0.2 → 0.2 % | 2.4 → 2.3 | +8.5 → +6.4 dB |
| +12, -5, -8 | identical | | | | |

Tone balance above 100 Hz is unchanged at every amount; the small tbDev changes are in the bass bands.

**Weak spots left:**
- **Overtone collisions.** When a bass note's lowest part goes up with the main path (below the floor) and its 2nd
  harmonic is folded down, both land on the same frequency from two different shifters and can cancel by chance.
  2.0.0 had this too, for lower notes; the higher floor moves it into common bass notes (at +5: notes of 34-67 Hz,
  was 26-52 Hz). Example: the funk bass part alone at +5 has 14.7 % lost moments (2.0.0: 5.0 %); the whole funk song
  1.5 % (0.6 %). A 40 Hz floor avoids that case but leaves the EDM weak spot as bad as 2.0.0.
- Bass is a little more often louder than the original (moments more than 6 dB above: +5 6.4 → 7.8 %, +8 5.1 → 6.1 %).
- EDM sub bass at 32 Hz (see the table) and the piano left hand: better at most amounts, not solved.
- Not checked by ear yet. Samples: `~/Downloads/Pitch Shift bass samples/` (5 test songs, original / 2.0.0 / new at
  +5 and +8).

## Tone fix (branch `v2-tone`)

The owner, with Advanced processing on: going down the bass is too loud next to the mids and highs; going up the
mids are slightly too loud; songs sometimes sound muffled, both ways, **compared with normal mode** (Advanced off).

**Test set** (never the owner's music): the 6 Apple Loops songs A-F, each in 4 versions: normal level (-16 dBFS),
"loud" (-9 LUFS through a peak limiter, like a store-bought master), "streaming" (cut above 16 kHz, like AAC) and
both; 20 s of pink noise (shifted pink noise stays pink, so what is left is the engine's own error); 2 more songs
(R&B, soul vocal) never used for tuning. Amounts -12, -8, -5, -3, +3, +5, +8, +12. Rendered with the engine itself
(same output as `--render-file --advanced`). Every level below is after matching loudness, the first 3 s skipped.
Compared with the original **and** with normal mode (installed 2.0.0).

**What the numbers showed (recipe 4 = PR #3):**
- *Bass going down:* the deepest bass, 25-32 Hz, was 8-10 dB above the original at -8 and -12. The shift moves the
  original's 40-60 Hz down there, and the tone EQ boosted 62 Hz by up to 9 dB "where the sub used to be". The rest of
  the bass (40-250 Hz) was not too loud (1.1 dB under the mids).
- *Mids going up:* close to the original (MIDX -0.4 dB, 1 kHz band +1.2 dB at +8). Next to normal mode, though, the
  top above 8 kHz was 1.6-2.7 dB lower, so the mids stand out more.
- *Muffled*, the three suspects:
  - (a) the EQ cutting the treble going up: **real, moderate.** The 11.3 kHz shelf sat at -4 to -5 dB at +8 and +12
    (-5 on streaming copies). Against the original the top was right; normal mode keeps the extra brightness that the
    shift adds, and the EQ was taking it away. Worst songs (hip hop, rock): treble vs mids 2.7-2.8 dB under normal.
  - (b) the safety limiter: **real on loud songs, both ways.** On the loud versions it worked 65-75 % of the time
    (worst song 90 %), up to 5-6 dB, pulling 2-8 kHz down by 0.5-0.8 dB on average and 2.4-3.6 dB in the worst 1 % of
    moments. Going down it was mostly caused by the EQ's boosts (EQ off: 21-37 % of the time); going up by the shift
    itself (normal mode's output on the same songs goes 0.3-3.4 dB over full scale; it has no limiter). On
    normal-level songs: 0.1-2.8 % of the time (one song 15 % at -5).
  - (c) the dip where the unshifted top joins in going down: **real, small.** -1.0 to -1.4 dB at 10-12.5 kHz on pink
    noise (-3 to -8), -2.4 dB at 10 kHz in the songs at -3/-5. Going up there is no dip.
  - Going down, Advanced is never duller than normal mode in the long-term sound (2-5 dB brighter, normal mode loses
    the top). There "muffled" can only be the limiter on loud songs and the deep rumble.
  - Not a cause: the EQ looking at a mono mix (mono vs left+right differ by up to 5 dB in single bands, the same in
    normal mode: it comes from the shift itself).

**The fix: engine recipe 5, now the default** (`advanced_tune(chain, "recipe", 4)` gives PR #3's output sample for
sample, `3` gives 2.0.0's; knobs in `AdvancedTuning.h`):
- The EQ knows which way the pitch went.
  - Going down: a 4th-order high-pass on the shifted sound, 40 Hz at -8 and below (less at smaller amounts), so the
    original's deep bass doesn't pile up under 32 Hz; the EQ may boost below 70 Hz by 3 dB at most (was 6); small
    target changes (+1 dB at 100 Hz, +0.5 at 200 Hz, -0.5 at 800 Hz and 1.6 kHz).
  - Going up: the EQ cuts at most 3 dB from 7 kHz up (keeps the top closer to normal mode), and -0.5 dB at 800 Hz and
    1.6 kHz.
  - The EQ's prediction now counts a frequency on a band edge in both bands, as its measurement does (it was nudging
    the bass up by up to 1.2 dB).
- Going down, the split to the unshifted top is a Butterworth 4 (its two halves add up to full power): no dip.
- Limiter: after a short over (under 5 ms) the gain comes back in 25 ms instead of 120 ms. Longer overs keep 120 ms.
- Tried and not kept: a "headroom guard" that turns down the EQ's bass boost while the limiter works. The bass boost
  was not the main cause, and the guard changed the tone of loud songs (0.6-0.9 dB quieter, less bass).
- Tuning: the target offsets were fitted from the measured leftovers (`fit_offsets.py`); after the changes above the
  songs mostly disagreed on what was left, so only these few small offsets stayed.

**Before → after (recipe 4 → recipe 5):**

Going down (6 songs, normal level, vs the original):

| N | deep bass 25-32 Hz | bass vs mids (BMR) | 60-150 Hz | tone error (tbDev) | 2 held-out songs: 25-32 Hz |
|---|---|---|---|---|---|
| -3 | +2.3 → +2.4 dB | -1.2 → -1.5 dB | -0.4 → -0.5 dB | 2.94 → 2.94 | +1.9 → +2.1 dB |
| -5 | +3.5 → +2.4 dB | -1.1 → -1.3 dB | -0.5 → -0.8 dB | 4.05 → 3.97 | +3.8 → +3.9 dB |
| -8 | +8.1 → +2.2 dB | -1.1 → -1.4 dB | -0.1 → -0.5 dB | 4.45 → 4.08 | +7.4 → +5.1 dB |
| -12 | +9.6 → +1.2 dB | -0.2 → -0.8 dB | +0.3 → -0.2 dB | 4.69 → 4.50 | +8.2 → +3.0 dB |

Going up (mids vs the original; top vs normal mode, on the streaming copies):

| N | mids (MIDX) | 1 kHz band | treble vs mids, vs normal | above 8 kHz, vs normal | tone error (tbDev) |
|---|---|---|---|---|---|
| +3 | -0.5 → -0.5 dB | +0.7 → +0.5 dB | -0.6 → -0.4 dB | -1.6 → -1.4 dB | 3.72 → 3.70 |
| +5 | -0.5 → -0.6 dB | +0.2 → -0.0 dB | -0.5 → -0.3 dB | -1.8 → -1.1 dB | 3.80 → 3.82 |
| +8 | -0.4 → -0.7 dB | +1.2 → +0.7 dB | -0.5 → -0.1 dB | -2.7 → -1.4 dB | 3.70 → 3.77 |
| +12 | +0.8 → +0.3 dB | +0.3 → -0.4 dB | +0.3 → +1.1 dB | -2.7 → -1.0 dB | 1.72 → 1.84 |

Safety limiter (normal-level songs: share of time limiting, mean / worst song; loud songs: the same, and how much
2-8 kHz is pulled down):

| N | normal level | loud: time | loud: 2-8 kHz, mean | loud: worst 1 % |
|---|---|---|---|---|
| -12 | 1.2 / 6.1 % → 0.0 / 0.0 % | 65 → 23 % | -0.8 → -0.4 dB | -3.3 → -2.5 dB |
| -8 | 1.4 / 5.2 % → 0.2 / 0.4 % | 70 → 26 % | -0.7 → -0.3 dB | -3.0 → -2.2 dB |
| -5 | 2.8 / 15.4 % → 0.2 / 0.9 % | 72 → 27 % | -0.6 → -0.3 dB | -2.7 → -2.0 dB |
| -3 | 0.6 / 3.5 % → 0.1 / 0.4 % | 75 → 27 % | -0.6 → -0.3 dB | -2.7 → -2.0 dB |
| +3 | 0.5 / 1.4 % → 0.1 / 0.3 % | 73 → 25 % | -0.5 → -0.2 dB | -2.4 → -1.9 dB |
| +5 | 0.1 / 0.8 % → 0.0 / 0.1 % | 65 → 20 % | -0.5 → -0.2 dB | -2.5 → -1.8 dB |
| +8 | 0.5 / 3.0 % → 0.1 / 0.6 % | 66 → 27 % | -0.5 → -0.2 dB | -3.3 → -2.5 dB |
| +12 | 1.4 / 7.0 % → 0.3 / 1.5 % | 71 → 26 % | -0.5 → -0.2 dB | -2.8 → -2.0 dB |

- Going down, the top-end dip on pink noise: -1.4 → -0.2 dB (-5, -3), -1.0 → +0.3 dB (-8).
- PR #3's lost-bass measure (16 bass clips): +5 3.25 → 3.54 %, +8 1.72 → 1.73 % (limit: 1 point worse).
- Unchanged: normal mode (byte-identical with 2.0.0), the delay (138 ms engine within ±12, 225 ms past), CPU
  (median +1.4 % at +5, 0 % at -8), no memory made while playing, Windows checks (27/27 on the Mac's copy).

**Weak spots left:**
- Going down, more of the low bass goes: on bass-only clips the 20-100 Hz level is 2.4 dB lower at -8 than with
  recipe 4 (lost-bass moments 35 → 43 %). That is the deep rumble the owner called too loud, but listen for it.
- The hip hop song's 50 Hz sub ends up near 31 Hz at -8, so its bass vs mids stays 6-7 dB under the original with both
  recipes. Only moving that bass up an octave going down would fix it.
- Held-out songs: the deep bass improved at -8/-12 (+7.4 → +5.1, +8.2 → +3.0 dB), not at -3/-5; at +8/+12 their tone
  error grew a little (1.55 → 1.68, 0.85 → 1.23 dB) because the top now stays closer to normal mode.
- Loud songs: the limiter still has to take 3.6-5 dB off the biggest shifted peaks (normal mode lets them go over full
  scale instead). It now does it more briefly.
- Not heard yet. Samples: `~/Downloads/Pitch Shift tone samples/` (4 test songs plus a loud, streaming-like pop song;
  original / 2.0.0 / new at -5, -8, +5, +8; all at -18 LUFS).

## Auto EQ (branch `paid-auto-eq`)

For a future paid version; local branch only. Five sections, **Sub** (20-80 Hz), **Bass** (80-250), **Mids**
(250-2k), **Highs** (2k-8k) and **Air** (8k and up), whose levels are moved automatically so each stays near the
ORIGINAL song's share, whatever the amount. It only looks at loudness; the per-pitch tone fix (recipe 5) stays as it
is. Off by default, and then the sound is byte-identical to `v2-next`.

**Design (engine `AutoEQ5` in `AdvancedChain.cpp`):**
- Where: in `render()`, after the keep signal is added back and **before** bass / treble and the limiter. Planned
  after bass / treble, but then it measures the Bass ↔ Treble slider's own change and undoes it (within ±6 dB);
  before it, the slider still tilts the sound on top of the matched balance. The delay does not change (IIR only).
- Split: Linkwitz-Riley 4th-order crossovers at 80, 250, 2000, 8000 Hz in a tree. The high side of each crossover is
  "all-pass minus low-pass" (an LR4 pair adds up to that all-pass exactly), one filter instead of two. The lower
  sections go through the higher crossovers' all-passes, nested (`AP4(AP3(AP2(g1·Sub) + g2·Bass) + g3·Mids) +
  g4·Highs + g5·Air`), so all five stay in phase: at 0 dB the stage is an all-pass, flat within 0.000 dB (checked
  with an impulse). Both channels run side by side in double precision (`Biquad2`, the compiler pairs them).
- Measuring, every 256 samples (512 above 64 kHz): each section's mean square over the last 1 s (a running sum
  of block energies), of the sound coming in (mono mix of its sections) and of the original input at the same moment
  (history + keep at `t - L`, mono). Sub is measured from 20 Hz up (2nd-order high-pass on the measuring only): pink
  noise and some songs have energy below 20 Hz that the engine's 40 Hz high-pass going down removes on purpose, and
  counting it made Auto EQ pump up the Sub.
- Target per section: the original's share minus this sound's share (dB), with a common level so the **loudness**
  stays: the totals are weighted with the K-weighting (BS.1770) at each section's middle, and the common level is
  solved again after the ±8 dB limit (±6 before tuning). A section quieter than -60 dBFS in both goes to 0 dB.
- Moves: cut with a 300 ms time constant, lift with 1.5 s (200 ms / 1 s before tuning; one-pole in dB, once per
  block); the gain itself ramps
  sample by sample across the next block. (The first plan, a 400 ms window with 80 / 600 ms, matched worse and
  wobbled more; see the results.) Because cuts are faster than lifts, the gains on their own drift down (up
  to 1.5 dB quieter on the test songs); the level change they make (same weighting) is taken back out, smoothed like a
  cut, so only the balance moves.
- Manual offsets (−12…+12 dB per section) glide 0.25 dB per 32 samples and are added on top; automatic + offset is
  held within ±15 dB. Switching on or off fades over 50 ms between the untouched sound and the stage (the split turns
  the phase, so a hard switch would click); off with all offsets 0, once faded, the stage is skipped.
- Live values: `advanced_get_auto_eq` reads the automatic gains and each section's output level through a sequence
  lock over atomics (written once per block; a reader never makes the sound thread wait).

**API:** C `advanced_set_auto_eq(chain, on, offsetsDb[5])`, `advanced_get_auto_eq(chain, autoDb[5], levelDb[5])`;
tune keys `aeqrange` 8, `aeqattack` 300, `aeqrelease` 1500, `aeqwindow` 1000, `aeqf1`..`aeqf4` 80/250/2000/8000,
`aeqfloor` -60, plus `aeqlowhz` 20, `aeqweight` 1, `aeqkeep` 1. Swift `AdvancedProcessor.setAutoEQ(on:offsets:)`,
`readAutoEQ()`, `AdvancedPlayer.setAutoEQ`/`autoEQReadout`/`init(..., autoEQ:)`, `HearShifter.setAutoEQ`/
`autoEQReadout`. Command line: `--render-file … --advanced --auto-eq [--eq-offsets a,b,c,d,e]`, the same for `--test`
(`--watch` also prints the gains).

**Results of the first build** (before tuning: range 6, 200 ms / 1 s; offline; Apple Loops test songs A-F and pink
noise; tools in `research/advanced/autoeq/`):
- Auto EQ off (the default) = byte-identical to the `v2-next` build: 21 of 21 renders (pink noise and song B at
  +5 -5 +8 -8 0, Bass ↔ Treble settings, +15, amounts changed while playing, normal mode; offsets all 0 without
  `--auto-eq`; normal mode with `--auto-eq --eq-offsets 3,3,3,3,3`, which it ignores).
- Delay: `advanced_latency_frames` 6619 within ±12 and 10797 past ±12, on or off, the same as `v2-next`.
- At 0 dB the stage is flat: 20 Hz-20 kHz within 0.000000 dB.
- Pink noise, each section's share minus the original's (dB, Sub … Air), off → on:
  +5: +0.17 -0.03 +0.01 +0.11 -0.33 → -0.03 -0.06 +0.01 +0.09 -0.02;
  -5: -1.58 +0.76 +0.17 +0.24 +0.47 → -0.50 +0.51 +0.03 +0.08 +0.07. Loudness on vs off: -0.01 / +0.04 LU.
- 28 cases (6 songs + pink noise at +5 -5 +8 -8), from 2 s on: mean share error off 1.12 → on 0.40 dB; the worst
  section per case 2.00 → 0.98 dB on average (largest 5.30 → 3.73, song A's Bass at +8); cases with every section
  within 1 dB: 9 → 18. Per section off 1.26 1.19 0.98 0.89 1.30 → on 0.53 0.78 0.19 0.18 0.30 dB. Loudness on vs off:
  mean +0.00, worst +0.43 LU (EDM at -8), all 28 within 0.5. The gains wobble (std over time) 0.74 dB on average,
  1.89 at most. The first plan's timing (400 ms window, 80 / 600 ms) on the same cases: 1.12 → 0.58 dB, largest 6.18,
  13 cases within 1 dB, loudness worst -0.56 LU, wobble 1.13 / 2.01 dB, steps up to 0.43 dB per 256 samples.
- Gain speed: at most 0.10 dB per 256 samples on the 28 cases (0.12 when switched on mid-song; usually 0.01-0.04),
  and each change is ramped sample by sample.
- Clicks: switching on and off every 2 s, and jumping all offsets by 6 dB, on a 200 Hz tone and a 5-tone mix at +5
  and -5: nothing above 16 kHz louder than -92.7 dBFS (-108 without the switching); the largest sample-to-sample step
  does not change when switching.
- CPU (`advanced_process`, song B, 512-sample calls, mean of 3 runs): +5: `v2-next` 1.18 ms, off 1.21, on 1.22;
  -8: 0.56 / 0.57 / 0.585. The stage alone: 1.41 ms per second of stereo sound (0.14% of one core).
- No memory is made inside `advanced_process` / `advanced_set_semis` with Auto EQ on, switched off and on, and the
  offsets moving while the amount changes (±12 and full range).
- Readout: 199 million `advanced_get_auto_eq` reads from a second thread while the engine ran, 0 torn values (the
  thread sanitizer crashes on this Mac even on an empty program, so it was not used).
- Builds: the engine with `-Wall -Wextra`, portable FFT (as on Windows) and vDSP: no warnings; the app: no new
  warnings.

### Auto EQ tuning and checks

**Test set** (never the owner's music): the 6 Apple Loops songs A-F, their "loud" (hot) and "streaming" (lp16)
copies, pink noise, and 2 songs never used for tuning (G R&B, H soul vocal); amounts -12 -8 -5 -3 +3 +5 +8 +12.
Rendered like `--render-file --advanced` (1024-frame calls, delay taken out; harness `aeqrender.cpp`, which also logs
the five automatic gains and levels every 100 ms). Compared with the original, from 2 s on:
- *share error*: each section's share of the total (section dB minus total dB; the engine's own LR4 split, mono) in
  400 ms windows, render minus original; the mean and the 95th percentile (p95) of |error| per section. A window
  counts only where the original's section is above -60 dBFS and within 40 dB of the total. Shares don't depend on
  the level, so no loudness matching is needed.
- long-term: the same over the whole song; the 1/3-octave error `tonal_balance` (loudness matched);
- loudness (LUFS) Auto EQ on minus off; *movement*: |change| of each automatic gain per second (dB/s) from the 100 ms
  log; Highs onset crest (2-8 kHz peak around each drum hit over the level around it), on minus off; the limiter's
  time over 0.1 dB.

**Results, final setting (range 8, 300 ms / 1.5 s), 6 songs, Sub / Bass / Mids / Highs / Air (dB):**

| N | p95 off | p95 on | p95 normal mode | mean off | mean on |
|---|---|---|---|---|---|
| -12 | 8.0 / 5.4 / 4.2 / 5.5 / 4.7 | 6.5 / 4.6 / 3.3 / 4.2 / 3.3 | 7.4 / 7.1 / 4.8 / 7.0 / 15.0 | 3.3 / 2.8 / 2.0 / 2.4 / 2.8 | 2.4 / 2.2 / 1.5 / 1.7 / 1.5 |
| -8 | 6.8 / 4.2 / 3.7 / 4.0 / 3.7 | 5.3 / 4.0 / 2.9 / 3.1 / 2.9 | 5.6 / 5.2 / 3.4 / 4.8 / 9.2 | 2.8 / 2.2 / 1.9 / 2.0 / 2.2 | 1.9 / 1.8 / 1.1 / 1.2 / 1.2 |
| -5 | 5.0 / 3.6 / 2.9 / 2.9 / 3.0 | 3.7 / 3.1 / 2.1 / 2.1 / 2.3 | 3.9 / 3.6 / 2.2 / 3.2 / 5.5 | 2.0 / 1.6 / 1.4 / 1.4 / 1.5 | 1.4 / 1.4 / 0.8 / 0.9 / 1.0 |
| -3 | 3.3 / 2.8 / 2.1 / 2.0 / 2.2 | 2.6 / 2.3 / 1.5 / 1.5 / 1.8 | 2.6 / 2.3 / 1.4 / 2.1 / 3.2 | 1.3 / 1.2 / 0.9 / 0.9 / 1.1 | 0.9 / 1.0 / 0.6 / 0.6 / 0.8 |
| +3 | 2.5 / 1.7 / 1.3 / 1.6 / 1.7 | 2.2 / 1.7 / 1.1 / 1.5 / 1.6 | 2.8 / 2.2 / 0.9 / 1.2 / 2.1 | 1.1 / 0.8 / 0.6 / 0.8 / 0.8 | 1.0 / 0.8 / 0.5 / 0.6 / 0.6 |
| +5 | 3.1 / 2.8 / 2.3 / 2.8 / 2.8 | 3.1 / 2.6 / 1.5 / 2.2 / 2.2 | 5.0 / 3.6 / 1.6 / 2.1 / 3.4 | 1.1 / 1.3 / 1.1 / 1.3 / 1.5 | 1.1 / 1.1 / 0.7 / 0.9 / 0.9 |
| +8 | 3.2 / 3.4 / 2.3 / 2.9 / 3.3 | 2.9 / 3.0 / 1.9 / 2.4 / 2.8 | 8.6 / 5.4 / 2.7 / 3.4 / 4.9 | 1.3 / 1.6 / 1.1 / 1.3 / 1.9 | 1.0 / 1.4 / 0.7 / 1.0 / 1.2 |
| +12 | 0.8 / 0.8 / 1.8 / 3.2 / 4.4 | 1.1 / 1.0 / 1.8 / 2.9 / 4.3 | 14.5 / 7.5 / 4.0 / 5.1 / 6.7 | 0.3 / 0.3 / 0.9 / 1.3 / 2.6 | 0.4 / 0.4 / 0.7 / 1.3 / 1.6 |
| all | 4.1 / 3.1 / 2.6 / 3.1 / 3.2 | 3.4 / 2.8 / 2.0 / 2.5 / 2.6 | 6.3 / 4.6 / 2.6 / 3.6 / 6.2 | 1.7 / 1.5 / 1.2 / 1.4 / 1.8 | 1.2 / 1.2 / 0.8 / 1.0 / 1.1 |

- Long-term share error (mean |error|): 1.1 / 1.1 / 1.0 / 0.9 / 1.4 → 0.5 / 0.7 / 0.2 / 0.2 / 0.4 dB; 1/3-octave
  error 3.59 → 3.52 dB (normal mode 7.73). Loudness on vs off: mean +0.00, worst +0.43 LU, 48 of 48 within 0.5.
  Highs onset crest: -0.01 dB on average, worst case -0.14. Limiter time: 0.112 → 0.047 %. Movement: 0.68 dB/s
  (RMS), 95th percentile 1.4 dB/s, the busiest song 2.6 dB/s; at most 0.083 dB per 256 samples.
- Pink noise: p95 2.4 / 1.1 / 0.5 / 0.5 / 0.9 → 1.7 / 1.0 / 0.5 / 0.5 / 0.4, loudness within 0.12 LU.
- Held-out songs G, H: p95 1.5 / 1.7 / 2.0 / 2.5 / 2.1 → 1.4 / 1.6 / 1.8 / 2.4 / 1.5, mean 0.7 / 0.8 / 0.8 / 0.9 / 1.2 →
  0.5 / 0.7 / 0.8 / 0.9 / 0.7, long-term 0.5 / 0.4 / 0.4 / 0.4 / 1.0 → 0.2 / 0.3 / 0.1 / 0.1 / 0.2; loudness worst
  +0.29 LU; limiter 2.0 → 1.7 %.
- Loud copies: p95 3.7 / 3.2 / 2.6 / 3.1 / 3.5 → 3.1 / 2.9 / 1.9 / 2.5 / 2.7; limiter 25.1 → 24.9 %; loudness 47 of 48
  within 0.5 (hip hop at -8: -0.71 LU). Streaming copies: like the normal songs (p95 → 3.4 / 2.8 / 2.0 / 2.5 / 2.7).

**Goals** (Auto EQ on at the defaults, mean over the 6 songs): p95 ≤ 2 dB in every section: **not met** (3.4 / 2.8 /
2.0 / 2.5 / 2.6; at ±3 only the Sub, and the Bass at -3, are above 2; the held-out songs meet it except Highs 2.4). Loudness within ±0.5 dB: met (one loud-copy
case -0.71). Movement under ~6 dB/s: met (0.7 RMS, 2.6 worst). Onset crest not worse by > 0.5 dB: met (-0.01).
Limiter not worse: met (better). Held-out songs improve: yes, in every section.

**Why p95 ≤ 2 dB can't be reached with a slow leveler:** a perfect 1 s leveler (it knows the true share error over
the last second and applies it exactly, no delay; `oracle.py` on the Auto EQ-off renders) gets p95 2.9 / 2.1 / 1.7 /
2.2 / 2.1 (2.8 / 1.8 / 1.4 / 2.0 / 1.8 if it could also see the next half second). What is left is inside the beat:
the shifted kick's and bass notes' low end lasts and decays differently from the original's, so the Sub's share in a
400 ms window swings ±2 dB with the rhythm. Only a leveler that pumps with the beat could follow that.

**Settings tried** (6 songs x 8 amounts; p95 Sub..Air, movement RMS, worst loudness change):

| setting | p95 | dB/s | LU |
|---|---|---|---|
| first build: range 6, 200 ms / 1 s, window 1 s | 3.48 / 2.80 / 1.99 / 2.49 / 2.64 | 0.86 | +0.43 |
| range 8 / 9 / 12 | 3.43 / 2.78 / 1.97 / 2.47 / 2.61; 3.42 / 2.78 / 1.97 / 2.46 / 2.60; 3.41 / 2.78 / 1.99 / 2.44 / 2.58 | 0.87-0.88 | +0.43 / +0.48 / +0.62 |
| window 0.5 s / 1.5 s | 3.49 / 2.77 / 2.01 / 2.49 / 2.76; 3.50 / 2.80 / 2.03 / 2.54 / 2.70 | 1.65 / 0.62 | -0.52 / +0.42 |
| 100 ms / 0.5 s, window 0.5 s | 3.51 / 2.75 / 1.99 / 2.53 / 2.77 | 2.57 | -0.53 |
| 50 ms / 0.3 s, window 0.4 s | 3.43 / 2.74 / 1.99 / 2.62 / 2.80 | 4.30 | -0.54 |
| 150 ms / 0.8 s; 300 ms / 1.5 s | 3.48 / 2.80 / 1.99 / 2.49 / 2.63; 3.48 / 2.80 / 2.02 / 2.50 / 2.67 | 0.99 / 0.67 | +0.43 / +0.42 |
| **range 8, 300 ms / 1.5 s (kept)** | **3.43 / 2.79 / 2.00 / 2.48 / 2.64** | **0.68** | **+0.43** |
| floor -50 dBFS | no change | | |
| `aeqkeep` 0 / `aeqweight` 0 | the same errors | | -0.90 / -2.70 |

Faster settings only add movement; the errors hardly change (see the floor above). Range 8 helps the Sub a little on
sub-heavy songs; 9 and 12 start to move the loudness. 300 ms / 1.5 s move 20 % less for the same match and use the
limiter a little less. After an amount change while playing (0 → +8 → -8, songs A, B, F) the first-build timing and
the kept one settle the same (within 0.1 dB); 100 ms / 0.5 s settles a little faster in the first second only.
Crossovers stay at the owner's sections (80 / 250 / 2000 / 8000 Hz).

**Found and not changed: a section's gain only partly reaches its section.** The five sections overlap (LR4), so a
gain on one section moves that section's measured level by only about 70-90 % (Bass about 68 % on pink noise, often
50 % on bass-heavy songs, where the notes sit near 80 Hz), and less when a neighbour moves the other way (song A at
+8: Bass asked -3.3 dB, got -0.4 dB). That is why song A's Bass stays 3-4 dB too strong at ±8 and ±12. Tried in a
scratch copy: applying `W⁻¹ x` the wanted changes (W = how much each section's gain reaches each section, for pink
noise): Sub / Bass p95 3.37 / 2.65 (from 3.48 / 2.80), long-term Bass 0.73 → 0.53 dB (worst 5.8 → 4.0), but Mids-Air
p95 a little worse and song A 1 dB quieter (the loudness model adds section powers, which overlap in phase). Measured
loudness weights per section made the loudness worse. Not kept; a possible next step is to measure each section's
level after the gains and correct slowly.

**Lost-bass check (PR #3's measure, 16 bass clips, % of 100 ms moments with 20-100 Hz more than 6 dB under the
original):** +5: off 3.54 → on 4.87 (**+1.33, over the 1-point limit**); +8: 1.73 → 2.25 (+0.52); -5: 24.2 → 15.4;
-8: 43.3 → 36.4. The increase comes from the split's phase turn, not from the gains: with every gain held at 0
(`aeqrange` 0) it is +1.50 / +0.61, and the gains themselves lower it a little (-0.17 / -0.09 points). The split is an
all-pass at 0 dB: no level change, but the lowest notes come out about 7 ms later than the highs (80 Hz and 250 Hz
corners), so some 100 ms moments next to a note's start or end fall under -6 dB. Measured against the original passed
through the same all-pass, Auto EQ on scores 3.43 % at +5 (off: 3.54 %). No tune setting changes it (range 4, 2 s
window, 500 ms / 2 s: +1.22 … +1.37). Avoiding it would need a different split (gains added to the untouched sound),
a bigger change.

**Fixed: slowdown in digital silence on Intel and AMD processors.** After a few seconds of exact zeros the stage's
filter memories sank into "denormal" numbers; an Intel build (Rosetta) then took up to 102 ms for one 512-sample call
at -8 (mean 0.87 ms, p99 5.6 ms; Auto EQ off: 0.55 ms). Now memories under 1e-20 are set to 0 once per block: mean
0.48 ms, p99 0.96 ms, max 1.8 ms. Apple silicon was not affected; music renders with Auto EQ on are byte-identical.

**Checks with the final engine:**
- Auto EQ off = byte-identical to the `v2-next` build: 6 of 6 (pink +5, song B -8, +12, +15, +5 with the tone slider
  at 0.6 and `--eq-offsets 0,0,0,0,0`, normal mode -5 with `--auto-eq --eq-offsets 3,3,3,3,3`).
- New defaults = the tuned keys on the old defaults: byte-identical (songs A and B at +5 and -8); the app's
  `--render-file --advanced --auto-eq` gives the same samples as the harness.
- Delay: 6619 frames within ±12, 10797 past it, Auto EQ on and off, the same as `v2-next`.
- Clicks: switching on/off every 2 s and 6 dB offset jumps (200 Hz tone, 5-tone mix, +5 and -5): nothing above 16 kHz
  louder than -92.7 dBFS.
- CPU (song B, 512-sample calls, mean of 3): +5: `v2-next` 1.243 ms, off 1.254, on 1.267; -8: 0.594 / 0.602 / 0.620.
- Memory: 0 allocations inside `advanced_process` / `advanced_set_semis` (on, switching, offsets moving, ±12 and full
  range). Readout: 201.8 million reads from another thread while playing, 0 broken values.
- Engine with `-Wall -Wextra`, portable FFT and vDSP: no warnings; app: no new warnings. Windows DSP tests built on
  the Mac with the portable FFT: 27 of 27 passed (peak -0.30 dBFS).
- Not run: the one live check (`--test --advanced --auto-eq --watch` on a quiet tone). The owner's Swoopy app
  was running for the whole 10 minutes it waited, so nothing was played or recorded.

**Review notes** (engine and Swift glue): no memory or locks on the sound path; the readout is a sequence lock over
atomics; the five sections add back up flat (derived: at 0 dB the output is AP4·AP3·AP2·AP1 of the input). Two small
things left as they are: `HearShifter.autoEQReadout` uses `audioQueue.sync`, so a window timer can wait while a
player is being rebuilt (never the sound); and a new offsets array replaces the old one on the Advanced worker thread
when a slider moves (one small free there, not on the Core Audio thread). Switching Auto EQ on or off crossfades the
untouched and the phase-turned sound for 50 ms: no click, at most a brief "swish".

**Samples:** `~/Downloads/Pitch Shift auto EQ samples/` (hip hop, EDM, piano, held-out soul vocal; A original, B
Advanced, C Advanced + Auto EQ at -8, +5, +8; 12 s at -18 LUFS). Measured on the samples, worst section vs the
original, B → C: hip hop 5.4 → 2.5 (-8), 3.9 → 3.4 (+5), 5.3 → 3.9 (+8); EDM 3.5 → 2.5, 1.7 → 0.6, 2.6 → 1.2; piano
4.6 → 2.1, 1.0 → 0.2, 1.5 → 0.7; soul vocal 0.6 → 0.2, 1.4 → 0.3, 1.2 → 0.3 dB.

Tools and results: `research/advanced/autoeq/tune/` (`aeqrender.cpp`, `aeqmeasure.py`, `grid.py`, `report.py`,
`tables.py`, `oracle.py`, the scripts, every measurement as JSON in `results/`; the scripts were run from a scratchpad
folder, see `env.sh`). Agent 1's checks in `research/advanced/autoeq/` run with `AEQ_TREE` / `AEQ_WORK` set.

## Not verified yet

- Listening (all choices were made by measurements).
- Real songs (only Apple Loops mixes were used), Bluetooth headphones, other Macs (M1), long sessions.
- How fast clicking through amounts sounds (numbers only).
- Amounts beyond ±12 were tuned by numbers on the same 6 songs only.

## Listening samples

`~/Downloads/Pitch Shift advanced samples/` (made with the app's own `--render-file`, except D): 4 test songs at +5,
+8 and -5, each as A original, B normal, C advanced, and for + amounts D advanced with AI drums (research render).
All at the same loudness (-18 LUFS). README.txt in the folder says what to listen for.

## Checks

- `Swoopy --render-file IN OUT --steps N [--advanced] [--steps-at "4:8,8:-5"]`: shift a file with the app's own
  code (normal or advanced); `--steps-at` changes the amount while it plays.
- `Swoopy --test --pid N --steps N --advanced --watch [--record-out F.wav] [--steps-at ...]`: live test with a
  quiet tone; prints the delay parts every half second; `--record-out` saves what Advanced processing played.
- Bass fix measurements: the harness, scripts and test-clip maker are in the git-ignored `research/advanced/bass/`
  (`advrender.cpp` renders like `--render-file --advanced` with `advanced_tune` settings; `run.py` renders all clips
  and measures; `cmp.py` compares setups; `synth.py` makes the made-up bass clips).
- Tone fix measurements: `research/advanced/tone/` (git-ignored). `tools/tonerender.cpp` = the harness plus the EQ
  gains and limiter numbers every second; `grid.py` renders a setup over songs × versions × amounts and keeps only the
  measurements (`results/feat/`); `analyze.py` / `targets.py` / `muffled.py` / `report_*.py` make the tables;
  `fit_offsets.py` fits the target offsets; `verify.sh`, `cpu.sh`, `live.sh`, `bassgate.sh` are the checks.
  `make_variants.py` makes the loud / streaming versions and the pink noise, `make_heldout.py` the 2 extra songs.
