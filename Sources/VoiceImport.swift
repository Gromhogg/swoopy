// The voice changer's own voices: the Voices folder (~/Library/Application Support/Pitch Shift/Voices, with a
// README.txt), "Add Voice…" (a voice folder or a .zip of one: copied in, a .mlpackage compiled, the model and its
// voice.json checked, a Natural block written if it has none), Rename, Remove (to the Trash; never a built-in voice)
// and a watcher that tells the window when the folder changes. --add-voice / --rename-voice / --remove-voice do the
// same from the command line (main.swift). Downloaded RVC voices (.pth) are turned into voice folders by
// tools/convert-voice.sh first.
import CoreML
import Foundation

// "How high is this voice?" for a voice with no Natural block: its Natural mode settings and the pitch the AI voice
// is given. Keep in step with tools/voice-converter/convert_voice.py (PRESETS).
enum VoicePitch: String, CaseIterable {
    case high, medium, low

    var title: String { rawValue.capitalized }

    // The voice.json "natural" block (a typical woman's voice for High, Woman's settings; a man's for Low, Man's).
    var natural: [String: Any] {
        switch self {
        case .high:
            return ["targetHz": 220, "assumedInputHz": 120, "intonation": 1.4, "formant": 1.21, "breathDb": -30,
                    "presenceDb": 2.5, "sibilanceKeep": 0, "eqAmount": 0.5, "ltas": Self.womanLtas]
        case .medium:
            return ["targetHz": 160, "assumedInputHz": 140, "intonation": 1.0, "formant": 1.0, "breathDb": -120,
                    "presenceDb": 0, "sibilanceKeep": 0, "eqAmount": 0, "ltas": [Double](repeating: 0, count: 21)]
        case .low:
            return ["targetHz": 112, "assumedInputHz": 205, "intonation": 0.75, "formant": 0.85, "breathDb": -120,
                    "presenceDb": 0, "sibilanceKeep": 0, "eqAmount": 0.5, "ltas": Self.manLtas]
        }
    }

    // A number of Hz (--pitch 210) takes the nearest kind's other settings.
    static func natural(hz: Double) -> [String: Any] {
        var block = (hz >= 185 ? VoicePitch.high : hz <= 135 ? .low : .medium).natural
        block["targetHz"] = (hz * 10).rounded() / 10
        return block
    }

    static let womanLtas = [-7.02, -1.87, 3.77, 3.16, 0.12, 2.69, 3.77, 3.7, 1.45, -0.14, -1.53, -2.74, -4.5, -6.87, -8.83,
                            -11.38, -15.21, -18.28, -19.82, -20.19, -22.41]
    static let manLtas = [3.34, 2.63, 3.37, 4.46, 4.29, 5.59, 6.76, 4.51, 0.53, -1.43, -1.74, -3.05, -5.58, -7.22, -8.4,
                          -10.64, -15, -18.27, -20.78, -23.45, -26.41]
}

enum VoiceFolder {
    // Makes the folder (and its README.txt) if it isn't there yet.
    static func ensure(_ folder: URL = VoiceLibrary.userFolder) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let readme = folder.appendingPathComponent("README.txt")
        if !fm.fileExists(atPath: readme.path) { try Self.readme.write(to: readme, atomically: true, encoding: .utf8) }
    }

    // The same text as tools/voice-converter/convert_voice.py writes.
    static let readme = """
    Swoopy voices

    Each voice is a folder in here (or a .zip of one you add with Add Voice...). Swoopy lists them in the Voice
    changer's voice menu.

    A voice folder holds:
    - voice.json: the voice's name and settings. Swoopy writes it for you when you add a voice.
    - a .mlmodelc folder (optional): the AI voice (Macs with Apple silicon). Without one, the voice
      uses the plain voice changer.

    To add a voice:
    - Downloaded an RVC v2 voice (a .pth file, or a .zip with one inside)? Turn it into a voice folder with the one line
      under "Your own voices" in Swoopy's README (https://github.com/Gromhogg/swoopy#your-own-voices). The new
      voice lands in here.
    - Got a voice folder, or a .zip of one? In Swoopy's Voice changer, click the button next to the voice menu and
      choose Add Voice..., or drop the folder in here.

    To remove a voice, choose Remove in the same menu, or move its folder to the Trash.

    Voices made from a real person or a character are your own responsibility: only use voices you are allowed to use.

    """
}

