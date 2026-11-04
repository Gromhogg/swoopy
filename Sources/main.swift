// Pitch Shift: plays an app's sound (or all sound) and/or your voice at a higher or lower pitch, live.
// Checks from Terminal (inside "Pitch Shift.app/Contents/MacOS/PitchShift"):
//   --list                                     sound devices (with model UIDs; and which are in use), Pitch Shift Mic,
//                                              the saved Bass ↔ Treble and Auto EQ per output, the voice's mic, and
//                                              which app each sound process belongs to
//   --watch-output [--seconds 10]              once a second: the output's sample rate (Bluetooth call mode shows
//                                              8000-24000 Hz), its own mic, and which apps record from which devices
// The device tests (--test, --test-voice, --test-button, --test-sounds, --test-default-mic) refuse to start while Pitch
// Shift Mic, the built-in mic or a Bluetooth mic is in use by another app (for example a call), or the Pitch Shift app
// is open.
//   --test [--pid N | --app BUNDLE_ID | --all] [--steps 2.5] [--seconds S]     "What you hear" for a few seconds
//   --test-voice [--mic NAME] [--tone 440 | --file F] [--steps 3] [--cartoon | --cartoon-amount 0.5] [--seconds S]
//                [--slow-deeper] [--out F.caf] [--watch] [--buffer N]
//                                              sends a tone or file through the voice chain and records Pitch Shift Mic
//                                              (voice style from 0 = Natural, the default, to 1 = Cartoon; --cartoon = 1;
//                                              --slow-deeper turns on "Deeper when slow" and prints the speaking rate
//                                              and the extra shift once a second).
//                                              --watch: the tone plays for half of every second; once a second it prints
//                                              the sound waiting to go out, the dry-outs/trims/replays and the delay from
//                                              the mic to Pitch Shift Mic (the delay parts are printed at the start).
//                                              --buffer N: callback size to ask for (default 128, or 256 above 48 kHz)
//                                              --voice Woman [--strength S] [--realism R] [--changer-tune ...]
//                                              [--changer-stats] [--compute cpu|gpu|ane|all]: with the voice changer
//                                              on (--realism 0 ... 1 = "Faster ↔ More real": from 0.05 the AI voice;
//                                              --quality realistic = its default 0.25; its fixed delay, late pieces and
//                                              the time Natural filled in are printed; --watch also prints what
//                                              it does; with --file, --watch measures the delay at each start of the
//                                              file's sound: give it a file with ~1 s of silence first)
//   --render-voice IN OUT [--steps 3] [--cartoon | --cartoon-amount 0.5] [--cartoon-at "1:1,2:0"] [--slow-deeper]
//                [--voice-preset old]          shifts a sound file with the voice's own settings (offline, no devices;
//                                              --cartoon-at "1:1,2:0" moves the style to 1 at 1 s and back to 0 at 2 s;
//                                              --voice-preset old: as before the Natural level fix, for comparing)
//                [--fast-higher N]             with --slow-deeper (here and in --test-voice): "Higher when fast", up
//                                              to N half-steps higher when talking fast (0 ... 8; left out = 0, off)
//                [--voice Woman [--strength 1] [--realism R] [--changer-tune "k=v,..."] [--changer-stats]]
//                                              with the voice changer (the amount, style and --slow-deeper are then
//                                              ignored: only one at a time;
//                                              --changer-stats prints what it does once per second of sound;
//                                              --changer-tune ai32=0: the AI voice exactly as in 3.1.1, see VoiceModel.h;
//                                              aiSounds=0: claps, clicks and whistles changed by the AI too, as
//                                              before 3.4; aiSecond=0: no second voice for laughs and hums;
//                                              --block-background: "Block background sounds" on, the AI voice's
//                                              main voice is its quiet version, here and in --test-voice/-button)
//                [--live-sim [--buffer 128]]   instead: the live chain's steps in callback-sized pieces (with the
//                                              waiting sound), printing the delay they add (no devices)
//   --list-voices [--voices-dir DIR]           the voice changer's voices (and files that were skipped)
//   --add-voice PATH [--pitch high|medium|low|HZ] [--voices-dir DIR]
//                                              adds a voice folder or a .zip of one, as "Add Voice…" does (into DIR,
//                                              else the Voices folder); --rename-voice ID NAME, --remove-voice ID
//   --render-sounds VOICE OUT --sound FILE [--at 5,20] [--sound-volume 1] [--speakers] [--voice-db 0] [--shifted]
//                [--buffer 128] [--sound-preset old]
//                                              Soundboard, offline (no devices): VOICE as the mic, FILE clicked at each
//                                              --at second, OUT = what Pitch Shift Mic would send (the chain's own
//                                              mixing); prints the highest sample, how many samples are near full
//                                              scale, and how long the mixing takes per callback (--sound-preset old:
//                                              as in 2.0.2, before the limiter, fades and loudness cap)
//   --test-button [--mic NAME] [--volume 0.03] presses Test with a quiet tone as the voice (record 5 s, play back)
//                [--file F] [--voice Woman [--realism R | --quality realistic]]
//                                              --file: a speech file as the voice (looped, its loudest point at
//                                              --volume); --voice: with the voice changer on, so it records and plays
//                                              back the changed voice (Realistic: Test is pressed once the AI voice
//                                              is ready; --steps is not used with --voice: only one at a time)
//   --test-sounds FILE [--speakers] [--seconds S] [--out F.caf] [--mic NAME] [--steps 3] [--volume 0.05] [--hear 0.02]
//                [--sound-volume 0.5] [--voice-off] [--voice Woman [--realism R | --quality realistic]]
//                                              Soundboard: plays FILE into Pitch Shift Mic 1 s in, with a quiet tone as
//                                              the voice, records Pitch Shift Mic and checks it (one copy of the sound,
//                                              its level; --speakers: as if on the Mac's speakers, so the voice must
//                                              stop while it plays). --hear: also play it here at that volume.
//                                              --recording F.caf: check a recording saved with --out (no devices).
//                                              --stop-after S: press Stop S seconds after the sound starts.
//                                              --hear-out F.caf: save the owner's copy (with --hear).
//                                              --sound-volume V: the sound's own volume (0 ... 1.5, Volume… on its
//                                              button), so its level in Pitch Shift Mic should be V x the file.
//                                              --voice-off: as with "Your voice" off and the Soundboard open: the
//                                              tone must come through at its own pitch (440 Hz), no shift.
//   --test ... --advanced [--record-out F.wav] [--steps-at "3:8,6:-5"] [--tone-amount 0.5] [--tone-at "2:1,4:-1"]
//              [--as-device UID] [--tone-db 6,-6] [--auto-eq] [--eq-offsets 0,0,0,0,0]
//                                              "What you hear" with Advanced processing on (--watch prints the delay;
//                                              --record-out saves what it played; --steps-at changes the amount live;
//                                              --tone-amount sets the Bass ↔ Treble slider, −1 … 1, for the output;
//                                              --tone-at moves it live; --as-device uses that device's saved Bass ↔
//                                              Treble and Auto EQ as if it were playing; --tone-db sets bass and
//                                              treble in dB; --auto-eq turns on Auto EQ, --eq-offsets gives its five
//                                              manual offsets in dB, Sub, Bass, Mids, Highs, Air, instead of the saved
//                                              Auto EQ; --watch also prints its gains and levels while it's in use)
//   --render-file IN OUT [--steps 5] [--advanced | --super] [--steps-at "4:8,8:-5"] [--tone-amount 0.5] [--tone-at "2:1,4:-1"]
//                [--tone-db 6,-6] [--auto-eq] [--eq-offsets 0,0,0,0,0]
//                                              shifts a sound file with the app's own code (normal, Advanced
//                                              processing or Super Advanced)
//   --as-free (with any mode above)            as the free version plays it: Bass ↔ Treble in the middle, Auto EQ off,
//                                              the voice style at Cartoon, Deeper when slow and Higher when fast off,
//                                              no Voice changer; the options for those are ignored (one note says
//                                              which), and --render-sounds, --test-sounds (the Soundboard) and
//                                              --add-voice, --rename-voice, --remove-voice stop with a message.
//                                              A copy with Pitch Shift Pro locked always plays this way, like the
//                                              window ("Pitch Shift Pro is locked: ... ignored (free version)").
// Pitch Shift Pro (Sources/Pro.swift, notes/paid-unlock-plan.md):
//   --pro-status                               locked or unlocked, and why
//   --pro-key KEY                              unlocks with a key, like the unlock window (checks it on this Mac, no
//                                              internet, and keeps it)
//   --pro-reset                                locks Pro again (forgets the key)
//                [--pro-file F] [--pro-public-key HEX] [--pro-old-keys ISSUED]
//                                              checks only: keep the key in F (any mode); check keys with another
//                                              public key (64 hex characters) and/or the older keys listed in ISSUED
//                                              (lines like issued.txt's), not this build's (only with --pro-key /
//                                              --pro-status and --pro-file, or --pro-check: they never unlock the
//                                              sound or the window)
//   --pro-check F [--pro-public-key HEX] [--pro-old-keys ISSUED]
//                                              checks only: each key in F (one per line): unlocks, typo or wrong
//   --pro-test tools/pro-keys-test.txt         checks only: the app accepts the same fixed test keys as
//                                              tools/pro-keys.sh, and only those
import AppKit
import AVFoundation
import CoreAudio
import CryptoKit

