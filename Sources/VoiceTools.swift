// The small "…" button next to the Voice changer's voice picker: Add Voice…, Open Voices Folder, and Rename / Remove
// for a voice the user added. Also watches the Voices folder, so the picker follows voices dropped in with Finder or
// made by the converter (tools/convert-voice.sh). The work itself is in VoiceImport.swift.
import AppKit

final class VoiceTools: NSObject {
    private unowned let app: AppDelegate
    private let button = NSButton()
    private let busy = NSProgressIndicator()  // while a voice is being added
    private var widths: [NSLayoutConstraint] = []
    private var watcher: VoiceFolderWatcher?
    private var adding = false

    init(app: AppDelegate) {
        self.app = app
        super.init()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(showMenu)
        button.toolTip = "Add or manage your own voices"
        button.setAccessibilityLabel("Your own voices")
        busy.style = .spinning
        busy.controlSize = .small
        busy.isDisplayedWhenStopped = false
        busy.isHidden = true
        busy.setAccessibilityLabel("Adding a voice")
        for view in views {
            let width = view.widthAnchor.constraint(equalToConstant: 22)
            width.isActive = true
            widths.append(width)
        }
        if preview == nil { watch() }  // pictures watch nothing
    }

    var views: [NSView] { [button, busy] }

    // Swoopy Pro is locked: the button is greyed out and a click opens the unlock window.
    var locked = false {
        didSet {
            guard oldValue != locked else { return }
            drawButton()
            button.toolTip = locked ? "Swoopy Pro" : "Add or manage your own voices"
            button.setAccessibilityHelp(locked ? "Swoopy Pro" : nil)
        }
    }
    private var points: CGFloat = 0

    // Sizes the button with the window (scale 1 = smallest window).
    func size(for scale: CGFloat) {
        points = Theme.fontSize(Theme.controlSize(scale)) + 3
        drawButton()
        widths.forEach { $0.constant = (points + 6).rounded() }
    }

    private func drawButton() {
        guard points > 0 else { return }
        button.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Your own voices")?
            .withSymbolConfiguration(.init(pointSize: points, weight: .regular)
                .applying(.init(paletteColors: [locked ? NSColor.tertiaryLabelColor : Theme.mid])))
    }

    // MARK: The menu

    @objc private func showMenu() {
        guard !locked else { app.showUnlock(); return }  // adding voices is part of Swoopy Pro
        let menu = NSMenu()
        menu.autoenablesItems = false
        add(menu, "Add Voice…", #selector(addVoice))
        add(menu, "Open Voices Folder", #selector(openFolder))
        if let current = currentUserVoice {
            menu.addItem(.separator())
            add(menu, "Rename “\(current.name)”…", #selector(renameVoice))
            add(menu, "Remove “\(current.name)”", #selector(removeVoice))
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = !adding
    }

    // The voice picked now, if the user added it (built-in voices can't be renamed or removed).
    private var currentUserVoice: VoiceEntry? {
        VoiceLibrary.shared.voice(app.voice.changer.voiceID).flatMap { $0.isUserVoice ? $0 : nil }
    }

    // MARK: Voices folder

    // Opens the folder in Finder (the user's own click), making it with its README.txt first.
    @objc private func openFolder() {
        do {
            try VoiceFolder.ensure()
        } catch {
            tell("Can't make the Voices folder", error)
            return
        }
        watch()
        NSWorkspace.shared.open(VoiceLibrary.userFolder)
    }

    private func watch() {
        if let watcher { watcher.start() } else {
            watcher = VoiceFolderWatcher(VoiceLibrary.userFolder) { [weak self] in self?.folderChanged() }
        }
    }

    // Something was added, removed or renamed in the folder: read the voices again (not while a menu is open; the
    // picker reads them again when it opens anyway).
    private func folderChanged() {
        watcher?.start()
        guard RunLoop.current.currentMode != .eventTracking else { return }
        VoiceLibrary.shared.rescan()
        if VoiceLibrary.shared.voice(app.voice.changer.voiceID) == nil { app.voice.changer.voiceID = "woman" }  // (the saved choice is kept)
        app.rebuildChangerMenu()
        app.refresh()
    }

    // MARK: Add Voice…

    @objc private func addVoice() {
        guard !adding, let window = app.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a voice folder, or a .zip of one."
        panel.prompt = "Add"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.add(url)
        }
    }

    // Adds a voice folder or .zip (also for files dropped on the picker later). Slow parts run in the background.
    func add(_ url: URL) {
        setAdding(true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = Result { try VoiceImport.examine(url) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch found {
                case .failure(let error):
                    self.setAdding(false)
                    self.tell("Can't add this voice", error)
                case .success(let voice) where voice.needsPitch:
                    self.askPitch(voice.name) { pitch in
                        guard let pitch else {
                            voice.discard()
                            self.setAdding(false)
                            return
                        }
                        self.install(voice, pitch: pitch.natural)
                    }
                case .success(let voice):
                    self.install(voice, pitch: nil)
                }
            }
        }
    }

    private func install(_ voice: VoiceImport, pitch: [String: Any]?) {
        VoiceLibrary.shared.rescan()
        let taken = Set(VoiceLibrary.shared.voices.map { $0.id.lowercased() })
        let names = Set(VoiceLibrary.shared.voices.map { $0.name.lowercased() })
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try voice.install(into: VoiceLibrary.userFolder, pitch: pitch, taken: taken, names: names) }
            voice.discard()
            DispatchQueue.main.async {
                guard let self else { return }
                self.setAdding(false)
                switch result {
                case .failure(let error):
                    self.tell("Can't add this voice", error)
                case .success(let id):
                    self.watch()
                    self.pick(id)
                }
            }
        }
    }

    // A voice with no Natural settings: how high is it? (Sets its pitch in both modes.)
    private func askPitch(_ name: String, done: @escaping (VoicePitch?) -> Void) {
        guard let window = app.window else { done(nil); return }
        let alert = NSAlert()
        alert.messageText = "How high is “\(name)”?"
        alert.informativeText = "Swoopy moves your voice to this pitch. High: most women's voices. Low: most men's voices."
        for pitch in VoicePitch.allCases { alert.addButton(withTitle: pitch.title) }
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            done(index >= 0 && index < VoicePitch.allCases.count ? VoicePitch.allCases[index] : nil)
        }
    }

    private func setAdding(_ on: Bool) {
        adding = on
        button.isHidden = on
        busy.isHidden = !on
        if on { busy.startAnimation(nil) } else { busy.stopAnimation(nil) }
    }

    // Shows the voice in the picker and uses it.
    private func pick(_ id: String) {
        app.voice.changer.voiceID = id
        app.defaults.set(id, forKey: Keys.changerVoice)
        app.rebuildChangerMenu()
        app.refresh()
    }

    // MARK: Rename and Remove

    @objc private func renameVoice() {
        guard let entry = currentUserVoice, let window = app.window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename “\(entry.name)”"
        let field = NSTextField(string: entry.name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                try VoiceImport.rename(entry, to: field.stringValue)
            } catch {
                self.tell("Can't rename this voice", error)
            }
            self.app.rebuildChangerMenu()
            self.app.refresh()
        }
    }

    // Moves the voice to the Trash (so it can be put back); Woman is used instead.
    @objc private func removeVoice() {
        guard let entry = currentUserVoice else { return }
        do {
            try VoiceImport.remove(entry)
        } catch {
            tell("Can't remove this voice", error)
            return
        }
        pick("woman")
    }

    private func tell(_ title: String, _ error: Error) {
        guard let window = app.window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = (error as? Problem)?.message ?? error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}
