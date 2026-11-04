// Realistic mode (AI voices, Apple silicon): loads a voice's Core ML models once, in the background, while Natural
// mode keeps playing, and frees them when Realistic is turned off. Also the pieces the voice chain and the command
// line use around Sources/Voice/VoiceModel.h.
//
// The first time a voice is loaded on a Mac, macOS prepares the models for its chips: that can take up to a minute
// (later loads take about a second). The window shows that through ChangerState.loading (see `loadingNote`).
import AVFoundation
import Foundation

final class VoiceModelStore {
    static let shared = VoiceModelStore()
    // --compute cpu|gpu|ane|all (VOICEMODEL_COMPUTE_*); auto = the content encoder on the Neural Engine and the voice
    // on the GPU, the CPU if those can't be used.
    static var computeUnits: Int32 = Int32(VOICEMODEL_COMPUTE_AUTO)

    // (The ids are VoiceEntry.modelKey: "woman", or "woman+quiet" with "Block background sounds" on.)
    enum Status: Equatable {
        case none
        case loading(String)          // voice id
        case ready(String)
        case failed(String, String)   // voice id, why
    }
    private(set) var status: Status = .none
    private(set) var model: OpaquePointer?   // VoiceModel *, for `status` .ready
    var onChange: () -> Void = {}            // called on the main thread when `status` changes
    private var wanted: String?              // the voice id asked for last (nil = none)
    private var retired: [OpaquePointer] = [] // models of a voice no longer wanted, freed once no chain uses them
    private let queue = DispatchQueue(label: "Pitch Shift AI voice loading", qos: .userInitiated)

    // True until this voice has been loaded once on this Mac (then macOS keeps the prepared models).
    func firstTime(_ entry: VoiceEntry, quiet: Bool = false) -> Bool {
        !UserDefaults.standard.bool(forKey: Self.preparedKey(entry, quiet: quiet))
    }

    // What the window can say while loading.
    func loadingNote(_ entry: VoiceEntry?, quiet: Bool = false) -> String {
        guard let entry, firstTime(entry, quiet: quiet) else { return "Getting the AI voice ready…" }
        return "Getting the AI voice ready. The first time can take up to a minute."
    }

    // Asks for a voice's models (main thread). Loads in the background unless they are loaded or loading already.
    func want(_ entry: VoiceEntry, quiet: Bool = false) {
        let id = entry.modelKey(quiet: quiet)
        wanted = id
        switch status {
        case .ready(let ready) where ready == id, .loading(let ready) where ready == id: return
        default: break
        }
        guard let encoder = entry.encoderURL?.path, let voice = entry.modelURL(quiet: quiet)?.path else {
            setStatus(.failed(id, "\(entry.name) has no AI voice"))
            return
        }
        guard FileManager.default.fileExists(atPath: encoder), FileManager.default.fileExists(atPath: voice) else {
            setStatus(.failed(id, "the AI voice files are missing"))
            return
        }
        if let model { retired.append(model) }  // another voice was loaded: a running chain may still use it
        model = nil
        setStatus(.loading(id))
        let units = Self.computeUnits, key = Self.preparedKey(entry, quiet: quiet), second = Self.secondFiles(entry)
        queue.async { [weak self] in
            var err = [CChar](repeating: 0, count: 200)
            let made = voicemodel_load(encoder, voice, units, &err, Int32(err.count))
            let why = String(cString: err)
            if let made { Self.addSecond(made, second) }
            DispatchQueue.main.async {
                guard let self else { voicemodel_free(made); return }
                guard self.wanted == id, self.status == .loading(id) else { voicemodel_free(made); return }  // no longer wanted
                if let made {
                    UserDefaults.standard.set(true, forKey: key)
                    self.model = made
                    self.setStatus(.ready(id))
                } else {
                    self.setStatus(.failed(id, why.isEmpty ? "the AI voice can't run here" : why))
                }
            }
        }
    }

    // Lets the models go (main thread). Only call it after every voice chain using them was closed.
    func free() {
        wanted = nil
        if let model { voicemodel_free(model) }
        model = nil
        freeRetired()
        setStatus(.none)
    }

