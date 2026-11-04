// "What you hear": grabs one app's sound (or all sound) with a macOS audio tap, which also mutes the original,
// changes the pitch with Rubber Band, and plays it to whatever speakers or headphones are picked in the Sound menu.
import AppKit
import AVFoundation
import CoreAudio

// Grabs the sound of some apps (or of every app but this one) and mutes the original.
final class Capture {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let description: CATapDescription
    private(set) var format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    // Advanced processing: the sound goes into this ring instead of onSound (no memory is made on the sound thread).
    private(set) var ring: SoundRing?

    init(_ description: CATapDescription, advanced: Bool = false, onSound: @escaping (AVAudioPCMBuffer) -> Void) throws {
        self.description = description
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else {
            throw Problem(message: "Could not grab the sound.")
        }
        // A private, hidden sound device that only holds the tap. Leaving the real speakers out of it keeps
        // headphone mics switched off (a Bluetooth mic turning on would drop the headphones into low-quality call mode).
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Pitch Shift",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        guard AudioHardwareCreateAggregateDevice(settings as CFDictionary, &device) == noErr else {
            stop()
            throw Problem(message: "Could not grab the sound.")
        }
        let streamFormat = getValue(device, kAudioDevicePropertyStreamFormat, kAudioDevicePropertyScopeInput, default: AudioStreamBasicDescription())
        let format = AVAudioFormat(standardFormatWithSampleRate: streamFormat.mSampleRate > 0 ? streamFormat.mSampleRate : 48000, channels: 2)!
        self.format = format
        let ring = advanced ? SoundRing(seconds: 2, sampleRate: format.sampleRate) : nil
        self.ring = ring

        // Runs on Core Audio's sound thread: copy the sound into a left/right buffer and pass it on.
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, first.mNumberChannels > 0, first.mData != nil else { return }
            if let ring { ring.write(buffers); return }
            let frames = Int(first.mDataByteSize) / (Int(first.mNumberChannels) * MemoryLayout<Float>.size)
            guard frames > 0, let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
            copy.frameLength = AVAudioFrameCount(frames)
            var channel = 0
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let count = Int(buffer.mNumberChannels)
                for c in 0..<count where channel + c < 2 {
                    let dst = copy.floatChannelData![channel + c]
                    for i in 0..<frames { dst[i] = data[i * count + c] }
                }
                channel += count
            }
            if channel == 1 { memcpy(copy.floatChannelData![1], copy.floatChannelData![0], frames * MemoryLayout<Float>.size) }
            onSound(copy)
        }
        guard status == noErr, AudioDeviceStart(device, proc) == noErr else {
            stop()
            throw Problem(message: "Could not grab the sound.")
        }
    }

    // Changes which processes are grabbed without stopping (an app's helper processes come and go).
    func update(processes: [AudioObjectID]) -> Bool {
        description.processes = processes
        var addr = address(kAudioTapPropertyDescription)
        var value = description
        return AudioObjectSetPropertyData(tap, &addr, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), &value) == noErr
    }

    // Removing the tap also unmutes the original sound.
    func stop() {
        if let proc {
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
        }
        proc = nil
        if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        device = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }
}

// What HearShifter needs from a player: normal mode (Player) or "Advanced processing" (AdvancedPlayer).
protocol HearPlayer: AnyObject {
    var engine: AVAudioEngine { get }
    var device: AudioDeviceID { get }
    var format: AVAudioFormat { get }
    var received: AVAudioFrameCount { get }
    var loudest: Float { get }
    var isPlaying: Bool { get }
    var dropouts: Int { get }
    var skips: Int { get }
    func play(_ buffer: AVAudioPCMBuffer)
    func setHalfSteps(_ value: Float)
    func setTone(bass: Double, treble: Double)
    func setAutoEQ(on: Bool, offsets: [Double])
    func stop()
    // Where the delay comes from, in milliseconds: the cushion, the pitch shifting, and the speakers or headphones.
    var delays: (cushion: Double, shifter: Double, device: Double) { get }
}

