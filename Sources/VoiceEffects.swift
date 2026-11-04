// Echo and Radio: two effects on the voice, each with a slider from 0 (off) to 1 (full). They come after the voice is
// made (plain, shifted, Natural or AI) and before the Soundboard's sound is mixed in, so sounds stay clean and the AI
// voice never hears an echo. Used on the voice chain's sound thread (VoiceChain) and by the offline checks
// (--render-voice, --render-sounds), so both do exactly the same.
import AVFoundation

// One filter from Robert Bristow-Johnson's audio EQ cookbook. Cutoffs stay under 0.4 of the sample rate, for
// Bluetooth mics at 8 or 16 kHz.
struct EffectFilter {
    private var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var s1 = 0.0, s2 = 0.0

    mutating func lowPass(_ hz: Double, q: Double, rate: Double) {
        let w = 2 * Double.pi * min(hz, rate * 0.4) / rate
        let c = cos(w), alpha = sin(w) / (2 * q), n = 1 + alpha
        b0 = (1 - c) / 2 / n
        b1 = (1 - c) / n
        b2 = b0
        a1 = -2 * c / n
        a2 = (1 - alpha) / n
    }

    mutating func highPass(_ hz: Double, q: Double, rate: Double) {
        let w = 2 * Double.pi * min(hz, rate * 0.4) / rate
        let c = cos(w), alpha = sin(w) / (2 * q), n = 1 + alpha
        b0 = (1 + c) / 2 / n
        b1 = -(1 + c) / n
        b2 = b0
        a1 = -2 * c / n
        a2 = (1 - alpha) / n
    }

    mutating func peak(_ hz: Double, q: Double, db: Double, rate: Double) {
        let w = 2 * Double.pi * min(hz, rate * 0.4) / rate
        let c = cos(w), alpha = sin(w) / (2 * q), size = pow(10, db / 40), n = 1 + alpha / size
        b0 = (1 + alpha * size) / n
        b1 = -2 * c / n
        b2 = (1 - alpha * size) / n
        a1 = b1
        a2 = (1 - alpha / size) / n
    }

    mutating func clear() {
        s1 = 0
        s2 = 0
    }

    @inline(__always) mutating func run(_ x: Float) -> Float {
        let input = Double(x)
        let output = b0 * input + s1
        s1 = b1 * input - a1 * output + s2
        s2 = b2 * input - a2 * output
        return Float(output)
    }
}

// Echo: the voice comes back every 0.28 s, a little thinner and darker each time. Full is a first repeat at three
// quarters of the voice's level, then each one under half of the last, so 6 or 7 can be heard. It can't run away: each
// trip round the loop takes the repeat down to 0.45 or less (the filters only take away, and softLimit caps what's
// stored). On a note held for ever all repeats added up pass the voice (0.75 / (1 - 0.45) = 1.36), and CallMix eases
// that. While you talk the repeats are turned down, measured against your own recent loudness so a quiet mic works the
// same; they come up in the pauses.
//
// Radio: more and more like a small radio as the slider goes up: a narrower band of sound, a peak where small speakers
// ring, the tops of the waves worn off, and at the far end light static that follows the voice (none in silence). It
// sounds like AM radio about halfway and a walkie-talkie at full. How hard the waves are hit follows the voice's
// loudness, so a quiet mic gets the same grit as a loud one. The voice stays about as loud all along the slider.
//
// Radio comes first, so the echo repeats the radio's sound. Slider moves glide over about 30 ms. At 0 an effect is
// skipped and what it holds is cleared, so old speech can't come back later. Makes no memory on the sound thread (the
// delay line is made in init, freed with free()) and never waits.
struct VoiceEffects {
    static let echoSeconds = 0.28
    static let tailSeconds = 2.0        // after this, Echo at full is over 50 dB under the voice
    private static let firstRepeat: Float = 0.75, nextRepeats: Float = 0.45  // at full
    private static let duck: Float = 0.4       // the part of the repeats taken away while talking
    private static let talkingAt: Float = 0.4  // the share of the recent loudness that counts as talking
    private static let radioStart: Float = 0.05  // below this a little of the plain voice is mixed in, so it starts softly