    // Frees the models of voices no longer wanted (main thread; call after the chain that used them was closed).
    func freeRetired() {
        for old in retired { voicemodel_free(old) }
        retired = []
    }

    // The loaded model for a voice, or nil.
    func model(for id: String) -> OpaquePointer? {
        if case .ready(let ready) = status, ready == id { return model }
        return nil
    }

    // Loads right here and waits (for --render-voice). The caller frees it with voicemodel_free.
    static func loadNow(_ entry: VoiceEntry, quiet: Bool = false) throws -> OpaquePointer {
        guard let encoder = entry.encoderURL?.path, let voice = entry.modelURL(quiet: quiet)?.path,
              FileManager.default.fileExists(atPath: encoder), FileManager.default.fileExists(atPath: voice) else {
            throw Problem(message: "\(entry.name): the AI voice files are missing")
        }
        var err = [CChar](repeating: 0, count: 200)
        guard let made = voicemodel_load(encoder, voice, computeUnits, &err, Int32(err.count)) else {
            throw Problem(message: "Realistic mode: \(String(cString: err))")
        }
        UserDefaults.standard.set(true, forKey: preparedKey(entry, quiet: quiet))
        addSecond(made, secondFiles(entry))
        return made
    }

    // 3.5: the second voice (hums, laughs, sighs, singing) and the sound sorter, if the voice has them.
    static func secondFiles(_ entry: VoiceEntry) -> (voice: String, sorter: String)? {
        guard let voice = entry.soundsURL?.path, let sorter = VoiceLibrary.sorterURL(for: entry)?.path,
              FileManager.default.fileExists(atPath: voice), FileManager.default.fileExists(atPath: sorter) else { return nil }
        return (voice, sorter)
    }

    static func addSecond(_ model: OpaquePointer, _ files: (voice: String, sorter: String)?) {
        guard let files else { return }
        var err = [CChar](repeating: 0, count: 200)
        if voicemodel_add_second(model, files.voice, files.sorter, &err, Int32(err.count)) == 0 {
            print("Second voice not used: \(String(cString: err))")
        }
    }

    private func setStatus(_ new: Status) {
        guard new != status else { return }
        status = new
        onChange()
    }

    // Changes when the model files change (size of the voice file, and its name when it isn't "<id>.mlmodelc", as for
    // Woman's woman_us.mlmodelc, which has the old Woman's size), so a new version counts as "first time" again.
    private static func preparedKey(_ entry: VoiceEntry, quiet: Bool = false) -> String {
        let size = entry.modelURL(quiet: quiet).flatMap { url -> Int? in
            let weights = url.appendingPathComponent("weights/weight.bin")
            return (try? FileManager.default.attributesOfItem(atPath: weights.path)[.size] as? Int) ?? nil
        } ?? 0
        let model = (quiet && entry.quietURL != nil ? entry.manifest.realistic?.quiet : entry.manifest.realistic?.model) ?? ""
        let name = model == "\(entry.id).mlmodelc" || model.isEmpty ? "" : ".\(model)"
        return "aiVoicePrepared.\(entry.id)\(name).\(size)"
    }
}

// --compute cpu|gpu|ane|all|auto -> VOICEMODEL_COMPUTE_*
func computeUnits(named name: String) -> Int32? {
    switch name {
    case "auto": return Int32(VOICEMODEL_COMPUTE_AUTO)
    case "cpu": return Int32(VOICEMODEL_COMPUTE_CPU)
    case "gpu": return Int32(VOICEMODEL_COMPUTE_GPU)
    case "ane": return Int32(VOICEMODEL_COMPUTE_ANE)
    case "all": return Int32(VOICEMODEL_COMPUTE_ALL)
    default: return nil
    }
}

