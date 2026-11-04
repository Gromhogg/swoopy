// "Advanced processing" for What you hear (made for music). At big shifts a plain pitch shift squeezes a song:
// going up the bass disappears and it gets thin, going down it gets muddy and dull. This keeps the song balanced:
// going up, the bass is moved back down an octave so it stays bass; going down, the very top of the original is
// kept; and a slow tone control keeps the overall balance like the original's. The work is done by AdvancedChain
// (C++, in Sources/Advanced). It is made for music and a new amount kicks in a moment later, so it is a switch and
// normal mode stays exactly as it was. Research and numbers: notes/advanced-processing-research.md.
import Accelerate
import AVFoundation
import CoreAudio
import os

// A ring of stereo sound between two threads (see AudioRing.h), plus a signal for the reading thread.
final class SoundRing {
    let ring: OpaquePointer
    let wake = DispatchSemaphore(value: 0)
    let sampleRate: Double
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private static let scratch = 4096

    init(seconds: Double, sampleRate: Double) {
        self.sampleRate = sampleRate
        ring = audio_ring_new(Int32(seconds * sampleRate))!
        left = .allocate(capacity: Self.scratch)
        right = .allocate(capacity: Self.scratch)
    }

    deinit {
        audio_ring_free(ring)
        left.deallocate()
        right.deallocate()
    }

    var count: Int { Int(audio_ring_count(ring)) }

    // Called on Core Audio's sound thread with the grabbed sound: copies it in as left/right and wakes the reader.
    // Makes no memory.
    func write(_ buffers: UnsafeMutableAudioBufferListPointer) {
        guard let first = buffers.first, first.mNumberChannels > 0 else { return }
        let total = Int(first.mDataByteSize) / (Int(first.mNumberChannels) * MemoryLayout<Float>.size)
        var done = 0
        while done < total {
            let frames = min(Self.scratch, total - done)
            var channel = 0
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let count = Int(buffer.mNumberChannels)
                for c in 0..<count where channel + c < 2 {
                    let dst = channel + c == 0 ? left : right
                    for i in 0..<frames { dst[i] = data[(done + i) * count + c] }
                }
                channel += count
            }
            if channel == 1 { right.update(from: left, count: frames) }
            audio_ring_write(ring, left, right, Int32(frames))
            done += frames
        }
        wake.signal()
    }
}