// Bass and treble and Auto EQ are Advanced processing settings: normal mode ignores them.
extension HearPlayer {
    func setTone(bass: Double, treble: Double) {}
    func setAutoEQ(on: Bool, offsets: [Double]) {}
}

// Changes the pitch with Rubber Band and plays to one speaker or headphone device.
// Rubber Band's "R3" mode keeps bass and drums much better than Apple's built-in pitch shifter.
// A small cushion of sound sits before the speakers so it doesn't crackle. Only used on audioQueue.
final class Player: HearPlayer {
    let engine = AVAudioEngine()
    let node = AVAudioPlayerNode()
    let device: AudioDeviceID
    let format: AVAudioFormat
    private var shifter: RubberBandState?
    private let limiter: OpaquePointer?  // a shift can push a very loud song well over full scale
    private var halfSteps: Float
    private let startFrames: AVAudioFrameCount
    private let maxFrames: AVAudioFrameCount
    private var queuedFrames: AVAudioFrameCount = 0
    private var playing = false
    private(set) var received: AVAudioFrameCount = 0
    private(set) var loudest: Float = 0
    private(set) var dropouts = 0  // times the cushion ran dry (a tiny gap)
    private(set) var skips = 0     // times sound was skipped to catch up

    init(device: AudioDeviceID, format: AVAudioFormat, halfSteps: Float) throws {
        self.device = device
        self.format = format
        self.halfSteps = halfSteps
        // Rubber Band hands back sound in pieces of at most ~16 ms, so a 50 ms cushion is enough; more is just delay.
        startFrames = AVAudioFrameCount(format.sampleRate * 0.05)
        maxFrames = AVAudioFrameCount(format.sampleRate * 0.15)
        let options = Int32(RubberBandOptionProcessRealTime.rawValue | RubberBandOptionEngineFiner.rawValue | RubberBandOptionChannelsTogether.rawValue)
        shifter = rubberband_new(UInt32(format.sampleRate), format.channelCount, options, 1, pow(2, Double(halfSteps) / 12))
        if let shifter { rubberband_set_max_process_size(shifter, 1024) }
        limiter = heavy_limiter_new(format.sampleRate)

        guard useDevice(engine.outputNode.audioUnit!, device) else { throw Problem(message: "Could not play to \(deviceName(device)).") }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()
    }

    deinit {
        engine.stop()
        if let shifter { rubberband_delete(shifter) }
        if let limiter { heavy_limiter_delete(limiter) }
    }

    func stop() { engine.stop() }

    func setHalfSteps(_ value: Float) {
        if let shifter {
            if halfSteps == 0 && value != 0 {  // clear out old sound
                rubberband_reset(shifter)
                if let limiter { heavy_limiter_reset(limiter) }
            }
            rubberband_set_pitch_scale(shifter, pow(2, Double(value) / 12))
        }
        halfSteps = value
    }