let args = CommandLine.arguments
func arg(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
// --preview STATES [--size 800x400] [--cartoon-amount 0.5] [--tone-amount -0.4] [--eq-offsets 3,-2,0,1,-1]
// [--strength 0.6]: show the window in a state for screenshots, without touching any sound or settings, and without
// switching apps (states: hear-on, voice-on, waiting, typing, recording, playing, listening, hover, menu, roll, resize,
// no-driver, advanced-alert, sounds, rename, volume, drop, light, tone, super, slow, eq, changer, changer-man,
// changer-realistic, changer-loading, changer-fallback, changer-slider-natural|fast|default|max|NN, changer-intel,
// changer-second-off, changer-quiet-on, changer-card-off, click-voice, click-vc;
// --cartoon-amount sets the voice style slider; sounds opens the Soundboard with example names, rename shows the first
// name being changed, volume the first sound's volume slider and drop files being dragged over it; "tone" shows
// Advanced processing on, and --tone-amount sets the Bass ↔ Treble slider; slow turns on "Deeper when slow"; eq turns
// on Auto EQ, and --eq-offsets sets its five sliders, which show only the offsets since no sound plays; without eq,
// Auto EQ shows off; changer turns on the Voice changer with Woman (Your voice then shows off, even with voice-on:
// only one at a time), changer-man with Man (--voice NAME: that voice, an added one too), --strength sets its
// Strength slider, changer-realistic/-loading/-fallback show the AI voice (the slider's default) working/getting
// ready/standing in with Natural, changer-slider-* puts the "Faster ↔ More real" slider at Natural, the first AI
// step, the default, the far right or NN percent, changer-intel the card as on an Intel Mac (the slider stays at
// Natural), changer-second-off / changer-quiet-on the two 3.5 switches off / on, changer-card-off the card with its
// switch off (its settings as given); click-voice / click-vc turn Your voice's / the Voice changer's switch on half
// a second in, as a click
// would (the other one goes off); resize drags the window's corner through the three layouts; pro-locked shows
// Pitch Shift Pro locked, pro-unlocked unlocked (the default for pictures), pro-unlock the unlock window, with pro-typo
// a key with a typo in it, with pro-paste a key pasted from an email (line breaks and spaces in it), with pro-done
// the "Unlocked" message, with pro-alone as its own window instead of a sheet;
// switch-flip shows the switches slowed down 10 times: the first card's goes on and turns back halfway, the second
// card's is held down). --steps 3,-2 sets the two cards' big numbers (one number: both).
let preview = arg("--preview")
let previewStates = Set((preview ?? "").split(separator: ",").map(String.init))

// Pitch Shift Pro. Checks only: --pro-file F keeps the key in F (see --pro-public-key below).
if let path = arg("--pro-file") { Pro.shared.file = URL(fileURLWithPath: path) }
// There is no unlock server and no key secret any more (keys are signed, and checked on the Mac); an old test script
// stops here instead of opening the window.
if args.contains("--pro-server") { print("--pro-server: there is no server any more (keys are checked on this Mac)"); exit(1) }
if args.contains("--pro-secret") { print("--pro-secret: there is no key secret any more (keys are signed); see --pro-public-key"); exit(1) }
// While Pitch Shift Pro is locked (a build with the public key and no key that works), every mode below plays as the
// free version does, like the window (see Free): the options for paid features are ignored with one note, and the
// Soundboard modes and adding voices stop here, before any device is touched. --as-free does the same in any copy
// (for comparing). Pictures (--preview) show the state they're asked for instead and play nothing.
if preview == nil { Pro.shared.load() }
let proLocked = preview == nil && !Pro.shared.unlocked
let asFree = preview == nil && (proLocked || args.contains("--as-free"))
if asFree {
    let why = proLocked ? "Pitch Shift Pro is locked" : "--as-free"
    if let mode = ["--render-sounds", "--test-sounds"].first(where: args.contains) {
        print("\(why): the Soundboard is part of Pitch Shift Pro, so \(mode) doesn't run (free version)."); exit(1)
    }
    if let mode = ["--add-voice", "--rename-voice", "--remove-voice"].first(where: args.contains) {
        print("\(why): your own voices are part of Pitch Shift Pro, so \(mode) doesn't run (free version)."); exit(1)
    }
    // The Voice changer, Natural ↔ Cartoon, Deeper when slow and Higher when fast, Bass ↔ Treble, Auto EQ.
    let paid = ["--voice", "--strength", "--realism", "--quality", "--changer-tune", "--changer-stats", "--block-background",
                "--cartoon", "--cartoon-amount", "--cartoon-at", "--slow-deeper", "--fast-higher",
                "--tone-db", "--tone-amount", "--tone-at", "--as-device", "--auto-eq", "--eq-offsets"].filter(args.contains)
    if !paid.isEmpty { print("\(why): \(paid.joined(separator: ", ")) ignored (free version).") }
}
// Checks of the key code only: --pro-public-key HEX checks keys with that public key instead of this build's, and
// --pro-old-keys ISSUED accepts the older keys listed in ISSUED (lines like issued.txt's) instead of this build's
// list; with --pro-check F, or with --pro-key / --pro-status and --pro-file F (so the real Pro.json is never
// touched). They're read after the lock above was worked out and never reach the sound or the window: a key pair
// anyone can make must not unlock anything.
if arg("--pro-public-key") != nil || arg("--pro-old-keys") != nil {
    guard ["--pro-check", "--pro-key", "--pro-status"].contains(where: args.contains),
          arg("--pro-file") != nil || arg("--pro-check") != nil else {
        print("--pro-public-key, --pro-old-keys: only with --pro-check F, or with --pro-key or --pro-status and --pro-file F")
        exit(1)
    }
    if let hex = arg("--pro-public-key") {
        guard ProKeyCheck(publicKey: hex, oldKeys: []).publicKey != nil else { print("--pro-public-key: 64 hex characters"); exit(1) }
        Pro.shared.publicKey = hex
    }
    if let path = arg("--pro-old-keys") {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("--pro-old-keys: can't read \(path)"); exit(1) }
        // The last word of each line is a key (as in issued.txt: date, name, key); the 25-character ones count.
        Pro.shared.oldKeys = text.split(whereSeparator: \.isNewline).compactMap { $0.split(separator: " ").last.map(String.init) }
            .filter { ProKey.raw($0).count == ProKey.length }.map(ProKey.oldFingerprint)
    }
}

var signalSources: [DispatchSourceSignal] = []
func onQuitSignals(_ handler: @escaping () -> Void) {
    signalSources = [SIGINT, SIGTERM, SIGHUP].map { sig in
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler(handler: handler)
        source.resume()
        return source
    }
}

// --tone-db "B,T": Advanced processing's bass and treble in dB (not --tone, which is a frequency in --test-voice).
// The free version (asFree): none of the Bass ↔ Treble or Auto EQ options below.
let toneDbArg: (bass: Double, treble: Double)? = {
    let parts = (arg("--tone-db") ?? "").split(separator: ",").compactMap { Double($0) }
    return parts.count == 2 && !asFree ? (parts[0], parts[1]) : nil
}()
// --tone-amount T: the Bass ↔ Treble slider, −1 (more bass) … 0 (middle) … 1 (more treble). In --preview it sets
// where the slider is. --tone-at "2:1,4:-1": moves it to 1 at 2 s, then to −1 at 4 s.
func parseTilt(_ text: Substring) -> Float? { Float(text).flatMap { $0.isFinite ? max(-1, min(1, $0)) : nil } }
let toneArg: Float? = asFree ? nil : arg("--tone-amount").flatMap { parseTilt(Substring($0)) }
let toneChanges: [(Double, Float)] = asFree ? [] : (arg("--tone-at") ?? "").split(separator: ",").compactMap { item in
    let parts = item.split(separator: ":")
    guard parts.count == 2, let t = Double(parts[0]), let value = parseTilt(parts[1]) else { return nil }
    return (t, value)
}

// --auto-eq: Advanced processing's Auto EQ on. --eq-offsets "a,b,c,d,e": its manual offsets in dB (Sub, Bass, Mids,
// Highs, Air; −12 … 12; missing ones are 0).
let autoEQArg: (on: Bool, offsets: [Double]) = {
    guard !asFree else { return (false, AdvancedProcessor.noOffsets) }
    let given = (arg("--eq-offsets") ?? "").split(separator: ",").compactMap { Double($0) }.filter(\.isFinite).map { max(-12, min(12, $0)) }
    return (args.contains("--auto-eq"), Array((given + AdvancedProcessor.noOffsets).prefix(5)))
}()

func fourCC(_ value: UInt32) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }, encoding: .ascii) ?? "\(value)"
}

// Voice style from the command line: --cartoon = 1 (Cartoon), --cartoon-amount X (0 = Natural ... 1 = Cartoon).
// In --preview it sets where the slider is. The free version: always Cartoon.
let cartoonArg: Float? = asFree ? Free.cartoon
    : args.contains("--cartoon") ? 1 : arg("--cartoon-amount").flatMap(Float.init).map { max(0, min(1, $0)) }