    private let rate: Double
    private let glide: Float  // per sample: 30 ms

    private let line: UnsafeMutablePointer<Float>  // the voice and its repeats on their way back
    private let length: Int
    private var at = 0
    private var echoOn = false
    private var echoAmount: Float = 0  // the slider, gliding
    private var first: Float = 0       // how loud the first repeat is
    private var next: Float = 0        // how much of each repeat comes round again
    private var thin = EffectFilter(), dark = EffectFilter()
    private var voice: Float = 0, recent: Float = 0  // the voice's level now, and its loudest in the last few seconds
    private let voiceUp: Float    // 5 ms
    private let voiceDown: Float  // 120 ms
    private let recentFall: Float // 3 s

    private var radioOn = false
    private var radioAmount: Float = 0  // the slider, gliding
    private var blend: Float = 0        // 0 = the plain voice, 1 = all radio
    private var band1 = EffectFilter(), band2 = EffectFilter(), band3 = EffectFilter(), band4 = EffectFilter()
    private var ring = EffectFilter()   // the peak of a small speaker
    private var level: Float = 0        // the voice's level going into the grit
    private let levelUp: Float    // 2 ms
    private let levelDown: Float  // 120 ms
    private let hissSize: Float   // the same static at any sample rate (the band keeps a bigger share of it at a low one)
    private var random: UInt32 = 2_463_534_242

    init(rate: Double) {
        self.rate = rate
        glide = Float(1 / (0.03 * rate))
        length = max(1, Int(rate * Self.echoSeconds))
        line = .allocate(capacity: length)
        line.initialize(repeating: 0, count: length)
        voiceUp = Float(1 - exp(-1 / (0.005 * rate)))
        voiceDown = Float(1 - exp(-1 / (0.12 * rate)))
        recentFall = Float(exp(-1 / (3 * rate)))
        levelUp = Float(1 - exp(-1 / (0.002 * rate)))
        levelDown = voiceDown
        hissSize = Float((rate / 48000).squareRoot())
        thin.highPass(160, q: 0.7071, rate: rate)
        dark.lowPass(4000, q: 0.7071, rate: rate)
    }

    // Call once, when nothing uses it any more (the chain's sound has stopped).
    func free() { line.deallocate() }

    // One callback of the voice, changed in place. True while an effect is at work: CallMix must then ease the
    // loudest moments.
    mutating func process(_ sound: UnsafeMutablePointer<Float>, _ frames: Int, echo: Float, radio: Float) -> Bool {
        guard echo > 0 || radio > 0 || echoOn || radioOn else { return false }
        for i in 0..<frames where !sound[i].isFinite { sound[i] = 0 }  // it would stay in the filters and the echo
        if radio > 0 || radioOn { playRadio(sound, frames, radio) }
        if echo > 0 || echoOn { playEcho(sound, frames, echo) }
        return true
    }

    private func glided(_ now: Float, to wanted: Float, _ frames: Int) -> Float {
        let moved = now + (wanted - now) * (1 - exp(-Float(frames) * glide))
        return abs(wanted - moved) < 0.002 ? wanted : moved
    }

    private mutating func playEcho(_ sound: UnsafeMutablePointer<Float>, _ frames: Int, _ wanted: Float) {
        echoOn = true
        echoAmount = glided(echoAmount, to: wanted, frames)
        let strength = echoAmount.squareRoot()  // so the left half of the slider isn't nearly silent
        let firstEnd = Self.firstRepeat * strength, nextEnd = Self.nextRepeats * strength
        let firstStep = (firstEnd - first) / Float(frames), nextStep = (nextEnd - next) / Float(frames)
        for i in 0..<frames {
            first += firstStep
            next += nextStep
            let dry = sound[i]
            let back = dark.run(thin.run(line[at]))
            line[at] = softLimit(dry + back * next)
            at = at + 1 == length ? 0 : at + 1
            let size = abs(dry)
            voice += (size - voice) * (size > voice ? voiceUp : voiceDown)
            recent = max(voice, recent * recentFall)
            let talking = min(1, voice / max(recent * Self.talkingAt, 1e-4))
            sound[i] = dry + back * first * (1 - Self.duck * talking)
        }
        first = firstEnd
        next = nextEnd
        if wanted == 0 && echoAmount == 0 {
            echoOn = false
            line.update(repeating: 0, count: length)
            at = 0
            thin.clear()
            dark.clear()
            voice = 0
            recent = 0
        }
    }