    // At normal pitch the sound skips Rubber Band entirely.
    private func shift(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard halfSteps != 0, let shifter else { return buffer }
        let channels = Int(buffer.format.channelCount)
        var done = 0
        while done < Int(buffer.frameLength) {
            let count = min(1024, Int(buffer.frameLength) - done)
            let inputs: [UnsafePointer<Float>?] = (0..<channels).map { UnsafePointer(buffer.floatChannelData![$0] + done) }
            rubberband_process(shifter, inputs, UInt32(count), 0)
            done += count
        }
        let available = Int(rubberband_available(shifter))
        guard available > 0, let output = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(available)) else { return nil }
        let outputs: [UnsafeMutablePointer<Float>?] = (0..<channels).map { output.floatChannelData![$0] }
        output.frameLength = rubberband_retrieve(shifter, outputs, UInt32(available))
        if let limiter, channels > 1 { heavy_limiter_process(limiter, output.floatChannelData![0], output.floatChannelData![1], Int32(output.frameLength)) }
        return output
    }

    func play(_ buffer: AVAudioPCMBuffer) {
        received += buffer.frameLength
        for ch in 0..<Int(buffer.format.channelCount) {
            let data = buffer.floatChannelData![ch]
            for i in 0..<Int(buffer.frameLength) { loudest = max(loudest, abs(data[i])) }
        }
        guard let shifted = shift(buffer) else { return }
        let frames = shifted.frameLength
        if queuedFrames + frames > maxFrames { skips += 1; return }  // falling behind: skip a bit to catch up
        queuedFrames += frames
        node.scheduleBuffer(shifted) { [weak self] in
            audioQueue.async {
                guard let self else { return }
                self.queuedFrames -= frames
                if self.queuedFrames == 0 && self.playing { self.node.pause(); self.playing = false; self.dropouts += 1 }  // ran dry: refill cushion
            }
        }
        if !playing && queuedFrames >= startFrames { node.play(); playing = true }
    }

    var isPlaying: Bool { playing }

    // Where the delay comes from, in milliseconds: the cushion, Rubber Band, and the speakers or headphones.
    var timing: (cushion: Double, shifter: Double, device: Double) {
        let rate = format.sampleRate
        let shifterFrames = halfSteps != 0 && shifter != nil ? Double(rubberband_get_start_delay(shifter!)) : 0
        return (Double(queuedFrames) / rate * 1000, shifterFrames / rate * 1000, outputLatency(device) * 1000)
    }

    var delays: (cushion: Double, shifter: Double, device: Double) {
        let t = timing
        // Rubber Band's real delay is about 110 ms at 48 kHz (its "start delay" alone undercounts it).
        return (t.cushion, t.shifter > 0 ? 110.0 : 0, t.device)
    }
}

// How long the speakers or headphones take to play sound we hand them (as macOS reports it; Bluetooth adds more).
func outputLatency(_ device: AudioDeviceID) -> Double {
    let scope = kAudioDevicePropertyScopeOutput
    let rate = nominalRate(device)
    guard rate > 0 else { return 0 }
    var frames = Double(getValue(device, kAudioDevicePropertyLatency, scope, default: UInt32(0)))
    frames += Double(getValue(device, kAudioDevicePropertySafetyOffset, scope, default: UInt32(0)))
    frames += Double(getValue(device, kAudioDevicePropertyBufferFrameSize, scope, default: UInt32(0)))
    if let stream = getArray(device, kAudioDevicePropertyStreams, scope, of: AudioStreamID.self).first {
        frames += Double(getValue(stream, kAudioStreamPropertyLatency, default: UInt32(0)))
    }
    return frames / rate
}

enum HearSource: Equatable {
    case all
    case apps([String])  // bundle IDs; can be several, or none

    init(saved: String?) {
        switch saved {
        case nil, "music": self = .apps(["com.apple.Music"])  // "music" was the setting in version 1
        case "all": self = .all
        case let list?: self = .apps(list.split(separator: ",").map(String.init))
        }
    }

    var saved: String {
        if case .apps(let bundleIDs) = self { return bundleIDs.joined(separator: ",") }
        return "all"
    }

    var bundleIDs: [String] {
        if case .apps(let bundleIDs) = self { return bundleIDs }
        return []
    }
}

enum HearState: Equatable {
    case off
    case waiting           // the chosen app isn't running or hasn't made sound yet
    case playing(String)   // name of the speakers or headphones
    case problem(String)
}

// Advanced processing's Auto EQ for one speakers or headphones: on or off, and the owner's offset for each section
// (Sub, Bass, Mids, Highs, Air) in dB, −12 … 12. The offsets are kept while it's off, for when it's turned back on.
struct AutoEQSetting: Equatable {
    var on: Bool
    var offsets: [Float]

    init(on: Bool = false, offsets: [Float] = []) {
        self.on = on
        let clean = offsets.prefix(5).map { $0.isFinite ? max(-12, min(12, $0)) : 0 }
        self.offsets = clean + [Float](repeating: 0, count: 5 - clean.count)
    }

