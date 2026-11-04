// The Soundboard: sound effects (files the owner adds) that play into "Pitch Shift Mic", so the people in a call
// hear them. They're mixed in after the voice (never through the mic or the pitch change, see VoiceChain), and the
// owner hears them too, on the Mac's current speakers or headphones. On the Mac's own speakers the mic is muted
// while a sound plays (and 150 ms after), so the mic can't pick the sound up and send it a second time (an echo).
import AppKit
import AVFoundation
import Accelerate
import CoreAudio
import UniformTypeIdentifiers

// One sound, ready to play: one channel at the voice chain's rate, its loudest point at -6 dBFS, and no louder on
// average than a usual sound (see `averageCap`).
final class SoundClip {
    let buffer: AVAudioPCMBuffer
    let rate: Double
    var count: Int { Int(buffer.frameLength) }
    var seconds: Double { Double(count) / rate }
    var samples: UnsafePointer<Float> { UnsafePointer(buffer.floatChannelData![0]) }
    static let longest: Double = 300  // only the first 5 minutes of a longer file are used
    static let peak: Float = 0.501187  // -6 dBFS
    // The most a sound's loudest 0.4 s may average (rms): -16 dBFS. A usual sound effect, with its loudest point at
    // -6 dBFS, averages -16 to -20 dBFS and isn't changed. A squashed, clipped "loud" one (many meme sounds) averages
    // -7 to -10 dBFS at the same loudest point: 10 dB louder than the others, 20-40 dB louder than a voice from the
    // Mac's mic, which makes call apps (Discord) turn it and the voice down or cut them as noise.
    static let averageCap: Float = 0.158489
    static let averageWindow: Double = 0.4

    // `levelFix: false`: as in 2.0.2 (the sample peak at -6 dBFS, nothing else), for --render-sounds --sound-preset old.
    init(url: URL, rate: Double, levelFix: Bool = true) throws {
        let problem = Problem(message: "Can't read \(url.lastPathComponent).")
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let length = AVAudioFrameCount(max(0, min(file.length, AVAudioFramePosition(format.sampleRate * Self.longest))))
        guard length > 0, rate > 0, let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length),
              let monoFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: length) else { throw problem }
        try file.read(into: source, frameCount: length)
        let frames = Int(source.frameLength)
        guard frames > 0, let channels = source.floatChannelData else { throw problem }

        // One channel: the file's channels averaged.
        let out = mono.floatChannelData![0]
        let count = Int(format.channelCount)
        vDSP_vclr(out, 1, vDSP_Length(frames))
        for c in 0..<count { vDSP_vadd(out, 1, channels[c], 1, out, 1, vDSP_Length(frames)) }
        var share = 1 / Float(max(1, count))
        vDSP_vsmul(out, 1, &share, out, 1, vDSP_Length(frames))
        mono.frameLength = AVAudioFrameCount(frames)

        // At the voice chain's rate.
        var result = mono
        if format.sampleRate != rate {
            guard let target = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
                  let converter = AVAudioConverter(from: monoFormat, to: target),
                  let converted = AVAudioPCMBuffer(pcmFormat: target,
                                                   frameCapacity: AVAudioFrameCount((Double(frames) * rate / format.sampleRate).rounded(.up)) + 1024)
            else { throw problem }
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            var given = false
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, state in
                if given { state.pointee = .endOfStream; return nil }
                given = true
                state.pointee = .haveData
                return mono
            }
            guard status != .error, converted.frameLength > 0 else { throw problem }
            result = converted
        }

        // Loudest point at -6 dBFS, so every sound is about as loud and there's room for the voice. The loudest point
        // counts the points between samples: a hard-edged (clipped) sound swings up to ~5 dB past its samples there,
        // and the clock matching into Pitch Shift Mic (and the call app) turn those points into samples.
        let data = result.floatChannelData![0]
        let total = Int(result.frameLength)
        var loudest: Float = 0
        vDSP_maxmgv(data, 1, &loudest, vDSP_Length(total))
        if levelFix { loudest = max(loudest, Self.peakBetweenSamples(data, total)) }
        if loudest > 0 {
            var gain = Self.peak / loudest
            // ... and its loudest 0.4 s no louder on average than `averageCap`.
            if levelFix {
                let average = Self.loudestAverage(data, total, window: Int(rate * Self.averageWindow)) * gain
                if average > Self.averageCap { gain *= Self.averageCap / average }
            }
            vDSP_vsmul(data, 1, &gain, data, 1, vDSP_Length(total))
        }
        buffer = result
        self.rate = rate
    }

    // The loudest point between samples, from the sound made 4 times finer (a 16-sample windowed sinc for each of the
    // three points between two samples, as in loudness meters' "true peak").
    static func peakBetweenSamples(_ data: UnsafePointer<Float>, _ count: Int) -> Float {
        let taps = 16, half = taps / 2
        guard count > taps else { return 0 }
        let outCount = count - taps + 1
        var result = [Float](repeating: 0, count: outCount)
        var loudest: Float = 0
        for k in 1...3 {
            let at = Double(k) / 4  // the point at sample + 1/4, 1/2, 3/4
            var filter = (0..<taps).map { p -> Float in
                let t = Double(p - half + 1) - at  // distance from that point to sample p
                let sinc = t == 0 ? 1 : sin(.pi * t) / (.pi * t)
                let w = 0.42 + 0.5 * cos(.pi * t / Double(half)) + 0.08 * cos(2 * .pi * t / Double(half))  // Blackman
                return Float(sinc * w)
            }
            let sum = filter.reduce(0, +)
            for p in filter.indices { filter[p] /= sum }  // a steady level stays the same
            vDSP_conv(data, 1, filter, 1, &result, 1, vDSP_Length(outCount), vDSP_Length(taps))
            var most: Float = 0
            vDSP_maxmgv(result, 1, &most, vDSP_Length(outCount))
            loudest = max(loudest, most)
        }
        return loudest
    }

    // The loudest average (rms) over `window` samples, looked at every quarter window; the whole sound if it's shorter.
    static func loudestAverage(_ data: UnsafePointer<Float>, _ count: Int, window: Int) -> Float {
        guard count > 0 else { return 0 }
        let size = min(max(1, window), count)
        var loudest: Float = 0
        var at = 0
        while true {
            var squares: Float = 0
            vDSP_svesq(data + at, 1, &squares, vDSP_Length(size))
            loudest = max(loudest, (squares / Float(size)).squareRoot())
            if at + size >= count { break }
            at = min(count - size, at + max(1, size / 4))
        }
        return loudest
    }
}

