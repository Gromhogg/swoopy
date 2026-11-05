// The voice changer's voices. Built in: Contents/Resources/Voices/*.json (woman.json, man.json). Added by the user:
// ~/Library/Application Support/Pitch Shift/Voices/<id>/voice.json. The command line's --voices-dir DIR is read last,
// so a voice there replaces a built-in one with the same id (for tuning). Each file:
//   {id, name, version, natural{targetHz, assumedInputHz, intonation, formant, breathDb, presenceDb, sibilanceKeep,
//    eqAmount, ltas[21]}, realistic{model, encoder, rate, eqAmount}, credits}
// A voice with only a "natural" block works on every Mac. Bad files are skipped and listed in `problems`. An added
// voice with no speech reader (encoder) of its own uses the built-in one (contentvec_ahead.mlmodelc since 3.1; see
// sharedEncoder). Adding, renaming and removing voices: VoiceImport.swift.
import Foundation

struct VoiceManifest: Decodable, Equatable {
    struct Natural: Decodable, Equatable {
        var targetHz: Float
        var assumedInputHz: Float
        var intonation: Float
        var formant: Float
        var breathDb: Float
        var presenceDb: Float
        var sibilanceKeep: Float
        var eqAmount: Float
        var ltas: [Float]
    }
    struct Realistic: Decodable, Equatable {
        var model: String    // the voice's .mlmodelc, next to the json file
        var encoder: String  // the shared encoder's .mlmodelc
        var rate: Double     // the model's sample rate
        var eqAmount: Float
        var quiet: String?   // 3.5: used instead of `model` while "Block background sounds" is on
    }
    var id: String
    var name: String
    var version: Int
    var natural: Natural?
    var realistic: Realistic?
    var credits: String?
}

// One voice. `natural` is what the sound thread reads; it is made once and never freed (it lives as long as the app),
// so a running chain can keep reading it while the list is scanned again.
final class VoiceEntry {
    let manifest: VoiceManifest
    let folder: URL      // where its files are
    let file: URL        // its json file
    let builtIn: Bool
    let natural: UnsafePointer<VoiceChangerVoice>?

    var id: String { manifest.id }
    var name: String { manifest.name }
    var modelURL: URL? { manifest.realistic.map { folder.appendingPathComponent($0.model) } }
    var quietURL: URL? { manifest.realistic?.quiet.map { folder.appendingPathComponent($0) } }
    func modelURL(quiet: Bool) -> URL? { quiet ? quietURL ?? modelURL : modelURL }
    // Another file gets another name, so turning "Block background sounds" loads it the way a voice change does.
    func modelKey(quiet: Bool) -> String { quiet && quietURL != nil ? id + "+quiet" : id }
    // The voice's own speech reader, or (for an added voice that has none) the built-in one (VoiceLibrary.sharedEncoder).
    var encoderURL: URL? {
        guard let realistic = manifest.realistic else { return nil }
        let own = folder.appendingPathComponent(realistic.encoder)
        guard !builtIn, !FileManager.default.fileExists(atPath: own.path) else { return own }
        return VoiceLibrary.sharedEncoder(named: realistic.encoder) ?? own
    }
    // Added by the user in the Voices folder (so it can be renamed and removed; built-in and --voices-dir ones can't).
    var isUserVoice: Bool { !builtIn && isInside(VoiceLibrary.userFolder) }

    func isInside(_ voices: URL) -> Bool {
        let dir = file.deletingLastPathComponent().standardizedFileURL.path, root = voices.standardizedFileURL.path
        return dir == root || dir.hasPrefix(root + "/")
    }

    init(manifest: VoiceManifest, folder: URL, file: URL, builtIn: Bool) {
        self.manifest = manifest
        self.folder = folder
        self.file = file
        self.builtIn = builtIn
        natural = manifest.natural.map { n in
            var voice = VoiceChangerVoice()
            voice.targetHz = n.targetHz
            voice.assumedInputHz = n.assumedInputHz
            voice.intonation = n.intonation
            voice.formant = n.formant
            voice.breathDb = n.breathDb
            voice.presenceDb = n.presenceDb
            voice.sibilanceKeep = n.sibilanceKeep
            voice.eqAmount = n.eqAmount
            withUnsafeMutableBytes(of: &voice.ltas) { raw in
                let bands = raw.bindMemory(to: Float.self)
                for k in 0..<min(bands.count, n.ltas.count) { bands[k] = n.ltas[k] }
            }
            let stored = UnsafeMutablePointer<VoiceChangerVoice>.allocate(capacity: 1)
            stored.initialize(to: voice)
            return UnsafePointer(stored)
        }
    }
}

