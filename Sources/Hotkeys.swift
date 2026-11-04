// Hotkeys: keys that work while another app is in front. One each for Input pitch shifter on/off, Voice changer on/off
// and push-to-talk, and one for each sound. Free, except the Voice changer's key and the sounds' keys, which are Pitch
// Shift Pro like what they do. RegisterEventHotKey needs no permission from the Mac,
// and it tells when a key goes up as well as down.
import AppKit
import Carbon.HIToolbox

// One key and the ⌘ ⌃ ⌥ ⇧ held with it. A set key is taken from every app, so plain letters and numbers are refused:
// it needs ⌘ or ⌃, or to be an F-key.
struct HotKey: Equatable {
    let code: UInt32       // the key's place on the keyboard
    let modifiers: UInt32  // Carbon's cmdKey, controlKey, optionKey, shiftKey
    let label: String      // what's printed on the key

    static let rule = "Use ⌘ or ⌃ with a key, or an F-key."

    private static let fKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20"]
    private static let otherKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "Return", kVK_ANSI_KeypadEnter: "Enter", kVK_Tab: "Tab", kVK_Delete: "Delete",
        kVK_ForwardDelete: "⌦", kVK_Escape: "Esc", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑",
        kVK_DownArrow: "↓", kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down"]
    private static let symbols: [(Int, String)] = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]

    init?(code: UInt32, modifiers: UInt32, label: String) {
        let known = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        guard code < 128, modifiers & ~known == 0, !label.isEmpty,
              modifiers & UInt32(cmdKey | controlKey) != 0 || Self.fKeys[Int(code)] != nil else { return nil }
        self.code = code
        self.modifiers = modifiers
        self.label = label
    }

    init?(event: NSEvent) {
        let flags: [(NSEvent.ModifierFlags, Int)] = [(.command, cmdKey), (.control, controlKey), (.option, optionKey), (.shift, shiftKey)]
        let modifiers = flags.filter { event.modifierFlags.contains($0.0) }.reduce(0) { $0 | $1.1 }
        let code = Int(event.keyCode)
        let printed = (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "").uppercased()
        self.init(code: UInt32(code), modifiers: UInt32(modifiers),
                  label: Self.fKeys[code] ?? Self.otherKeys[code] ?? (printed.isEmpty ? "Key \(code)" : printed))
    }

    // A saved key. One that breaks the rules (a settings file changed by hand) is dropped.
    init?(saved: Any?) {
        guard let entry = saved as? [String: Any], let code = (entry["code"] as? NSNumber)?.uint32Value,
              let modifiers = (entry["modifiers"] as? NSNumber)?.uint32Value, let label = entry["label"] as? String else { return nil }
        self.init(code: code, modifiers: modifiers, label: label)
    }

    var saved: [String: Any] { ["code": Int(code), "modifiers": Int(modifiers), "label": label] }

    // "⌃⌥V"
    var name: String { Self.symbols.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + label }
}

// Where keys are taken from the Mac. `onEvent` gets a key's id and true (down) or false (up).
protocol KeySystem: AnyObject {
    var onEvent: (UInt32, Bool) -> Void { get set }
    func add(_ key: HotKey, id: UInt32) -> Bool  // false: another app has it
    func remove(id: UInt32)
}

final class SystemKeys: KeySystem {
    static let signature: OSType = 0x5053_4B59  // 'PSKY'
    var onEvent: (UInt32, Bool) -> Void = { _, _ in }
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?

    // Called on the main thread by the app's event loop.
    private static let received: EventHandlerUPP = { _, event, me in
        guard let event, let me else { return OSStatus(eventNotHandledErr) }
        var id = EventHotKeyID()
        let found = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                      MemoryLayout<EventHotKeyID>.size, nil, &id)
        guard found == noErr, id.signature == SystemKeys.signature else { return OSStatus(eventNotHandledErr) }
        Unmanaged<SystemKeys>.fromOpaque(me).takeUnretainedValue().onEvent(id.id, GetEventKind(event) == UInt32(kEventHotKeyPressed))
        return noErr
    }

    func listen() {
        guard handler == nil else { return }
        let kinds = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), Self.received, kinds.count, kinds, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func add(_ key: HotKey, id: UInt32) -> Bool {
        listen()
        var ref: EventHotKeyRef?
        // Without "exclusive" the Mac gives the key to every app that asks, and never says it's taken.
        let status = RegisterEventHotKey(key.code, key.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        return true
    }

    func remove(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
    }
}