// The owner's copy's playing state, kept by its sound thread.
private final class HearMix: @unchecked Sendable {
    var mix: SoundMix
    init(_ mix: SoundMix) { self.mix = mix }
}

// One sound on the Soundboard: its file (a copy in the Sounds folder), the name on its button, which the owner
// can change (the file keeps its name), and its own volume (1 = as loud as the others, up to 1.5).
struct SoundEntry: Equatable {
    static let loudest: Float = 1.5
    let file: String
    var name: String
    var volume: Float

    init(file: String, name: String? = nil, volume: Float = 1) {
        self.file = file
        self.name = name.flatMap { $0.isEmpty ? nil : $0 } ?? Soundboard.displayName(file)
        self.volume = volume.isFinite ? max(0, min(Self.loudest, volume)) : 1
    }

    // One entry of the saved list: {file, name, volume}, or older forms: {file, name}, or just the file name.
    init?(saved: Any) {
        if let file = saved as? String {
            self.init(file: file)
        } else if let entry = saved as? [String: Any], let file = entry["file"] as? String, !file.isEmpty {
            self.init(file: file, name: entry["name"] as? String, volume: (entry["volume"] as? NSNumber)?.floatValue ?? 1)
        } else {
            return nil
        }
    }

    var saved: [String: Any] { ["file": file, "name": name, "volume": Double(volume)] }
}

// The list of sounds (copies of the owner's files, kept in Application Support), and playing them.
final class Soundboard {
    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pitch Shift", isDirectory: true).appendingPathComponent("Sounds", isDirectory: true)
    static let key = "soundboard"  // the sounds in order, each {file, name, volume}
    static let examples = ["Air horn.m4a", "Applause.wav", "Sad trombone.mp3"].map { SoundEntry(file: $0) }  // for pictures

    private(set) var sounds: [SoundEntry]
    var files: [String] { sounds.map(\.file) }
    private(set) var playing: String?  // its file
    var onChange: () -> Void = {}
    var speakers: Bool?        // tests: act as if the sound plays on the Mac's speakers (true) or headphones (false)
    var hearVolume: Float = 1  // the owner's own copy (tests: quiet, or 0 for none)
    var hearTap: AVAudioNodeTapBlock?  // tests: gets the owner's copy as it plays
    private let voice: VoiceShifter
    private let saves: Bool
    private let folder: URL
    private let defaults: UserDefaults
    private var clips: [String: SoundClip] = [:]
    private var current: SoundClip?
    // The owner's copy: it plays what the voice chain plays (voice.sounds), with the same 10 ms fade (SoundMix).
    private var engine: AVAudioEngine?
    private var source: AVAudioSourceNode?
    private var engineRate: Double = 0
    private var engineWatch: NSObjectProtocol?
    private var restart: DispatchWorkItem?
    private var stopping: DispatchWorkItem?
    private var ending: DispatchWorkItem?
    // While the Soundboard is open, the owner's player stays running (silent), so a click plays at once instead of
    // after the ~0.1 s it takes to start.
    var ready = false {
        didSet {
            guard oldValue != ready else { return }
            if ready { runEngine(rate: rate) } else { stopEngineSoon() }
        }
    }

    // `folder` and `defaults` are only changed by tests.
    init(voice: VoiceShifter, sounds: [SoundEntry], saves: Bool, folder: URL = Soundboard.folder, defaults: UserDefaults = .standard) {
        self.voice = voice
        self.sounds = sounds
        self.saves = saves
        self.folder = folder
        self.defaults = defaults
    }