// "Deeper when slow" asked for (--test-voice, --render-voice; left out with --voice, see slowDeeperArg).
let slowDeeperAsked = args.contains("--slow-deeper")

// The voice changer, for --render-voice and --test-voice: --voice NAME (Woman, Man or another voice's id),
// --strength S (0 ... 1, default 1), --realism R (0 ... 1) or --quality natural|realistic, --changer-tune
// "key=value,..." (VoiceChanger.h, VoiceModel.h), --changer-stats (once a second: what it is doing). --voices-dir DIR: also read voices from DIR (they replace
// built-in voices with the same id). --list-voices: the voices found, and files that were skipped.
if let dir = arg("--voices-dir") { VoiceLibrary.extraFolder = URL(fileURLWithPath: dir) }
let changerTuneArg: [(String, Float)] = (arg("--changer-tune") ?? "").split(separator: ",").compactMap { item in
    let parts = item.split(separator: "=")
    guard parts.count == 2, let value = Float(parts[1].trimmingCharacters(in: .whitespaces)) else {
        print("--changer-tune: can't read \"\(item)\" (use key=value)"); exit(1)
    }
    return (parts[0].trimmingCharacters(in: .whitespaces), value)
}
// The voice asked for with --voice (nil without --voice; stops with a message if it can't be used). The free version
// (asFree): none (the Voice changer is part of Pitch Shift Pro).
let changerArg: ChangerOptions? = {
    guard let name = arg("--voice"), !asFree else { return nil }
    guard let entry = VoiceLibrary.shared.voice(name) else {
        print("--voice: no voice \"\(name)\". Voices: \(VoiceLibrary.shared.voices.map(\.name).joined(separator: ", "))"); exit(1)
    }
    guard let natural = entry.natural else { print("--voice: \(entry.name) has no Natural mode settings"); exit(1) }
    if !changerTuneArg.isEmpty, let probe = voicechanger_new(48000, 512) {  // check the keys before starting
        let aiKeys = ["aiSlowMs", "aiSlowEvery", "aiGainMaxDb", "aiSmoothFrames", "aiGapFrames", "aiQuietDb",
                      "aiLookaheadMs", "aiSlowFrames", "aiIntonation", "aiSolaMode", "aiGainMs", "aiOnsetFrames",
                      // 3.2 (VoiceModel.h): "ai32=0" = 3.1.1's AI voice
                      "aiSplit", "aiAheadMax", "aiAutoChip", "aiStartChip", "aiGraceMs", "aiRealtime", "aiLeftMs",
                      "aiFadeAdapt", "aiJoinGains", "aiGainTwoSided", "aiNearMs", "aiBridgeStrict", "aiShortRunMs",
                      "aiHissCross", "aiGainCap", "aiPauseDb", "aiLimit", "aiSlowChip",
                      // 3.4 (VoiceModel.h; "hum34=0" = 3.3's voice changer, VoiceChanger.cpp too)
                      "aiHumLiftDb", "aiHumLevelDb"]  // Realistic mode's test keys (voicestream_tune)
        let unknown = changerTuneArg.filter { voicechanger_tune(probe, $0.0, $0.1) == 0 && !aiKeys.contains($0.0) && !isVoiceShifterTuneKey($0.0)
            && voicestream_second_key($0.0) == 0 }.map(\.0)  // (3.5: the second voice's keys)
        voicechanger_delete(probe)
        let gate = soundgate_new(48000)  // 3.4: "aiSounds" and SoundGate's "sg..." keys
        let stillUnknown = unknown.filter { key in key != "aiSounds" && soundgate_tune(gate, key, changerTuneArg.first { $0.0 == key }?.1 ?? 0) == 0 }
        soundgate_delete(gate)
        if !stillUnknown.isEmpty { print("--changer-tune: unknown keys \(stillUnknown.joined(separator: ", "))"); exit(1) }
    }
    let strength = arg("--strength").flatMap(Float.init).map { max(0, min(1, $0)) } ?? 1
    let quiet = args.contains("--block-background")
    if quiet && entry.quietURL == nil { print("Note: \(entry.name) has no \"Block background sounds\" voice; its usual AI voice is used.") }
    return ChangerOptions(voice: natural, strength: strength, tune: changerTuneArg, stats: args.contains("--changer-stats"), quiet: quiet)
}()
// Only one at a time (the owner's rule, as in the window): with --voice the voice changer sets the pitch, so --steps
// and --slow-deeper are left out.
if changerArg != nil && (arg("--steps") != nil || slowDeeperAsked) {
    print("Note: with --voice the voice changer sets the pitch, so --steps and --slow-deeper are ignored (only one at a time).")
}
let slowDeeperArg = asFree ? Free.slowDeeper : slowDeeperAsked && changerArg == nil
// "Higher when fast" with --slow-deeper: --fast-higher N half-steps (0 ... 8; left out = 0, off, as before).
let fastHigherArg: Float = asFree ? Free.fastHigher
    : slowDeeperArg ? VoiceShifter.cleanFastHigher(arg("--fast-higher").flatMap(Float.init) ?? 0) : 0
// The amount for the voice: --steps (or `fallback`), except with --voice, where it is not used (the changer sets the
// pitch; the fallback keeps the renders as they were).
func voiceStepsArg(_ fallback: Float) -> Float { changerArg != nil ? fallback : arg("--steps").flatMap(Float.init) ?? fallback }
// Why Realistic (AI) mode can't run here (nil = it can).
#if arch(arm64)
let realisticUnavailable: String? = nil
#else
let realisticUnavailable: String? = "needs Apple silicon"
#endif
// --compute cpu|gpu|ane|all|auto: which chips run the AI voice (auto: the encoder on the Neural Engine, the voice on
// the GPU, the CPU if those can't be used).
if let name = arg("--compute") {
    guard let units = computeUnits(named: name) else { print("--compute: cpu, gpu, ane, all or auto"); exit(1) }
    VoiceModelStore.computeUnits = units
}
// The voice changer's "Faster ↔ More real" slider: --realism 0 ... 1 (0 = Natural, from 0.05 the AI voice with more
// look-ahead further right, 1 = the most real, about a second of delay). --quality realistic = the slider's default
// AI position, --quality natural = 0 (the old switch's two settings).
let realismArg: Float = {
    if let text = arg("--realism") {
        guard let value = Float(text), value.isFinite, value >= 0, value <= 1 else { print("--realism: a number from 0 to 1"); exit(1) }
        return value
    }
    switch arg("--quality") ?? "natural" {
    case "natural": return 0
    case "realistic": return ChangerSettings.defaultRealism
    default: print("--quality: natural or realistic"); exit(1)
    }
}()
let realisticArg = realismArg >= ChangerSettings.aiStart
let lookaheadArg = ChangerSettings(realism: realismArg).lookaheadMs

if args.contains("--list-voices") {
    let library = VoiceLibrary.shared
    print("Voices (built in: \(VoiceLibrary.builtInFolder?.path ?? "-"); added: \(VoiceLibrary.userFolder.path)\(VoiceLibrary.extraFolder.map { "; --voices-dir: \($0.path)" } ?? "")):")
    for voice in library.voices {
        let m = voice.manifest
        var modes: [String] = []
        if let n = m.natural {
            modes.append(String(format: "natural (target %.0f Hz, formant x%.2f, intonation %.2f)", n.targetHz, n.formant, n.intonation))
        }
        if let r = m.realistic {
            let have = voice.modelURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            modes.append("realistic (\(r.model)\(have ? "" : ", model file missing"))")
        }
        print("  \(m.id) \"\(m.name)\" v\(m.version)\(voice.builtIn ? " [built in]" : ""): \(modes.joined(separator: "; ")) — \(voice.folder.path)")
    }
    if library.voices.isEmpty { print("  none") }
    for problem in library.problems { print("  skipped \(problem)") }
    exit(0)
}

// --add-voice PATH [--pitch high|medium|low|HZ]: adds a voice folder (or a .zip of one) as "Add Voice…" does, into
// --voices-dir DIR if given, else the Voices folder (--pitch: for a voice with no Natural settings; default medium).
// --rename-voice ID NAME, --remove-voice ID (to the Trash): an added voice in the same folder (never a built-in one).
if let path = arg("--add-voice") {
    let folder = VoiceLibrary.extraFolder ?? VoiceLibrary.userFolder
    do {
        let found = try VoiceImport.examine(URL(fileURLWithPath: path))
        defer { found.discard() }
        var pitch: [String: Any]?
        if found.needsPitch {
            let asked = arg("--pitch") ?? "medium"
            if let kind = VoicePitch(rawValue: asked.lowercased()) {
                pitch = kind.natural
            } else if let hz = Double(asked), (60...400).contains(hz) {
                pitch = VoicePitch.natural(hz: hz)
            } else {
                print("--pitch: high, medium, low or a number of Hz (60-400)"); exit(1)
            }
            print("\(found.name) has no Natural settings: using pitch \(asked)")
        }
        let taken = Set(VoiceLibrary.shared.voices.map { $0.id.lowercased() })
        let id = try found.install(into: folder, pitch: pitch, taken: taken, names: Set(VoiceLibrary.shared.voices.map { $0.name.lowercased() }))
        print("Added \"\(found.name)\" as \(id) in \(folder.path)")
        exit(0)
    } catch {
        print("Can't add this voice: \((error as? Problem)?.message ?? "\(error)")"); exit(2)
    }
}
if let i = args.firstIndex(where: { $0 == "--rename-voice" || $0 == "--remove-voice" }) {
    let folder = VoiceLibrary.extraFolder ?? VoiceLibrary.userFolder
    let renaming = args[i] == "--rename-voice"
    guard i + (renaming ? 2 : 1) < args.count, let entry = VoiceLibrary.shared.voice(args[i + 1]) else {
        print(renaming ? "usage: --rename-voice ID NAME" : "usage: --remove-voice ID", "(an added voice; --list-voices shows them)"); exit(1)
    }
    do {
        if renaming { try VoiceImport.rename(entry, to: args[i + 2], in: folder) } else { try VoiceImport.remove(entry, in: folder) }
        print(renaming ? "Renamed \(entry.id) to \"\(args[i + 2])\"" : "Moved \(entry.name) to the Trash")
        exit(0)
    } catch {
        print("Can't change this voice: \((error as? Problem)?.message ?? "\(error)")"); exit(2)
    }
}

