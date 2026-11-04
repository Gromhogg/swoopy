// Pitch Shift Pro: the $5 unlock (plan: notes/paid-unlock-plan.md). People email the owner for a key; the owner makes
// it on their Mac with tools/pro-keys.sh and emails it back. The app checks a key on its own, with no internet: a key
// is signed with the owner's private signing key, and the app holds only the public half, which can check a key but
// can't make one (see ProKey). An accepted key is kept in ~/Library/Application Support/Pitch Shift/Pro.json and
// checked again at every launch. While Pro is locked, the paid settings use the free version's values (Free); what
// was saved is kept and comes back once Pro is unlocked.
import AppKit
import CryptoKit

// What the free version uses in place of the paid settings.
enum Free {
    static let cartoon: Float = 1  // the voice style stays at Cartoon
    static let slowDeeper = false  // Deeper when slow stays off
    static let fastHigher: Float = 0  // and so does Higher when fast
    static let tone: Float = 0     // Bass ↔ Treble stays in the middle
    // Auto EQ and the Voice changer stay off.
}

// The keys, from 31 characters that can't be read two ways (no 0, 1, I, L or O), shown in groups of 5. Typing is
// forgiving: small letters, spaces, dashes and line breaks don't matter. Must match tools/pro-keys.swift exactly
// (tools/pro-keys-test.txt has fixed examples both check).
// - Signed keys (since 2026-10-19): 115 characters. "P2" (the kind of key), a 5-character serial number, 104
//   characters holding an Ed25519 signature of "PSPRO3:P2" + serial made with the owner's private key, and a
//   4-character check part, so a typo is caught right away.
// - Older keys (sent out before): 25 characters, a serial, 16 characters made with a secret the app no longer has,
//   and the same check part. The app accepts one only if its fingerprint (SHA-256 of "PSPRO-OLD:" + the key) is on
//   the list build.sh makes from the owner's issued.txt (ProConfig.oldKeys).
enum ProKey {
    static let alphabet = Array("23456789ABCDEFGHJKMNPQRSTUVWXYZ")
    static let length = 25  // an older key
    static let marker = "P2", serialLength = 5, signatureLength = 104, checkLength = 4
    static let signedLength = marker.count + serialLength + signatureLength + checkLength  // 115
    static let groupsPerLine = 6  // how a signed key is shown: 6 groups of 5 per line, 4 lines

    enum Problem: Error, Equatable { case length, characters, check }
    enum Kind { case old, signed }