    // The saved list, without files that are gone. A list saved before sounds could be renamed (only file names) is
    // saved again in the new form the first time it's read.
    static func saved(_ defaults: UserDefaults) -> [SoundEntry] {
        let stored = defaults.array(forKey: key) ?? []
        let all = stored.compactMap(SoundEntry.init(saved:))
        if stored.contains(where: { $0 is String }) { defaults.set(all.map(\.saved), forKey: key) }
        return all.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.file).path) }
    }

    static func displayName(_ file: String) -> String { (file as NSString).deletingPathExtension }

    // The Mac's own speakers (not headphones in its jack, Bluetooth, USB or anything else): its mic hears them.
    static func onSpeakers(_ device: AudioDeviceID) -> Bool {
        guard transportType(device) == kAudioDeviceTransportTypeBuiltIn else { return false }
        let source = getValue(device, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput, default: UInt32(0))
        return source != 0x6864_706E  // 'hdpn': headphones in the Mac's jack
    }

    // Click = play; clicking the one playing stops it.
    func click(_ file: String) {
        if playing == file { stop() } else { play(file) }
    }

    // The voice chain's rate (sounds are made ready at that rate).
    private var rate: Double {
        voice.chain?.sampleRate ?? voice.currentMic.map(nominalRate).flatMap { $0 > 0 ? $0 : nil } ?? 48000
    }

    func play(_ file: String) {
        let rate = self.rate
        if let clip = clips[file], clip.rate != rate {
            if clip !== current { keepAlive(clip) }
            clips[file] = nil
        }
        if clips[file] == nil { clips[file] = try? SoundClip(url: folder.appendingPathComponent(file), rate: rate) }
        guard let clip = clips[file] else { NSSound.beep(); return }
        play(clip, as: file, volume: sounds.first { $0.file == file }?.volume ?? 1)
    }

    func play(_ clip: SoundClip, as name: String, volume: Float = 1) {
        if let current, current !== clip { keepAlive(current) }
        current = clip
        // The owner's copy first (starting it can take a moment), then the call's copy, so they start together and
        // the mic stays muted until the speakers are done.
        hear(clip)
        let next = SoundPlay(samples: clip.samples, count: clip.count, rate: clip.rate, take: 0,
                             muteMic: speakers ?? Self.onSpeakers(defaultOutput()), volume: volume)
        voice.sounds.withLock { state in
            var play = next
            play.take = state.take + 1
            state = play
        }
        playing = name
        ending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.clear() }
        ending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + clip.seconds + 0.1, execute: work)
        onChange()
    }

    func stop() {
        guard playing != nil else { return }
        clear()
    }

    // For pictures only: shows a sound as playing, without any sound.
    func showAsPlaying(_ file: String) {
        playing = file
        onChange()
    }

    private func clear() {
        ending?.cancel()
        ending = nil
        voice.sounds.withLock { state in state = SoundPlay(take: state.take + 1) }  // both copies fade out
        if !ready { stopEngineSoon() }
        if let current { keepAlive(current) }
        current = nil
        playing = nil
        onChange()
    }

    // The sound threads (both copies) may read a sound for a moment after it was replaced or stopped: keep it a
    // second longer.
    private func keepAlive(_ clip: SoundClip) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { withExtendedLifetime(clip) {} }
    }

    // The owner's own copy, on the Mac's current speakers or headphones: its player only has to be running, it picks
    // the sound up from voice.sounds like the voice chain.
    private func hear(_ clip: SoundClip) {
        guard hearVolume > 0 else { return }
        runEngine(rate: clip.rate)
    }

    private func runEngine(rate: Double) {
        stopping?.cancel()
        stopping = nil
        if engine?.isRunning != true || engineRate != rate { startEngine(rate: rate) }
    }

    private func startEngine(rate: Double) {
        stopEngine()
        guard hearVolume > 0, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return }
        let engine = AVAudioEngine()
        let sounds = voice.sounds, gain = hearVolume
        let state = HearMix(SoundMix(rate: rate, take: sounds.withLock { $0.take }))
        // Runs on the speakers' sound thread. Makes no memory.
        let source = AVAudioSourceNode(format: format) { silence, _, frameCount, list -> OSStatus in
            if let play = sounds.withLockIfAvailable({ $0 }) {
                if play.take != state.mix.take { _ = state.mix.start(play) }
                state.mix.follow(volume: play.volume)
            }
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard state.mix.active, let out = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else {
                for buffer in buffers { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
                silence.pointee = true
                return noErr
            }
            var mix = state.mix, ended = false  // (a copy for the loop, put back after)
            for i in 0..<Int(frameCount) { out[i] = mix.next(&ended) * gain }
            state.mix = mix
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        if let hearTap { source.installTap(onBus: 0, bufferSize: 4096, format: format, block: hearTap) }
        do { try engine.start() } catch { return }
        self.engine = engine
        self.source = source
        engineRate = rate
        // Other speakers or headphones were picked: the player stopped; start it again there once things settle
        // (connecting headphones can send several changes in a row).
        engineWatch = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restart?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.ready else { return }
                self.startEngine(rate: self.rate)
            }
            self?.restart = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    // Once a sound that was just stopped has faded out (and reached the speakers).
    private func stopEngineSoon() {
        guard engine != nil else { return }
        stopping?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.stopEngine() }
        stopping = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func stopEngine() {
        restart?.cancel()
        restart = nil
        stopping?.cancel()
        stopping = nil
        if let engineWatch { NotificationCenter.default.removeObserver(engineWatch) }
        engineWatch = nil
        engine?.stop()
        engine = nil
        source = nil
        engineRate = 0
    }

    // Copies the files into the Sounds folder and adds them to the end of the list (files that can't be read are
    // skipped with a beep).
    func add(_ urls: [URL]) {
        guard saves else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var added = false
        for url in urls {
            guard (try? AVAudioFile(forReading: url)) != nil else { NSSound.beep(); continue }
            let name = freeName(url.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name))
            } catch {
                NSSound.beep()
                continue
            }
            sounds.append(SoundEntry(file: name))
            added = true
        }
        guard added else { return }
        save()
        onChange()
    }

    // Removes a sound from the list and deletes its copy (the owner's original file stays where it was).
    func remove(_ file: String) {
        if playing == file { stop() }
        if let clip = clips.removeValue(forKey: file) { keepAlive(clip) }
        sounds.removeAll { $0.file == file }
        if saves {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
            save()
        }
        onChange()
    }

    // A new name for a sound's button (the file keeps its name). An empty name keeps the old one.
    func rename(_ file: String, to name: String) {
        let clean = name.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, let i = sounds.firstIndex(where: { $0.file == file }), sounds[i].name != clean else { return }
        sounds[i].name = clean
        save()
        onChange()
    }

    // A sound's own volume (0 ... 1.5). Heard at once if it's playing (both copies glide there, so no click).
    func setVolume(_ file: String, _ volume: Float) {
        guard let i = sounds.firstIndex(where: { $0.file == file }) else { return }
        let clean = max(0, min(SoundEntry.loudest, volume))
        guard sounds[i].volume != clean else { return }
        sounds[i].volume = clean
        if playing == file { voice.sounds.withLock { $0.volume = clean } }
        save()
    }

    func volume(of file: String) -> Float { sounds.first { $0.file == file }?.volume ?? 1 }

    private func save() {
        guard saves else { return }
        defaults.set(sounds.map(\.saved), forKey: Self.key)
    }

    // "Air horn.mp3", or "Air horn 2.mp3" if that name is taken.
    private func freeName(_ file: String) -> String {
        let base = (file as NSString).deletingPathExtension, ext = (file as NSString).pathExtension
        var name = file, number = 2
        while files.contains(name) || FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            number += 1
        }
        return name
    }
}