// Pictures and checks: no key is taken from the Mac.
final class PretendKeys: KeySystem {
    var onEvent: (UInt32, Bool) -> Void = { _, _ in }
    var taken: [HotKey] = []  // checks: as if another app has these
    private(set) var held: [UInt32: HotKey] = [:]

    func add(_ key: HotKey, id: UInt32) -> Bool {
        guard !taken.contains(key) else { return false }
        held[id] = key
        return true
    }

    func remove(id: UInt32) { held[id] = nil }
}

// The keys that are set, and what they do. Sounds keep theirs in the Soundboard's list. The Voice changer's key and the
// sounds' keys are Pitch Shift Pro: while that's locked they aren't taken, and what's saved is kept for later. Setting
// the push-to-talk key turns it on, and clearing it turns it off. If another app has that key it stays off too, or the mic
// could never be heard.
final class Hotkeys {
    enum Action: Hashable { case voice, changer, talk, sound(String) }
    static let fixed: [Action] = [.voice, .changer, .talk]
    private static let savedNames: [Action: String] = [.voice: "voice", .changer: "changer", .talk: "talk"]
    private static let trialID = UInt32.max

    var onPress: (Action) -> Void = { _ in }
    var onChange: () -> Void = {}
    var unlocked: () -> Bool = { true }
    // While a new key is being picked: no key works, so the one pressed can be seen as what it is.
    var paused = false { didSet { refresh() } }
    private let voice: VoiceShifter
    private let board: Soundboard
    private let defaults: UserDefaults
    private let saves: Bool
    private let system: KeySystem
    private var keys: [Action: HotKey] = [:]  // all but the sounds
    private var registered: [Action: (key: HotKey, id: UInt32)] = [:]
    private var down: Set<UInt32> = []
    private var nextID: UInt32 = 0

    // `saves` false (pictures): starts with no keys and writes nothing.
    init(voice: VoiceShifter, board: Soundboard, defaults: UserDefaults, saves: Bool, system: KeySystem) {
        self.voice = voice
        self.board = board
        self.defaults = defaults
        self.saves = saves
        self.system = system
        if saves {
            let stored = defaults.dictionary(forKey: Keys.hotkeys) ?? [:]
            for (action, name) in Self.savedNames { keys[action] = HotKey(saved: stored[name]) }
        }
        system.onEvent = { [weak self] id, pressed in self?.received(id, pressed: pressed) }
        board.onKeys = { [weak self] in
            self?.refresh()
            self?.onChange()
        }
    }

    private var wanted: [Action: HotKey] {
        var all = keys
        for sound in board.sounds { all[.sound(sound.file)] = sound.key }
        return all
    }

    func key(for action: Action) -> HotKey? { wanted[action] }

    // The Voice changer's key and the sounds' keys are Pitch Shift Pro, like the Voice changer and the Soundboard.
    static func needsPro(_ action: Action) -> Bool {
        if case .sound = action { return true }
        return action == .changer
    }

    func isLocked(_ action: Action) -> Bool { Self.needsPro(action) && !unlocked() }

    var soundsWithKeys: [Action] { board.sounds.filter { $0.key != nil }.map { .sound($0.file) } }

    func hasSound(_ file: String) -> Bool { board.files.contains(file) }

    func name(of action: Action) -> String {
        switch action {
        case .voice: return "Input pitch shifter"
        case .changer: return "Voice changer"
        case .talk: return "Push to talk"
        case .sound(let file): return board.sounds.first { $0.file == file }?.name ?? Soundboard.displayName(file)
        }
    }