// The watchdog: a second copy of the app that gives the real mic back if the app ends without doing it.
if let pid = arg("--watchdog").flatMap({ pid_t($0) }) { DefaultMic.watch(pid) }

// Device tests share the Mac's microphones and Pitch Shift Mic with whatever the owner is doing. They only start
// when Pitch Shift Mic, the built-in mic and every Bluetooth mic are idle (not used by any app, for example a call
// in FaceTime, Discord or a browser), and the Pitch Shift app itself isn't open: with "Your voice" on, a test
// reading Pitch Shift Mic would wake the app's voice on the real mic, and the Test playback would send that to the
// owner's headphones. Otherwise they stop right away, before touching any device.
func refuseIfMicsBusy() {
    let me = ProcessInfo.processInfo.processIdentifier
    // (also the installed app's own name: a copy of the app with another bundle name must still see it)
    let names = Set([Bundle.main.bundleIdentifier ?? "local.pitch-shift", "local.pitch-shift"])
    if names.flatMap({ NSRunningApplication.runningApplications(withBundleIdentifier: $0) })
        .contains(where: { $0.processIdentifier != me }) {
        print("Not starting: the Pitch Shift app is open (its voice or sound would mix into the test). Nothing was changed; try again later.")
        exit(2)
    }
    let busy = allDevices().filter { id in
        guard streamCount(id, kAudioDevicePropertyScopeInput) > 0, isRunningSomewhere(id) else { return false }
        let transport = transportType(id)
        return deviceUID(id) == virtualMicUID || transport == kAudioDeviceTransportTypeBuiltIn
            || transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
    guard busy.isEmpty else {
        print("Not starting: \(busy.map(deviceName).joined(separator: ", ")) in use by another app right now (maybe a call). Nothing was changed; try again later.")
        exit(2)
    }
}
// A sound file as one channel at `rate`, to play into the voice chain as the "mic" (--test-voice, --test-button).
func testVoiceFile(_ path: String, rate: Double) -> [Float] {
    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
          let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
          (try? file.read(into: input)) != nil,
          let target = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
          let converter = AVAudioConverter(from: file.processingFormat, to: target),
          let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * rate / file.processingFormat.sampleRate) + 1024)
    else { print("Can't read \(path)"); exit(1) }
    var given = false
    _ = converter.convert(to: converted, error: nil) { _, status in
        if given { status.pointee = .endOfStream; return nil }
        given = true
        status.pointee = .haveData
        return input
    }
    return Array(UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength)))
}

if ["--test", "--test-voice", "--test-button", "--test-default-mic"].contains(where: { args.contains($0) })
    || (args.contains("--test-sounds") && !args.contains("--recording")) { refuseIfMicsBusy() }

// Makes Pitch Shift Mic the default mic and then waits, so a test can force-quit it and check the watchdog.
if args.contains("--test-default-mic") {
    DefaultMic.takeOver()
    print("default mic now: \(deviceName(defaultInput()))")
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { exit(0) }
    dispatchMain()
}

if args.contains("--list") {
    let out = defaultOutput(), inp = defaultInput()
    print("Devices:")
    for id in allDevices() {
        let flags = (id == out ? " [default output]" : "") + (id == inp ? " [default input]" : "") + (isRunningSomewhere(id) ? " [in use]" : "")
        let model = modelUID(id)
        print("  \(id) \(deviceName(id)) | \(deviceUID(id)) | model \(model.isEmpty ? "-" : model) | \(Int(nominalRate(id))) Hz | \(fourCC(transportType(id))) | in \(streamCount(id, kAudioDevicePropertyScopeInput)) out \(streamCount(id, kAudioDevicePropertyScopeOutput))\(flags)")
    }
    // The Bass ↔ Treble slider (Advanced processing), as saved for each speakers or headphones (read only).
    let tones = AppDelegate.savedTones(UserDefaults.standard)
    print("Bass ↔ Treble saved per output (-1 bass … 1 treble):\(tones.isEmpty ? " none" : "")")
    for (uid, tilt) in tones.sorted(by: { $0.key < $1.key }) {
        let id = device(uid: uid)
        let name = id.map { deviceName($0) } ?? "not connected"
        print(String(format: "  %@ (%@): %.2f", uid, name, tilt) + (id == out ? " [default output]" : ""))
    }
    // Auto EQ (Advanced processing), as saved for each speakers or headphones (read only).
    let eqs = AppDelegate.savedAutoEQs(UserDefaults.standard)
    print("Auto EQ saved per output (offsets in dB: Sub, Bass, Mids, Highs, Air):\(eqs.isEmpty ? " none" : "")")
    for (uid, eq) in eqs.sorted(by: { $0.key < $1.key }) {
        let id = device(uid: uid)
        let name = id.map { deviceName($0) } ?? "not connected"
        print("  \(uid) (\(name)): \(eq.on ? "on" : "off"), " + eq.offsets.map { String(format: "%+.1f", $0) }.joined(separator: " ")
            + (id == out ? " [default output]" : ""))
    }
    if let mic = Mics.virtualMic, let feed = Mics.virtualFeed {
        print("Pitch Shift Mic: \(mic) (\(Int(nominalRate(mic))) Hz, in use: \(isRunningSomewhere(mic))), hidden feed: \(feed) (hidden: \(getValue(feed, kAudioDevicePropertyIsHidden, default: UInt32(0)) != 0))")
    } else {
        print("Pitch Shift Mic: not installed")
    }
    print("Microphones to choose from: \(Mics.list().map(\.name))")
    let picked = Mics.choose(nil)
    let why = picked.skipped.map { " (skipped headset mic of the current output: \(deviceName($0)))" } ?? ""
    print("Voice mic (default): \(picked.mic.map(deviceName) ?? "none")\(why)")
    if let saved = UserDefaults.standard.string(forKey: Keys.voiceMic) {
        print("Voice mic (picked in the app): \(Mics.resolve(saved).map(deviceName) ?? "none") (saved: \(saved))")
    }
    print("Sound processes:")
    for process in getArray(system, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self) {
        let pid = getValue(process, kAudioProcessPropertyPID, default: pid_t(-1))
        let bundleID = getString(process, kAudioProcessPropertyBundleID)
        let owner = Apps.ownerApp(of: pid)
        let playing = getValue(process, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
        print("  pid \(pid) \(bundleID.isEmpty ? "(no bundle id)" : bundleID) -> \(owner?.bundleIdentifier ?? "none") (\(owner?.localizedName ?? "-"))\(playing ? " PLAYING" : "")")
    }
    print("Apps in the list: \(Apps.scan().map { "\($0.name)\($0.isPlaying ? " (playing)" : "")" })")
    exit(0)
}

if args.contains("--pro-status") {
    Pro.shared.load()
    print(Pro.shared.status)
    exit(0)
}

if args.contains("--pro-reset") {
    Pro.shared.reset()
    print("Pro: locked (removed \(Pro.shared.file.path))")
    exit(0)
}

if let typed = arg("--pro-key") {
    Pro.shared.load()
    switch Pro.shared.activate(typed) {
    case .unlocked:
        print("Unlocked. \(Pro.shared.status)")
        exit(0)
    case .problem(let text):
        print("Not unlocked: \(text)")
        exit(1)
    }
}

// Checks only: one key per line in F; prints each with "unlocks", "typo" or "wrong" (with this build's public key and
// list of older keys, or --pro-public-key / --pro-old-keys). Nothing is saved.
if let path = arg("--pro-check") {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("--pro-check: can't read \(path)"); exit(1) }
    var counts: [String: Int] = [:]
    for line in text.split(whereSeparator: \.isNewline) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
        let typed = String(line)
        let verdict: String
        if case .failure = ProKey.read(typed) { verdict = "typo" } else { verdict = Pro.shared.works(typed) ? "unlocks" : "wrong" }
        counts[verdict, default: 0] += 1
        print("\(typed)\t\(verdict)")
    }
    print("total: " + ["unlocks", "typo", "wrong"].map { "\(counts[$0] ?? 0) \($0)" }.joined(separator: ", "))
    exit(0)
}

