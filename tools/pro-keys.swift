// Swoopy Pro keys, for the owner: the program behind tools/pro-keys.sh (see there for how to use it).
// Runs with the Swift that comes with the Mac's Command Line Tools; nothing else to install.
//
// Signed keys (since 2026-10-19): 115 characters from 23456789ABCDEFGHJKMNPQRSTUVWXYZ (no 0, 1, I, L or O), shown in
// groups of 5: "P2" (which kind of key), a 5-character serial number, 104 characters holding an Ed25519 signature of
// "PSPRO3:P2" + serial made with the owner's private signing key, and a 4-character typo check (SHA-256 of
// "PSPRO1:" + the first 111 characters). The app holds only the public half, which can check keys but not make them.
// Must match Sources/Pro.swift (ProKey); tools/pro-keys-test.txt has fixed examples both check.
//
// Older keys (sent out before signed keys): 25 characters, a serial and an HMAC of it with secret.txt. The app no
// longer holds that secret: it accepts an older key only if its fingerprint (SHA-256 of "PSPRO-OLD:" + the key) is
// on the list build.sh makes from issued.txt (tools/pro-config.sh).
import CryptoKit
import Foundation

let alphabet = Array("23456789ABCDEFGHJKMNPQRSTUVWXYZ")
let marker = "P2"
let oldLength = 25, signedLength = 115, serialLength = 5, signatureLength = 104

let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PITCH_SHIFT_KEYS_DIR"]
    ?? NSHomeDirectory() + "/Library/Application Support/Pitch Shift Keys")
let privateFile = folder.appendingPathComponent("signing-private.txt")
let publicFile = folder.appendingPathComponent("signing-public.txt")
let issuedFile = folder.appendingPathComponent("issued.txt")
let oldSecretFile = folder.appendingPathComponent("secret.txt")

func say(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
func stop(_ text: String) -> Never { say(text); exit(1) }

// What was typed or pasted, in capitals, with spaces, dashes, line breaks and anything else that isn't a letter or
// digit gone.
func raw(_ text: String) -> String { String(text.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }) }

func groups(_ raw: String) -> [String] {
    var out: [String] = [], rest = Substring(raw)
    while !rest.isEmpty { out.append(String(rest.prefix(5))); rest = rest.dropFirst(5) }
    return out
}
// "ABCDE-FGHJK-…" on one line (issued.txt), or 6 groups per line (to paste into an email).
func grouped(_ raw: String) -> String { groups(raw).joined(separator: "-") }
func inLines(_ raw: String) -> String {
    let all = groups(raw)
    return stride(from: 0, to: all.count, by: 6).map { all[$0..<min($0 + 6, all.count)].joined(separator: "-") }.joined(separator: "\n")
}

// The 4-character typo check: the first 4 bytes of SHA-256("PSPRO1:" + body), below 31^4, in 4 characters.
func checkPart(_ body: String) -> String {
    let hash = Array(SHA256.hash(data: Data(("PSPRO1:" + body).utf8)))
    var number = (UInt32(hash[0]) << 24 | UInt32(hash[1]) << 16 | UInt32(hash[2]) << 8 | UInt32(hash[3])) % 923_521
    var out = ""
    for _ in 0..<4 { out = String(alphabet[Int(number % 31)]) + out; number /= 31 }
    return out
}

// Bytes (one big number, most significant first) as `digits` characters, and back.
func encode(_ bytes: [UInt8], digits: Int) -> String {
    var number = bytes, out: [Character] = []
    for _ in 0..<digits {
        var remainder = 0, next: [UInt8] = []
        for byte in number {
            let value = remainder * 256 + Int(byte)
            if !next.isEmpty || value / 31 != 0 { next.append(UInt8(value / 31)) }
            remainder = value % 31
        }
        out.append(alphabet[remainder])
        number = next
    }
    precondition(number.isEmpty, "number too big for \(digits) characters")
    return String(out.reversed())
}
func decode(_ text: Substring, count: Int) -> [UInt8]? {
    var number = [UInt8](repeating: 0, count: count)
    for character in text {
        guard var carry = alphabet.firstIndex(of: character) else { return nil }
        for i in stride(from: count - 1, through: 0, by: -1) {
            let value = Int(number[i]) * 31 + carry
            number[i] = UInt8(value & 0xFF)
            carry = value >> 8
        }
        if carry != 0 { return nil }  // more than `count` bytes can hold
    }
    return number
}