    // What was typed or pasted, in capitals, with spaces, dashes, line breaks and anything else that isn't a letter or
    // digit gone.
    static func raw(_ text: String) -> String {
        String(text.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    private static func groups(_ raw: String) -> [String] {
        var groups: [String] = []
        var rest = Substring(raw)
        while !rest.isEmpty {
            groups.append(String(rest.prefix(5)))
            rest = rest.dropFirst(5)
        }
        return groups
    }

    // "ABCDEFGHJK…" → "ABCDE-FGHJK-…" (one line: how a key is kept).
    static func grouped(_ raw: String) -> String { groups(raw).joined(separator: "-") }

    // For the key box: 6 groups per line (an older key fits on the first line).
    static func shown(_ raw: String) -> String {
        let all = groups(raw)
        return stride(from: 0, to: all.count, by: groupsPerLine)
            .map { all[$0..<min($0 + groupsPerLine, all.count)].joined(separator: "-") }.joined(separator: "\n")
    }

    // The check part: the first 4 bytes of SHA-256("PSPRO1:" + everything before it), as a number below 31^4, in
    // 4 characters.
    static func checkPart(_ body: String) -> String {
        let hash = Array(SHA256.hash(data: Data(("PSPRO1:" + body).utf8)))
        var number = (UInt32(hash[0]) << 24 | UInt32(hash[1]) << 16 | UInt32(hash[2]) << 8 | UInt32(hash[3])) % 923_521
        var out = ""
        for _ in 0..<4 {
            out = String(alphabet[Int(number % 31)]) + out
            number /= 31
        }
        return out
    }

    // The key in its usual form, or what's wrong with how it was typed (only the typo check: no key data needed).
    static func read(_ text: String) -> Result<String, Problem> {
        let raw = raw(text)
        guard raw.count == length || raw.count == signedLength else { return .failure(.length) }
        guard raw.allSatisfy(alphabet.contains) else { return .failure(.characters) }
        guard raw.count == length || raw.hasPrefix(marker),
              checkPart(String(raw.dropLast(checkLength))) == String(raw.suffix(checkLength)) else { return .failure(.check) }
        return .success(grouped(raw))
    }

    static func kind(_ text: String) -> Kind? {
        guard case .success(let key) = read(text) else { return nil }
        return raw(key).count == length ? .old : .signed
    }

    // What a signed key's signature covers.
    static func signedMessage(serial: String) -> Data { Data(("PSPRO3:" + marker + serial).utf8) }

    // A signed key's serial number and signature (64 bytes), or nil if it isn't one.
    static func signedParts(_ text: String) -> (serial: String, signature: Data)? {
        guard kind(text) == .signed else { return nil }
        let raw = raw(text)
        let serial = String(raw.dropFirst(marker.count).prefix(serialLength))
        guard let signature = decode(raw.dropFirst(marker.count + serialLength).prefix(signatureLength), count: 64) else { return nil }
        return (serial, Data(signature))
    }

    // An older key's fingerprint, as on the list build.sh makes (tools/pro-config.sh).
    static func oldFingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(("PSPRO-OLD:" + raw(text)).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // Characters (one big number, most significant first) back into `count` bytes; nil if it doesn't fit.
    static func decode(_ text: Substring, count: Int) -> [UInt8]? {
        var number = [UInt8](repeating: 0, count: count)
        for character in text {
            guard var carry = alphabet.firstIndex(of: character) else { return nil }
            for i in stride(from: count - 1, through: 0, by: -1) {
                let value = Int(number[i]) * 31 + carry
                number[i] = UInt8(value & 0xFF)
                carry = value >> 8
            }
            if carry != 0 { return nil }
        }
        return number
    }

    static func unhex(_ text: String) -> Data? {
        let text = text.filter { !$0.isWhitespace }
        guard text.count % 2 == 0 else { return nil }
        var data = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}

// What keys are checked with: the public half of the owner's signing key pair, and the older keys' fingerprints.
struct ProKeyCheck {
    let publicKey: Curve25519.Signing.PublicKey?
    let oldKeys: Set<String>

    init(publicKey hex: String, oldKeys: [String]) {
        publicKey = ProKey.unhex(hex).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
        self.oldKeys = Set(oldKeys.map { $0.lowercased() })
    }

    // Does this key unlock Pro? (A signed key made with the owner's private key, or an older key on the list.)
    func works(_ text: String) -> Bool {
        switch ProKey.kind(text) {
        case .signed:
            guard let publicKey, let parts = ProKey.signedParts(text) else { return false }
            return publicKey.isValidSignature(parts.signature, for: ProKey.signedMessage(serial: parts.serial))
        case .old: return oldKeys.contains(ProKey.oldFingerprint(text))
        case nil: return false
        }
    }
}

final class Pro {
    static let shared = Pro()

    // The public key keys are checked with, and the older keys that still work (built in by build.sh). No public key:
    // nothing is locked. Checks only: --pro-public-key.
    var publicKey = ProConfig.publicKey
    var oldKeys = ProConfig.oldKeys
    var enabled: Bool { pretending != nil || !publicKey.isEmpty }
    private var check: ProKeyCheck { ProKeyCheck(publicKey: publicKey, oldKeys: oldKeys) }

    // Pro is unlocked: everything works. (Always true in a build without the public key.)
    var unlocked: Bool { pretending ?? (publicKey.isEmpty || verified) }
    private(set) var key: String?  // the saved key
    private var verified = false
    private var pretending: Bool?  // pictures (--preview) show a state and touch no file
    var onChange: () -> Void = {}

    // Checks only: --pro-file F.
    var file: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pitch Shift/Pro.json")

    // What Pro adds, for the unlock window.
    static let features = ["the Voice changer", "Natural ↔ Cartoon", "Bass ↔ Treble", "Auto EQ", "Deeper when slow",
                           "the Soundboard"]

    // Pictures only: a key made with the test key pair in tools/pro-keys-test.txt (it unlocks nothing).
    static let exampleKey = "P23WN-RJ3JB-23GWE-NTH5S-KX5XB-4TQEQ-6XS6N-AWQEY-3ZSWK-D864K-5FQ8N-4H3PJ-7UJJ2-FNNN5-RB7BG-"
        + "MTDQ4-59W6A-SJ8M8-XQW3R-ENYZP-Z9ZKK-TU4AA-3GHXX"

    private struct Saved: Codable {
        var key: String
        var unlocked: String?  // when (for people, not checked)
    }

    // For pictures: shows Pro locked or unlocked without reading or writing anything.
    func pretend(unlocked: Bool) {
        pretending = unlocked
        key = unlocked ? Self.exampleKey : nil
    }

    // At launch: reads the saved key and checks it (no internet).
    func load() {
        guard pretending == nil, !publicKey.isEmpty else { return }
        key = read()?.key
        verified = key.map(check.works) ?? false
    }

    // Locks Pro again and forgets the key (--pro-reset).
    func reset() {
        try? FileManager.default.removeItem(at: file)
        key = nil
        verified = false
        onChange()
    }

    // MARK: The saved file

    private func read() -> Saved? {
        guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data),
              case .success(let key) = ProKey.read(saved.key) else { return nil }
        return Saved(key: key, unlocked: saved.unlocked)
    }

    private func write(_ saved: Saved) {
        let folder = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(saved) else { return }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    // MARK: Checking a key

    enum Outcome: Equatable {
        case unlocked
        case problem(String)
    }

    static func message(for problem: ProKey.Problem) -> String {
        switch problem {
        case .characters: return "That key has a typo: keys never use 0, 1, I, L or O."
        case .length: return "That isn't a whole key. Paste all of it, as it is in the email."
        case .check: return "That key has a typo. Check it and try again."
        }
    }

    static let wrongKey = "That key doesn't work. Check it and try again."

    // Does this key unlock Pro in this copy? (--pro-check)
    func works(_ typed: String) -> Bool { check.works(typed) }

    // Checks a typed key (typos first, then whether it's a key the owner made), then keeps it.
    func activate(_ typed: String) -> Outcome {
        guard !publicKey.isEmpty else { return .problem("Unlocking isn't set up in this copy of Pitch Shift.") }
        let key: String
        switch ProKey.read(typed) {
        case .success(let good): key = good
        case .failure(let problem): return .problem(Self.message(for: problem))
        }
        guard check.works(key) else { return .problem(Self.wrongKey) }
        write(Saved(key: key, unlocked: ISO8601DateFormatter().string(from: Date())))
        self.key = key
        let was = unlocked
        verified = true
        if !was { onChange() }
        return .unlocked
    }

    // For --pro-status.
    var status: String {
        guard !publicKey.isEmpty else { return "Pro: not set up in this build (nothing is locked)" }
        guard let key else { return "Pro: locked (no key saved in \(file.path))" }
        let ending = (ProKey.kind(key) == .old ? "older key …-" : "key …-") + key.suffix(5)
        return verified ? "Pro: unlocked (\(ending))" : "Pro: locked (\(ending) saved, but it doesn't work in this copy)"
    }
}

// The unlock window: a sheet on the main window. Locked: "Pitch Shift Pro: $5", what it adds, the address to email
// for a key with an "Email for a key" button (opens Mail), a box for the key, and Unlock. Unlocked: a thank-you and
// the end of the key.
final class ProSheet: NSObject, NSTextFieldDelegate {
    static let shared = ProSheet()
    private var panel: NSPanel?
    private let field = NSTextField()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let unlockButton = NSButton(title: "Unlock", target: nil, action: nil)
    private let emailButton = NSButton(title: "Email for a key", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var width: CGFloat = 380  // the sheet's width: 380, or the window's width in a narrow window
    private lazy var fieldWidth = field.widthAnchor.constraint(equalToConstant: 340)
    private lazy var fieldHeight = field.heightAnchor.constraint(equalToConstant: 80)
    var isOpen: Bool { panel != nil }

    // A new email to the owner, with the subject filled in (opens in the Mail app, or whatever app handles email).
    static let mailURL = URL(string: "mailto:\(ProConfig.email)?subject=Pitch%20Shift%20Pro%20key")

    override init() {
        super.init()
        emailButton.bezelStyle = .rounded
        emailButton.bezelColor = Theme.purple
        emailButton.target = self
        emailButton.action = #selector(email)
        emailButton.toolTip = ProConfig.email
        // A box of 4 lines: a key is 115 characters, shown 6 groups of 5 per line. A key pasted from an email with
        // line breaks or spaces in it is cleaned up as it comes in (controlTextDidChange).
        field.placeholderString = "Paste your key here"
        field.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        field.alignment = .center
        field.delegate = self
        field.setAccessibilityLabel("Your key")
        field.cell?.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byCharWrapping
        fieldWidth.isActive = true
        fieldHeight.isActive = true
        message.font = .systemFont(ofSize: 12)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(close)
        unlockButton.bezelStyle = .rounded
        unlockButton.keyEquivalent = "\r"
        unlockButton.bezelColor = Theme.purple
        unlockButton.target = self
        unlockButton.action = #selector(unlock)
    }

    // `alone` (pictures only, the pro-alone state): its own window next to the main one instead of a sheet, for when
    // macOS can't picture a window with a sheet on it (an off-screen window).
    func show(on window: NSWindow, alone: Bool = false) {
        guard panel == nil else { return }
        width = min(380, max(300, window.frame.width.rounded(.down)))
        fieldWidth.constant = width - 40
        // The largest letters (up to 14 pt) that fit a line of 6 groups (35 characters) in the box, and 4 lines.
        let line = String(repeating: "W", count: ProKey.groupsPerLine * 6 - 1)
        var size: CGFloat = 14
        while size > 10, (line as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium)]).width > width - 40 - 14 {
            size -= 0.5
        }
        field.font = .monospacedSystemFont(ofSize: size, weight: .medium)
        // Tall enough for a whole key (4 lines) as the box itself lays it out, with a little room to spare (the
        // locked view empties the box right after).
        field.stringValue = ProKey.shown(String(repeating: "W", count: ProKey.signedLength))
        let needed = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width - 40, height: 10_000)).height ?? 80
        fieldHeight.constant = (needed + 6).rounded(.up)
        message.preferredMaxLayoutWidth = width - 40
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Pitch Shift Pro"
        panel.appearance = window.appearance  // light or dark, like the main window
        let content = Pro.shared.unlocked ? unlockedView() : lockedView()
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        self.panel = panel
        if alone {
            panel.level = window.level
            panel.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: window.frame.minY - 20))
            panel.orderBack(nil)
            return
        }
        window.beginSheet(panel) { [weak self] _ in self?.panel = nil }
        if !Pro.shared.unlocked { panel.makeFirstResponder(field) }
    }

    @objc func close() {
        guard let panel else { return }
        panel.sheetParent?.endSheet(panel)
    }

    // The icon, a title and a line under it.
    private func header(_ heading: String, _ line: String) -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 48), icon.heightAnchor.constraint(equalToConstant: 48)])
        let title = NSTextField(labelWithString: heading)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let about = NSTextField(wrappingLabelWithString: line)
        about.font = .systemFont(ofSize: 12)
        about.textColor = .secondaryLabelColor
        about.preferredMaxLayoutWidth = width - 40 - 60
        let words = NSStackView(views: [title, about])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 3
        let row = NSStackView(views: [icon, words])
        row.alignment = .top
        row.spacing = 12
        return row
    }

    private func stack(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 18, right: 20)
        NSLayoutConstraint.activate([stack.widthAnchor.constraint(equalToConstant: width)])
        return stack
    }

    private func buttonRow(_ buttons: [NSButton]) -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [spacer] + buttons)
        row.spacing = 10
        NSLayoutConstraint.activate([row.widthAnchor.constraint(equalToConstant: width - 40)])
        return row
    }

    private func lockedView() -> NSView {
        let list = Pro.features.dropLast().joined(separator: ", ") + " and " + (Pro.features.last ?? "")
        let line = "\(list.prefix(1).uppercased() + list.dropFirst()). Email \(ProConfig.email) for a key."
        field.stringValue = ""
        field.isEnabled = true
        show("", color: .secondaryLabelColor)
        cancelButton.isEnabled = true
        unlockButton.isEnabled = false
        return stack([header("Pitch Shift Pro: \(ProConfig.price)", line), emailButton, field, message,
                      buttonRow([cancelButton, unlockButton])])
    }

    private func unlockedView() -> NSView {
        let key = Pro.shared.key.map { NSTextField(labelWithString: "Key …-\($0.suffix(5))") }
        key?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        key?.textColor = .secondaryLabelColor
        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        return stack([header("Pitch Shift Pro", "Unlocked on this Mac. Thank you!")] + (key.map { [$0] } ?? []) + [buttonRow([done])])
    }

    private func show(_ text: String, color: NSColor) {
        message.stringValue = text
        message.textColor = color
        message.isHidden = text.isEmpty
    }

    // Typing or pasting: capitals, spaces and line breaks taken out, dashes and lines put in, at most 115 characters;
    // a whole key is checked for typos right away. At 25 characters it may be an older key (Unlock works if it has no
    // typo) or the start of a signed key ("P2…": no typo shown yet).
    func controlTextDidChange(_ obj: Notification) {
        let raw = String(ProKey.raw(field.stringValue).prefix(ProKey.signedLength))
        let shown = ProKey.shown(raw)
        if field.stringValue != shown { field.stringValue = shown }
        var typo: ProKey.Problem?
        var whole = false
        if raw.count == ProKey.signedLength || raw.count == ProKey.length {
            switch ProKey.read(raw) {
            case .success: whole = true
            case .failure(let problem): if raw.count == ProKey.signedLength || !raw.hasPrefix(ProKey.marker) { typo = problem }
            }
        }
        unlockButton.isEnabled = whole
        show(typo.map(Pro.message) ?? "", color: typo == nil ? .secondaryLabelColor : .systemRed)
    }

    @objc private func email() {
        guard let url = Self.mailURL, preview == nil else { return }  // pictures open nothing
        NSWorkspace.shared.open(url)
    }

    @objc private func unlock() {
        guard preview == nil else { return }
        switch Pro.shared.activate(field.stringValue) {
        case .unlocked:
            showDone()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.close() }
        case .problem(let text):
            show(text, color: .systemRed)
            panel?.makeFirstResponder(field)
        }
    }

    private func showDone() {
        show("Unlocked. Thank you!", color: .systemGreen)
        unlockButton.isEnabled = false
        cancelButton.isEnabled = false
        field.isEnabled = false
    }

    // Pictures: a key with a typo in the box, or the "Unlocked" message.
    func showTypo() {
        let key = Pro.exampleKey
        let last = key.last.flatMap { ProKey.alphabet.firstIndex(of: $0) } ?? 0
        field.stringValue = String(key.dropLast()) + String(ProKey.alphabet[(last + 1) % ProKey.alphabet.count])
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }

    func showUnlockedMessage() {
        field.stringValue = ProKey.shown(ProKey.raw(Pro.exampleKey))
        showDone()
    }

    // Pictures (pro-paste): the example key pasted as an email shows it, broken over lines with spaces at the ends,
    // through the box's own paste (from a private pasteboard, so the Mac's clipboard is left alone).
    func showPasted() {
        guard let panel else { return }
        let lines = ProKey.shown(ProKey.raw(Pro.exampleKey)).split(separator: "\n")
        let pasted = "  " + lines.joined(separator: " \r\n") + "\n"
        let board = NSPasteboard(name: NSPasteboard.Name("PitchShiftPreviewPaste"))
        board.clearContents()
        board.setString(pasted, forType: .string)
        panel.makeFirstResponder(field)
        if let editor = field.currentEditor() as? NSTextView {
            editor.readSelection(from: board, type: .string)
        }
        board.releaseGlobally()
    }
}