// Checks only: the fixed test keys in tools/pro-keys-test.txt, the same ones tools/pro-keys.sh checks. Signed keys
// ("public HEX", then "signed SERIAL KEY" lines) work with the test public key and not with another; older keys
// ("old SERIAL KEY") work only when they're on the list of older keys. A change of any one character in any of them
// never works.
if let path = arg("--pro-test") {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("--pro-test: can't read \(path)"); exit(1) }
    var publicKey = "", good = 0, bad = 0
    let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    func result(_ ok: Bool, _ what: @autoclosure () -> String) { if ok { good += 1 } else { bad += 1; print("different: \(what())") } }
    func changes(_ key: String) -> [String] {  // every one-character change of a key
        let raw = Array(ProKey.raw(key))
        return raw.indices.flatMap { i in ProKey.alphabet.filter { $0 != raw[i] }.map { c in var k = raw; k[i] = c; return String(k) } }
    }
    for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if parts.count == 2 && parts[0] == "public" { publicKey = parts[1]; continue }
        guard parts.count == 3 else { continue }
        let key = parts[2], serial = parts[1]
        switch parts[0] {
        case "signed":
            let check = ProKeyCheck(publicKey: publicKey, oldKeys: [])
            result(check.publicKey != nil && ProKey.signedParts(key)?.serial == serial && check.works(key)
                   && !ProKeyCheck(publicKey: other, oldKeys: []).works(key), "signed key \(serial) doesn't work with the test public key (only)")
            result(!changes(key).contains(where: check.works), "a one-character change of signed key \(serial) works")
        case "old":
            let listed = ProKeyCheck(publicKey: publicKey, oldKeys: [ProKey.oldFingerprint(key)])
            result(ProKey.kind(key) == .old && ProKey.raw(key).hasPrefix(serial) && listed.works(key)
                   && !ProKeyCheck(publicKey: publicKey, oldKeys: []).works(key), "older key \(serial) isn't accepted only when listed")
            result(!changes(key).contains(where: listed.works), "a one-character change of older key \(serial) works")
        default: continue
        }
    }
    print("pro-test: \(good) of \(good + bad) checks pass")
    exit(bad == 0 && good > 0 ? 0 : 1)
}

// Read only: once a second, the sound output's sample rate and streams, its own mic (Bluetooth headphones), and
// every app that is recording and from which devices. Headphones in call mode show 8000-24000 Hz.
if args.contains("--watch-output") {
    let seconds = arg("--seconds").flatMap(Double.init) ?? 10
    let started = Date()
    func show() {
        let out = defaultOutput()
        var line = String(format: "%4.1fs  ", Date().timeIntervalSince(started))
        line += "output \(deviceName(out)): \(Int(nominalRate(out))) Hz, in \(streamCount(out, kAudioDevicePropertyScopeInput)) out \(streamCount(out, kAudioDevicePropertyScopeOutput))"
        if let mic = Mics.headsetMic(of: out) { line += " | its mic: \(Int(nominalRate(mic))) Hz, open: \(isRunningSomewhere(mic))" }
        for process in getArray(system, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
        where getValue(process, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) != 0 {
            let pid = getValue(process, kAudioProcessPropertyPID, default: pid_t(-1))
            let devices = getArray(process, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput, of: AudioObjectID.self)
            let bundleID = getString(process, kAudioProcessPropertyBundleID)
            let name = bundleID.isEmpty ? Apps.ownerApp(of: pid)?.localizedName ?? "?" : bundleID
            line += " | recording: \(name) (pid \(pid)) from \(devices.map { "\($0) \(deviceName($0))" })"
        }
        print(line)
        if Date().timeIntervalSince(started) + 0.5 >= seconds { exit(0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { show() }
    }
    show()
    dispatchMain()
}

if let input = arg("--render-file") {
    let i = args.firstIndex(of: "--render-file")!
    guard i + 2 < args.count else { print("usage: --render-file IN OUT [--steps N] [--advanced | --super] [--auto-eq] [--eq-offsets a,b,c,d,e]"); exit(1) }
    // "4:8,8:-5" = at 4 s go to +8, at 8 s go to -5
    let changes: [(Double, Float)] = (arg("--steps-at") ?? "").split(separator: ",").compactMap { item in
        let parts = item.split(separator: ":")
        guard parts.count == 2, let t = Double(parts[0]), let n = Float(parts[1]) else { return nil }
        return (t, n)
    }
    let started = Date()
    do {
        // --as-free: Bass ↔ Treble stays in the middle and Auto EQ off, as in the free version.
        try renderFile(input: input, output: args[i + 2], halfSteps: arg("--steps").flatMap(Float.init) ?? 2,
                       advanced: args.contains("--advanced"), heavy: args.contains("--super"), changes: changes,
                       tone: asFree ? AdvancedProcessor.toneDb(tilt: Free.tone) : toneDbArg ?? AdvancedProcessor.toneDb(tilt: toneArg ?? 0),
                       toneChanges: asFree ? [] : toneChanges,
                       autoEQ: asFree ? (false, AdvancedProcessor.noOffsets) : autoEQArg)
        print(String(format: "wrote %@ (%.1f s)", args[i + 2], Date().timeIntervalSince(started)))
        exit(0)
    } catch {
        print("render failed: \((error as? Problem)?.message ?? "\(error)")")
        exit(1)
    }
}

if let input = arg("--render-voice") {
    let i = args.firstIndex(of: "--render-voice")!
    guard i + 2 < args.count else {
        print("usage: --render-voice IN OUT [--steps N] [--cartoon-amount X] [--slow-deeper] [--voice-preset old] [--voice Woman [--strength S]]"); exit(1)
    }
    let preset = arg("--voice-preset") ?? "current"
    guard preset == "current" || preset == "old" else { print("--voice-preset: old or current"); exit(1) }
    // "1:1,2:0" = at 1 s go to Cartoon, at 2 s back to Natural
    let changes: [(Double, Float)] = (arg("--cartoon-at") ?? "").split(separator: ",").compactMap { item in
        let parts = item.split(separator: ":")
        guard parts.count == 2, let t = Double(parts[0]), let n = Float(parts[1]) else { return nil }
        return (t, n)
    }
    if changerArg != nil && realisticArg, let why = realisticUnavailable { print("Realistic mode: \(why); Natural mode is used.") }
    if args.contains("--live-sim") {  // the live chain's timing, offline (see simulateVoiceChain; Natural mode only)
        do {
            try simulateVoiceChain(input: input, output: args[i + 2], halfSteps: voiceStepsArg(3),
                                   cartoon: cartoonArg ?? 0, slowDeeper: slowDeeperArg, fastHigher: fastHigherArg, changer: changerArg,
                                   blockFrames: arg("--buffer").flatMap(Int.init) ?? 128)
            print("wrote \(args[i + 2])")
            exit(0)
        } catch {
            print("live-sim failed: \((error as? Problem)?.message ?? "\(error)")")
            exit(1)
        }
    }
    do {
        // --as-free: the style stays at Cartoon, Deeper when slow off and no voice changer, as in the free version.
        try renderVoiceFile(input: input, output: args[i + 2], halfSteps: voiceStepsArg(3),
                            cartoon: asFree ? Free.cartoon : cartoonArg ?? 0, changes: asFree ? [] : changes,
                            slowDeeper: asFree ? Free.slowDeeper : slowDeeperArg, fastHigher: asFree ? Free.fastHigher : fastHigherArg,
                            levelFix: preset != "old",
                            changer: changerArg)
        // Realistic: the AI voice over the same file, inline (it never comes late), with the Natural render as its
        // fallback sound (only used before the first piece is ready).
        if let changerArg, realisticArg, realisticUnavailable == nil, let entry = arg("--voice").flatMap({ VoiceLibrary.shared.voice($0) }) {
            let natural = try readMonoFile(args[i + 2])
            try renderRealisticFile(input: input, natural: natural.samples, rate: natural.rate, output: args[i + 2], entry: entry,
                                    options: changerArg, lookaheadMs: lookaheadArg)
        }
        print("wrote \(args[i + 2])")
        exit(0)
    } catch {
        print("render failed: \((error as? Problem)?.message ?? "\(error)")")
        exit(1)
    }
}

// Soundboard, offline: VOICE (one channel used) as the mic, FILE clicked at each --at time, written to OUT as what
// Pitch Shift Mic would send. --voice-db: the voice's level change first (a quiet or loud mic); --shifted: the voice
// file already went through the pitch change (--render-voice), so it's treated like the shifted voice.
if let input = arg("--render-sounds") {
    let i = args.firstIndex(of: "--render-sounds")!
    guard i + 2 < args.count, let path = arg("--sound") else {
        print("usage: --render-sounds VOICE OUT --sound FILE [--at 5,20] [--sound-volume 1] [--speakers] [--voice-db 0] [--shifted] [--buffer 128] [--sound-preset old]")
        exit(1)
    }
    let preset = arg("--sound-preset") ?? "current"
    guard preset == "current" || preset == "old" else { print("--sound-preset: old or current"); exit(1) }
    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: input)),
          let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
          (try? file.read(into: source)) != nil else { print("Can't read \(input)"); exit(1) }
    let rate = file.processingFormat.sampleRate
    let clip: SoundClip
    do { clip = try SoundClip(url: URL(fileURLWithPath: path), rate: rate, levelFix: preset != "old") } catch { print("Can't read \(path)"); exit(1) }
    let gain = Float(pow(10, (arg("--voice-db").flatMap(Double.init) ?? 0) / 20))
    let voice = Array(UnsafeBufferPointer(start: source.floatChannelData![0], count: Int(source.frameLength))).map { $0 * gain }
    let starts = (arg("--at") ?? "1").split(separator: ",").compactMap { Double($0) }
    let volume = arg("--sound-volume").flatMap(Float.init).map { max(0, min(SoundEntry.loudest, $0)) } ?? 1
    let made = renderSounds(voice: voice, rate: rate, shifted: args.contains("--shifted"), clip: clip, starts: starts,
                            volume: volume, speakers: args.contains("--speakers"), buffer: arg("--buffer").flatMap(Int.init) ?? 128,
                            old: preset == "old")
    guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, made.out.count))) else { exit(1) }
    buffer.frameLength = AVAudioFrameCount(made.out.count)
    for (n, x) in made.out.enumerated() { buffer.floatChannelData![0][n] = x }
    do { try AVAudioFile(forWriting: URL(fileURLWithPath: args[i + 2]), settings: format.settings).write(from: buffer) } catch {
        print("Can't write \(args[i + 2])"); exit(1)
    }
    let peak = made.out.reduce(Float(0)) { max($0, abs($1)) }
    func over(_ level: Float) -> Int { made.out.reduce(0) { $0 + (abs($1) >= level ? 1 : 0) } }
    print(String(format: "wrote %@: highest sample %.4f (%.2f dBFS); samples at or above 0.999: %d, 0.95: %d, 0.708 (-3 dBFS): %d, 0.7: %d",
                 args[i + 2], peak, 20 * log10(max(1e-9, Double(peak))), over(0.999), over(0.95), over(0.708), over(0.7)))
    print(made.timing)
    exit(0)
}