    private mutating func tuneRadio() {
        let amount = Double(radioAmount)
        let low = 70 * pow(5, amount), high = 14000 * pow(0.2, amount)  // 70 Hz ... 350 Hz, 14 kHz ... 2.8 kHz
        band1.highPass(low, q: 0.5412, rate: rate)
        band2.highPass(low, q: 1.3066, rate: rate)
        band3.lowPass(high, q: 0.5412, rate: rate)
        band4.lowPass(high, q: 1.3066, rate: rate)
        ring.peak(1700, q: 0.9, db: 8 * amount, rate: rate)
    }

    private mutating func playRadio(_ sound: UnsafeMutablePointer<Float>, _ frames: Int, _ wanted: Float) {
        radioOn = true
        if radioAmount != wanted {
            radioAmount = glided(radioAmount, to: wanted, frames)
            tuneRadio()
        }
        let square = radioAmount * radioAmount
        let drive = 0.25 + 4.75 * square   // how hard the waves are hit; under 1 they keep their shape
        let lift = 1 + 1.3 * square        // what the narrower band and the worn tops took from the loudness
        let hiss = 0.06 * hissSize * square * radioAmount  // about 19 dB under the voice at full
        let blendEnd = min(1, radioAmount / Self.radioStart)
        let blendStep = (blendEnd - blend) / Float(frames)
        for i in 0..<frames {
            blend += blendStep
            let dry = sound[i]
            let cut = band1.run(dry)
            let size = abs(cut)
            level += (size - level) * (size > level ? levelUp : levelDown)
            let push = drive / max(level, 0.002)
            random ^= random << 13
            random ^= random >> 17
            random ^= random << 5
            let noise = Float(Int32(truncatingIfNeeded: random)) / 2_147_483_648
            let worn = tanh(cut * push) / push + noise * hiss * level
            let wet = ring.run(band4.run(band3.run(band2.run(worn)))) * lift
            sound[i] = dry + (wet - dry) * blend
        }
        blend = blendEnd
        if wanted == 0 && radioAmount == 0 {
            radioOn = false
            band1.clear()
            band2.clear()
            band3.clear()
            band4.clear()
            ring.clear()
            level = 0
        }
    }

    // A whole voice through the effects in callbacks of `block` samples, eased at its loudest as CallMix does, with
    // room after the end for Echo's last repeats.
    static func render(_ voice: [Float], rate: Double, echo: Float, radio: Float, block: Int = 128) -> [Float] {
        var effects = VoiceEffects(rate: rate)
        defer { effects.free() }
        var out = voice + [Float](repeating: 0, count: echo > 0 ? Int(rate * tailSeconds) : 0)
        out.withUnsafeMutableBufferPointer { samples in
            var position = 0
            while position < samples.count {
                let frames = min(block, samples.count - position)
                _ = effects.process(samples.baseAddress! + position, frames, echo: echo, radio: radio)
                position += frames
            }
        }
        return out.map(softLimit)
    }
}

// --render-voice --echo --radio: puts the effects on a finished file (plain, shifted, Natural or AI), which is written
// as one channel.
func addVoiceEffects(file: String, echo: Float, radio: Float) throws {
    let voice = try readMonoFile(file)
    let out = VoiceEffects.render(voice.samples, rate: voice.rate, echo: echo, radio: radio)
    guard let format = AVAudioFormat(standardFormatWithSampleRate: voice.rate, channels: 1),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, out.count))) else {
        throw Problem(message: "Could not write \(file).")
    }
    buffer.frameLength = AVAudioFrameCount(out.count)
    _ = out.withUnsafeBufferPointer { memcpy(buffer.floatChannelData![0], $0.baseAddress!, out.count * MemoryLayout<Float>.size) }
    try AVAudioFile(forWriting: URL(fileURLWithPath: file), settings: format.settings).write(from: buffer)
}