// The sound processing, the same for live sound and for files (--render-file). One thread uses it at a time.
// `process` makes no memory, so it is safe to run on a sound thread.
final class AdvancedProcessor: HearProcessor {
    let sampleRate: Double
    let maxFrames: Int
    private let chain: OpaquePointer
    private var halfSteps: Float
    private var tone = (bass: 0.0, treble: 0.0)
    private var autoEQ: (on: Bool, offsets: [Double]) = (false, AdvancedProcessor.noOffsets)
    // Made for -12..+12 (less delay); a bigger amount needs a version made with fullRange (more delay).
    let fullRange: Bool
    private let ins = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: 2)
    private let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 2)

    init?(sampleRate: Double, halfSteps: Float, fullRange: Bool? = nil, maxFrames: Int = 1024) {
        let full = fullRange ?? (abs(halfSteps) > 12)
        self.fullRange = full
        let flags = full ? 0 : Int32(ADVANCED_RANGE_12)
        guard let chain = advanced_new(sampleRate, 2, Int32(maxFrames), flags) else { return nil }
        self.chain = chain
        self.sampleRate = sampleRate
        self.maxFrames = maxFrames
        self.halfSteps = halfSteps
        advanced_set_semis(chain, Double(halfSteps))
    }

    deinit {
        advanced_delete(chain)
        ins.deallocate()
        outs.deallocate()
    }

    // The delay it adds, in frames. It never changes while it runs, whatever the amount.
    var latencyFrames: Int { Int(advanced_latency_frames(chain)) }

    func setHalfSteps(_ value: Float) {
        guard value != halfSteps else { return }
        halfSteps = value
        advanced_set_semis(chain, Double(value))
    }

    // The "Bass ↔ Treble" slider: a tilt from −1 (more bass) through 0 (untouched) to +1 (more treble) moves the bass
    // and the treble this many dB, opposite ways.
    static let toneDb = 6.0
    static func toneDb(tilt: Float) -> (bass: Double, treble: Double) {
        let db = Double(tilt) * toneDb
        return db == 0 ? (0, 0) : (-db, db)
    }

    // Bass and treble in dB (0, 0 = untouched). They glide, so moving them doesn't click.
    func setTone(bass: Double, treble: Double) {
        guard bass != tone.bass || treble != tone.treble else { return }
        tone = (bass, treble)
        advanced_set_tone(chain, bass, treble)
    }

    // Auto EQ: five sections (Sub, Bass, Mids, Highs, Air) kept near the original song's balance as it plays.
    // on: the automatic part; offsets: a manual offset per section in dB (−12 … 12, Sub first), added on top. Off with
    // all offsets 0 (the default) the sound is untouched. Makes no memory, so it is safe on the processing thread.
    static let sections = ["Sub", "Bass", "Mids", "Highs", "Air"]
    static let noOffsets = [Double](repeating: 0, count: 5)
    func setAutoEQ(on: Bool, offsets: [Double]) {
        guard on != autoEQ.on || offsets != autoEQ.offsets else { return }
        autoEQ = (on, offsets)
        var five = (0.0, 0.0, 0.0, 0.0, 0.0)
        withUnsafeMutableBytes(of: &five) { raw in
            let values = raw.bindMemory(to: Double.self)
            for i in 0..<min(5, offsets.count) { values[i] = offsets[i] }
            advanced_set_auto_eq(chain, on ? 1 : 0, values.baseAddress)
        }
    }

    // Auto EQ's live values, Sub first: the automatic gain now (dB, without the offsets) and each section's level
    // coming out (dBFS, −120 while Auto EQ is off). Safe from any thread, also while `process` runs.
    func readAutoEQ() -> (auto: [Float], level: [Float]) {
        var gains = [Double](repeating: 0, count: 5), levels = [Double](repeating: 0, count: 5)
        advanced_get_auto_eq(chain, &gains, &levels)
        return (gains.map(Float.init), levels.map(Float.init))
    }

    // `frames` in, the same number out (delayed by latencyFrames). At most maxFrames per call.
    func process(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>,
                 _ outLeft: UnsafeMutablePointer<Float>, _ outRight: UnsafeMutablePointer<Float>, _ frames: Int) {
        ins[0] = left; ins[1] = right
        outs[0] = outLeft; outs[1] = outRight
        advanced_process(chain, ins, nil, outs, Int32(frames))
    }
}

// Plays What you hear through AdvancedProcessor: the grabbed sound comes in through a ring, a worker thread
// processes it, and a second ring with a small cushion feeds the speakers or headphones.
final class AdvancedPlayer: HearPlayer {
    let engine = AVAudioEngine()
    let device: AudioDeviceID
    let format: AVAudioFormat
    private let worker: AdvancedWorker
    private var source: AVAudioSourceNode!
    private var stopped = false