if args.contains("--test") {
    let source: HearSource = args.contains("--all") ? .all : HearSource(saved: arg("--app") ?? "com.apple.Music")
    // Uses the saved Bass ↔ Treble and Auto EQ for the output, like the app (only read; --tone-amount changes the tone
    // for this test, --auto-eq / --eq-offsets replace the Auto EQ). The free version: none of them, like the window.
    let shifter = HearShifter(halfSteps: arg("--steps").flatMap(Float.init) ?? 2, source: source, advanced: args.contains("--advanced"),
                              heavy: args.contains("--super"), tones: asFree ? [:] : AppDelegate.savedTones(UserDefaults.standard),
                              autoEQs: asFree ? [:] : AppDelegate.savedAutoEQs(UserDefaults.standard))
    shifter.testPID = arg("--pid").flatMap { pid_t($0) }
    shifter.testOutputKey = asFree ? nil : arg("--as-device")
    shifter.fixedToneDb = toneDbArg
    if let toneArg { shifter.setTone(toneArg, for: shifter.outputKey) }
    if !asFree && (args.contains("--auto-eq") || arg("--eq-offsets") != nil) { shifter.fixedAutoEQ = autoEQArg }
    let usedEQ = shifter.fixedAutoEQ ?? shifter.autoEQ(for: shifter.outputKey).engine
    let showAutoEQ = usedEQ.on || usedEQ.offsets.contains { $0 != 0 }
    for (t, value) in toneChanges {
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { shifter.setTone(value, for: shifter.outputKey) }
    }
    let seconds = arg("--seconds").flatMap(Double.init) ?? 3
    // --record-out F (Advanced processing only): saves what it played. --steps-at "2:8,4:-5": change the amount live.
    let recordPath = arg("--record-out")
    if recordPath != nil { shifter.testRecordSeconds = seconds + 1 }
    for item in (arg("--steps-at") ?? "").split(separator: ",") {
        let parts = item.split(separator: ":")
        guard parts.count == 2, let t = Double(parts[0]), let n = Float(parts[1]) else { continue }
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { shifter.halfSteps = n }
    }
    func finish() {
        print("test: \(shifter.report)")
        if let recordPath { shifter.saveTestRecording(to: recordPath); print("wrote \(recordPath)") }
        shifter.stop()
        exit(0)
    }
    onQuitSignals { shifter.stop(); exit(0) }
    shifter.start()
    if args.contains("--watch") {  // print the delay every half second
        let started = Date()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            var line = String(format: "%5.1fs  ", Date().timeIntervalSince(started)) + shifter.timing
            if showAutoEQ, let eq = shifter.autoEQReadout {
                line += "  auto EQ dB" + eq.auto.map { String(format: " %+.1f", $0) }.joined() +
                    "  levels" + eq.level.map { String(format: " %.0f", $0) }.joined()
            }
            print(line)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { finish() }
        RunLoop.main.run()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { finish() }
    dispatchMain()
}

if args.contains("--test-voice") {
    let steps = voiceStepsArg(3)
    let micUID = arg("--mic").flatMap { name in Mics.list().first { $0.name == name }?.uid }
    let voice = VoiceShifter(halfSteps: steps, cartoon: cartoonArg ?? 0, slowDeeper: slowDeeperArg, fastHigher: fastHigherArg, micUID: micUID)
    if let changerArg, let entry = arg("--voice").flatMap({ VoiceLibrary.shared.voice($0) }) {  // --voice: the voice changer on
        voice.changerTune = changerArg.tune
        voice.changer = ChangerSettings(on: true, quiet: changerArg.quiet, voiceID: entry.id, strength: changerArg.strength, realism: realismArg)
    }
    guard let mic = voice.currentMic, let virtualMic = Mics.virtualMic else { print("No mic or Pitch Shift Mic not installed"); exit(1) }
    let rate = nominalRate(mic)
    let seconds = arg("--seconds").flatMap(Double.init) ?? 3
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let cpuStart = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    let wallStart = Date()
    let tone = arg("--tone").flatMap(Double.init)
    let sourceSamples: [Float] = arg("--file").map { testVoiceFile($0, rate: rate) } ?? []
    var phase = 0.0, position = 0
    let toneStart = Int(rate)  // the tone starts 1 s in, once recording runs, so its delay can be measured
    // --watch: the tone plays for half of every second, so the delay can be measured again each second.
    // With --file, the delay is measured where the file's sound starts, each time it starts over.
    let watch = args.contains("--watch")
    let fileOnset = sourceSamples.firstIndex { abs($0) > 0.02 } ?? 0
    let watchFile = watch && tone == nil && !sourceSamples.isEmpty
    let toneStarts = UnsafeMutablePointer<Double>.allocate(capacity: Int(seconds) + 2)  // host time of each tone start (s)
    var toneCount = 0
    voice.testBufferFrames = arg("--buffer").flatMap(UInt32.init)
    voice.testSource = { buffer, frames in
        for i in 0..<frames {
            if let tone {
                let t = position - toneStart
                let on = t >= 0 && (!watch || t % Int(rate) < Int(rate) / 2)
                if watch && t >= 0 && t % Int(rate) == 0 && toneCount < Int(seconds) + 2, let chain = voice.chain {
                    phase = 0
                    toneStarts[toneCount] = Double(AudioConvertHostTimeToNanos(chain.blockInputTime)) / 1e9 + Double(i) / rate
                    toneCount += 1
                }
                buffer[i] = on ? Float(0.3 * sin(phase)) : 0
                if on { phase += 2 * .pi * tone / rate }
                position += 1
            } else if !sourceSamples.isEmpty {
                if watchFile && position % sourceSamples.count == fileOnset && toneCount < Int(seconds) + 2, let chain = voice.chain {
                    toneStarts[toneCount] = Double(AudioConvertHostTimeToNanos(chain.blockInputTime)) / 1e9 + Double(i) / rate
                    toneCount += 1
                }
                buffer[i] = sourceSamples[position % sourceSamples.count]
                position += 1
            } else {
                buffer[i] = 0
            }
        }
    }
    onQuitSignals { voice.stop(); exit(0) }
    voice.start()
    voice.hold(true)  // runs the chain like the Test button does (no app is listening yet)
    guard let chain = voice.chain else { print("voice did not start: \(voice.state)"); exit(1) }
    if changerArg != nil {  // the Voice changer card's "Delay: about …" for these settings (the test's sound skips the mic's own part)
        let card = voice.changerDelay(for: voice.changer), mic = deviceDelay(mic, kAudioDevicePropertyScopeInput)
        print(String(format: "card: Delay: about %.2f s (%.0f ms; without the mic's own %.0f ms: %.0f ms, to compare with the measured delay)",
                     card, card * 1000, mic * 1000, (card - mic) * 1000))
    }
    let recorder = try! Recorder(device: virtualMic, seconds: seconds)
    var delays: [Double] = []  // --watch: mic to Pitch Shift Mic, once per tone start (ms)
    if watch {
        print(chain.delayParts)
        let started = Date()
        var scanned = 0, quiet = 0, matched = 0
        func ms(_ frames: Int) -> Double { Double(frames) / chain.sampleRate * 1000 }
        func look() {
            // New tone starts heard in Pitch Shift Mic: loud after at least 0.15 s of quiet.
            let heard = recorder.recorded(from: scanned)
            let base = Double(AudioConvertHostTimeToNanos(recorder.firstInputTime)) / 1e9
            for (k, x) in heard.enumerated() {
                if abs(x) > 0.02 {
                    if quiet >= Int(0.15 * recorder.sampleRate), recorder.firstInputTime > 0 {
                        let at = base + Double(scanned + k) / recorder.sampleRate
                        // Count only the first sound soon after a tone start (a tone fades in and out a little): within
                        // 0.9 s for the tone (it starts every second), 1.5 s for a file (the AI voice can be 1 s late).
                        if let index = (0..<toneCount).last(where: { toneStarts[$0] <= at }), index >= matched,
                           at - toneStarts[index] < (watchFile ? 1.5 : 0.9) {
                            delays.append((at - toneStarts[index]) * 1000)
                            matched = index + 1
                        }
                    }
                    quiet = 0
                } else {
                    quiet += 1
                }
            }
            scanned += heard.count
            let s = chain.stats.withLock { s -> VoiceStats in
                let copy = s
                s.lowest = .max
                return copy
            }
            var line = String(format: "%3.0fs  ring %5d (%5.1f ms, lowest %@) | Rubber Band + ring %5.1f ms | callback %d",
                              Date().timeIntervalSince(started), s.ring, ms(s.ring), s.lowest == .max ? "  -  " : String(format: "%5.1f ms", ms(s.lowest)),
                              ms(s.delay), s.frames)
            line += String(format: " | margin %.1f ms | dry-outs %d, trims %d (%.0f ms), replays %d (%.0f ms), overloads %d",
                           ms(s.margin), s.dryOuts, s.trims, ms(s.trimmed), s.replays, ms(s.replayed), s.overloads)
            if tone != nil || watchFile {
                line += delays.last.map { String(format: " | mic to Pitch Shift Mic %.0f ms", $0) } ?? " | mic to Pitch Shift Mic -"
            }
            print(line)
            if s.changing { print(changerStatsLine(s.changer, seconds: Date().timeIntervalSince(started).rounded())) }
            if let ai = chain.aiStats { print(aiStatsLine(ai.stats, latencyMs: ai.latencyMs, seconds: Date().timeIntervalSince(started).rounded())) }
            if Date().timeIntervalSince(started) < seconds - 0.5 { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { look() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { look() }
    }
    // Realistic: when the AI voice started playing (the models load in the background; Natural plays meanwhile).
    let aiStarted = Date()
    var aiReadyAfter: Double?
    if chain.aiStats != nil {
        func check() {
            if aiReadyAfter == nil, let ai = chain.aiStats, ai.stats.loaded != 0 {
                aiReadyAfter = Date().timeIntervalSince(aiStarted)
                print(String(format: "AI voice playing after %.1f s (%@)", aiReadyAfter!, voice.changerState == .realistic ? "realistic" : "\(voice.changerState)"))
            }
            if !watch, let ai = chain.aiStats, Int(Date().timeIntervalSince(aiStarted)) % 10 == 9 {
                print(aiStatsLine(ai.stats, latencyMs: ai.latencyMs, seconds: Date().timeIntervalSince(aiStarted).rounded()))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { check() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { check() }
    }
    if changerArg?.stats == true && !watch {  // once a second: what the voice changer is doing
        let started = Date()
        func report() {
            let s = chain.stats.withLock { $0 }
            if s.changing { print(changerStatsLine(s.changer, seconds: Date().timeIntervalSince(started).rounded())) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { report() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { report() }
    }
    if slowDeeperArg {  // once a second: the speaking rate and the extra shift in use
        let started = Date()
        func report() {
            let reading = chain.slowReading.withLock { $0 }
            print(String(format: "%4.1fs  ", Date().timeIntervalSince(started)) + reading.line)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { report() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { report() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.2) {
        let recorded = recorder.finish()
        let changerState = voice.changerState  // before stopping (stopping turns it off)
        voice.stop()
        let peak = recorded.reduce(Float(0)) { max($0, abs($1)) }
        let firstSound = recorded.firstIndex { abs($0) > 0.02 }.map { Double($0) / recorder.sampleRate * 1000 }
        let s = chain.stats.withLock { $0 }
        getrusage(RUSAGE_SELF, &usage)
        let cpuEnd = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        let cpuShare = (cpuEnd - cpuStart) / max(0.001, Date().timeIntervalSince(wallStart)) * 100
        var line = "voice test: mic=\(chain.micName) rate=\(Int(chain.sampleRate)) style=\(voice.cartoon) callback=\(s.frames) "
        line += String(format: "shifter+wait=%.0fms dry-outs=%d overloads=%d ", Double(s.delay) / chain.sampleRate * 1000, s.dryOuts, s.overloads)
        line += "recorded=\(recorded.count) peak=\(peak) firstSound=\(firstSound.map { "\(Int($0))ms" } ?? "none")"
        line += String(format: " cpu=%.1f%% of one core (whole test)", cpuShare)
        if let ai = chain.aiStats {  // Realistic: misses count only after the AI voice started playing
            line += String(format: " | AI voice: ready after %@, delay %.0f ms fixed, pieces %lld, late %lld, Natural filled in %.2f s, piece %.1f ms avg / %.1f ms worst, AI thread %.0f%% of a core",
                           aiReadyAfter.map { String(format: "%.1f s", $0) } ?? "never", ai.latencyMs, ai.stats.hops, ai.stats.misses,
                           ai.stats.fallbackSeconds, ai.stats.averageHopMs, ai.stats.worstHopMs, ai.stats.cpuShare * 100)
        }
        if changerArg != nil {
            line += " changer=\(changerState)"
            if s.changing {
                line += String(format: " (shift %+.2f half-steps, shape x%.3f, speaker median %.0f Hz, cost %.3f ms per 10 ms, worst %.3f)",
                               s.changer.semitones, s.changer.formant, s.changer.medianHz, s.changer.analyseMs, s.changer.worstMs)
            }
        }
        if tone != nil, let heard = recorded.firstIndex(where: { abs($0) > 0.02 }), chain.firstInputTime > 0, recorder.firstInputTime > 0 {
            // From the tone starting at the mic to it coming out of Pitch Shift Mic.
            let toneAt = Double(AudioConvertHostTimeToNanos(chain.firstInputTime)) / 1e9 + Double(toneStart) / rate
            let heardAt = Double(AudioConvertHostTimeToNanos(recorder.firstInputTime)) / 1e9 + Double(heard) / recorder.sampleRate
            line += String(format: " delay=%.0fms", (heardAt - toneAt) * 1000)
        }
        if let tone, recorded.count > Int(recorder.sampleRate) {
            let tail = Array(recorded.suffix(Int(recorder.sampleRate)))
            let sr = recorder.sampleRate
            func level(_ f: Double) -> Double {
                var re = 0.0, im = 0.0
                for (i, x) in tail.enumerated() { re += Double(x) * cos(2 * .pi * f * Double(i) / sr); im += Double(x) * sin(2 * .pi * f * Double(i) / sr) }
                return 2 * sqrt(re * re + im * im) / Double(tail.count)
            }
            let expected = tone * pow(2, (s.changing ? Double(s.changer.semitones) : Double(steps)) / 12)
            let best = stride(from: min(tone, expected) * 0.5, through: max(tone, expected) * 2, by: 0.5).max { level($0) < level($1) }!
            line += String(format: " | expected %.1f Hz, measured %.1f Hz, level %.3f, original left %.4f", expected, best, level(best), level(tone))
        }
        print(line)
        if !delays.isEmpty {
            let sorted = delays.sorted()
            print(String(format: "watch: mic to Pitch Shift Mic %.0f..%.0f ms (median %.0f) over %d %@ starts (first %.0f, last %.0f)",
                         delays.min()!, delays.max()!, sorted[sorted.count / 2], delays.count, watchFile ? "sound" : "tone",
                         delays.first!, delays.last!))
        }
        if let path = arg("--out"), let format = AVAudioFormat(standardFormatWithSampleRate: recorder.sampleRate, channels: 1),
           let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(recorded.count)) {
            buffer.frameLength = AVAudioFrameCount(recorded.count)
            recorded.withUnsafeBufferPointer { memcpy(buffer.floatChannelData![0], $0.baseAddress!, recorded.count * MemoryLayout<Float>.size) }
            let file = try! AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: format.settings)
            try! file.write(from: buffer)
            print("wrote \(path)")
        }
        exit(0)
    }
    dispatchMain()
}

// Presses the Test button with a quiet tone as the "voice": records 5 s from Pitch Shift Mic, then plays it back.
// --voice NAME [--quality realistic]: with the voice changer on, so it records the changed voice (Realistic: Test is
// pressed once the AI voice is ready). --file F: a speech file (looped, its loudest point at --volume) instead of the
// tone.
if args.contains("--test-button") {
    let micUID = arg("--mic").flatMap { name in Mics.list().first { $0.name == name }?.uid }  // e.g. not a Bluetooth headset's
    let voice = VoiceShifter(halfSteps: voiceStepsArg(3), cartoon: asFree ? Free.cartoon : 0, micUID: micUID)
    let rate = voice.currentMic.map(nominalRate) ?? 48000
    let volume = arg("--volume").flatMap(Double.init) ?? 0.03
    var speech = arg("--file").map { testVoiceFile($0, rate: rate) } ?? []
    if let peak = speech.map(abs).max(), peak > 0 { speech = speech.map { $0 * Float(volume) / peak } }
    var phase = 0.0, position = 0
    voice.testSource = { buffer, frames in
        for i in 0..<frames {
            if speech.isEmpty {
                buffer[i] = Float(volume * sin(phase)); phase += 2 * .pi * 440 / rate
            } else {
                buffer[i] = speech[position % speech.count]; position += 1
            }
        }
    }
    if let changerArg, let entry = arg("--voice").flatMap({ VoiceLibrary.shared.voice($0) }) {  // --voice: the voice changer on
        voice.changerTune = changerArg.tune
        voice.changer = ChangerSettings(on: true, quiet: changerArg.quiet, voiceID: entry.id, strength: changerArg.strength, realism: realismArg)
        print("voice changer: \(entry.name), \(realisticArg && realisticUnavailable == nil ? "Realistic (look-ahead \(lookaheadArg) ms)" : "Natural")")
    }
    let test = VoiceTest(voice: voice)
    let started = Date()
    test.onChange = {
        let silent = voice.params.withLock { $0.silent }
        print(String(format: "%.1fs: %@ (voice %@, sending silence: %@, real mic open: %@, voice changer %@)", Date().timeIntervalSince(started),
                     "\(test.phase)", "\(voice.state)", "\(silent)", "\(voice.chain != nil)", "\(voice.changerState)"))
        if test.phase == .idle { voice.stop(); exit(0) }
    }
    voice.start()
    print("mic: \(voice.currentMic.map(deviceName) ?? "none")")
    // Realistic: the AI voice loads in the background (up to a minute the first time); Test is pressed once it's ready.
    func press(waited: Double) {
        if voice.changer.realistic && voice.changerState == .loading && waited < 90 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { press(waited: waited + 0.25) }
            return
        }
        if voice.changer.on { print(String(format: "pressing Test after %.1f s (voice changer %@)", waited, "\(voice.changerState)")) }
        test.click()
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { print("timed out"); exit(1) }
    }
    press(waited: 0)
    dispatchMain()
}

// Soundboard check: a quiet tone is the voice, FILE plays into Pitch Shift Mic 1 s in, Pitch Shift Mic is recorded.
// --voice-off: as with "Your voice" off and the Soundboard open (the voice goes through unchanged).
if let path = arg("--test-sounds") {
    let voiceOff = args.contains("--voice-off")
    let steps = voiceOff ? 0 : arg("--steps").flatMap(Float.init) ?? 3
    let toneHz = 440.0
    // --recording F.caf: checks a recording saved earlier with --out (no devices are used).
    if let saved = arg("--recording") {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: saved)),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let reference = try? SoundClip(url: URL(fileURLWithPath: path), rate: file.processingFormat.sampleRate) else {
            print("Can't read \(saved) or \(path)")
            exit(1)
        }
        let recorded = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let samples = Array(UnsafeBufferPointer(start: reference.samples, count: reference.count))
        soundTestReport(recorded: recorded, reference: samples, rate: reference.rate,
                        toneHz: toneHz * pow(2, Double(steps) / 12)).forEach { print($0) }
        exit(0)
    }
    let micUID = arg("--mic").flatMap { name in Mics.list().first { $0.name == name }?.uid }
    let voice = VoiceShifter(halfSteps: steps, cartoon: 0, micUID: micUID)
    guard let mic = voice.currentMic, let virtualMic = Mics.virtualMic else { print("No mic or Pitch Shift Mic not installed"); exit(1) }
    let rate = nominalRate(mic)
    let volume = arg("--volume").flatMap(Double.init) ?? 0.05
    var phase = 0.0
    voice.testSource = { buffer, frames in
        for i in 0..<frames { buffer[i] = Float(volume * sin(phase)); phase += 2 * .pi * toneHz / rate }
    }
    let board = Soundboard(voice: voice, sounds: [], saves: false)
    board.speakers = args.contains("--speakers")
    board.hearVolume = arg("--hear").flatMap(Float.init) ?? 0
    // --hear-out: the owner's copy, as its player makes it (collected on the main thread).
    var heard: [Float] = []
    var heardRate = 0.0
    if arg("--hear-out") != nil {
        board.hearTap = { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let piece = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
            let rate = buffer.format.sampleRate
            DispatchQueue.main.async { heard += piece; heardRate = rate }
        }
    }
    board.ready = board.hearVolume > 0  // like the open Soundboard: the owner's player is already running
    let url = URL(fileURLWithPath: path)
    let clip: SoundClip
    do { clip = try SoundClip(url: url, rate: rate) } catch { print("Can't read \(path)"); exit(1) }
    let seconds = arg("--seconds").flatMap(Double.init) ?? (1 + clip.seconds + 2)
    let soundVolume = arg("--sound-volume").flatMap(Float.init).map { max(0, min(SoundEntry.loudest, $0)) } ?? 1
    let started = Date()
    board.onChange = {
        print(String(format: "%.2fs: %@", Date().timeIntervalSince(started), board.playing.map { "playing \($0)" } ?? "stopped"))
    }
    onQuitSignals { voice.stopAll(); exit(0) }
    // --voice Woman [--quality realistic]: with the voice changer on (the sound must still arrive unchanged, after it;
    // the tone then comes out at the voice's pitch, not at --steps).
    if !voiceOff, let changerArg, let entry = arg("--voice").flatMap({ VoiceLibrary.shared.voice($0) }) {
        voice.changerTune = changerArg.tune
        voice.changer = ChangerSettings(on: true, quiet: changerArg.quiet, voiceID: entry.id, strength: changerArg.strength, realism: realismArg)
    }
    if voiceOff { voice.keepForSounds(true) } else { voice.start() }
    voice.hold(true)  // runs the chain like the Test button does (no app is listening yet)
    guard let chain = voice.chain else { print("voice did not start: \(voice.state)"); exit(1) }
    let recorder = try! Recorder(device: virtualMic, seconds: seconds)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        let asked = Date()
        board.play(clip, as: url.lastPathComponent, volume: soundVolume)
        if board.hearVolume > 0 { print(String(format: "the owner's copy took %.0f ms to start", Date().timeIntervalSince(asked) * 1000)) }
    }
    if let stopAfter = arg("--stop-after").flatMap(Double.init) {  // presses Stop part way through
        DispatchQueue.main.asyncAfter(deadline: .now() + 1 + stopAfter) { board.stop() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.2) {
        let recorded = recorder.finish()
        voice.stopAll()
        print(String(format: "sound test: file=%@ (%.2f s) mic=%@ rate=%d voice=%@ steps=%g speakers=%@ tone=%g sound volume=%g",
                     url.lastPathComponent, clip.seconds, chain.micName, Int(chain.sampleRate), voiceOff ? "off" : "on", steps,
                     board.speakers == true ? "yes" : "no", volume, soundVolume))
        // The file as the chain plays it, at the recording's rate.
        let reference = recorder.sampleRate == clip.rate ? clip : (try? SoundClip(url: url, rate: recorder.sampleRate))
        if let reference {
            let samples = Array(UnsafeBufferPointer(start: reference.samples, count: reference.count))
            let shifted = toneHz * pow(2, Double(steps) / 12)
            soundTestReport(recorded: recorded, reference: samples, rate: recorder.sampleRate, toneHz: shifted).forEach { print($0) }
        }
        if let out = arg("--out"), let format = AVAudioFormat(standardFormatWithSampleRate: recorder.sampleRate, channels: 1),
           let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(recorded.count)) {
            buffer.frameLength = AVAudioFrameCount(recorded.count)
            for (i, x) in recorded.enumerated() { buffer.floatChannelData![0][i] = x }
            if (try? AVAudioFile(forWriting: URL(fileURLWithPath: out), settings: format.settings).write(from: buffer)) != nil {
                print("wrote \(out)")
            }
        }
        if let out = arg("--hear-out"), heardRate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: heardRate, channels: 1),
           let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, heard.count))) {
            buffer.frameLength = AVAudioFrameCount(heard.count)
            for (i, x) in heard.enumerated() { buffer.floatChannelData![0][i] = x }
            if (try? AVAudioFile(forWriting: URL(fileURLWithPath: out), settings: format.settings).write(from: buffer)) != nil {
                print("wrote \(out) (the owner's copy)")
            }
        }
        exit(0)
    }
    dispatchMain()
}

// Pitch Shift Pro: pictures show the state asked for (unlocked unless pro-locked or the unlock window is asked for)
// and touch no file; the app has read and checked its saved key at the top.
if preview != nil {
    let locked = previewStates.contains("pro-locked") || (previewStates.contains("pro-unlock") && !previewStates.contains("pro-unlocked"))
    Pro.shared.pretend(unlocked: !locked)
}

let app = NSApplication.shared
app.setActivationPolicy(preview == nil ? .regular : .accessory)  // pictures: no Dock icon, no switching apps
let delegate = AppDelegate()
app.delegate = delegate
onQuitSignals {
    delegate.hear.stop()
    delegate.voice.stopAll()
    DefaultMic.giveBack()
    exit(0)
}
app.run()