    // What the sound processing gets: off means the stage is skipped (offsets 0, so the sound is untouched).
    var engine: (on: Bool, offsets: [Double]) { on ? (true, offsets.map(Double.init)) : (false, AdvancedProcessor.noOffsets) }
}

// How What you hear shifts: plain (normal mode), Advanced processing, or Super Advanced (made for heavy songs).
enum HearMode: Equatable {
    case normal, advanced, heavy
}

// Keeps a Capture and a Player going, and rebuilds them when the app opens or quits or the speakers change.
final class HearShifter {
    var halfSteps: Float {
        didSet {
            let value = halfSteps
            // Advanced processing is made for -12..+12 (less delay); a bigger amount needs a new player with more delay.
            if advanced, abs(value) > 12, audioQueue.sync(execute: { (player as? AdvancedPlayer)?.fullRange == false }) {
                rebuildPlayer()
                return
            }
            audioQueue.async { self.player?.setHalfSteps(value) }
        }
    }
    var source: HearSource {
        didSet { if oldValue != source { restartCapture() } }
    }
    // Switching rebuilds the player. "Advanced processing" (music) keeps the song balanced at big shifts; "Super
    // Advanced" keeps the notes of heavy songs. One at a time.
    var mode: HearMode {
        didSet { if oldValue != mode, running { restartCapture() } }
    }
    var advanced: Bool { mode == .advanced }
    // Advanced processing's "Bass ↔ Treble" for each speakers or headphones: device UID → tilt, from −1 (more bass)
    // through 0 to +1 (more treble). Normal mode ignores it. A new player (other headphones, or past ±12) starts
    // with the right one.
    private(set) var tones: [String: Float]
    func setTone(_ tilt: Float, for uid: String) {
        tones[uid] = tilt
        guard uid == playerKey else { return }
        let db = toneDb(uid)
        audioQueue.async { self.player?.setTone(bass: db.bass, treble: db.treble) }
    }
    // Advanced processing's Auto EQ for each speakers or headphones: device UID → on, and the owner's offset per
    // section (see AutoEQSetting); a device that isn't listed has it off. Normal mode ignores it. A new player
    // (other headphones, or past ±12) starts with the right one.
    private(set) var autoEQs: [String: AutoEQSetting]
    func autoEQ(for uid: String) -> AutoEQSetting { autoEQs[uid] ?? AutoEQSetting() }
    func setAutoEQ(on: Bool, offsets: [Float], for uid: String) {
        autoEQs[uid] = AutoEQSetting(on: on, offsets: offsets)
        guard uid == playerKey else { return }
        let eq = autoEQValue(uid)
        audioQueue.async { self.player?.setAutoEQ(on: eq.on, offsets: eq.offsets) }
    }
    // Auto EQ's live values (Sub … Air): the automatic gain (dB) and the level (dBFS). nil in normal mode.
    var autoEQReadout: (auto: [Float], level: [Float])? {
        audioQueue.sync { (player as? AdvancedPlayer)?.autoEQReadout }
    }
    // Checks only: --as-device UID uses that device's tone and Auto EQ, whatever is playing; --tone-db B,T uses these
    // dB everywhere; --auto-eq / --eq-offsets use this Auto EQ everywhere, as given.
    var testOutputKey: String?
    var fixedToneDb: (bass: Double, treble: Double)?
    var fixedAutoEQ: (on: Bool, offsets: [Double])?
    // The device whose tone and Auto EQ the player uses.
    var outputKey: String { testOutputKey ?? deviceUID(defaultOutput()) }
    private var playerKey: String?
    private func toneDb(_ key: String?) -> (bass: Double, treble: Double) {
        fixedToneDb ?? AdvancedProcessor.toneDb(tilt: key.flatMap { tones[$0] } ?? 0)
    }
    private func autoEQValue(_ key: String?) -> (on: Bool, offsets: [Double]) {
        fixedAutoEQ ?? (key.flatMap { autoEQs[$0] } ?? AutoEQSetting()).engine
    }
    var onChange: () -> Void = {}
    var testPID: pid_t?
    var testRecordSeconds: Double = 0  // checks only: Advanced processing keeps what it plays (see saveTestRecording)
    private(set) var state: HearState = .off
    private var capture: Capture?
    private var capturedProcesses: [AudioObjectID] = []
    private var player: HearPlayer?  // only touched on audioQueue
    private var playerObserver: NSObjectProtocol?
    private var listeners: [Listener] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private let outputDebounce = Debouncer(0.3)
    private let processDebounce = Debouncer(0.2)
    private var running = false
    private var rebuilds: [Date] = []