// Calls `onChange` (main thread, at most every half second) when files are added to, removed from or renamed in the
// folder. Only the folder itself is watched (not what happens inside a voice's folder): the voice menu reads the
// folder again each time it opens anyway.
final class VoiceFolderWatcher {
    private var source: DispatchSourceFileSystemObject?
    private let folder: URL
    private let onChange: () -> Void
    private var pending = false

    init(_ folder: URL, onChange: @escaping () -> Void) {
        self.folder = folder
        self.onChange = onChange
        start()
    }

    deinit { source?.cancel() }

    var watching: Bool { source != nil }

    // (Again, after the folder was made, moved or deleted.)
    func start() {
        guard source == nil else { return }
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let made = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        made.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            if !source.data.isDisjoint(with: [.rename, .delete]) {  // the folder itself went away: watch it again later
                source.cancel()
                self.source = nil
            }
            self.changed()
        }
        made.setCancelHandler { close(fd) }
        source = made
        made.resume()
    }

    private func changed() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.pending = false
            self.onChange()
        }
    }
}

// One voice being added. `examine` finds it (unpacking a .zip first) and says whether it needs a pitch answer;
// `install` copies it in. Both may be slow (unzip, compile, checks): call them off the main thread.
struct VoiceImport {
    let source: URL               // what was picked
    let root: URL                 // the folder holding the voice
    let manifest: [String: Any]   // its voice.json (empty if it has none)
    let model: URL?               // its AI voice (.mlmodelc or .mlpackage)
    let name: String
    private let scratch: URL?     // unpacked .zip, deleted by `discard`

    // No Natural block: ask how high the voice is.
    var needsPitch: Bool { manifest["natural"] == nil }