    // Takes the keys that are set from the Mac and lets go of the rest. Gives back the ones another app has.
    @discardableResult func refresh() -> [Action] {
        let wanted = paused ? [:] : self.wanted.filter { !isLocked($0.key) }
        for (action, entry) in registered where wanted[action] != entry.key {
            system.remove(id: entry.id)
            registered[action] = nil
            received(entry.id, of: action, pressed: false)
        }
        var taken: [Action] = []
        for (action, key) in wanted where registered[action] == nil {
            nextID += 1
            if system.add(key, id: nextID) { registered[action] = (key, nextID) } else { taken.append(action) }
        }
        if !paused { voice.pushToTalk = registered[.talk] != nil }
        return taken
    }

    // A new key (nil: no key). Gives back what's wrong with it, for the window to show; nothing changes then.
    func set(_ key: HotKey?, for action: Action) -> String? {
        guard key != self.key(for: action) else { return nil }
        if let key {
            if let other = wanted.first(where: { $0.value == key }) { return "\(key.name) is set for \(name(of: other.key))." }
            guard system.add(key, id: Self.trialID) else { return "Another app is using \(key.name). Try another key." }
            system.remove(id: Self.trialID)
        }
        if case .sound(let file) = action {
            board.setKey(file, key)
            return nil
        }
        keys[action] = key
        if saves {
            defaults.set(Dictionary(uniqueKeysWithValues: Self.fixed.compactMap { action in
                keys[action].map { (Self.savedNames[action] ?? "", $0.saved) }
            }), forKey: Keys.hotkeys)
        }
        refresh()
        onChange()
        return nil
    }

    private func received(_ id: UInt32, pressed: Bool) {
        guard let action = registered.first(where: { $0.value.id == id })?.key else { return }
        received(id, of: action, pressed: pressed)
    }

    private func received(_ id: UInt32, of action: Action, pressed: Bool) {
        guard pressed else {
            down.remove(id)
            if action == .talk { voice.talking = false }
            return
        }
        guard down.insert(id).inserted else { return }  // a key held down can repeat
        if action == .talk { voice.talking = true } else { onPress(action) }
    }
}

// The Hotkeys window: a row for each key, with the key on a button. Click it and press the new key; Escape keeps the
// old one, Delete or the ✕ clears it. Opened for one sound (its right-click menu), it shows only that sound, ready for
// a key. Like the Soundboard, it floats and clicking it doesn't switch away from the call app.
final class HotkeysPanel: NSObject, NSWindowDelegate {
    private let hotkeys: Hotkeys
    private let panel: NSPanel
    private let list = NSStackView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private var onlySound: String?
    private var actions: [Hotkeys.Action] = []
    private var keyButtons: [NSButton] = []
    private var clearButtons: [NSButton] = []
    private var catching: Hotkeys.Action?
    private var monitor: Any?
    private var placed = false
    private let nameWidth: CGFloat = 150, keyWidth: CGFloat = 130, clearWidth: CGFloat = 18, margin: CGFloat = 16

    init(hotkeys: Hotkeys) {
        self.hotkeys = hotkeys
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "Hotkeys"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true  // only the close button
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 10
        list.edgeInsets = NSEdgeInsets(top: margin, left: margin, bottom: margin, right: margin)
        message.font = .systemFont(ofSize: 12)
        message.textColor = .secondaryLabelColor
        message.preferredMaxLayoutWidth = nameWidth + keyWidth + clearWidth + 16
        panel.contentView = list
        hotkeys.onChange = { [weak self] in if self?.isOpen == true { self?.reload() } }
    }

    var isOpen: Bool { panel.isVisible }

    // Pitch Shift Pro was locked or unlocked: the rows show it.
    func update() {
        guard isOpen else { return }
        if let catching, hotkeys.isLocked(catching) { stopCatching() }
        reload()
    }