    // recordSeconds > 0 (checks only): also keeps what is sent to the speakers, for `saveRecording`.
    // tone: bass and treble in dB (see setTone), autoEQ: Auto EQ (see setAutoEQ), so a rebuilt player keeps them.
    // heavy: Super Advanced instead of Advanced processing.
    init(device: AudioDeviceID, format: AVAudioFormat, halfSteps: Float, tone: (bass: Double, treble: Double) = (0, 0),
         autoEQ: (on: Bool, offsets: [Double]) = (false, AdvancedProcessor.noOffsets), heavy: Bool = false,
         input: SoundRing, recordSeconds: Double = 0) throws {
        self.device = device
        self.format = format
        let made: HearProcessor? = heavy ? HeavyProcessor(sampleRate: format.sampleRate, halfSteps: halfSteps)
            : AdvancedProcessor(sampleRate: format.sampleRate, halfSteps: halfSteps)
        guard let processor = made else {
            throw Problem(message: "Could not start Advanced processing.")
        }
        processor.setTone(bass: tone.bass, treble: tone.treble)
        processor.setAutoEQ(on: autoEQ.on, offsets: autoEQ.offsets)
        let wanted = AdvancedWanted(halfSteps: halfSteps, bassDb: tone.bass, trebleDb: tone.treble,
                                    autoEQOn: autoEQ.on, autoEQOffsets: autoEQ.offsets)
        worker = AdvancedWorker(processor: processor, input: input, wanted: wanted, recordFrames: Int(recordSeconds * format.sampleRate))
        // The cushion before the speakers: like normal mode (starts at 50 ms, at most 150 ms).
        let ring = worker.output.ring
        let start = Int32(format.sampleRate * 0.05), most = Int32(format.sampleRate * 0.15)
        // Runs on the speakers' sound thread: takes sound from the ring (or silence). Makes no memory.
        source = AVAudioSourceNode(format: format) { _, _, frameCount, list -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let second = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) ?? first : first
            audio_ring_play(ring, first, second, Int32(frameCount), start, most)
            return noErr
        }
        guard useDevice(engine.outputNode.audioUnit!, device) else { throw Problem(message: "Could not play to \(deviceName(device)).") }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try engine.start()
        worker.start()
    }

    deinit { stop() }

    func stop() {
        guard !stopped else { return }
        stopped = true
        worker.finish()
        engine.stop()
    }

    func setHalfSteps(_ value: Float) { worker.wanted.withLock { $0.halfSteps = value } }
    func setTone(bass: Double, treble: Double) { worker.wanted.withLock { $0.bassDb = bass; $0.trebleDb = treble } }
    var tone: (bass: Double, treble: Double) { worker.wanted.withLock { ($0.bassDb, $0.trebleDb) } }
    func setAutoEQ(on: Bool, offsets: [Double]) { worker.wanted.withLock { $0.autoEQOn = on; $0.autoEQOffsets = offsets } }
    var autoEQ: (on: Bool, offsets: [Double]) { worker.wanted.withLock { ($0.autoEQOn, $0.autoEQOffsets) } }
    // Auto EQ's live values for the window (see AdvancedProcessor.readAutoEQ). Any thread.
    var autoEQReadout: (auto: [Float], level: [Float]) { worker.processor.readAutoEQ() }

    // Not used live (the capture writes straight into the ring), but handy for tests.
    func play(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let right = buffer.format.channelCount > 1 ? data[1] : data[0]
        audio_ring_write(worker.input.ring, data[0], right, Int32(buffer.frameLength))
        worker.input.wake.signal()
    }

    var fullRange: Bool { worker.processor.fullRange }
    var outputLoudest: Float { worker.outputLoudest }

    // Checks only: writes what was sent to the speakers (see recordSeconds) to a WAV file.
    func saveRecording(to path: String) throws {
        guard let record = worker.record else { return }
        let frames = worker.recorded
        let out = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        buffer.floatChannelData![0].update(from: record.left, count: frames)
        buffer.floatChannelData![1].update(from: record.right, count: frames)
        try out.write(from: buffer)
    }
    var received: AVAudioFrameCount { AVAudioFrameCount(worker.received) }
    var loudest: Float { worker.loudest }
    var isPlaying: Bool { audio_ring_is_playing(worker.output.ring) != 0 }
    var dropouts: Int { Int(audio_ring_dropouts(worker.output.ring)) }
    var skips: Int { Int(audio_ring_skips(worker.output.ring)) }

    var delays: (cushion: Double, shifter: Double, device: Double) {
        let rate = format.sampleRate
        let waiting = Double(worker.output.count + worker.input.count)
        return (waiting / rate * 1000, Double(worker.processor.latencyFrames) / rate * 1000, outputLatency(device) * 1000)
    }
}

// What the worker should use next: the amount, the bass and treble in dB, and Auto EQ.
struct AdvancedWanted: Equatable {
    var halfSteps: Float
    var bassDb: Double = 0
    var trebleDb: Double = 0
    var autoEQOn = false
    var autoEQOffsets = AdvancedProcessor.noOffsets
}

// The worker thread: waits for grabbed sound, processes it, and hands it to the speakers' ring.
final class AdvancedWorker {
    let processor: HearProcessor
    let input: SoundRing
    let output: SoundRing
    let wanted: OSAllocatedUnfairLock<AdvancedWanted>
    private(set) var received = 0
    private(set) var loudest: Float = 0
    private(set) var outputLoudest: Float = 0
    let record: (left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, capacity: Int)?
    private(set) var recorded = 0
    private let keepGoing = OSAllocatedUnfairLock(initialState: true)
    private let done = DispatchSemaphore(value: 0)
    private var thread: Thread?
    private let block = 1024
    private let scratch: [UnsafeMutablePointer<Float>]