final class VoiceLibrary {
    static let shared = VoiceLibrary()
    static var extraFolder: URL?  // --voices-dir DIR

    private(set) var voices: [VoiceEntry] = []
    private(set) var problems: [String] = []  // "file: why it was skipped"
    private var made: [String: VoiceEntry] = [:]  // every entry ever made, by path, so pointers stay valid

    static var builtInFolder: URL? { Bundle.main.resourceURL?.appendingPathComponent("Voices") }
    // The built-in speech reader for an added voice that has none of its own: the one it names if the app has it, else
    // the look-ahead one (3.1 and later; it also reads for voices made in the first shape), else contentvec.mlmodelc.
    static func sharedEncoder(named name: String) -> URL? {
        guard let shared = builtInFolder else { return nil }
        let fm = FileManager.default
        let candidates = [(name as NSString).lastPathComponent, "contentvec_ahead.mlmodelc", "contentvec.mlmodelc"]
        return candidates.map { shared.appendingPathComponent($0) }.first { fm.fileExists(atPath: $0.path) }
            ?? shared.appendingPathComponent("contentvec_ahead.mlmodelc")
    }
    static var userFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pitch Shift/Voices")
    }

    private init() { rescan() }

    // Reads all voice folders again (cheap; the window does it when its voice menu opens).
    func rescan() {
        var found: [VoiceEntry] = []
        problems = []
        let folders: [(URL?, Bool)] = [(Self.builtInFolder, true), (Self.userFolder, false), (Self.extraFolder, false)]
        for case let (folder?, builtIn) in folders {
            for file in Self.manifestFiles(in: folder) {
                guard let entry = load(file, builtIn: builtIn) else { continue }
                found.removeAll { $0.id == entry.id }  // a later folder replaces a voice with the same id
                found.append(entry)
            }
        }
        voices = found
    }

    // By id ("woman") or name ("Woman"), ignoring case.
    func voice(_ idOrName: String) -> VoiceEntry? {
        let key = idOrName.lowercased()
        return voices.first { $0.id.lowercased() == key } ?? voices.first { $0.name.lowercased() == key }
    }

    // DIR/*.json and DIR/<folder>/voice.json, in name order.
    private static func manifestFiles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var files: [URL] = []
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where !item.lastPathComponent.hasPrefix(".") {
            if item.pathExtension == "json" {
                files.append(item)
            } else if fm.fileExists(atPath: item.appendingPathComponent("voice.json").path) {
                files.append(item.appendingPathComponent("voice.json"))
            }
        }
        return files
    }

    private func load(_ file: URL, builtIn: Bool) -> VoiceEntry? {
        do {
            let manifest = try JSONDecoder().decode(VoiceManifest.self, from: Data(contentsOf: file))
            guard !manifest.id.isEmpty, !manifest.name.isEmpty else { throw Problem(message: "no id or name") }
            guard manifest.natural != nil || manifest.realistic != nil else { throw Problem(message: "no natural or realistic block") }
            if let n = manifest.natural {
                guard n.ltas.count == Int(VOICECHANGER_LTAS_BANDS) else { throw Problem(message: "ltas needs \(VOICECHANGER_LTAS_BANDS) values") }
                let values = [n.targetHz, n.assumedInputHz, n.intonation, n.formant, n.breathDb, n.presenceDb, n.sibilanceKeep, n.eqAmount] + n.ltas
                guard values.allSatisfy(\.isFinite), n.targetHz > 0, n.assumedInputHz > 0, n.formant > 0 else {
                    throw Problem(message: "bad natural values")
                }
            }
            if let old = made[file.path], old.manifest == manifest, old.builtIn == builtIn { return old }
            let entry = VoiceEntry(manifest: manifest, folder: file.deletingLastPathComponent(), file: file, builtIn: builtIn)
            made[file.path] = entry
            return entry
        } catch {
            problems.append("\(file.path): \((error as? Problem)?.message ?? "\(error)")")
            return nil
        }
    }
}