    // Pictures: kept out of sight under the desktop picture, like the Soundboard.
    func open(sound file: String? = nil) {
        stopCatching()
        onlySound = file
        show("")
        reload()
        if !placed {
            placed = true
            panel.center()
        }
        if preview != nil {
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
            panel.orderBack(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        if let file { catchKey(.sound(file)) }
    }

    func close() { panel.close() }

    func windowWillClose(_ notification: Notification) { stopCatching() }

    // The owner went back to another app: keys go to it again.
    func windowDidResignKey(_ notification: Notification) { stopCatching() }

    private func reload() {
        if let onlySound, !hotkeys.hasSound(onlySound) { close(); return }
        actions = onlySound.map { [.sound($0)] } ?? Hotkeys.fixed + hotkeys.soundsWithKeys
        if let catching, !actions.contains(catching) { stopCatching(); return }
        keyButtons = []
        clearButtons = []
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for action in actions { list.addArrangedSubview(row(action)) }
        list.addArrangedSubview(message)
        fit()
    }

    // Grows downward.
    private func fit() {
        let top = panel.frame.maxY
        panel.setContentSize(list.fittingSize)
        panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top))
    }

    // A Pitch Shift Pro key while that's locked: dimmed, with a small lock after its name, and it can't be changed.
    private func row(_ action: Hotkeys.Action) -> NSView {
        let name = hotkeys.name(of: action), key = hotkeys.key(for: action), locked = hotkeys.isLocked(action)
        let label = NSTextField(labelWithString: name)
        label.lineBreakMode = .byTruncatingTail
        if locked, let font = label.font, let lock = GradientSlider.lockImage(size: font.pointSize - 2) {
            let words = NSMutableAttributedString(string: name + " ", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])
            let attachment = NSTextAttachment()
            attachment.image = lock
            attachment.bounds = NSRect(x: 0, y: ((font.capHeight - lock.size.height) / 2).rounded(), width: lock.size.width, height: lock.size.height)
            words.append(NSAttributedString(attachment: attachment))
            label.attributedStringValue = words
            label.toolTip = "Pitch Shift Pro"
        }
        let button = NSButton(title: action == catching ? "Press a key…" : key?.name ?? "Set Key…", target: self, action: #selector(keyClicked))
        button.bezelStyle = .rounded
        button.setAccessibilityLabel("\(name) key")
        button.isEnabled = !locked
        if locked { button.toolTip = "Pitch Shift Pro" }
        keyButtons.append(button)
        let glyph = NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor])
        let clear = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear")?.withSymbolConfiguration(glyph) ?? NSImage(),
                             target: self, action: #selector(clearClicked))
        clear.isBordered = false
        clear.isHidden = key == nil || locked
        clear.setAccessibilityLabel("Clear \(name) key")
        clearButtons.append(clear)
        let row = NSStackView(views: [label, button, clear])
        row.detachesHiddenViews = false
        row.spacing = 8
        NSLayoutConstraint.activate([label.widthAnchor.constraint(equalToConstant: nameWidth),
                                     button.widthAnchor.constraint(equalToConstant: keyWidth),
                                     clear.widthAnchor.constraint(equalToConstant: clearWidth)])
        return row
    }

    private func show(_ text: String) {
        message.stringValue = text
        message.isHidden = text.isEmpty
        fit()
    }

    @objc private func keyClicked(_ sender: NSButton) {
        guard let i = keyButtons.firstIndex(of: sender) else { return }
        let action = actions[i]
        DispatchQueue.main.async {  // this rebuilds the rows, and this button is still handling its click
            if action == self.catching { self.stopCatching() } else { self.catchKey(action) }
        }
    }

    @objc private func clearClicked(_ sender: NSButton) {
        guard let i = clearButtons.firstIndex(of: sender) else { return }
        let action = actions[i]
        DispatchQueue.main.async {  // as above
            self.stopCatching()
            _ = self.hotkeys.set(nil, for: action)
        }
    }

    private func catchKey(_ action: Hotkeys.Action) {
        stopCatching()
        show("")
        catching = action
        hotkeys.paused = true
        reload()
        // Every key pressed in this app comes here first, ⌘Q too, and goes no further.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.caught(event)
            return nil
        }
    }

    private func stopCatching() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard catching != nil else { return }
        catching = nil
        hotkeys.paused = false
        if isOpen { reload() }
    }

    private func caught(_ event: NSEvent) {
        guard let action = catching, !event.isARepeat else { return }
        let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        if plain && event.keyCode == UInt16(kVK_Escape) {
            stopCatching()
        } else if plain && [kVK_Delete, kVK_ForwardDelete].contains(Int(event.keyCode)) {
            stopCatching()
            _ = hotkeys.set(nil, for: action)
        } else if let key = HotKey(event: event) {
            if let problem = hotkeys.set(key, for: action) {
                show(problem)
            } else {
                stopCatching()
            }
        } else {
            show(HotKey.rule)
        }
    }

    // For pictures: hotkeys shows example keys, hotkeys-sound the window for one sound, hotkeys-catch the first row
    // waiting for a key. hotkeys-press and hotkeys-bad send ⌃⌥K and a plain "a" through the real handling of a key.
    func showPicture(_ states: Set<String>) {
        let example = { (code: Int, modifiers: Int, label: String) in HotKey(code: UInt32(code), modifiers: UInt32(modifiers), label: label) }
        _ = hotkeys.set(example(kVK_ANSI_V, controlKey | optionKey, "V"), for: .voice)
        _ = hotkeys.set(example(kVK_F5, 0, "F5"), for: .talk)
        _ = hotkeys.set(example(kVK_ANSI_1, cmdKey | shiftKey, "1"), for: .sound(Soundboard.examples[0].file))
        open(sound: states.contains("hotkeys-sound") ? Soundboard.examples[1].file : nil)
        if states.contains("hotkeys-catch") { catchKey(actions[0]) }
        if states.contains("hotkeys-press") { press(keyEvent(kVK_ANSI_K, [.control, .option], "k")) }
        if states.contains("hotkeys-bad") { press(keyEvent(kVK_ANSI_A, [], "a")) }
    }

    private func press(_ event: NSEvent) {
        catchKey(actions[0])
        NSApp.postEvent(event, atStart: false)
    }
}