// One sound's button: its name, filled with the theme colors while it plays. Click to play, again to stop. A small
// ✕ shows in its corner while the mouse is over it (or right-click → Remove). Right-click → Rename… or a double-click
// turns the name into a text field: Return keeps the new name, Escape the old one. Right-click → Volume… shows a
// small slider for its own volume.
final class SoundPad: NSView, NSTextFieldDelegate {
    let file: String
    var onPlay: () -> Void = {}
    var onRemove: () -> Void = {}
    var onRename: (String) -> Void = { _ in }
    var onVolume: () -> Void = {}
    var isPlaying = false {
        didSet {
            guard oldValue != isPlaying else { return }
            setAccessibilityValue(isPlaying ? "playing" : nil)
            needsDisplay = true
        }
    }
    var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    private var pressed = false { didSet { if oldValue != pressed { needsDisplay = true } } }
    private var pressedRemove = false
    private var startedByClick = false  // the last click started this sound (the second click of a double-click stops it)
    private var editor: NSTextField?    // while renaming
    var name: String {
        didSet { if oldValue != name { named() } }
    }
    private static let font = NSFont.systemFont(ofSize: 13, weight: .medium)

    init(sound: SoundEntry) {
        file = sound.file
        name = sound.name
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        named()
        let menu = NSMenu()
        menu.addItem(withTitle: "Rename…", action: #selector(renameClicked), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Volume…", action: #selector(volumeClicked), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Remove", action: #selector(removeClicked), keyEquivalent: "").target = self
        self.menu = menu
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Rename") { [weak self] in
                self?.startRenaming()
                return true
            },
            NSAccessibilityCustomAction(name: "Volume") { [weak self] in
                self?.onVolume()
                return true
            },
            NSAccessibilityCustomAction(name: "Remove") { [weak self] in
                self?.onRemove()
                return true
            }])
    }

    private func named() {
        setAccessibilityLabel(name)
        // The full name shows on hover only when it doesn't fit.
        toolTip = (name as NSString).size(withAttributes: [.font: Self.font]).width > bounds.width - 20 ? name : nil
        needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // The ✕ in the top right corner.
    private var removeSpot: NSRect { NSRect(x: bounds.maxX - 17, y: bounds.maxY - 17, width: 14, height: 14) }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        if isPlaying {
            Theme.gradient.draw(in: shape, angle: 0)
            if pressed {
                NSColor.black.withAlphaComponent(0.12).setFill()
                shape.fill()
            }
        } else {
            NSColor.labelColor.withAlphaComponent(pressed ? 0.16 : hovered ? 0.1 : 0.06).setFill()
            shape.fill()
            NSColor.separatorColor.setStroke()
            shape.stroke()
        }

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let font = isPlaying ? NSFont.systemFont(ofSize: 13, weight: .semibold) : Self.font
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: isPlaying ? NSColor.white : NSColor.labelColor, .paragraphStyle: style]
        let height = (font.ascender - font.descender).rounded(.up)
        let line = NSRect(x: bounds.minX + 10, y: (bounds.midY - height / 2).rounded(), width: bounds.width - 20, height: height)
        if editor == nil {
            (name as NSString).draw(with: line, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        }

        guard hovered, editor == nil else { return }
        let spot = removeSpot
        NSColor.secondaryLabelColor.setFill()
        NSBezierPath(ovalIn: spot).fill()
        let cross = NSBezierPath()
        let r: CGFloat = 3
        cross.move(to: NSPoint(x: spot.midX - r, y: spot.midY - r))
        cross.line(to: NSPoint(x: spot.midX + r, y: spot.midY + r))
        cross.move(to: NSPoint(x: spot.midX - r, y: spot.midY + r))
        cross.line(to: NSPoint(x: spot.midX + r, y: spot.midY - r))
        cross.lineWidth = 1.5
        cross.lineCapStyle = .round
        NSColor.windowBackgroundColor.setStroke()
        cross.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    // A click works at once, even while another app (the call) is in front.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressed = false
        pressedRemove = false
        if editor != nil {  // a click on the button around the name being typed keeps it
            finishRenaming(keep: true)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let onRemoveSpot = hovered && removeSpot.insetBy(dx: -3, dy: -3).contains(point)
        if event.clickCount == 2 && !onRemoveSpot {
            // A double-click renames. Its first click played the sound: this one stops it again.
            if isPlaying && startedByClick { onPlay() }
            startedByClick = false
            startRenaming()
            return
        }
        pressedRemove = onRemoveSpot
        pressed = !pressedRemove
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let wasPressed = pressed, wasRemove = pressedRemove
        pressed = false
        pressedRemove = false
        if wasRemove && removeSpot.insetBy(dx: -3, dy: -3).contains(point) { onRemove() }
        if wasPressed && bounds.contains(point) {
            startedByClick = !isPlaying
            onPlay()
        }
    }

    // MARK: Renaming

    // Turns the name into a text field with the whole name selected. The Soundboard takes the typing (it never
    // switches apps); pictures (--preview) only show the field.
    func startRenaming() {
        guard editor == nil else { return }
        let field = NSTextField(string: name)
        field.font = Self.font
        field.alignment = .center
        field.bezelStyle = .roundedBezel
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.setAccessibilityLabel("Name")
        field.delegate = self
        let height = field.intrinsicContentSize.height
        field.frame = NSRect(x: 6, y: ((bounds.height - height) / 2).rounded(), width: bounds.width - 12, height: height)
        addSubview(field)
        editor = field
        needsDisplay = true
        if preview == nil { window?.makeKey() }
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    // Return or clicking elsewhere keeps what was typed (an empty name keeps the old one); Escape keeps the old name.
    func finishRenaming(keep: Bool) {
        guard let field = editor else { return }
        editor = nil
        let typed = field.stringValue
        if field.currentEditor() != nil { window?.makeFirstResponder(nil) }
        field.removeFromSuperview()
        needsDisplay = true
        if keep { onRename(typed) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): finishRenaming(keep: true)
        case #selector(NSResponder.cancelOperation(_:)): finishRenaming(keep: false)
        default: return false
        }
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) { finishRenaming(keep: true) }

    override func accessibilityPerformPress() -> Bool {
        onPlay()
        return true
    }

    @objc private func removeClicked() { onRemove() }
    @objc private func renameClicked() { startRenaming() }
    @objc private func volumeClicked() { onVolume() }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// The Soundboard's background: sound files dragged in from Finder (one or several) are added like with +. While
// they're over it, a frame in the theme color shows they can be dropped. Other files are refused (no message).
private final class DropArea: NSView {
    var onDrop: ([URL]) -> Void = { _ in }
    var highlighted = false { didSet { if oldValue != highlighted { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    // The sound files being dragged (by their file type; ones that still can't be read are skipped when added).
    private func soundFiles(_ drag: NSDraggingInfo) -> [URL] {
        drag.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.audio.identifier],
        ]) as? [URL] ?? []
    }

    override func draggingEntered(_ drag: NSDraggingInfo) -> NSDragOperation {
        highlighted = !soundFiles(drag).isEmpty
        return highlighted ? .copy : []
    }

    override func draggingUpdated(_ drag: NSDraggingInfo) -> NSDragOperation { highlighted ? .copy : [] }
    override func draggingExited(_ drag: NSDraggingInfo?) { highlighted = false }
    override func draggingEnded(_ drag: NSDraggingInfo) { highlighted = false }

    override func performDragOperation(_ drag: NSDraggingInfo) -> Bool {
        highlighted = false
        let urls = soundFiles(drag)
        guard !urls.isEmpty else { return false }
        onDrop(urls)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard highlighted else { return }
        let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 5), xRadius: 8, yRadius: 8)
        Theme.mid.withAlphaComponent(0.1).setFill()
        frame.fill()
        Theme.mid.setStroke()
        frame.lineWidth = 2
        frame.stroke()
    }
}