// Hands the mic sound and the pitch frames voicechanger_analyse just made to the AI voice (sound thread). (3.5: with
// each frame's tracked pitch and flags, for the choice between the main and the second voice.)
func voicestreamPush(_ stream: OpaquePointer, _ mic: UnsafePointer<Float>, _ frames: Int, _ pitch: UnsafeMutablePointer<VoiceChangerPitch>) {
    let raw = UnsafeMutableRawPointer(pitch)
    let hz = (raw + MemoryLayout<VoiceChangerPitch>.offset(of: \VoiceChangerPitch.frameHz)!).assumingMemoryBound(to: Float.self)
    let pos = (raw + MemoryLayout<VoiceChangerPitch>.offset(of: \VoiceChangerPitch.framePos)!).assumingMemoryBound(to: Int64.self)
    let f0In = (raw + MemoryLayout<VoiceChangerPitch>.offset(of: \VoiceChangerPitch.frameF0In)!).assumingMemoryBound(to: Float.self)
    let flags = (raw + MemoryLayout<VoiceChangerPitch>.offset(of: \VoiceChangerPitch.frameFlags)!).assumingMemoryBound(to: UInt8.self)
    voicestream_push2(stream, mic, Int32(frames), hz, pos, f0In, flags, pitch.pointee.newFrames)
}

// One line about the AI voice for --watch and --render-voice --quality realistic.
func aiStatsLine(_ s: VoiceStreamStats, latencyMs: Double, seconds: Double) -> String {
    String(format: "%4.0fs  AI voice: %@ | delay %.0f ms (fixed; look-ahead %d ms, %lld switches) | pieces %lld, late %lld, Natural filled in %.2f s | piece %.1f ms average, %.1f ms worst | AI thread %.0f%% of a core",
           seconds, s.loaded != 0 ? "playing" : "not yet", latencyMs, s.lookaheadMs, s.switches, s.hops, s.misses, s.fallbackSeconds,
           s.averageHopMs, s.worstHopMs, s.cpuShare * 100)
        // (3.2) the time kept in hand, which chip makes the voice, pieces that came late or close, grace saves, loud samples
        + String(format: " | reserve %d ms, voice on %@ (%lld switches), late by the clock %lld, tight %lld, tail saves %lld | above 0.7: %lld of %lld",
                 s.reserveMs, s.onCPU != 0 ? "the CPU copy" : "its chip", s.chipSwitches, s.lateHops, s.tightHops, s.graceSaves,
                 s.loudSamples, s.samplesOut)
}