// A key going down, for pictures and checks.
func keyEvent(_ code: Int, _ flags: NSEvent.ModifierFlags, _ characters: String) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code))!
}

// MARK: Checks (--check-hotkeys)

// Offline: the key rules, saving, what each step does, and the mic's fade. It takes no key from the Mac, opens no sound
// device, and uses its own settings and folder. Says whether everything passed.
func checkHotkeys() -> Bool {
    var failed = 0
    func check(_ name: String, _ good: Bool) {
        print("\(good ? "ok" : "FAILED"): \(name)")
        if !good { failed += 1 }
    }
    func key(_ code: Int, _ modifiers: Int = 0, _ label: String = "X") -> HotKey? {
        HotKey(code: UInt32(code), modifiers: UInt32(modifiers), label: label)
    }

    // The rules.
    check("a plain letter is refused", key(kVK_ANSI_A) == nil)
    check("a plain number is refused", key(kVK_ANSI_1) == nil)
    check("a plain Space is refused", key(kVK_Space) == nil)
    check("⇧ with a letter is refused", key(kVK_ANSI_A, shiftKey) == nil)
    check("⌥ with a letter is refused", key(kVK_ANSI_A, optionKey) == nil)
    check("⌘ with a letter works", key(kVK_ANSI_A, cmdKey) != nil)
    check("⌃ with a number works", key(kVK_ANSI_1, controlKey) != nil)
    check("F1 alone works", key(kVK_F1) != nil)
    check("F20 alone works", key(kVK_F20) != nil)
    check("⇧ with an F-key works", key(kVK_F5, shiftKey) != nil)
    check("a modifier that isn't known is refused", key(kVK_ANSI_A, cmdKey | 1 << 20) == nil)
    check("a key number that doesn't exist is refused", key(200, cmdKey) == nil)
    let pressed = HotKey(event: keyEvent(kVK_ANSI_V, [.control, .option], "v"))
    check("⌃⌥V pressed reads as \(pressed?.name ?? "nothing")", pressed?.name == "⌃⌥V")
    check("⌘⇧1 pressed reads as ⇧⌘1", HotKey(event: keyEvent(kVK_ANSI_1, [.command, .shift], "1"))?.name == "⇧⌘1")
    check("F5 pressed reads as F5", HotKey(event: keyEvent(kVK_F5, [.function], ""))?.name == "F5")
    check("a plain letter pressed gives no key", HotKey(event: keyEvent(kVK_ANSI_A, [], "a")) == nil)

    // A saved sound.
    let ctrl1 = key(kVK_ANSI_1, controlKey, "1")!, ctrl2 = key(kVK_ANSI_2, controlKey, "2")!, f5 = key(kVK_F5, 0, "F5")!, f6 = key(kVK_F6, 0, "F6")!
    check("only a file name still loads", SoundEntry(saved: "a.wav") == SoundEntry(file: "a.wav"))
    check("{file, name} still loads", SoundEntry(saved: ["file": "a.wav", "name": "A"]) == SoundEntry(file: "a.wav", name: "A"))
    check("{file, name, volume} still loads", SoundEntry(saved: ["file": "a.wav", "name": "A", "volume": 0.5]) == SoundEntry(file: "a.wav", name: "A", volume: 0.5))
    check("a sound with no key saves as before", Set(SoundEntry(file: "a.wav").saved.keys) == ["file", "name", "volume"])
    let withKey = SoundEntry(file: "a.wav", key: ctrl1)
    check("a sound's key saves and loads", SoundEntry(saved: withKey.saved) == withKey)
    let changed = SoundEntry(saved: ["file": "a.wav", "key": ["code": kVK_ANSI_A, "modifiers": 0, "label": "A"]])
    check("a saved plain letter is dropped, the sound stays", changed == SoundEntry(file: "a.wav"))

    // The steps, with their own settings and a pretend Mac.
    let suite = "local.pitch-shift.check-\(getpid())"
    guard let defaults = UserDefaults(suiteName: suite) else { print("FAILED: no settings"); return false }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
    defer {
        defaults.removePersistentDomain(forName: suite)
        defaults.synchronize()
        let home = FileManager.default.homeDirectoryForCurrentUser
        try? FileManager.default.removeItem(at: home.appendingPathComponent("Library/Preferences/\(suite).plist"))
        try? FileManager.default.removeItem(at: folder)
    }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for file in ["a.wav", "b.wav"] { FileManager.default.createFile(atPath: folder.appendingPathComponent(file).path, contents: nil) }
    let voice = VoiceShifter(halfSteps: 0, cartoon: 0, micUID: nil)
    var micHeld: Bool { voice.params.withLock { $0.micHeld } }
    let board = Soundboard(voice: voice, sounds: [SoundEntry(file: "a.wav"), SoundEntry(file: "b.wav")], saves: true, folder: folder, defaults: defaults)
    let system = PretendKeys()
    var unlocked = true, presses: [Hotkeys.Action] = []
    let hotkeys = Hotkeys(voice: voice, board: board, defaults: defaults, saves: true, system: system)
    hotkeys.unlocked = { unlocked }
    hotkeys.onPress = { presses.append($0) }
    func send(_ key: HotKey, down: Bool) {
        if let id = system.held.first(where: { $0.value == key })?.key { system.onEvent(id, down) }
    }
    func holds(_ keys: [HotKey]) -> Bool { system.held.count == keys.count && keys.allSatisfy(system.held.values.contains) }

    check("no keys: none taken, mic open", holds([]) && !micHeld)
    check("voice key set", hotkeys.set(ctrl1, for: .voice) == nil && holds([ctrl1]))
    send(ctrl1, down: true)
    send(ctrl1, down: true)
    send(ctrl1, down: false)
    check("a key held down counts once", presses == [.voice])
    send(ctrl1, down: true)
    send(ctrl1, down: false)
    check("pressed again counts again", presses == [.voice, .voice])
    let twice = hotkeys.set(ctrl1, for: .changer)
    check("the same key for two things is refused: \(twice ?? "")", twice != nil && hotkeys.key(for: .changer) == nil)
    system.taken = [ctrl2]
    let taken = hotkeys.set(ctrl2, for: .changer)
    check("a key another app has is refused: \(taken ?? "")", taken != nil && hotkeys.key(for: .changer) == nil && holds([ctrl1]))
    check("changer key set", hotkeys.set(f6, for: .changer) == nil && holds([ctrl1, f6]))

    check("setting the push-to-talk key turns it on", hotkeys.set(f5, for: .talk) == nil && voice.pushToTalk && micHeld)
    send(f5, down: true)
    check("key down: mic open", !micHeld)
    send(f5, down: false)
    check("key up: mic silent", micHeld)
    voice.hold(true)
    check("Test gets the mic", !micHeld)
    voice.hold(false)
    check("after Test: mic silent", micHeld)
    send(f5, down: true)
    hotkeys.paused = true
    check("picking a key: no key works, mic silent", holds([]) && micHeld)
    hotkeys.paused = false
    check("after picking: keys back", holds([ctrl1, f6, f5]) && micHeld)

    unlocked = false
    hotkeys.refresh()
    check("Pro locked: the Voice changer's key let go, the free keys kept, push-to-talk on", holds([ctrl1, f5]) && voice.pushToTalk && micHeld)
    check("Pro locked: its key stays saved", hotkeys.key(for: .changer) == f6)
    send(ctrl1, down: true)
    send(ctrl1, down: false)
    check("Pro locked: the Input pitch shifter key still works", presses.last == .voice && presses.count == 3)
    unlocked = true
    hotkeys.refresh()
    check("Pro unlocked: keys back, push-to-talk on", holds([ctrl1, f6, f5]) && micHeld)

    check("a sound's key another app has is refused", hotkeys.set(ctrl2, for: .sound("a.wav")) != nil && holds([ctrl1, f6, f5]))
    system.taken = []
    check("sound key set", hotkeys.set(ctrl2, for: .sound("a.wav")) == nil && holds([ctrl1, f6, f5, ctrl2]))
    send(ctrl2, down: true)
    send(ctrl2, down: false)
    check("sound key pressed", presses.last == .sound("a.wav"))
    check("sound keys listed", hotkeys.soundsWithKeys == [.sound("a.wav")])
    unlocked = false
    hotkeys.refresh()
    check("Pro locked: the sound's key let go too", holds([ctrl1, f5]) && hotkeys.key(for: .sound("a.wav")) == ctrl2)
    unlocked = true
    hotkeys.refresh()
    check("Pro unlocked: the sound's key back", holds([ctrl1, f6, f5, ctrl2]))
    let again = Hotkeys(voice: voice, board: Soundboard(voice: voice, sounds: Soundboard.saved(defaults, folder: folder), saves: false),
                        defaults: defaults, saves: true, system: PretendKeys())
    check("keys load from the saved settings", again.key(for: .voice) == ctrl1 && again.key(for: .changer) == f6
          && again.key(for: .talk) == f5 && again.key(for: .sound("a.wav")) == ctrl2 && again.key(for: .sound("b.wav")) == nil)
    let busy = PretendKeys()
    busy.taken = [f5]
    let blocked = Hotkeys(voice: voice, board: Soundboard(voice: voice, sounds: [], saves: false), defaults: defaults, saves: true, system: busy)
    check("saved push-to-talk key taken at the start: said so, mic open", blocked.refresh() == [.talk] && !voice.pushToTalk && !micHeld)
    hotkeys.refresh()
    board.remove("a.wav")
    check("removing a sound lets go of its key", holds([ctrl1, f6, f5]) && hotkeys.soundsWithKeys.isEmpty)
    check("clearing the push-to-talk key turns it off", hotkeys.set(nil, for: .talk) == nil && holds([ctrl1, f6]) && !voice.pushToTalk && !micHeld)
    check("cleared keys stay cleared", (defaults.dictionary(forKey: Keys.hotkeys) ?? [:]).keys.sorted() == ["changer", "voice"])

    // The real path from the Mac's event to the key's id, with an event sent to the app itself.
    let keys = SystemKeys()
    var got: [String] = []
    keys.onEvent = { id, down in got.append("\(id) \(down)") }
    keys.listen()
    func sendEvent(_ kind: Int, id: UInt32, signature: OSType) {
        var event: EventRef?
        CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kind), 0, 0, &event)
        guard let event else { return }
        var hotkey = EventHotKeyID(signature: signature, id: id)
        SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &hotkey)
        SendEventToEventTarget(event, GetApplicationEventTarget())
    }
    sendEvent(kEventHotKeyPressed, id: 7, signature: SystemKeys.signature)
    sendEvent(kEventHotKeyReleased, id: 7, signature: SystemKeys.signature)
    sendEvent(kEventHotKeyPressed, id: 8, signature: 0)
    check("key events reach the app, down and up, and others' are left alone: \(got)", got == ["7 true", "7 false"])

    // The mic: 128-sample callbacks of a steady 1, so what comes out is its gain.
    let rate = 48000.0, fade = Int(rate * 0.01)
    var mix = CallMix(rate: rate, take: 0)
    func gains(_ callbacks: Int) -> [Float] {
        (0..<callbacks).flatMap { _ -> [Float] in
            var block = [Float](repeating: 1, count: 128)
            block.withUnsafeMutableBufferPointer { mix.muteIfNeeded($0.baseAddress!, 128) }
            return block
        }
    }
    func biggestStep(_ gains: [Float], from: Float) -> Float { zip([from] + gains, gains).map { abs($0 - $1) }.max() ?? 0 }
    check("nothing changes with the flag off", gains(4).allSatisfy { $0 == 1 })
    mix.micHeld = true
    let falling = gains(8)
    print(String(format: "  mic fades out: silent after %d samples (%.1f ms), biggest step %.5f", falling.firstIndex(of: 0) ?? -1, Double(falling.firstIndex(of: 0) ?? -1) / rate * 1000, biggestStep(falling, from: 1)))
    check("mic fades out in 10 ms, with no jump", abs((falling.firstIndex(of: 0) ?? 0) - fade) <= 2 && biggestStep(falling, from: 1) < 1.01 / Float(fade))
    check("mic stays silent", falling[(fade + 2)...].allSatisfy { $0 == 0 } && gains(4).allSatisfy { $0 == 0 })
    mix.micHeld = false
    let rising = gains(8)
    print(String(format: "  mic fades in: full after %d samples (%.1f ms), biggest step %.5f", rising.firstIndex(of: 1) ?? -1, Double(rising.firstIndex(of: 1) ?? -1) / rate * 1000, biggestStep(rising, from: 0)))
    check("mic fades in in 10 ms, with no jump", abs((rising.firstIndex(of: 1) ?? 0) - fade) <= 2 && biggestStep(rising, from: 0) < 1.01 / Float(fade))
    mix = CallMix(rate: rate, take: 0, micHeld: true)
    check("a chain that starts with the mic held lets nothing through", gains(1).allSatisfy { $0 == 0 })
    let sound = [Float](repeating: 0.25, count: 4800)
    let out = sound.withUnsafeBufferPointer { samples -> [Float] in
        mix.follow(SoundPlay(samples: samples.baseAddress, count: samples.count, rate: rate, take: 1, muteMic: false, volume: 1))
        return gains(8).map { mix.out($0, shifting: false) }
    }
    check("a sound still plays while the mic is held silent (\(out.last ?? 0))", abs((out.last ?? 0) - 0.25) < 0.001)

    print(failed == 0 ? "all ok" : "FAILED: \(failed)")
    return failed == 0
}