// The small floating "Soundboard" window: a grid of sounds, + to add files (or drop them on it), Stop. It floats above other apps and
// stays open while the owner is in a call, and clicking it doesn't switch away from the call app.
final class SoundboardPanel: NSObject, NSWindowDelegate, NSPopoverDelegate {
    let panel: NSPanel
    private let board: Soundboard
    private let scroll = NSScrollView()
    private let grid = FlippedView()
    private let dropArea = DropArea()
    private let addButton = NSButton()
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private var pads: [SoundPad] = []
    var onClose: () -> Void = {}
    private var volumePopover: NSPopover?
    private var clickWatch: Any?  // closes the volume popover on a click in another app
    private let columns = 3, padSize = NSSize(width: 120, height: 40), gap: CGFloat = 8, margin: CGFloat = 16
    private let visibleRows = 5  // more scroll
    private var placed = false

    init(board: Soundboard) {
        self.board = board
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "Soundboard"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true  // only the close button
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self

        let content = dropArea
        dropArea.onDrop = { [weak self] urls in self?.board.add(urls) }  // pictures: adds nothing (changes no settings)
        scroll.documentView = grid
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        content.addSubview(scroll)

        addButton.bezelStyle = .rounded
        let glyph = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [Theme.mid]))
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add sounds")?.withSymbolConfiguration(glyph)
        addButton.setAccessibilityLabel("Add sounds")
        addButton.target = self
        addButton.action = #selector(addClicked)
        stopButton.bezelStyle = .rounded
        stopButton.attributedTitle = NSAttributedString(string: "Stop", attributes: [
            .foregroundColor: Theme.mid, .font: NSFont.systemFont(ofSize: 13, weight: .medium)])
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        content.addSubview(addButton)
        content.addSubview(stopButton)
        panel.contentView = content
        reload()
    }

    var isOpen: Bool { panel.isVisible }

    // Opens next to the main window the first time (then where the owner left it). Pictures: kept out of sight
    // under the desktop picture like the main window, never in front, never switching apps.
    func open(beside window: NSWindow) {
        if !placed {
            placed = true
            let size = panel.frame.size
            let restored = preview == nil && panel.setFrameUsingName("Soundboard")
            if restored && NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
                // Where the owner left it (if that screen is still there), at the size the list needs now.
                panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width, height: size.height), display: false)
            } else {
                let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
                var origin = NSPoint(x: window.frame.maxX + 12, y: window.frame.maxY - panel.frame.height)
                if origin.x + panel.frame.width > screen.maxX { origin.x = max(screen.minX, window.frame.minX - 12 - panel.frame.width) }
                origin.y = max(screen.minY, origin.y)
                panel.setFrameOrigin(origin)
            }
            if preview == nil { panel.setFrameAutosaveName("Soundboard") }  // pictures change no settings
        }
        if preview != nil {
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
            panel.orderBack(nil)
            return
        }
        board.ready = true
        panel.orderFront(nil)
    }

    func close() { panel.close() }

    func windowWillClose(_ notification: Notification) {
        closeVolume()
        pads.forEach { $0.finishRenaming(keep: true) }
        board.stop()
        board.ready = false
        onClose()
    }

    // Typing a new name ends when the owner goes back to another app.
    func windowDidResignKey(_ notification: Notification) { pads.forEach { $0.finishRenaming(keep: true) } }

    // Makes one button per sound, three to a row, and fits the window around them.
    func reload() {
        closeVolume()
        pads.forEach { $0.removeFromSuperview() }
        pads = board.sounds.map { sound in
            let pad = SoundPad(sound: sound)
            let file = sound.file
            pad.onPlay = { [weak self] in self?.board.click(file) }
            pad.onRename = { [weak self] name in self?.board.rename(file, to: name) }
            pad.onVolume = { [weak self, weak pad] in if let pad { self?.showVolume(pad) } }
            // A moment later: removing rebuilds the buttons, and this one is still handling its click.
            pad.onRemove = { [weak self] in DispatchQueue.main.async { self?.board.remove(file) } }
            return pad
        }
        let rows = (pads.count + columns - 1) / columns
        let width = CGFloat(columns) * padSize.width + CGFloat(columns - 1) * gap
        let gridHeight = rows == 0 ? 0 : CGFloat(rows) * padSize.height + CGFloat(rows - 1) * gap
        for (i, pad) in pads.enumerated() {
            pad.frame = NSRect(x: CGFloat(i % columns) * (padSize.width + gap), y: CGFloat(i / columns) * (padSize.height + gap),
                               width: padSize.width, height: padSize.height)
            grid.addSubview(pad)
        }
        grid.frame = NSRect(x: 0, y: 0, width: width, height: gridHeight)
        let shown = min(gridHeight, CGFloat(visibleRows) * padSize.height + CGFloat(visibleRows - 1) * gap + padSize.height / 2)

        addButton.sizeToFit()
        stopButton.sizeToFit()
        let buttonHeight = max(addButton.frame.height, stopButton.frame.height)
        addButton.frame = NSRect(x: margin, y: margin, width: 48, height: buttonHeight)
        stopButton.frame = NSRect(x: margin + width - 72, y: margin, width: 72, height: buttonHeight)
        let top = margin + buttonHeight + (rows == 0 ? 0 : 12)
        scroll.frame = NSRect(x: margin, y: top, width: width, height: shown)
        let size = NSSize(width: width + 2 * margin, height: top + shown + margin)
        if panel.contentView?.frame.size != size {
            let frame = panel.frame
            panel.setContentSize(size)
            panel.setFrameTopLeftPoint(NSPoint(x: frame.minX, y: frame.maxY))  // grows downward
        }
        update()
    }

    // Shows the names and which sound is playing.
    func update() {
        if pads.map(\.file) != board.files { reload(); return }
        for (pad, sound) in zip(pads, board.sounds) {
            pad.name = sound.name
            pad.isPlaying = pad.file == board.playing
        }
        stopButton.isEnabled = board.playing != nil
    }

    // For pictures: the mouse over the first sound.
    func showHover() { pads.first?.hovered = true }

    // For pictures: the first sound's name being changed.
    func showRenaming() { pads.first?.startRenaming() }

    // For pictures: sound files being dragged over it.
    func showDropping() { dropArea.highlighted = true }

    // For pictures: the first sound's volume slider, at 80%.
    func showVolume() {
        guard let pad = pads.first else { return }
        board.setVolume(pad.file, 0.8)
        showVolume(pad)
    }

    // A small popover under a sound: one slider from 0 to 150% (a mark at 100%) and the amount, e.g. "80%". It
    // changes the volume as it moves.
    private func showVolume(_ pad: SoundPad) {
        closeVolume()
        let file = pad.file
        let percent = { (value: Float) in "\(Int((value * SoundEntry.loudest * 100).rounded()))%" }
        let slider = GradientSlider(left: "", right: "", name: "Volume", describe: percent)
        let amount = NSTextField(labelWithString: "")
        amount.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        amount.textColor = Theme.mid
        amount.alignment = .right
        slider.steps = 150  // 1% each
        slider.mark = 1 / SoundEntry.loudest
        slider.clickThrough = true
        slider.value = board.volume(of: file) / SoundEntry.loudest
        amount.stringValue = percent(slider.value)
        slider.onChange = { [weak self, weak amount] value in
            amount?.stringValue = percent(value)
            self?.board.setVolume(file, (value * SoundEntry.loudest * 100).rounded() / 100)
        }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 226, height: 36))
        slider.frame = NSRect(x: 12, y: 6, width: 150, height: 24)
        amount.frame = NSRect(x: 166, y: 9, width: 48, height: 18)
        content.addSubview(slider)
        content.addSubview(amount)
        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = content.frame.size
        popover.behavior = .transient
        popover.animates = preview == nil
        popover.delegate = self
        popover.show(relativeTo: pad.bounds, of: pad, preferredEdge: .minY)
        volumePopover = popover
        if preview != nil, let window = content.window {  // pictures: under the desktop picture like the Soundboard
            window.level = panel.level
            window.orderBack(nil)
            return
        }
        clickWatch = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closeVolume()
        }
    }

    private func closeVolume() {
        volumePopover?.close()
        volumeClosed()
    }

    // It also closes by itself on a click elsewhere in the app.
    func popoverDidClose(_ notification: Notification) {
        if notification.object as? NSPopover === volumePopover { volumeClosed() }
    }

    private func volumeClosed() {
        if let clickWatch { NSEvent.removeMonitor(clickWatch) }
        clickWatch = nil
        volumePopover = nil
    }

    @objc private func addClicked() {
        guard preview == nil else { return }
        let open = NSOpenPanel()
        open.allowsMultipleSelection = true
        open.canChooseDirectories = false
        open.allowedContentTypes = [.audio]
        NSApp.activate(ignoringOtherApps: true)
        open.begin { [weak self] answer in
            guard answer == .OK else { return }
            self?.board.add(open.urls)
        }
    }

    @objc private func stopClicked() { board.stop() }
}