    init(halfSteps: Float, source: HearSource, advanced: Bool = false, heavy: Bool = false, tones: [String: Float] = [:],
         autoEQs: [String: AutoEQSetting] = [:]) {
        self.halfSteps = halfSteps
        self.source = source
        mode = heavy ? .heavy : advanced ? .advanced : .normal
        self.tones = tones
        self.autoEQs = autoEQs
    }

    var isOn: Bool { running }

    func start() {
        guard !running else { return }
        running = true
        // Version 1 sent all sound to BlackHole. If it didn't close cleanly, put the sound back.
        if deviceName(defaultOutput()) == "BlackHole 2ch",
           let last = UserDefaults.standard.string(forKey: "lastSpeakers"),
           let speakers = allDevices().first(where: { deviceName($0) == last }) {
            setDefaultOutput(speakers)
        }
        listeners = [
            Listener(system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.outputChanged() },
            Listener(system, kAudioHardwarePropertyProcessObjectList) { [weak self] in
                self?.processDebounce.call { self?.refreshCapture() }
            },
        ]
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map {
            center.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in self?.processDebounce.call { self?.refreshCapture() } }
        }
        restartCapture()
    }

    func stop() {
        guard running else { return }
        running = false
        listeners = []
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers = []
        stopCapture()
        setState(.off)
    }

    var report: String {
        let tone = toneText
        return audioQueue.sync {
            guard let player else { return "state=\(state), no player" }
            return "state=\(state), out=\(deviceName(player.device)) running=\(player.engine.isRunning), rate=\(Int(player.format.sampleRate)), " +
                "frames=\(player.received), loudest=\(player.loudest), playing=\(player.isPlaying), processes=\(capturedProcesses)" +
                ((player as? AdvancedPlayer).map { ", advanced out loudest=\($0.outputLoudest), \(tone($0))" } ?? "")
        }
    }

    // "tone=0.80 (bass -4.8 dB, treble +4.8 dB), auto EQ on (+3.0 -2.0 +0.0 +1.0 -1.0 dB)": the slider for the
    // player's device, and what the player really has.
    private var toneText: (AdvancedPlayer) -> String {
        let setting = fixedToneDb == nil ? String(format: "tone=%.2f", playerKey.flatMap { tones[$0] } ?? 0) : "tone=--tone-db"
        return { player in
            let eq = player.autoEQ
            return setting + String(format: " (bass %+.1f dB, treble %+.1f dB)", player.tone.bass, player.tone.treble) +
                ", auto EQ \(eq.on ? "on" : "off") (" + eq.offsets.map { String(format: "%+.1f", $0) }.joined(separator: " ") + " dB)"
        }
    }

    // Checks only: saves what Advanced processing played (needs testRecordSeconds > 0 before start).
    func saveTestRecording(to path: String) {
        audioQueue.sync { try? (player as? AdvancedPlayer)?.saveRecording(to: path) }
    }

    var timing: String {
        let tone = toneText
        return audioQueue.sync {
            guard let player else { return "no player" }
            let t = player.delays
            let name = player is AdvancedPlayer ? "advanced" : "shifter"
            return String(format: "cushion %.0f ms + %@ %.0f ms + %@ %.0f ms = %.0f ms  (dropouts %d, skips %d)", t.cushion, name, t.shifter, deviceName(player.device), t.device, t.cushion + t.shifter + t.device, player.dropouts, player.skips) +
                ((player as? AdvancedPlayer).map { "  " + tone($0) } ?? "")
        }
    }

    private func setState(_ new: HearState) {
        guard new != state else { return }
        state = new
        onChange()
    }

    private func stopCapture() {
        capture?.stop()
        capture = nil
        capturedProcesses = []
        if let playerObserver { NotificationCenter.default.removeObserver(playerObserver) }
        playerObserver = nil
        playerKey = nil
        audioQueue.sync { player?.stop(); player = nil }
    }

    private func restartCapture() {
        stopCapture()
        refreshCapture()
    }

    // Start grabbing sound when the chosen app is around, follow its helper processes, and stop when it quits.
    private func refreshCapture() {
        guard running else { return }
        let processes: [AudioObjectID]
        let everythingElse: Bool
        if let testPID {
            processes = audioProcess(for: testPID).map { [$0] } ?? []
            everythingElse = false
        } else {
            switch source {
            case .all:
                // Everything except this app's own sound (so our output isn't grabbed again).
                guard let me = audioProcess(for: getpid()) else { setState(.waiting); return }
                processes = [me]
                everythingElse = true
            case .apps(let bundleIDs):
                processes = Apps.scan().filter { bundleIDs.contains($0.bundleID) }.flatMap(\.processes).sorted()
                everythingElse = false
            }
        }
        if processes.isEmpty {
            stopCapture()
            setState(.waiting)
            return
        }
        if capture != nil {
            if processes == capturedProcesses { return }
            if !everythingElse, capture!.update(processes: processes) {
                capturedProcesses = processes
                return
            }
            stopCapture()
        }
        let description = everythingElse
            ? CATapDescription(stereoGlobalTapButExcludeProcesses: processes)
            : CATapDescription(stereoMixdownOfProcesses: processes)
        do {
            capture = try Capture(description, advanced: mode != .normal) { [weak self] buffer in
                audioQueue.async { self?.player?.play(buffer) }
            }
            capturedProcesses = processes
            rebuildPlayer()
        } catch {
            capture = nil
            setState(.problem((error as? Problem)?.message ?? "\(error)"))
        }
    }

    // The speakers or headphones changed (picked in the Sound menu, plugged in, connected, or disconnected).
    private func outputChanged() {
        guard running, capture != nil else { return }
        let device = defaultOutput()
        let needed = audioQueue.sync { player == nil || player!.device != device || !player!.engine.isRunning }
        guard needed else { return }
        // If something keeps changing, slow down instead of rebuilding over and over.
        rebuilds = rebuilds.filter { $0.timeIntervalSinceNow > -10 } + [Date()]
        if rebuilds.count > 5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.rebuildPlayer() }
        } else {
            outputDebounce.call { [weak self] in self?.rebuildPlayer() }
        }
    }

    private func rebuildPlayer() {
        guard running, let format = capture?.format else { return }
        let device = defaultOutput()
        let steps = halfSteps
        let key = testOutputKey ?? deviceUID(device)
        let tone = toneDb(key)
        let eq = autoEQValue(key)
        playerKey = key
        let ring = capture?.ring
        if let playerObserver { NotificationCenter.default.removeObserver(playerObserver) }
        playerObserver = nil
        let result: Result<HearPlayer, Error> = audioQueue.sync {
            player?.stop()
            player = nil
            let made: Result<HearPlayer, Error> = Result {
                if let ring { return try AdvancedPlayer(device: device, format: format, halfSteps: steps, tone: tone, autoEQ: eq, heavy: mode == .heavy, input: ring, recordSeconds: testRecordSeconds) }
                return try Player(device: device, format: format, halfSteps: steps)
            }
            if case .success(let p) = made { player = p }
            return made
        }
        switch result {
        case .success(let player):
            playerObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: player.engine, queue: .main) { [weak self] _ in
                self?.outputChanged()
            }
            setState(.playing(deviceName(device)))
        case .failure:
            setState(.problem("Could not play to \(deviceName(device))."))
        }
    }
}