func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
func unhex(_ text: String) -> Data? {
    let text = text.filter { !$0.isWhitespace }
    guard text.count % 2 == 0 else { return nil }
    var data = Data(), index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
        data.append(byte)
        index = next
    }
    return data
}

// A random serial number: 5 characters from the alphabet, each equally likely.
func randomSerial() -> String { String((0..<serialLength).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] }) }

func signedMessage(_ serial: String) -> Data { Data(("PSPRO3:" + marker + serial).utf8) }

// A signed key (as raw characters) for a serial.
func signedKey(serial: String, signer: Curve25519.Signing.PrivateKey) -> String {
    let signature = try! signer.signature(for: signedMessage(serial))
    let body = marker + serial + encode(Array(signature), digits: signatureLength)
    return body + checkPart(body)
}

// The older keys' secret part (still needed to check an older key, not to make new ones).
func oldSecretPart(serial: String, secret: String) -> String {
    let code = Array(HMAC<SHA256>.authenticationCode(for: Data(("PSPRO2:" + serial).utf8), using: SymmetricKey(data: Data(secret.utf8))))
    return String((0..<16).map { alphabet[Int((UInt16(code[2 * $0]) << 8 | UInt16(code[2 * $0 + 1])) % 31)] })
}
func oldKey(serial: String, secret: String) -> String {
    let body = serial + oldSecretPart(serial: serial, secret: secret)
    return body + checkPart(body)
}

enum Kind { case old, signed }
// The kind of key as typed, or nil if it has a typo (or isn't a whole key).
func kind(_ raw: String) -> Kind? {
    guard raw.allSatisfy(alphabet.contains), raw.count == oldLength || (raw.count == signedLength && raw.hasPrefix(marker)),
          checkPart(String(raw.dropLast(4))) == String(raw.suffix(4)) else { return nil }
    return raw.count == oldLength ? .old : .signed
}
func signedWorks(_ raw: String, publicKey: Curve25519.Signing.PublicKey) -> Bool {
    guard kind(raw) == .signed else { return false }
    let serial = String(raw.dropFirst(marker.count).prefix(serialLength))
    guard let signature = decode(raw.dropFirst(marker.count + serialLength).prefix(signatureLength), count: 64) else { return false }
    return publicKey.isValidSignature(Data(signature), for: signedMessage(serial))
}
func oldWorks(_ raw: String, secret: String) -> Bool {
    kind(raw) == .old && String(raw.dropFirst(serialLength).prefix(16)) == oldSecretPart(serial: String(raw.prefix(serialLength)), secret: secret)
}
// The serial number of a key as written in issued.txt.
func serialOf(_ raw: String) -> String? {
    if raw.count == oldLength { return String(raw.prefix(serialLength)) }
    if raw.count == signedLength { return String(raw.dropFirst(marker.count).prefix(serialLength)) }
    return nil
}

func readText(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
func loadPrivate() -> Curve25519.Signing.PrivateKey? {
    readText(privateFile).flatMap(unhex).flatMap { try? Curve25519.Signing.PrivateKey(rawRepresentation: $0) }
}
func loadPublic() -> Curve25519.Signing.PublicKey? {
    readText(publicFile).flatMap(unhex).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) } ?? loadPrivate()?.publicKey
}
// Each line of issued.txt ("date  name  key"): the line and the key in it (its last word).
func issued() -> [(line: String, raw: String)] {
    (readText(issuedFile) ?? "").split(whereSeparator: \.isNewline).compactMap { line in
        line.split(separator: " ").last.map { (String(line), raw(String($0))) }
    }
}