// MARK: Checks (--test-sounds, --render-sounds)

// Offline check (--render-sounds): what Pitch Shift Mic would send while the Soundboard plays over a voice, made with
// the voice chain's own mixing (CallMix) in callbacks of `buffer` samples, with no devices. `voice` is one channel at
// `rate` (already shifted if wanted; `shifted`: it went through the pitch change, which the chain eases at its
// loudest). Each start is a click on the sound; like the app, the sound is cleared 0.1 s after its end, unless the
// next click comes first. The sound thread sees a click at the start of its next callback. Also times the mixing
// part of each callback (nanoseconds; worst and average, with a sound playing and without). `old`: the mixing as in
// 2.0.2 (no limiter, no fades at a sound's own ends; the clip should then be made with `levelFix: false` too).
// `echo`, `radio`: the voice's effects, which go on before the sound is mixed in, as in the chain.
func renderSounds(voice: [Float], rate: Double, shifted: Bool, clip: SoundClip, starts: [Double], volume: Float,
                  speakers: Bool, buffer: Int, old: Bool = false, echo: Float = 0, radio: Float = 0) -> (out: [Float], timing: String) {
    var events: [(at: Int, play: SoundPlay)] = []
    let sorted = starts.sorted()
    for (n, start) in sorted.enumerated() {
        let at = Int(start * rate)
        events.append((at, SoundPlay(samples: clip.samples, count: clip.count, rate: clip.rate, take: 0, muteMic: speakers, volume: volume)))
        let end = at + Int((clip.seconds + 0.1) * rate)
        if n + 1 == sorted.count || Int(sorted[n + 1] * rate) > end { events.append((end, SoundPlay())) }
    }
    var state = SoundPlay()
    var callMix = CallMix(rate: rate, take: state.take, limits: !old, ends: !old)
    var effects = VoiceEffects(rate: rate)
    defer { effects.free() }
    var out = [Float](repeating: 0, count: voice.count)
    var block = [Float](repeating: 0, count: buffer)
    var next = 0
    var worst = [UInt64](repeating: 0, count: 2), total = [UInt64](repeating: 0, count: 2), calls = [Int](repeating: 0, count: 2)
    var position = 0
    while position < voice.count {
        let frames = min(buffer, voice.count - position)
        while next < events.count && events[next].at <= position {
            var play = events[next].play
            play.take = state.take + 1
            state = play
            next += 1
        }
        for i in 0..<frames { block[i] = voice[position + i] }
        let started = DispatchTime.now().uptimeNanoseconds
        let playing = callMix.mix.active ? 1 : 0
        block.withUnsafeMutableBufferPointer { b in
            callMix.follow(state)
            callMix.muteIfNeeded(b.baseAddress!, frames)
            let effected = effects.process(b.baseAddress!, frames, echo: echo, radio: radio)
            for i in 0..<frames { b[i] = callMix.out(b[i], shifting: shifted || effected) }
        }
        let took = DispatchTime.now().uptimeNanoseconds - started
        worst[playing] = max(worst[playing], took)
        total[playing] += took
        calls[playing] += 1
        for i in 0..<frames { out[position + i] = block[i] }
        position += frames
    }
    func line(_ k: Int) -> String {
        calls[k] == 0 ? "-" : String(format: "worst %d ns, average %.0f ns over %d callbacks", worst[k], Double(total[k]) / Double(calls[k]), calls[k])
    }
    return (out, "mixing time per callback of \(buffer): with a sound \(line(1)); without \(line(0))")
}