// --render-voice ... --voice X --quality realistic: runs the AI voice inline over a file (it never comes late) after
// the Natural render (`natural`, lined up with the input), and writes the result lined up with the input too.
// Prints what it does once per second of sound.
func renderRealisticFile(input: String, natural: [Float], rate: Double, output: String, entry: VoiceEntry, options: ChangerOptions,
                         lookaheadMs: Int = 0) throws {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: input))
    guard file.processingFormat.sampleRate == rate,
          let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
        throw Problem(message: "Could not read \(input).")
    }
    try file.read(into: source)
    let length = Int(file.length)
    let channels = Int(file.processingFormat.channelCount), used = channels <= 2 ? channels : 1
    var mono = [Float](repeating: 0, count: length)
    for c in 0..<used { for i in 0..<length { mono[i] += source.floatChannelData![c][i] / Float(used) } }

    let started = Date()
    let model = try VoiceModelStore.loadNow(entry, quiet: options.quiet)
    defer { voicemodel_free(model) }
    print(String(cString: voicemodel_describe(model)))
    if options.quiet, let quiet = entry.manifest.realistic?.quiet { print("Block background sounds (3.5): main voice \(quiet)") }
    let block = 128
    var config = VoiceStreamConfig(hopMs: 160, contextMs: 480, crossfadeMs: 40, solaMs: 10, reserveMs: 70, lookaheadMs: Int32(lookaheadMs))
    guard let stream = voicestream_new(model, rate, Int32(block), 1, &config) else { throw Problem(message: "Could not start the AI voice.") }
    defer { voicestream_delete(stream) }
    if lookaheadMs > 0 && Int(voicemodel_max_lookahead_ms(model)) < lookaheadMs {
        print("Note: \(entry.name)'s AI voice file can look ahead \(voicemodel_max_lookahead_ms(model)) ms at most (asked for \(lookaheadMs) ms)")
    }
    voicestream_set_intonation(stream, 1 + max(0, min(1, options.strength)) * (options.voice.pointee.intonation - 1))
    for (key, value) in options.tune { _ = voicestream_tune(stream, key, value) }
    guard let changer = voicechanger_new(rate, Int32(block)) else { throw Problem(message: "Could not start the voice changer.") }
    defer { voicechanger_delete(changer) }
    for (key, value) in options.tune { _ = voicechanger_tune(changer, key, value) }
    voicechanger_set(changer, options.voice, options.strength)
    voicechanger_reset(changer)  // its pitch frames count the same samples as the stream
    let latency = Int(voicestream_latency_frames(stream))
    let pitch = UnsafeMutablePointer<VoiceChangerPitch>.allocate(capacity: 1)
    pitch.initialize(to: VoiceChangerPitch())
    defer { pitch.deallocate() }
    var mic = [Float](repeating: 0, count: block), nat = mic, out = mic
    var result: [Float] = []
    result.reserveCapacity(length + latency + block)
    var position = 0, nextReport = 1
    var stats = VoiceStreamStats()
    while result.count < length + latency {
        for i in 0..<block {
            mic[i] = position + i < length ? mono[position + i] : 0
            nat[i] = position + i < natural.count ? natural[position + i] : 0
        }
        mic.withUnsafeBufferPointer { m in
            voicechanger_analyse(changer, m.baseAddress!, Int32(block), 0, pitch)
            voicestreamPush(stream, m.baseAddress!, block, pitch)
        }
        nat.withUnsafeBufferPointer { n in
            out.withUnsafeMutableBufferPointer { o in voicestream_pull(stream, n.baseAddress!, 0, o.baseAddress!, Int32(block)) }
        }
        result.append(contentsOf: out)
        position += block
        if position >= nextReport * Int(rate) && position <= length {
            voicestream_get_stats(stream, &stats)
            print(aiStatsLine(stats, latencyMs: Double(latency) / rate * 1000, seconds: Double(nextReport)))
            nextReport += 1
        }
    }
    voicestream_get_stats(stream, &stats)
    print(String(format: "AI voice: %lld pieces in %.1f s (%.1f ms each on average, %.1f ms worst), fixed delay %.0f ms (taken out of the file)",
                 stats.hops, Date().timeIntervalSince(started), stats.averageHopMs, stats.worstHopMs, Double(latency) / rate * 1000))
    var sounds: Int64 = 0, whistles: Int64 = 0, passed = 0.0
    voicestream_get_passed(stream, &sounds, &whistles, &passed)
    print(String(format: "Other sounds heard as they are (3.4): %lld short sounds, %lld whistles, %.2f s", sounds, whistles, passed))
    if voicemodel_has_second(model) != 0 {
        var pieces: Int64 = 0, switches: Int64 = 0, blends: Int64 = 0
        voicestream_get_second(stream, &pieces, &switches, &blends)
        print(String(format: "Second voice (3.5): %lld of %lld pieces, %lld switches (%lld blended)", pieces, stats.hops, switches, blends))
    }
    let aligned = Array(result[min(latency, result.count)..<min(latency + length, result.count)])
    guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, aligned.count))) else {
        throw Problem(message: "Could not write \(output).")
    }
    buffer.frameLength = AVAudioFrameCount(aligned.count)
    _ = aligned.withUnsafeBufferPointer { memcpy(buffer.floatChannelData![0], $0.baseAddress!, aligned.count * MemoryLayout<Float>.size) }
    let outFile = try AVAudioFile(forWriting: URL(fileURLWithPath: output), settings: format.settings)
    try outFile.write(from: buffer)
}

// Reads a mono file written by renderVoiceFile (the Natural render) back in.
func readMonoFile(_ path: String) throws -> (samples: [Float], rate: Double) {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
        throw Problem(message: "Could not read \(path).")
    }
    var samples: [Float] = []
    samples.reserveCapacity(Int(file.length))
    while file.framePosition < file.length {  // one read can stop a few ms short of the end
        try file.read(into: buffer)
        guard buffer.frameLength > 0 else { break }
        samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    return (samples, file.processingFormat.sampleRate)
}