// Writes a file only this Mac user can read.
func writePrivate(_ text: String, to url: URL, append: Bool = false) {
    let manager = FileManager.default
    if append, let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
    } else {
        guard manager.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            stop("Couldn't write \(url.path)")
        }
    }
    try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first ?? "" {
case "setup":
    // Makes the key pair once. Never replaces one that's there: keys already sent out would stop working.
    let manager = FileManager.default
    let havePrivate = manager.fileExists(atPath: privateFile.path), havePublic = manager.fileExists(atPath: publicFile.path)
    if havePrivate || havePublic {
        if havePrivate && !havePublic, let key = loadPrivate() {
            writePrivate(hex(key.publicKey.rawRepresentation) + "\n", to: publicFile)
            print("The key pair is in \(folder.path) (signing-public.txt was missing and was made again from the private half).")
        } else if !havePrivate {
            stop("signing-public.txt is in \(folder.path) but signing-private.txt is missing. Copy it back from your backup of the Pitch Shift Keys folder (a new pair would make every signed key already sent out stop working).")
        } else if loadPrivate() == nil {
            stop("signing-private.txt in \(folder.path) can't be read. Copy it back from your backup; nothing was changed.")
        } else {
            print("The key pair is already in \(folder.path); nothing was changed.")
        }
        exit(0)
    }
    try? manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    let key = Curve25519.Signing.PrivateKey()
    writePrivate(hex(key.rawRepresentation) + "\n", to: privateFile)
    writePrivate(hex(key.publicKey.rawRepresentation) + "\n", to: publicFile)
    print("Made a key pair in \(folder.path): signing-private.txt (makes keys: never share it, never put it in git) and signing-public.txt (goes into the app).")
    print("Back up the whole Pitch Shift Keys folder now (for example on a USB stick): without signing-private.txt no more keys can be made for this app.")

case "new":
    let name = arguments.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { stop("Use: tools/pro-keys.sh new \"their name or email\"") }
    guard let signer = loadPrivate() else {
        stop("No key pair in \(folder.path) yet. Run tools/pro-keys.sh setup first (or copy your backup of the Pitch Shift Keys folder back).")
    }
    let taken = Set(issued().compactMap { serialOf($0.raw) })
    var serial = randomSerial()
    while taken.contains(serial) { serial = randomSerial() }  // never the same serial twice
    let key = signedKey(serial: serial, signer: signer)
    guard signedWorks(key, publicKey: signer.publicKey) else { stop("The new key didn't check out; nothing was saved.") }
    let date = { () -> String in let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f.string(from: Date()) }()
    writePrivate("\(date)  \(name.replacingOccurrences(of: "\n", with: " "))  \(grouped(key))\n", to: issuedFile,
                 append: FileManager.default.fileExists(atPath: issuedFile.path))
    print(inLines(key))
    say("Added to \(issuedFile.path). Paste the whole key (all \(inLines(key).split(separator: "\n").count) lines) into your email.")

case "list":
    let text = readText(issuedFile) ?? ""
    print(text.isEmpty ? "No keys made yet." : text, terminator: text.isEmpty ? "\n" : "")

case "check":
    let typed = raw(arguments.dropFirst().joined(separator: " "))
    guard !typed.isEmpty else { stop("Use: tools/pro-keys.sh check KEY (spaces, dashes and line breaks are fine)") }
    let listed = issued().first { $0.raw == typed }.map { " Made: \($0.line)" } ?? ""
    switch kind(typed) {
    case nil:
        print("That key has a typo (or isn't a whole key: signed keys are \(signedLength) characters, older ones \(oldLength)).")
        exit(1)
    case .signed:
        guard let publicKey = loadPublic() else { stop("No key pair in \(folder.path), so no signed key can be checked.") }
        if signedWorks(typed, publicKey: publicKey) {
            print("That key works.\(listed)")
        } else {
            print("That key doesn't work: it wasn't made with this Mac's signing key.")
            exit(1)
        }
    case .old:
        let inList = !listed.isEmpty
        let secret = readText(oldSecretFile)?.filter { !$0.isWhitespace }
        if let secret, !secret.isEmpty, !oldWorks(typed, secret: secret) {
            print("That older key doesn't work: it wasn't made with this Mac's secret.")
            exit(1)
        }
        if inList {
            print("That older key works: it's in issued.txt, so builds made on this Mac accept it.\(listed)")
        } else {
            print("That older key isn't in issued.txt, so the app won't accept it (only older keys listed there still work).")
            exit(1)
        }
    }

case "test":
    // The fixed examples in tools/pro-keys-test.txt: older keys made with the test secret, signed keys made with the
    // test key pair (whose private half is in the file on purpose: it unlocks nothing in a real build).
    let path = arguments.count > 1 ? arguments[1] : URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("pro-keys-test.txt").path
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { stop("Can't read \(path)") }
    var secret = "", publicKey: Curve25519.Signing.PublicKey?, signer: Curve25519.Signing.PrivateKey?
    var good = 0, bad = 0
    func result(_ ok: Bool, _ what: String) { if ok { good += 1 } else { bad += 1; print("different: \(what)") } }
    for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
        let parts = line.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { continue }
        switch parts[0] {
        case "secret": secret = parts[1]
        case "public": publicKey = unhex(parts[1]).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
        case "private": signer = unhex(parts[1]).flatMap { try? Curve25519.Signing.PrivateKey(rawRepresentation: $0) }
        case "old" where parts.count == 3:
            let made = grouped(oldKey(serial: parts[1], secret: secret))
            result(made == parts[2] && oldWorks(raw(parts[2]), secret: secret) && !oldWorks(raw(parts[2]), secret: secret + "x"),
                   "older key \(parts[1]) made \(made), the file says \(parts[2])")
        case "signed" where parts.count == 3:
            guard let publicKey else { result(false, "no public line before \(parts[1])"); continue }
            let key = raw(parts[2]), other = Curve25519.Signing.PrivateKey().publicKey
            result(serialOf(key) == parts[1] && signedWorks(key, publicKey: publicKey) && !signedWorks(key, publicKey: other),
                   "signed key \(parts[1]) doesn't check out with the test public key")
        default: continue
        }
    }
    // A new key from the test pair checks out, and a change anywhere in it is caught.
    if let signer, let publicKey {
        result(signer.publicKey.rawRepresentation == publicKey.rawRepresentation, "the test private and public halves don't belong together")
        let key = signedKey(serial: "TEST3", signer: signer)
        result(signedWorks(key, publicKey: publicKey), "a new test key doesn't check out")
        var changed = 0
        for i in 0..<key.count {
            for c in alphabet where c != Array(key)[i] {
                var chars = Array(key); chars[i] = c
                if signedWorks(String(chars), publicKey: publicKey) { changed += 1 }
            }
        }
        result(changed == 0, "\(changed) one-character changes of a new test key still work")
    }
    print("pro-keys test: \(good) of \(good + bad) checks pass")
    exit(bad == 0 && good > 0 ? 0 : 1)

case "help", "-h", "--help", "":
    print("""
    tools/pro-keys.sh setup                        makes your key pair, once (never replaces one that's there)
    tools/pro-keys.sh new "their name or email"   makes a key, prints it, and adds it to the list
    tools/pro-keys.sh list                         every key made so far (date, name, key)
    tools/pro-keys.sh check KEY                    says whether a key works, and who it was made for
    """)
default:
    stop("Unknown: \(arguments[0]) (try tools/pro-keys.sh help)")
}