// r[lag] = Σ a[lag + i]·b[i], for every lag where b fits inside a (with Accelerate's FFT).
func correlate(_ a: [Float], _ b: [Float]) -> [Float] {
    let lags = a.count - b.count + 1
    guard lags > 0, !b.isEmpty else { return [] }
    let log2n = vDSP_Length(log2(Double(a.count + b.count)).rounded(.up))
    let n = 1 << Int(log2n), half = n / 2
    guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
    defer { vDSP_destroy_fftsetup(setup) }
    func forward(_ x: [Float]) -> ([Float], [Float]) {
        let padded = x + [Float](repeating: 0, count: n - x.count)
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                padded.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }
        return (re, im)
    }
    var (ar, ai) = forward(a)
    let (br, bi) = forward(b)
    // A·conj(B). The first slot holds the 0 Hz and the top frequency parts on their own.
    let low = ar[0] * br[0], top = ai[0] * bi[0]
    for k in 1..<half {
        let re = ar[k] * br[k] + ai[k] * bi[k], im = ai[k] * br[k] - ar[k] * bi[k]
        ar[k] = re
        ai[k] = im
    }
    ar[0] = low
    ai[0] = top
    var out = [Float](repeating: 0, count: n)
    ar.withUnsafeMutableBufferPointer { rp in
        ai.withUnsafeMutableBufferPointer { ip in
            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
            out.withUnsafeMutableBytes { raw in
                vDSP_ztoc(&split, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(half))
            }
        }
    }
    let scale = 1 / Float(4 * n)
    return (0..<lags).map { out[$0] * scale }
}

// How much a recording looks like `reference` at each lag, from -1 to 1 (1 = an exact copy, at any loudness).
// Lags where the recording is nearly silent are left at 0.
func similarity(_ recording: [Float], _ reference: [Float]) -> [Float] {
    let raw = correlate(recording, reference)
    let m = reference.count
    let referenceEnergy = reference.reduce(0.0) { $0 + Double($1) * Double($1) }
    var sums = [Double](repeating: 0, count: recording.count + 1)
    for (i, x) in recording.enumerated() { sums[i + 1] = sums[i] + Double(x) * Double(x) }
    return raw.indices.map { lag in
        let energy = sums[lag + m] - sums[lag]
        guard energy > referenceEnergy * 0.01 else { return 0 }
        return Float(Double(raw[lag]) / (referenceEnergy * energy).squareRoot())
    }
}