    init(processor: HearProcessor, input: SoundRing, wanted: AdvancedWanted, recordFrames: Int = 0) {
        self.processor = processor
        self.input = input
        output = SoundRing(seconds: 2, sampleRate: input.sampleRate)
        self.wanted = OSAllocatedUnfairLock(initialState: wanted)
        scratch = (0..<4).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 1024) }
        record = recordFrames > 0 ? (.allocate(capacity: recordFrames), .allocate(capacity: recordFrames), recordFrames) : nil
    }

    deinit {
        scratch.forEach { $0.deallocate() }
        if let record { record.left.deallocate(); record.right.deallocate() }
    }

    func start() {
        audio_ring_skip(input.ring, Int32(input.count))  // old sound from before this player: drop it
        let thread = Thread { [self] in run() }
        thread.name = "Pitch Shift advanced"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 1 << 20
        self.thread = thread
        thread.start()
    }

    // Stops the thread and waits for it, so the rings are never used by two readers.
    func finish() {
        guard thread != nil else { return }
        keepGoing.withLock { $0 = false }
        input.wake.signal()
        done.wait()
        thread = nil
    }

    private func run() {
        var current = wanted.withLock { $0 }
        let (inL, inR, outL, outR) = (scratch[0], scratch[1], scratch[2], scratch[3])
        while keepGoing.withLock({ $0 }) {
            _ = input.wake.wait(timeout: .now() + .milliseconds(50))
            let value = wanted.withLock { $0 }
            if value != current {
                processor.setHalfSteps(value.halfSteps)
                processor.setTone(bass: value.bassDb, treble: value.trebleDb)
                processor.setAutoEQ(on: value.autoEQOn, offsets: value.autoEQOffsets)
                current = value
            }
            while true {
                let n = Int(audio_ring_read(input.ring, inL, inR, Int32(block)))
                if n == 0 { break }
                received += n
                var peak: Float = 0
                vDSP_maxmgv(inL, 1, &peak, vDSP_Length(n)); loudest = max(loudest, peak)
                vDSP_maxmgv(inR, 1, &peak, vDSP_Length(n)); loudest = max(loudest, peak)
                processor.process(inL, inR, outL, outR, n)
                audio_ring_write(output.ring, outL, outR, Int32(n))
                vDSP_maxmgv(outL, 1, &peak, vDSP_Length(n)); outputLoudest = max(outputLoudest, peak)
                if let record, recorded < record.capacity {
                    let m = min(n, record.capacity - recorded)
                    (record.left + recorded).update(from: outL, count: m)
                    (record.right + recorded).update(from: outR, count: m)
                    recorded += m
                }
            }
        }
        done.signal()
    }
}