    static func examine(_ url: URL) throws -> VoiceImport {
        let fm = FileManager.default
        let shown = url.lastPathComponent
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw Problem(message: "Can't find “\(shown)”.") }
        let ext = url.pathExtension.lowercased()
        if !isDir.boolValue {
            switch ext {
            case "zip":
                let scratch = fm.temporaryDirectory.appendingPathComponent("swoopy-voice-\(UUID().uuidString)")
                try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", url.path, scratch.path]
                unzip.standardOutput = FileHandle.nullDevice
                unzip.standardError = FileHandle.nullDevice
                try unzip.run()
                unzip.waitUntilExit()
                guard unzip.terminationStatus == 0 else {
                    try? fm.removeItem(at: scratch)
                    throw Problem(message: "“\(shown)” can't be unpacked.")
                }
                do {
                    return try found(in: scratch, shown: shown, fallbackName: url.deletingPathExtension().lastPathComponent, scratch: scratch)
                } catch {
                    try? fm.removeItem(at: scratch)
                    throw error
                }
            case "json":
                return try found(in: url.deletingLastPathComponent(), shown: shown, fallbackName: url.deletingLastPathComponent().lastPathComponent, scratch: nil)
            default:
                throw unusable(ext, shown)
            }
        }
        if ext == "mlmodelc" || ext == "mlpackage" {  // a lone model: its own voice, named after the file
            return VoiceImport(source: url, root: url.deletingLastPathComponent(), manifest: [:], model: url,
                               name: url.deletingPathExtension().lastPathComponent, scratch: nil)
        }
        return try found(in: url, shown: shown, fallbackName: url.lastPathComponent, scratch: nil)
    }

    private static func unusable(_ ext: String, _ shown: String) -> Problem {
        switch ext {
        case "pth":
            return Problem(message: "“\(shown)” is an RVC voice file. Turn it into a Swoopy voice first with the one line under “Your own voices” in Swoopy's README; it lands in the Voices folder by itself.")
        case "index":
            return Problem(message: "“\(shown)” is an RVC search index, not a voice. Swoopy needs the voice's .pth file, turned into a Swoopy voice with the converter (README, “Your own voices”).")
        case "onnx":
            return Problem(message: "“\(shown)” is an .onnx voice, which Swoopy can't use. Look for the voice's .pth file and turn it into a Swoopy voice with the converter (README, “Your own voices”).")
        default:
            return Problem(message: "“\(shown)” isn't a voice. Pick a voice folder (with a voice.json or a .mlmodelc inside) or a .zip of one.")
        }
    }

    // The folder (at most 3 levels down) with a voice.json, else one with a model.
    private static func found(in top: URL, shown: String, fallbackName: String, scratch: URL?) throws -> VoiceImport {
        let fm = FileManager.default
        var level = [top], withModel: URL?, other: String?
        for _ in 0..<4 {
            var next: [URL] = []
            for dir in level {
                let items = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                    .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                if items.contains(where: { $0.lastPathComponent == "voice.json" }) {
                    return try read(dir, shown: shown, fallbackName: dir == top ? fallbackName : dir.lastPathComponent, scratch: scratch)
                }
                for item in items {
                    let ext = item.pathExtension.lowercased()
                    if ext == "mlmodelc" || ext == "mlpackage" { withModel = withModel ?? dir; continue }
                    if ["pth", "onnx", "index"].contains(ext) { other = other ?? ext }
                    if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { next.append(item) }
                }
            }
            if let withModel {
                return try read(withModel, shown: shown, fallbackName: withModel == top ? fallbackName : withModel.lastPathComponent, scratch: scratch)
            }
            level = next
        }
        if let other { throw unusable(other, shown) }
        throw Problem(message: "There's no voice in “\(shown)”. A voice folder has a voice.json file or a .mlmodelc AI voice inside.")
    }

    private static func read(_ dir: URL, shown: String, fallbackName: String, scratch: URL?) throws -> VoiceImport {
        let fm = FileManager.default
        var manifest: [String: Any] = [:]
        let json = dir.appendingPathComponent("voice.json")
        if fm.fileExists(atPath: json.path) {
            guard let data = try? Data(contentsOf: json),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw Problem(message: "The voice.json in “\(shown)” can't be read.")
            }
            manifest = object
            if let version = manifest["version"] as? Int, version > 1 {
                throw Problem(message: "“\(shown)” was made for a newer version of Swoopy. Update Swoopy, then add it again.")
            }
            if let natural = manifest["natural"] {
                guard let n = try? JSONDecoder().decode(VoiceManifest.Natural.self, from: JSONSerialization.data(withJSONObject: natural)),
                      n.ltas.count == Int(VOICECHANGER_LTAS_BANDS),
                      ([n.targetHz, n.assumedInputHz, n.intonation, n.formant, n.breathDb, n.presenceDb, n.sibilanceKeep, n.eqAmount] + n.ltas).allSatisfy(\.isFinite),
                      n.targetHz > 0, n.assumedInputHz > 0, n.formant > 0 else {
                    throw Problem(message: "The voice.json in “\(shown)” has Natural settings Swoopy can't read.")
                }
            }
        }
        var model: URL?
        if let realistic = manifest["realistic"] as? [String: Any], let named = realistic["model"] as? String {
            let base = (named as NSString).lastPathComponent
            let candidates = [base, (base as NSString).deletingPathExtension + ".mlmodelc", (base as NSString).deletingPathExtension + ".mlpackage"]
            model = candidates.map { dir.appendingPathComponent($0) }.first { fm.fileExists(atPath: $0.path) }
            if model == nil { throw Problem(message: "“\(shown)” is missing its AI voice (\(base)).") }
        } else {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            model = items.sorted { $0.lastPathComponent < $1.lastPathComponent }
                .first { ["mlmodelc", "mlpackage"].contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix("contentvec") }
        }
        if manifest["natural"] == nil && model == nil {
            throw Problem(message: "There's no voice in “\(shown)”. A voice folder has a voice.json file or a .mlmodelc AI voice inside.")
        }
        let name = (manifest["name"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        return VoiceImport(source: dir, root: dir, manifest: manifest, model: model, name: String(name.prefix(60)), scratch: scratch)
    }

    func discard() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // Copies the voice into `voices` (as <id>/) and returns its id. `pitch` is used when it has no Natural block.
    // `taken`: ids already in use (built-in voices and others); the new one gets a free one (name-2, ...).
    // `names`: names already in the voice menu (the same voice added twice shows as "Name 2").
    func install(into voices: URL, pitch: [String: Any]?, taken: Set<String>, names: Set<String> = []) throws -> String {
        let fm = FileManager.default
        try VoiceFolder.ensure(voices)
        let wanted = Self.slug((manifest["id"] as? String) ?? name)
        var id = wanted, n = 2
        while taken.contains(id) || fm.fileExists(atPath: voices.appendingPathComponent(id).path) {
            id = "\(wanted)-\(n)"
            n += 1
        }
        var name = self.name
        if names.contains(name.lowercased()) {
            var k = 2
            while names.contains("\(name) \(k)".lowercased()) { k += 1 }
            name = "\(name) \(k)"
        }
        let stage = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: voices, create: true)
        defer { try? fm.removeItem(at: stage) }
        let folder = stage.appendingPathComponent(id)
        if model != nil && model?.deletingLastPathComponent() == root && manifest.isEmpty && source == model {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)  // a lone model: only that
            try fm.copyItem(at: model!, to: folder.appendingPathComponent(model!.lastPathComponent))
        } else {
            try fm.copyItem(at: root, to: folder)
        }
        // What a voice doesn't need: RVC's own files, Finder's and zip leftovers.
        if let all = fm.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] {
            for item in all where ["pth", "index", "onnx", "npy"].contains(item.pathExtension.lowercased())
                || [".DS_Store", "__MACOSX"].contains(item.lastPathComponent) {
                try? fm.removeItem(at: item)
            }
        }
        var voice = manifest
        voice["id"] = id
        voice["name"] = name
        voice["version"] = 1
        if voice["natural"] == nil { voice["natural"] = pitch ?? VoicePitch.medium.natural }
        if let model {
            var file = folder.appendingPathComponent(model.lastPathComponent)
            if file.pathExtension.lowercased() == "mlpackage" {  // compile it once, here
                let compiled: URL
                do { compiled = try MLModel.compileModel(at: file) } catch {
                    throw Problem(message: "“\(name)”'s AI voice can't be prepared (\(error.localizedDescription)).")
                }
                let target = file.deletingPathExtension().appendingPathExtension("mlmodelc")
                try? fm.removeItem(at: target)
                try fm.moveItem(at: compiled, to: target)
                try fm.removeItem(at: file)
                file = target
            }
            var realistic = (voice["realistic"] as? [String: Any]) ?? [:]
            let encoderName = (realistic["encoder"] as? String) ?? "contentvec_ahead.mlmodelc"
            let ownEncoder = folder.appendingPathComponent(encoderName)
            let encoder = fm.fileExists(atPath: ownEncoder.path) ? ownEncoder : VoiceLibrary.sharedEncoder(named: encoderName)
            let rate = try Self.check(model: file, encoder: encoder, name: name)
            realistic["model"] = file.lastPathComponent
            realistic["encoder"] = encoderName
            realistic["rate"] = rate
            if realistic["eqAmount"] == nil { realistic["eqAmount"] = 0.5 }
            voice["realistic"] = realistic
        } else {
            voice["realistic"] = nil
        }
        if voice["credits"] == nil { voice["credits"] = "Added from \(source.lastPathComponent)." }
        let data = try JSONSerialization.data(withJSONObject: voice, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard (try? JSONDecoder().decode(VoiceManifest.self, from: data)) != nil else {
            throw Problem(message: "The voice.json in “\(name)” has settings Swoopy can't read.")
        }
        try data.write(to: folder.appendingPathComponent("voice.json"))
        try fm.moveItem(at: folder, to: voices.appendingPathComponent(id))
        return id
    }

    // Checks that the AI voice fits Swoopy's player and speech reader; returns its sample rate.
    static func check(model: URL, encoder: URL?, name: String) throws -> Int {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        guard let loaded = try? MLModel(contentsOf: model, configuration: config) else {
            throw Problem(message: "“\(name)”'s AI voice can't be opened.")
        }
        let inputs = loaded.modelDescription.inputDescriptionsByName
        let convert = "Turn the original .pth voice into a Swoopy voice with the converter (README, “Your own voices”)."
        guard let features = inputs["features"]?.multiArrayConstraint?.shape.map(\.intValue), features.count == 3,
              let pitch = inputs["pitch"]?.multiArrayConstraint?.shape.map(\.intValue), pitch.count == 2,
              inputs["source"] != nil, inputs["noise"] != nil, loaded.modelDescription.outputDescriptionsByName["audio"] != nil else {
            throw Problem(message: "“\(name)”'s AI voice isn't one Swoopy can play. \(convert)")
        }
        if features[2] == 256 {
            throw Problem(message: "“\(name)” is an RVC v1 voice; Swoopy needs RVC v2 voices. Look for a v2 version of it.")
        }
        guard features[2] == 768 else { throw Problem(message: "“\(name)”'s AI voice isn't one Swoopy can play. \(convert)") }
        let meta = loaded.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        let rate = Int(meta["rate"] ?? "") ?? 0
        guard [32000, 40000, 48000].contains(rate) else {
            throw Problem(message: rate == 0 ? "“\(name)”'s AI voice isn't one Swoopy can play. \(convert)"
                                             : "“\(name)” was made at \(rate) Hz; Swoopy can play voices made at 32, 40 or 48 kHz.")
        }
        // The speech reader's window may be longer than the voice's (by an even number of frames), as VoiceModel.mm
        // allows: the 3.1 reader (look-ahead shape) also reads for voices made in the first shape.
        if let encoder, let frames = encoderFrames(encoder), frames < pitch[1] || (frames - pitch[1]) % 2 != 0 {
            throw Problem(message: "“\(name)” was made for a different version of Swoopy. Turn the original .pth voice into a Swoopy voice again with the converter (README, “Your own voices”).")
        }
        return rate
    }

    // The speech reader's window in 10 ms frames ("audio" is [1, frames * 160]), from its model.mil (no loading).
    static func encoderFrames(_ encoder: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: encoder.appendingPathComponent("model.mil")) else { return nil }
        defer { try? handle.close() }
        guard let head = (try? handle.read(upToCount: 4000)).flatMap({ String(data: $0, encoding: .utf8) }),
              let range = head.range(of: #"tensor<fp\d+, \[1, (\d+)\]> audio"#, options: .regularExpression) else { return nil }
        let digits = head[range].split(separator: "[")[1].split(separator: "]")[0].split(separator: ",")[1].trimmingCharacters(in: .whitespaces)
        guard let samples = Int(digits), samples % 160 == 0 else { return nil }
        return samples / 160
    }

    static func slug(_ text: String) -> String {
        let lowered = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }.joined()
        let parts = lowered.split(separator: "-").joined(separator: "-")
        return parts.isEmpty ? "voice" : String(parts.prefix(40))
    }

    // MARK: Rename and remove (added voices only)

    static func rename(_ entry: VoiceEntry, to name: String, in voices: URL = VoiceLibrary.userFolder) throws {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !name.isEmpty else { throw Problem(message: "A voice needs a name.") }
        guard !entry.builtIn, entry.isInside(voices) else { throw Problem(message: "\(entry.name) is built in and can't be renamed.") }
        guard let data = try? Data(contentsOf: entry.file),
              var voice = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Problem(message: "\(entry.name)'s voice.json can't be read.")
        }
        voice["name"] = name
        try JSONSerialization.data(withJSONObject: voice, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: entry.file, options: .atomic)
    }

    // Moves an added voice's folder (or its json file, for a json file lying in the Voices folder) to the Trash.
    static func remove(_ entry: VoiceEntry, in voices: URL = VoiceLibrary.userFolder) throws {
        guard !entry.builtIn, entry.isInside(voices) else { throw Problem(message: "\(entry.name) is built in and can't be removed.") }
        let parent = entry.file.deletingLastPathComponent().standardizedFileURL
        let inOwnFolder = entry.file.lastPathComponent == "voice.json" && parent.path != voices.standardizedFileURL.path
        try FileManager.default.trashItem(at: inOwnFolder ? parent : entry.file, resultingItemURL: nil)
    }
}