// The --test-sounds report: where and how loud the sound arrived in Pitch Shift Mic, whether there's a second copy
// of it (an echo), and how loud the voice (a steady tone) was before, while and after the sound played.
func soundTestReport(recorded: [Float], reference: [Float], rate: Double, toneHz: Double) -> [String] {
    let m = reference.count
    guard recorded.count > m + Int(rate) else { return ["recording too short"] }
    let ms = Int(rate / 1000)
    var lines: [String] = []

    // Where the sound is: the strongest likeness. A second strong one would be an echo.
    let likeness = similarity(recorded, reference)
    let best = likeness.indices.max { abs(likeness[$0]) < abs(likeness[$1]) }!
    let others = likeness.indices.filter { abs($0 - best) > 5 * ms }
    let second = others.max { abs(likeness[$0]) < abs(likeness[$1]) }
    let strong = likeness.indices.filter { abs(likeness[$0]) > 0.5 }
    var groups = 0, last: Int?
    for i in strong {
        if last.map({ i - $0 > 5 * ms }) ?? true { groups += 1 }
        last = i
    }
    let own = similarity(reference + [Float](repeating: 0, count: m), reference)  // the file against itself
    let ownSecond = own.indices.filter { $0 > 5 * ms }.map { abs(own[$0]) }.max() ?? 0

    // How loud it arrived, compared with the file (1 = -6 dBFS at its loudest point), half a second at a time. Each
    // half second is lined up on its own: Pitch Shift Mic's clock drifts a few samples from the mic's over a long sound.
    struct Piece { let at: Int, count: Int, lag: Int, gain: Float }
    var pieces: [Piece] = []
    let half = Int(rate / 2)
    recorded.withUnsafeBufferPointer { rec in
        reference.withUnsafeBufferPointer { ref in
            for at in stride(from: 0, to: m, by: half) {
                let count = min(half, m - at)
                var energy: Float = 0
                vDSP_dotpr(ref.baseAddress! + at, 1, ref.baseAddress! + at, 1, &energy, vDSP_Length(count))
                var lag = 0, most = -Float.greatestFiniteMagnitude
                for d in -2 * ms...2 * ms where best + at + d >= 0 && best + at + d + count <= rec.count {
                    var dot: Float = 0
                    vDSP_dotpr(rec.baseAddress! + best + at + d, 1, ref.baseAddress! + at, 1, &dot, vDSP_Length(count))
                    if dot > most { most = dot; lag = d }
                }
                pieces.append(Piece(at: at, count: count, lag: lag, gain: energy > 0 ? most / energy : 0))
            }
        }
    }
    let heard = pieces.filter { piece in  // half seconds with real sound in them
        piece.gain.isFinite && reference[piece.at..<piece.at + piece.count].contains { abs($0) > 0.05 }
    }.map(\.gain).sorted()
    let level = heard.isEmpty ? 0 : Double(heard[heard.count / 2])
    let start = Double(best) / rate, end = Double(best + m) / rate
    let peakDB = 20 * log10(max(1e-9, level * Double(SoundClip.peak)))
    lines.append(String(format: "  sound in Pitch Shift Mic from %.3f s to %.3f s, level %.3f x the file (loudest point %.1f dBFS)",
                        start, end, level, peakDB))
    lines.append(String(format: "  each half second: %.3f to %.3f x, the last one %.3f x; timing drift by the end %d samples",
                        heard.first ?? 0, heard.last ?? 0, pieces.last?.gain ?? 0, pieces.last?.lag ?? 0))
    lines.append(String(format: "  likeness: main peak %.3f at %.3f s; next highest %.3f at %.3f s (the file against itself: %.3f); peaks above 0.5: %d",
                        likeness[best], start, second.map { abs(likeness[$0]) } ?? 0, Double(second ?? 0) / rate, ownSecond, groups))

    // The voice: the recording minus the sound leaves the tone (and anything else, like an echo).
    var leftover = recorded
    for piece in pieces {
        for i in piece.at..<piece.at + piece.count where best + i + piece.lag >= 0 && best + i + piece.lag < leftover.count {
            leftover[best + i + piece.lag] -= piece.gain * reference[i]
        }
    }
    func tone(_ from: Double, _ to: Double) -> (Double, Double)? {
        let a = max(0, Int(from * rate)), b = min(leftover.count, Int(to * rate))
        guard b - a > Int(rate / 10) else { return nil }
        var re = 0.0, im = 0.0, energy = 0.0
        let step = 2 * Double.pi * toneHz / rate
        for i in a..<b {
            let x = Double(leftover[i])
            re += x * cos(step * Double(i))
            im += x * sin(step * Double(i))
            energy += x * x
        }
        return (2 * (re * re + im * im).squareRoot() / Double(b - a), (energy / Double(b - a)).squareRoot())
    }
    let parts = [("before", 0.3, start - 0.05), ("while it played", start + 0.3, end - 0.05),
                 ("after", end + 0.6, Double(recorded.count) / rate - 0.05)]
    var toneLine = String(format: "  voice (tone %.1f Hz):", toneHz)
    for (name, from, to) in parts {
        if let (amount, rms) = tone(from, to) {
            toneLine += String(format: " %@ %.4f (all leftover %.4f rms);", name, amount, rms)
        } else {
            toneLine += " \(name) -;"
        }
    }
    lines.append(toneLine)

    // Gaps in the voice after the sound: 10 ms pieces much quieter than usual.
    let after = Int((end + 0.6) * rate)
    if after + 20 * ms < leftover.count {
        let pieces = stride(from: after, to: leftover.count - 10 * ms, by: 10 * ms).map { from in
            (leftover[from..<from + 10 * ms].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(10 * ms)).squareRoot()
        }
        let usual = pieces.sorted()[pieces.count / 2]
        let gaps = pieces.filter { $0 < usual * 0.5 }.count
        lines.append("  gaps in the voice after the sound: \(gaps) of \(pieces.count) pieces of 10 ms")
    }
    let during = recorded[best..<best + m].reduce(Float(0)) { max($0, abs($1)) }
    let elsewhere = (recorded[..<best] + recorded[(best + m)...]).reduce(Float(0)) { max($0, abs($1)) }
    lines.append(String(format: "  highest sample: %.3f while the sound played, %.3f the rest of the time (full scale = 1)", during, elsewhere))
    return lines
}