// --render-file IN OUT [--steps N] [--advanced | --super] [--steps-at "SECONDS:N,SECONDS:N"] [--tone-db B,T | --tone-amount T]
//               [--tone-at "SECONDS:T,SECONDS:T"] [--auto-eq] [--eq-offsets a,b,c,d,e]
// Shifts a sound file offline with the app's own code (normal mode, Advanced processing or Super Advanced), for
// listening samples and checks. The output lines up with the input (the delay is taken out) and has the same length.
// --steps-at changes the amount while it plays, like moving the amount live. --tone-db: Advanced processing's bass
// and treble in dB; --tone-amount: the Bass ↔ Treble slider (−1 … 1); --tone-at moves the slider while it plays.
// --auto-eq / --eq-offsets: Advanced processing's Auto EQ on, and its manual offsets in dB (Sub … Air).
func renderFile(input: String, output: String, halfSteps: Float, advanced: Bool, heavy: Bool = false, changes: [(Double, Float)],
                tone: (bass: Double, treble: Double) = (0, 0), toneChanges: [(Double, Float)] = [],
                autoEQ: (on: Bool, offsets: [Double]) = (false, AdvancedProcessor.noOffsets)) throws {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: input))
    let rate = file.processingFormat.sampleRate
    let length = Int(file.length)
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(length)) else {
        throw Problem(message: "Could not read \(input).")
    }
    try file.read(into: source)
    let channels = Int(file.processingFormat.channelCount)
    let inputs = [source.floatChannelData![0], source.floatChannelData![min(1, channels - 1)]]
    var outputs = [[Float](repeating: 0, count: length), [Float](repeating: 0, count: length)]

    let block = 1024
    let zeros = [Float](repeating: 0, count: block)
    var outL = [Float](repeating: 0, count: block), outR = [Float](repeating: 0, count: block)
    func amount(at frame: Int) -> Float {
        changes.last { Int($0.0 * rate) <= frame }?.1 ?? halfSteps
    }

    if advanced || heavy {
        let biggest = ([halfSteps] + changes.map(\.1)).map(abs).max() ?? 0
        let made: HearProcessor? = heavy ? HeavyProcessor(sampleRate: rate, halfSteps: amount(at: 0))
            : AdvancedProcessor(sampleRate: rate, halfSteps: amount(at: 0), fullRange: biggest > 12)
        guard let processor = made else {
            throw Problem(message: "Could not start Advanced processing.")
        }
        processor.setTone(bass: tone.bass, treble: tone.treble)
        processor.setAutoEQ(on: autoEQ.on, offsets: autoEQ.offsets)
        let latency = processor.latencyFrames
        var position = 0, written = -latency
        while written < length {
            let n = min(block, max(1, length + latency - position))
            processor.setHalfSteps(amount(at: position))
            if let moved = toneChanges.last(where: { Int($0.0 * rate) <= position }) {
                let db = AdvancedProcessor.toneDb(tilt: moved.1)
                processor.setTone(bass: db.bass, treble: db.treble)
            }
            let take = max(0, min(n, length - position))
            // Past the end of the file, zeros push the last of the sound out.
            var inL = zeros, inR = zeros
            if take > 0 {
                for i in 0..<take { inL[i] = inputs[0][position + i]; inR[i] = inputs[1][position + i] }
            }
            processor.process(inL, inR, &outL, &outR, n)
            for i in 0..<n where written + i >= 0 && written + i < length {
                outputs[0][written + i] = outL[i]; outputs[1][written + i] = outR[i]
            }
            position += n
            written += n
        }
    } else {
        // Normal mode: the same Rubber Band settings as Player.
        let options = Int32(RubberBandOptionProcessRealTime.rawValue | RubberBandOptionEngineFiner.rawValue | RubberBandOptionChannelsTogether.rawValue)
        guard let shifter = rubberband_new(UInt32(rate), 2, options, 1, pow(2, Double(amount(at: 0)) / 12)) else {
            throw Problem(message: "Could not start Rubber Band.")
        }
        defer { rubberband_delete(shifter) }
        rubberband_set_max_process_size(shifter, UInt32(block))
        let pad = Int(rubberband_get_preferred_start_pad(shifter))
        // At normal pitch Player skips the shifter and the limiter, so the limiter stays out here too.
        let limiter = halfSteps != 0 || changes.contains { $0.1 != 0 } ? heavy_limiter_new(rate) : nil
        defer { if let limiter { heavy_limiter_delete(limiter) } }
        var skip = Int(rubberband_get_start_delay(shifter)) + (limiter.map { Int(heavy_limiter_latency_frames($0)) } ?? 0)
        var position = -pad, written = 0
        var current = amount(at: 0)
        while written < length {
            let value = amount(at: max(0, position))
            if value != current { rubberband_set_pitch_scale(shifter, pow(2, Double(value) / 12)); current = value }
            var inL = zeros, inR = zeros
            for i in 0..<block where position + i >= 0 && position + i < length {
                inL[i] = inputs[0][position + i]; inR[i] = inputs[1][position + i]
            }
            inL.withUnsafeBufferPointer { l in
                inR.withUnsafeBufferPointer { r in
                    let ins: [UnsafePointer<Float>?] = [l.baseAddress, r.baseAddress]
                    rubberband_process(shifter, ins, UInt32(block), 0)
                }
            }
            position += block
            while rubberband_available(shifter) > 0 {
                let want = min(Int(rubberband_available(shifter)), block)
                let got = outL.withUnsafeMutableBufferPointer { l in
                    outR.withUnsafeMutableBufferPointer { r in
                        let outs: [UnsafeMutablePointer<Float>?] = [l.baseAddress, r.baseAddress]
                        return Int(rubberband_retrieve(shifter, outs, UInt32(want)))
                    }
                }
                if let limiter { heavy_limiter_process(limiter, &outL, &outR, Int32(got)) }
                let drop = min(skip, got)
                skip -= drop
                for i in drop..<got where written < length {
                    outputs[0][written] = outL[i]; outputs[1][written] = outR[i]
                    written += 1
                }
            }
        }
    }

    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                   AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false]
    let out = try AVAudioFile(forWriting: URL(fileURLWithPath: output), settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length))!
    buffer.frameLength = AVAudioFrameCount(length)
    for c in 0..<2 { outputs[c].withUnsafeBufferPointer { buffer.floatChannelData![c].update(from: $0.baseAddress!, count: length) } }
    try out.write(from: buffer)
}
