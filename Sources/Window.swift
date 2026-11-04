// The window: three cards ("Output pitch shifter" for what you hear, "Input pitch shifter" for your voice, and "Voice
// changer"), each with an on/off switch and a picker; the first two also have a big number you can click and type
// into, and − 0 + buttons (they work while the card is off too). No extra text. The window can be resized: the cards
// sit in a row, in two columns, or one above the other, and everything grows with the window.
import AppKit
import AVFoundation
import CoreAudio

// The icon's colors: purple to pink. Plus the shared control sizes and animation helpers.
enum Theme {
    static let purple = NSColor(red: 0.45, green: 0.25, blue: 0.95, alpha: 1)
    static let pink = NSColor(red: 0.95, green: 0.3, blue: 0.6, alpha: 1)
    static let mid = purple.blended(withFraction: 0.5, of: pink)!
    static let gradient = NSGradient(starting: purple, ending: pink)!

    // Regular controls in a small window, large ones once everything is 1.3 times bigger.
    static func controlSize(_ scale: CGFloat) -> NSControl.ControlSize { scale >= 1.3 ? .large : .regular }
    static func fontSize(_ size: NSControl.ControlSize) -> CGFloat { size == .large ? 14 : 13 }

    // "Reduce motion" in the Mac's accessibility settings: nothing slides or pulses, things only fade.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // Fades from how a view looks now to how it looks after the changes made right after this call.
    static func crossfade(_ view: NSView?, _ duration: TimeInterval = 0.2) {
        guard let view, view.isShowing, let layer = view.layer else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: "crossfade")
    }

    // Eases changes made through `animator()`.
    static func animate(_ duration: TimeInterval, _ changes: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            changes()
        }
    }
}

extension NSView {
    var isShowing: Bool { window?.isVisible == true }
}

extension NSControl {
    // Regular or large control, with the matching text size.
    func useSize(_ size: NSControl.ControlSize) {
        guard controlSize != size || font?.pointSize != Theme.fontSize(size) else { return }
        controlSize = size
        font = .systemFont(ofSize: Theme.fontSize(size))
    }
}

// An on/off switch in the icon's colors (the standard switch can't be recolored). It never changes size: the knob
// slides across with an ease while the colors fade in or out (with Reduce Motion they only fade). It's made of layers,
// so it keeps moving smoothly while the app is busy turning something on.
final class GradientSwitch: NSView {
    var onChange: (Bool) -> Void = { _ in }
    var onEnabled: (Bool) -> Void = { _ in }  // when it starts or stops looking usable (for its label)
    var isEnabled = true {
        didSet {
            needsDisplay = true
            if oldValue != isEnabled { onEnabled(looksEnabled) }
        }
    }
    // Looks greyed out but still works.
    var dimmed = false {
        didSet {
            guard oldValue != dimmed else { return }
            needsDisplay = true
            onEnabled(looksEnabled)
        }
    }
    var looksEnabled: Bool { isEnabled && !dimmed }
    // Pitch Shift Pro is locked: dimmed, and a click only calls onLockedClick (which opens the unlock window).
    var locked = false {
        didSet {
            guard oldValue != locked else { return }
            needsDisplay = true
            toolTip = locked ? "Pitch Shift Pro" : nil
            onLocked(locked)
        }
    }
    var onLocked: (Bool) -> Void = { _ in }  // for its label
    var onLockedClick: () -> Void = {}
    var isOn = false {
        didSet {
            guard oldValue != isOn else { return }
            setAccessibilityValue(isOn ? 1 : 0)
            slide(animated: isShowing)
        }
    }
    var size = NSSize(width: 38, height: 22) {
        didSet {
            guard oldValue != size else { return }
            invalidateIntrinsicContentSize()
            noteFocusRingMaskChanged()
            needsLayout = true
        }
    }
    private var pressed = false { didSet { needsDisplay = true } }
    private let trackLayer = CALayer()
    private let colors = CALayer()       // holds the icon's colors (dims them while the switch can't be used)
    private let fill = CAGradientLayer()  // the icon's colors, shown while on
    private let knob = CALayer()
    private var placed: NSRect?           // the track the layers were last laid out for

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 38, height: 22))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilitySubrole(.switch)
        setAccessibilityValue(0)
        setContentHuggingPriority(.required, for: .horizontal)
        fill.colors = [Theme.purple.cgColor, Theme.pink.cgColor]
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        fill.opacity = 0
        colors.addSublayer(fill)
        knob.shadowColor = NSColor.black.cgColor
        knob.shadowOpacity = 0.3
        knob.shadowRadius = 1
        knob.shadowOffset = CGSize(width: 0, height: -1)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { size }
    override var wantsUpdateLayer: Bool { true }

    private var track: NSRect {
        NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height).insetBy(dx: 1, dy: 1)
    }

    // Where the knob's middle is, off (left) or on (right).
    private func knobCenter(_ on: Bool) -> CGPoint {
        let track = self.track, width = track.height - 4
        return CGPoint(x: track.minX + 2 + width / 2 + (on ? track.width - width - 4 : 0), y: track.midY)
    }

    private func quietly(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let layer else { return }
        let track = self.track
        guard track != placed else { return }  // (a knob on its way keeps going)
        placed = track
        quietly {
            if knob.superlayer == nil { [trackLayer, colors, knob].forEach(layer.addSublayer) }
            let round = track.height / 2
            trackLayer.frame = track
            trackLayer.cornerRadius = round
            colors.frame = track
            fill.frame = colors.bounds
            fill.cornerRadius = round
            let width = track.height - 4
            knob.bounds = CGRect(x: 0, y: 0, width: width, height: width)
            knob.cornerRadius = width / 2
            knob.shadowPath = CGPath(ellipseIn: knob.bounds, transform: nil)
            knob.removeAllAnimations()
            fill.removeAllAnimations()
            knob.position = knobCenter(isOn)
            fill.opacity = isOn ? 1 : 0
        }
    }

    // The colors for light or dark mode, and how usable it looks. Pressed, the knob turns a little grey.
    override func updateLayer() {
        let usable = looksEnabled && !locked
        CATransaction.begin()
        if isShowing { CATransaction.setAnimationDuration(0.12) } else { CATransaction.setDisableActions(true) }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            trackLayer.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(usable ? 0.35 : 0.2).cgColor
        }
        colors.opacity = usable ? 1 : 0.4
        knob.backgroundColor = NSColor(white: pressed ? 0.88 : 1, alpha: isEnabled && !locked ? 1 : 0.7).cgColor
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // Moves the knob and the colors to the switch's state, from wherever they are now: a second click while it's
    // moving turns it around smoothly, and it always ends fully on or off.
    private func slide(animated: Bool) {
        let target = knobCenter(isOn)
        let opacity: Float = isOn ? 1 : 0
        let fromPosition = knob.presentation()?.position ?? knob.position
        let fromOpacity = fill.presentation()?.opacity ?? fill.opacity
        let smooth = animated && !Theme.reduceMotion
        if animated && !smooth { Theme.crossfade(self, 0.2) }
        quietly {
            knob.removeAllAnimations()
            fill.removeAllAnimations()
            knob.position = target
            fill.opacity = opacity
        }
        let travel = knobCenter(true).x - knobCenter(false).x
        guard smooth, travel > 0 else { return }
        // The whole way takes 0.2 s; turning around partway takes less.
        let duration = 0.2 * Double(max(0.4, min(1, abs(target.x - fromPosition.x) / travel)))
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: fromPosition)
        move.toValue = NSValue(point: target)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.toValue = opacity
        for (part, animation) in [(knob, move), (fill as CALayer, fade)] {
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            part.add(animation, forKey: "slide")
        }
    }

    // Reachable with Tab when "Keyboard navigation" is on in the Mac's settings; Space switches it.
    override var acceptsFirstResponder: Bool { isEnabled && !locked && NSApp.isFullKeyboardAccessEnabled }
    override var focusRingMaskBounds: NSRect { track }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { flip() } else { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        if locked { onLockedClick(); return }
        guard isEnabled else { return }
        if !acceptsFirstResponder { window?.makeFirstResponder(nil) }  // stops typing in a number
        pressed = true
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { flip() }
    }

    override func accessibilityPerformPress() -> Bool {
        if locked { onLockedClick(); return true }
        guard isEnabled else { return false }
        flip()
        return true
    }

    private func flip() {
        guard isEnabled, !locked else { return }
        isOn.toggle()
        CATransaction.flush()  // starts the slide now, before whatever the switch turns on keeps the app busy
        onChange(isOn)
    }
}

// A slider from 0 (left) to 1 (right), like the voice style (Natural ... Cartoon) or the tone (Bass ... Treble). The
// track shows the icon's purple-to-pink colors from end to end, with a round white knob (like GradientSwitch's) and
// small labels under its ends. `mark` adds a small mark (at 0.5 = the middle), and the knob snaps to it when close.
// Click or drag to set it; with "Keyboard navigation" on, the arrow keys move it in steps of 0.1.
// Nothing moves on its own, so it's the same with Reduce Motion.
final class GradientSlider: NSView {
    var onChange: (Float) -> Void = { _ in }
    var mark: Float? { didSet { needsDisplay = true } }
    var steps: Float = 100     // values it can take between 0 and 1
    var clickThrough = false   // a click works even while another app is in front (the Soundboard's volume)
    // The labels under the ends, and what VoiceOver says for a value (both may change, e.g. Strength in Realistic).
    var left: String { didSet { if oldValue != left { needsDisplay = true } } }
    var right: String { didSet { if oldValue != right { needsDisplay = true } } }
    var describe: (Float) -> String { didSet { setAccessibilityValueDescription(describe(value)) } }
    var isEnabled = true {
        didSet {
            guard oldValue != isEnabled else { return }
            if !isEnabled && window?.firstResponder === self { window?.makeFirstResponder(nil) }
            needsDisplay = true
        }
    }
    // Pitch Shift Pro is locked: dimmed with a small lock under the middle, and a click only calls onLockedClick
    // (which opens the unlock window).
    var locked = false {
        didSet {
            guard oldValue != locked else { return }
            if locked && window?.firstResponder === self { window?.makeFirstResponder(nil) }
            toolTip = locked ? "Pitch Shift Pro" : nil
            setAccessibilityHelp(locked ? "Pitch Shift Pro" : nil)
            needsDisplay = true
        }
    }
    var onLockedClick: () -> Void = {}
    private var usable: Bool { isEnabled && !locked }
    var value: Float = 0 {
        didSet {
            guard oldValue != value else { return }
            setAccessibilityValue(NSNumber(value: value))
            setAccessibilityValueDescription(describe(value))
            needsDisplay = true
        }
    }
    // Sizes for the window's scale (1 = smallest window).
    var scale: CGFloat = 1 { didSet { if oldValue != scale { resized() } } }
    // The height of the button beside it (Test): the track runs through the middle of that height, so they line up.
    var rowHeight: CGFloat = 24 { didSet { if oldValue != rowHeight { resized() } } }
    private var grab: CGFloat?  // where on the knob the mouse took hold (so the knob doesn't jump)

    // left / right: the labels under the ends; name: what VoiceOver calls it.
    init(left: String, right: String, name: String, describe: @escaping (Float) -> String) {
        self.left = left
        self.right = right
        self.describe = describe
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 40))
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(name)
        setAccessibilityMinValue(NSNumber(value: 0))
        setAccessibilityMaxValue(NSNumber(value: 1))
        setAccessibilityValue(NSNumber(value: 0))
        setAccessibilityValueDescription(describe(0))
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func resized() {
        invalidateIntrinsicContentSize()
        noteFocusRingMaskChanged()
        needsDisplay = true
    }

    // The knob and track follow the switches' sizes (bigger once the window is 1.3 times bigger).
    private var large: Bool { Theme.controlSize(scale) == .large }
    private var knobSize: CGFloat { large ? 20 : 16 }
    private var trackHeight: CGFloat { large ? 7 : 6 }
    private var labelFont: NSFont { .systemFont(ofSize: 11 + (scale - 1) * 2.5) }
    private var labelHeight: CGFloat { (labelFont.ascender - labelFont.descender).rounded(.up) }
    private var middle: CGFloat { (bounds.maxY - rowHeight / 2).rounded() }  // the track's middle

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: (rowHeight / 2).rounded() + knobSize / 2 + 1 + labelHeight)
    }

    // The line the knob moves along, and the knob's place on it.
    private var track: NSRect {
        NSRect(x: bounds.minX, y: middle - trackHeight / 2, width: bounds.width, height: trackHeight)
    }

    private var knob: NSRect {
        let x = bounds.minX + CGFloat(value) * max(0, bounds.width - knobSize)
        return NSRect(x: x.rounded(), y: middle - knobSize / 2, width: knobSize, height: knobSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = track
        let shape = NSBezierPath(roundedRect: t, xRadius: t.height / 2, yRadius: t.height / 2)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.35).setFill()
        shape.fill()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(usable ? 1 : 0.35)
        Theme.gradient.draw(in: shape, angle: 0)
        NSGraphicsContext.restoreGraphicsState()

        // The labels: one under the left end ("Natural"), one under the right end ("Cartoon").
        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont, .foregroundColor: usable ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor]
        let top = middle - knobSize / 2 - 1  // just under the knob
        for (text, left) in [(left, true), (right, false)] {
            let width = (text as NSString).size(withAttributes: attributes).width
            (text as NSString).draw(at: NSPoint(x: left ? bounds.minX : bounds.maxX - width, y: top - labelHeight), withAttributes: attributes)
        }
        // Locked: a small lock between the labels, under the middle of the track.
        if locked, let lock = Self.lockImage(size: labelFont.pointSize - 1) {
            let size = lock.size
            lock.draw(in: NSRect(x: (bounds.midX - size.width / 2).rounded(), y: top - labelHeight + (labelHeight - size.height) / 2,
                                 width: size.width, height: size.height))
        }

        // The middle mark: a short line across the track's middle, just inside the knob's height (so the knob covers
        // it when it's there).
        if let mark {
            (usable ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor).setFill()
            let reach = knobSize / 2 - 1
            let x = (bounds.minX + knobSize / 2 + CGFloat(mark) * (bounds.width - knobSize) - 1).rounded()
            NSBezierPath(rect: NSRect(x: x, y: middle - reach, width: 2, height: reach - trackHeight / 2)).fill()
            NSBezierPath(rect: NSRect(x: x, y: middle + trackHeight / 2, width: 2, height: reach - trackHeight / 2)).fill()
        }

        // The knob, with a soft shadow and a thin edge (so it stands out on a white card too).
        let k = knob
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(usable ? 0.3 : 0.15)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.withAlphaComponent(usable ? 1 : 0.7).setFill()
        NSBezierPath(ovalIn: k).fill()
        NSGraphicsContext.restoreGraphicsState()
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        (dark ? NSColor.white : NSColor.black).withAlphaComponent((dark ? 0.25 : 0.14) * (usable ? 1 : 0.6)).setStroke()
        let edge = NSBezierPath(ovalIn: k.insetBy(dx: 0.5, dy: 0.5))
        edge.lineWidth = 1
        edge.stroke()
    }

    // The small lock shown on locked controls (a little brighter than their dimmed labels, so it's seen). Its color is
    // picked each time it's drawn, so it follows light and dark mode; `color` fixes it instead (for a button's title).
    static func lockImage(size: CGFloat, color: NSColor? = nil) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Pitch Shift Pro")?
            .withSymbolConfiguration(config) else { return nil }
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            (color ?? NSColor.secondaryLabelColor).set()
            rect.fill(using: .sourceIn)
            return true
        }
        image.cacheMode = .never
        image.accessibilityDescription = "Pitch Shift Pro"
        return image
    }

    // Reachable with Tab when "Keyboard navigation" is on in the Mac's settings (like the switches).
    override var acceptsFirstResponder: Bool { usable && NSApp.isFullKeyboardAccessEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { clickThrough }
    override var focusRingMaskBounds: NSRect { track.insetBy(dx: 0, dy: -(knobSize - trackHeight) / 2) }
    override func drawFocusRingMask() {
        let ring = focusRingMaskBounds
        NSBezierPath(roundedRect: ring, xRadius: ring.height / 2, yRadius: ring.height / 2).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard usable else { super.keyDown(with: event); return }
        switch event.specialKey {
        case .leftArrow?, .downArrow?: set(value - 0.1)
        case .rightArrow?, .upArrow?: set(value + 0.1)
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if locked { onLockedClick(); return }
        guard isEnabled else { return }
        window?.makeFirstResponder(acceptsFirstResponder ? self : nil)  // also stops typing in a number
        let point = convert(event.locationInWindow, from: nil)
        let k = knob
        grab = k.insetBy(dx: -2, dy: -4).contains(point) ? point.x - k.midX : 0
        follow(point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard grab != nil else { return }
        follow(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) { grab = nil }

    private func follow(_ point: NSPoint) {
        let travel = max(1, bounds.width - knobSize)
        set(Float((point.x - (grab ?? 0) - bounds.minX - knobSize / 2) / travel))
    }

    override func accessibilityPerformIncrement() -> Bool {
        guard usable else { return false }
        set(value + 0.1)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard usable else { return false }
        set(value - 0.1)
        return true
    }

    override func accessibilityPerformPress() -> Bool {
        guard locked else { return false }
        onLockedClick()
        return true
    }

    // Steps of 1/`steps` (0.01) from 0 to 1, and to the mark when within 3 steps of it.
    private func set(_ new: Float) {
        var clean = max(0, min(1, (new * steps).rounded() / steps))
        if let mark, abs(clean - mark) < 3.1 / steps { clean = mark }
        guard clean != value else { return }
        value = clean
        onChange(clean)
    }
}

// One of Auto EQ's five sections (Sub, Bass, Mids, Highs or Air): a thin upright slider with its name under it. The
// knob shows the section's gain now, from −15 dB (bottom) through 0 (the middle mark) to +15 dB (top): the automatic
// part, which moves on its own while music plays, plus the owner's offset. A bar in the section's color runs from the
// middle mark to the knob. Dragging the knob sets the offset (−12 … 12 dB, back to 0 when close to it); a
// double-click puts it back to 0; with "Keyboard navigation" on, ↑ ↓ move it 1 dB.
final class EQBand: NSView {
    static let most: Float = 15  // the sound processing keeps the automatic gain plus the offset within ±15 dB
    var onChange: (Float) -> Void = { _ in }  // the new offset
    private let name: String
    private let color: NSColor
    var isEnabled = true {
        didSet {
            guard oldValue != isEnabled else { return }
            if !isEnabled && window?.firstResponder === self { window?.makeFirstResponder(nil) }
            needsDisplay = true
        }
    }
    var auto: Float = 0 { didSet { if oldValue != auto { changed() } } }      // the automatic gain now, in dB
    var offset: Float = 0 { didSet { if oldValue != offset { changed() } } }  // the owner's offset, in dB
    // Sizes for the window's scale (1 = smallest window).
    var scale: CGFloat = 1 {
        didSet {
            guard oldValue != scale else { return }
            invalidateIntrinsicContentSize()
            noteFocusRingMaskChanged()
            needsDisplay = true
        }
    }
    private var grab: CGFloat?  // where on the knob the mouse took hold (so the knob doesn't jump)

    init(name: String, color: NSColor) {
        self.name = name
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 36, height: 60))
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(name)
        setAccessibilityMinValue(NSNumber(value: -Self.most))
        setAccessibilityMaxValue(NSNumber(value: Self.most))
        changed()
    }

    required init?(coder: NSCoder) { fatalError() }

    var total: Float { max(-Self.most, min(Self.most, auto + offset)) }

    private func changed() {
        setAccessibilityValue(NSNumber(value: total))
        setAccessibilityValueDescription(String(format: "%+.1f dB, automatic %+.1f, yours %+.1f", total, auto, offset))
        needsDisplay = true
    }

    // The knob and track: a little smaller than the other sliders' (bigger once the window is 1.3 times bigger).
    private var large: Bool { Theme.controlSize(scale) == .large }
    private var knobSize: CGFloat { large ? 16 : 12 }
    private var trackWidth: CGFloat { large ? 5 : 4 }
    private var labelFont: NSFont { .systemFont(ofSize: 11 + (scale - 1) * 2.5) }
    private var labelHeight: CGFloat { (labelFont.ascender - labelFont.descender).rounded(.up) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: (52 * scale).rounded() + 2 + labelHeight)
    }

    // The slider, above the name. `middle` is the 0 dB line; the knob's middle goes up to `reach` above and below it.
    private var slider: NSRect {
        NSRect(x: bounds.minX, y: bounds.minY + labelHeight + 2, width: bounds.width, height: max(0, bounds.height - labelHeight - 2))
    }
    var middle: CGFloat { slider.midY.rounded() }
    private var reach: CGFloat { max(1, slider.height / 2 - knobSize / 2) }

    private var track: NSRect {
        NSRect(x: (bounds.midX - trackWidth / 2).rounded(), y: slider.minY + 1, width: trackWidth, height: max(0, slider.height - 2))
    }

    private var knob: NSRect {
        let y = middle + CGFloat(total / Self.most) * reach
        return NSRect(x: (bounds.midX - knobSize / 2).rounded(), y: (y - knobSize / 2).rounded(), width: knobSize, height: knobSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = track, k = knob
        let round = t.width / 2
        NSColor.quaternaryLabelColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: t, xRadius: round, yRadius: round).fill()

        // The bar from the middle mark to the knob.
        if abs(k.midY - middle) >= 1 {
            color.withAlphaComponent(isEnabled ? 1 : 0.35).setFill()
            let bar = NSRect(x: t.minX, y: min(middle, k.midY), width: t.width, height: abs(k.midY - middle))
            NSBezierPath(roundedRect: bar, xRadius: round, yRadius: round).fill()
        }

        // The middle mark (0 dB): a short line each side of the track, inside the knob's width (so the knob covers it
        // when it's there).
        (isEnabled ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor).setFill()
        let side = knobSize / 2 - 1 - t.width / 2
        NSBezierPath(rect: NSRect(x: t.minX - side, y: middle - 1, width: side, height: 2)).fill()
        NSBezierPath(rect: NSRect(x: t.maxX, y: middle - 1, width: side, height: 2)).fill()

        // The knob, like the other sliders': white, a soft shadow and a thin edge.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(isEnabled ? 0.3 : 0.15)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.7).setFill()
        NSBezierPath(ovalIn: k).fill()
        NSGraphicsContext.restoreGraphicsState()
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        (dark ? NSColor.white : NSColor.black).withAlphaComponent((dark ? 0.25 : 0.14) * (isEnabled ? 1 : 0.6)).setStroke()
        let edge = NSBezierPath(ovalIn: k.insetBy(dx: 0.5, dy: 0.5))
        edge.lineWidth = 1
        edge.stroke()

        // The name, centered under the slider; in the section's color while the owner's offset is in use.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: !isEnabled ? NSColor.tertiaryLabelColor : offset != 0 ? color : NSColor.secondaryLabelColor]
        let width = (name as NSString).size(withAttributes: attributes).width
        (name as NSString).draw(at: NSPoint(x: (bounds.midX - width / 2).rounded(), y: bounds.minY), withAttributes: attributes)
    }

    // Reachable with Tab when "Keyboard navigation" is on in the Mac's settings (like the switches).
    override var acceptsFirstResponder: Bool { isEnabled && NSApp.isFullKeyboardAccessEnabled }
    override var focusRingMaskBounds: NSRect {
        NSRect(x: (bounds.midX - knobSize / 2).rounded(), y: track.minY, width: knobSize, height: track.height)
    }
    override func drawFocusRingMask() {
        let ring = focusRingMaskBounds
        NSBezierPath(roundedRect: ring, xRadius: ring.width / 2, yRadius: ring.width / 2).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { super.keyDown(with: event); return }
        switch event.specialKey {
        case .downArrow?: set(offset - 1)
        case .upArrow?: set(offset + 1)
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(acceptsFirstResponder ? self : nil)  // also stops typing in a number
        if event.clickCount > 1 { grab = nil; set(0); return }  // double-click: back to automatic
        let point = convert(event.locationInWindow, from: nil)
        let k = knob
        guard point.y >= slider.minY - 2 || k.contains(point) else { grab = nil; return }  // a click on the name
        grab = k.insetBy(dx: -4, dy: -2).contains(point) ? point.y - k.midY : 0
        follow(point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard grab != nil else { return }
        follow(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) { grab = nil }

    // The knob goes where the mouse is: the offset is that place minus the automatic gain.
    private func follow(_ point: NSPoint) {
        let db = Float((point.y - (grab ?? 0) - middle) / reach) * Self.most
        set(max(-Self.most, min(Self.most, db)) - auto)
    }

    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled else { return false }
        set(offset + 1)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled else { return false }
        set(offset - 1)
        return true
    }

    // Steps of 0.5 dB from −12 to 12, and 0 (automatic) within 0.75 dB of it.
    private func set(_ new: Float) {
        let clean: Float = abs(new) < 0.75 ? 0 : max(-12, min(12, (new * 2).rounded() / 2))
        guard clean != offset else { return }
        offset = clean
        onChange(clean)
    }
}

// Auto EQ's five sections side by side (see EQBand), and a small Auto button at the right that puts all five back
// to automatic (dimmed while they already are).
final class AutoEQStrip: NSView {
    var onChange: ([Float]) -> Void = { _ in }  // the owner's five offsets, Sub first
    let bands: [EQBand]
    let reset = NSButton(title: "Auto", target: nil, action: nil)
    var isEnabled = true {
        didSet {
            bands.forEach { $0.isEnabled = isEnabled }
            updateReset()
        }
    }
    // Sizes for the window's scale (1 = smallest window).
    var scale: CGFloat = 1 {
        didSet {
            guard oldValue != scale else { return }
            bands.forEach { $0.scale = scale }
            styleReset()
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    init() {
        bands = AdvancedProcessor.sections.enumerated().map { i, name in
            EQBand(name: name, color: Theme.purple.blended(withFraction: CGFloat(i) / 4, of: Theme.pink)!)
        }
        super.init(frame: NSRect(x: 0, y: 0, width: 232, height: 60))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Auto EQ")
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        for band in bands {
            band.onChange = { [weak self] _ in self?.changed() }
            addSubview(band)
        }
        reset.bezelStyle = .rounded
        reset.target = self
        reset.action = #selector(resetAll)
        reset.setAccessibilityLabel("All back to automatic")
        addSubview(reset)
        styleReset()
        updateReset()
    }

    required init?(coder: NSCoder) { fatalError() }

    var offsets: [Float] {
        get { bands.map(\.offset) }
        set {
            for (band, value) in zip(bands, newValue) { band.offset = value }
            updateReset()
        }
    }

    // The automatic gains now (dB, Sub first). Tiny moves are skipped, so the sliders aren't redrawn for nothing.
    var auto: [Float] {
        get { bands.map(\.auto) }
        set {
            for (band, value) in zip(bands, newValue) where abs(band.auto - value) >= 0.05 || (value == 0 && band.auto != 0) {
                band.auto = value
            }
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: bands[0].intrinsicContentSize.height)
    }

    // The five sliders share the width left of the Auto button, which sits level with their middle marks.
    override func layout() {
        super.layout()
        let button = reset.intrinsicContentSize
        let buttonWidth = max(button.width, (44 * scale).rounded())
        let width = max(0, bounds.width - buttonWidth - (6 * scale).rounded()) / 5
        for (i, band) in bands.enumerated() {
            let left = (CGFloat(i) * width).rounded(), right = (CGFloat(i + 1) * width).rounded()
            band.frame = NSRect(x: left, y: 0, width: right - left, height: bounds.height)
        }
        reset.frame = NSRect(x: bounds.maxX - buttonWidth, y: (bands[0].middle - button.height / 2).rounded(),
                             width: buttonWidth, height: button.height)
    }

    // Small in a small window, regular once everything is 1.3 times bigger; its word in the icon's middle color.
    private func styleReset() {
        let large = Theme.controlSize(scale) == .large
        reset.controlSize = large ? .regular : .small
        reset.attributedTitle = NSAttributedString(string: "Auto", attributes: [
            .foregroundColor: Theme.mid, .font: NSFont.systemFont(ofSize: large ? 13 : 11, weight: .medium)])
        needsLayout = true
    }

    private func updateReset() { reset.isEnabled = isEnabled && offsets.contains { $0 != 0 } }

    private func changed() {
        updateReset()
        onChange(offsets)
    }

    @objc private func resetAll() {
        window?.makeFirstResponder(nil)
        guard offsets.contains(where: { $0 != 0 }) else { return }
        offsets = [Float](repeating: 0, count: 5)
        onChange(offsets)
    }
}

// The big number. Shows "+2" / "−1.5" / "0"; click it to type any amount from −24 to 24, Return to apply, Esc to
// cancel, ↑ ↓ to step by 1 while typing. A new number rolls in: up when higher, down when lower.
final class AmountField: NSTextField, NSTextFieldDelegate {
    var onCommit: (Float) -> Void = { _ in }
    var value: Float = 0 {
        didSet {
            guard !editing, oldValue != value || stringValue != Self.display(value) else { return }
            roll(to: Self.display(value), up: value > oldValue)
        }
    }
    // How strong the number looks: 1 = on, lower = waiting for sound or switched off.
    var strength: CGFloat = 1 {
        didSet {
            guard oldValue != strength else { return }
            if isShowing { Theme.animate(0.3) { animator().alphaValue = strength } } else { alphaValue = strength }
        }
    }
    // A soft background behind the number while the mouse is over it: shows it can be clicked.
    @objc dynamic var highlight: CGFloat = 0 { didSet { updatePill() } }
    private var editing = false { didSet { updatePill() } }
    private var cancelled = false
    private var hideText = false      // while the roll animation shows pictures of the old and new number
    private let pill = CALayer()
    private var ghosts: [CALayer] = []
    private var rolls = 0
    private var hoverArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = false
        isEditable = true
        isSelectable = true
        alignment = .center
        font = .monospacedDigitSystemFont(ofSize: 48, weight: .bold)
        focusRingType = .none
        usesSingleLineMode = true
        lineBreakMode = .byClipping
        delegate = self
        stringValue = Self.display(value)
    }

    required init?(coder: NSCoder) { fatalError() }

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "highlight" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }

    func setFontSize(_ points: CGFloat) {
        let size = (points * 2).rounded() / 2
        guard font?.pointSize != size else { return }
        font = .monospacedDigitSystemFont(ofSize: size, weight: .bold)
        updatePill()
    }

    override var stringValue: String {
        didSet { updatePill() }
    }

    static func display(_ value: Float) -> String {
        value == 0 ? "0" : (value > 0 ? "+" : "−") + plain(abs(value))
    }

    // 2.5 -> "2.5", 3.0 -> "3", -1.25 -> "-1.25"
    static func plain(_ value: Float) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    static func parse(_ text: String) -> Float? {
        var cleaned = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: ",", with: ".")
        if cleaned.hasPrefix("+") { cleaned.removeFirst() }
        guard let number = Float(cleaned), number.isFinite else { return nil }
        return clamp(number)
    }

    static func clamp(_ value: Float) -> Float { (min(24, max(-24, value)) * 100).rounded() / 100 }

    // Draws the number, then paints the icon's gradient over just the text.
    override func draw(_ dirtyRect: NSRect) {
        guard !hideText else { return }
        super.draw(dirtyRect)
        guard !editing, let context = NSGraphicsContext.current?.cgContext, let font else { return }
        let size = (stringValue as NSString).size(withAttributes: [.font: font])
        let textRect = NSRect(x: bounds.midX - size.width / 2, y: bounds.minY, width: size.width, height: bounds.height)
        context.saveGState()
        context.setBlendMode(.sourceAtop)
        Theme.gradient.draw(in: textRect, angle: 0)
        context.restoreGState()
    }

    // The soft background behind the number (its own layer, so it also shows while typing).
    private func updatePill() {
        guard let layer, let font else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if pill.superlayer == nil { layer.insertSublayer(pill, at: 0) }
        let text = editing ? (currentEditor()?.string ?? stringValue) : stringValue
        let width = max((text as NSString).size(withAttributes: [.font: font]).width, font.pointSize) + font.pointSize * (editing ? 0.9 : 0.7)
        let height = min(bounds.height, font.capHeight + font.pointSize * 0.45)
        // Centered on the digits (they sit a little above the middle of the line).
        let digitsMiddle = bounds.midY + (layer.isGeometryFlipped ? 1 : -1) * font.descender * 0.08
        pill.frame = NSRect(x: bounds.midX - width / 2, y: digitsMiddle - height / 2, width: width, height: height).integral
        pill.cornerRadius = height * 0.22
        effectiveAppearance.performAsCurrentDrawingAppearance {
            pill.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
        }
        pill.opacity = Float(editing ? 1 : highlight)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        updatePill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updatePill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hover(isEnabled)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hover(false)
    }

    override var isEnabled: Bool {
        didSet { if !isEnabled { hover(false) } }
    }

    private func hover(_ on: Bool) {
        let target: CGFloat = on ? 1 : 0
        guard highlight != target else { return }
        if isShowing { Theme.animate(0.15) { animator().highlight = target } } else { highlight = target }
    }

    // Shows a new number: the old one slides away and fades while the new one comes in.
    private func roll(to text: String, up: Bool) {
        ghosts.forEach { $0.removeFromSuperlayer() }
        ghosts = []
        hideText = false
        guard isShowing, let layer, let before = snapshot() else { stringValue = text; return }
        stringValue = text
        guard let after = snapshot() else { needsDisplay = true; return }
        rolls += 1
        let roll = rolls
        let distance = Theme.reduceMotion ? 0 : bounds.height * 0.22 * (up ? 1 : -1) * (layer.isGeometryFlipped ? -1 : 1)
        hideText = true
        needsDisplay = true

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.rolls == roll else { return }
            self.ghosts.forEach { $0.removeFromSuperlayer() }
            self.ghosts = []
            self.hideText = false
            self.needsDisplay = true
        }
        let parts: [(CGImage, CGFloat, CGFloat, Float, Float)] = [(before, 0, distance, 1, 0), (after, -distance, 0, 0, 1)]
        for (image, fromY, toY, fromOpacity, toOpacity) in parts {
            let ghost = CALayer()
            ghost.frame = layer.bounds
            ghost.contents = image
            ghost.contentsGravity = .resize
            layer.addSublayer(ghost)
            let move = CABasicAnimation(keyPath: "transform.translation.y")
            move.fromValue = fromY
            move.toValue = toY
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = fromOpacity
            fade.toValue = toOpacity
            let group = CAAnimationGroup()
            group.animations = [move, fade]
            group.duration = 0.22
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            ghost.add(group, forKey: "roll")
            ghosts.append(ghost)
        }
        CATransaction.commit()
    }

    private func snapshot() -> CGImage? {
        guard let picture = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: picture)
        return picture.cgImage
    }

    override func becomeFirstResponder() -> Bool {
        editing = true
        cancelled = false
        stringValue = Self.plain(value)
        let ok = super.becomeFirstResponder()
        if ok {
            needsDisplay = true
            DispatchQueue.main.async {
                (self.currentEditor() as? NSTextView)?.insertionPointColor = Theme.mid
                self.currentEditor()?.selectAll(nil)
                self.updatePill()
            }
        } else {
            editing = false
        }
        return ok
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) {
            cancelled = true
            window?.makeFirstResponder(nil)
            return true
        }
        if selector == #selector(insertNewline(_:)) {
            window?.makeFirstResponder(nil)
            return true
        }
        // ↑ ↓ step the typed number by 1 and apply it right away.
        if selector == #selector(moveUp(_:)) || selector == #selector(moveDown(_:)) {
            let typed = Self.parse(textView.string) ?? value
            let stepped = Self.clamp(typed + (selector == #selector(moveUp(_:)) ? 1 : -1))
            textView.string = Self.plain(stepped)
            textView.selectAll(nil)
            value = stepped
            onCommit(stepped)
            updatePill()
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) { updatePill() }

    func controlTextDidEndEditing(_ obj: Notification) {
        editing = false
        needsDisplay = true
        if !cancelled {
            if let number = Self.parse(stringValue) {
                if number != value { value = number }  // rolls to the new number
                onCommit(number)
            } else {
                NSSound.beep()
            }
        }
        stringValue = Self.display(value)
    }
}

// Clicking empty space in the window stops typing in the big number.
final class BackgroundView: NSView {
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(nil) }
}

// The dot next to "Pitch Shift Mic": grey, or green with a gentle pulse while a call app is listening.
final class StatusDot: NSView {
    var isLive = false { didSet { if oldValue != isLive { update() } } }
    private let dot = CALayer()
    private let halo = CALayer()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        wantsLayer = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 8, height: 8) }

    override func layout() {
        super.layout()
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if dot.superlayer == nil {
            layer.addSublayer(halo)
            layer.addSublayer(dot)
        }
        for part in [halo, dot] {
            part.frame = bounds
            part.cornerRadius = bounds.height / 2
        }
        CATransaction.commit()
        update()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        update()
    }

    private func update() {
        var color = NSColor.tertiaryLabelColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = (isLive ? NSColor.systemGreen : NSColor.tertiaryLabelColor).cgColor
        }
        dot.backgroundColor = color  // fades to the new color
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.backgroundColor = color
        halo.opacity = 0
        CATransaction.commit()
        let pulsing = halo.animation(forKey: "pulse") != nil
        guard isLive, !Theme.reduceMotion, window != nil else {
            if pulsing { halo.removeAnimation(forKey: "pulse") }
            return
        }
        guard !pulsing else { return }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 2.4
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.45
        fade.toValue = 0
        let pulse = CAAnimationGroup()
        pulse.animations = [grow, fade]
        pulse.duration = 2
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        halo.add(pulse, forKey: "pulse")
    }
}

// A full-width row in a card. `onScale` resizes its controls as the window grows (scale 1 = smallest window).
final class CardRow: NSStackView {
    var onScale: (CGFloat) -> Void = { _ in }
}

// A card's picker. While Pitch Shift Pro is locked (the Voice changer's voices) it's greyed out, and a click only calls
// onLockedClick (which opens the unlock window).
final class CardPicker: NSPopUpButton {
    var locked = false {
        didSet {
            guard oldValue != locked else { return }
            toolTip = locked ? "Pitch Shift Pro" : nil
            setAccessibilityHelp(locked ? "Pitch Shift Pro" : nil)
        }
    }
    var onLockedClick: () -> Void = {}

    override func mouseDown(with event: NSEvent) {
        if locked { onLockedClick(); return }
        super.mouseDown(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        if locked { onLockedClick(); return true }
        return super.accessibilityPerformPress()
    }
}

// One card: title + switch, big number, − 0 +, a picker, and any extra rows below (see addRow). A card made with
// `showsAmount: false` (the Voice changer) has no big number and no − 0 +.
final class ShiftCard: NSView {
    static let baseWidth: CGFloat = 266  // card width in the smallest window
    static let offStrength: CGFloat = 0.65  // how strong the number looks while the card is off
    let toggle = GradientSwitch()
    let amount = AmountField()
    let minus = NSButton()
    let zero = NSButton(title: "0", target: nil, action: nil)
    let plus = NSButton()
    let picker = CardPicker(frame: .zero, pullsDown: false)
    let showsAmount: Bool
    // Pitch Shift Pro is locked (the Voice changer card): the switch and the picker are locked (see GradientSwitch and
    // CardPicker), and a small lock shows after the title.
    var locked = false {
        didSet {
            guard oldValue != locked else { return }
            toggle.locked = locked
            picker.locked = locked
            showTitle()
        }
    }
    var onToggle: (Bool) -> Void = { _ in }
    var onAmount: (Float) -> Void = { _ in }
    var keyViews: [NSView] { showsAmount ? [toggle, amount, minus, zero, plus, picker] : [toggle, picker] }
    // A tooltip for − 0 + in place of their own.
    var buttonsTip: String? {
        didSet {
            guard oldValue != buttonsTip else { return }
            for (button, tip) in zip([minus, zero, plus], ["Down 1", "Back to 0", "Up 1"]) { button.toolTip = buttonsTip ?? tip }
        }
    }
    private(set) var scale: CGFloat = 0
    // The purple-pink edge shown while the card is on.
    @objc dynamic var glow: CGFloat = 0 { didSet { needsDisplay = true } }
    private let title: NSTextField
    private let header: NSStackView
    private let buttons: NSStackView
    private let stack = NSStackView()
    private var rows: [NSView] = []
    private var tightAfter: [NSView] = []  // rows followed by a tight row (see addRow)
    private var widths: [NSLayoutConstraint] = []
    private var buttonWidths: [NSLayoutConstraint] = []
    private var heights: [Int: CGFloat] = [:]  // height needed at each scale
    private var column: CGFloat = 232          // width of the rows
    private var active: Bool?
    private var numberActive: Bool?
    private var accessoryScale: ((CGFloat) -> Void)?  // sizes the views next to the picker (addPickerAccessory)
    var keepsLook: [NSView] = []  // rows that look the same while the card is off (they don't belong to its switch)

    // The title, with a small lock after it while Pitch Shift Pro is locked.
    private func showTitle() {
        guard locked, let font = title.font, let lock = GradientSlider.lockImage(size: font.pointSize - 2) else {
            title.stringValue = titleText
            title.toolTip = nil
            return
        }
        let words = NSMutableAttributedString(string: titleText + " ", attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let attachment = NSTextAttachment()
        attachment.image = lock
        attachment.bounds = NSRect(x: 0, y: ((font.capHeight - lock.size.height) / 2).rounded(), width: lock.size.width, height: lock.size.height)
        words.append(NSAttributedString(attachment: attachment))
        title.attributedStringValue = words
        title.toolTip = "Pitch Shift Pro"
    }
    private let titleText: String

    init(title text: String, extraRows: [NSView] = [], showsAmount: Bool = true) {
        titleText = text
        title = NSTextField(labelWithString: text)
        header = NSStackView(views: [title, toggle])
        buttons = NSStackView(views: [minus, zero, plus])
        self.showsAmount = showsAmount
        super.init(frame: NSRect(x: 0, y: 0, width: Self.baseWidth, height: 260))
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(text)

        header.distribution = .equalSpacing
        toggle.setAccessibilityLabel(text)
        toggle.onChange = { [weak self] in self?.onToggle($0) }
        amount.setAccessibilityLabel("\(text) amount")
        amount.onCommit = { [weak self] in self?.onAmount($0) }
        let parts = [(minus, #selector(lower), "Lower", "Down 1"), (zero, #selector(reset), "Back to 0", "Back to 0"), (plus, #selector(higher), "Higher", "Up 1")]
        for (button, action, name, tip) in parts {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            button.setAccessibilityLabel(name)
            button.toolTip = tip
            buttonWidths.append(button.widthAnchor.constraint(equalToConstant: 48))
        }
        NSLayoutConstraint.activate(buttonWidths)

        stack.orientation = .vertical
        stack.alignment = .centerX
        for view in showsAmount ? [header, amount, buttons, picker] : [header, picker] { stack.addArrangedSubview(view) }
        for view in showsAmount ? [header, amount, picker] : [header, picker] { widen(view) }
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        extraRows.forEach(addRow)
        apply(scale: 1)
        place(width: Self.baseWidth)
    }

    required init?(coder: NSCoder) { fatalError() }

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "glow" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }

    // Adds a full-width row at the bottom of the card (for example `ShiftCard.switchRow`). Add rows while
    // building the window, before it's laid out. `tight`: closer to the row above (it belongs with it).
    func addRow(_ row: NSView, tight: Bool) {
        if tight, let above = stack.arrangedSubviews.last {
            tightAfter.append(above)
            if scale > 0 { stack.setCustomSpacing((6 * scale).rounded(), after: above) }
        }
        addRow(row)
    }

    func addRow(_ row: NSView) {
        stack.addArrangedSubview(row)
        widen(row)
        rows.append(row)
        if scale > 0 { (row as? CardRow)?.onScale(scale) }
        heights = [:]
    }

    // Small views to the right of the picker, in its row (the Voice changer's voices button). `onScale` sizes them.
    func addPickerAccessory(_ views: [NSView], onScale: @escaping (CGFloat) -> Void) {
        guard let index = stack.arrangedSubviews.firstIndex(of: picker) else { return }
        if let width = widths.first(where: { $0.firstItem === picker }) {
            width.isActive = false
            widths.removeAll { $0 === width }
        }
        stack.removeArrangedSubview(picker)
        let row = NSStackView(views: [picker] + views)
        row.distribution = .fill  // the picker takes the room the views leave
        row.spacing = 6
        picker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in views { view.setContentHuggingPriority(.required, for: .horizontal) }
        stack.insertArrangedSubview(row, at: index)
        widen(row)
        accessoryScale = onScale
        if scale > 0 { onScale(scale) }
        heights = [:]
    }

    // A row with a label on the left and a small switch on the right, for settings like "Advanced processing".
    // The label dims while the switch can't be used. `notes`: small views right after the label (shown when needed).
    // While Pitch Shift Pro is locked, the label dims and gets a small lock after it.
    static func switchRow(_ text: String, _ toggle: GradientSwitch, notes: [NSView] = []) -> CardRow {
        let label = NSTextField(labelWithString: text)
        func show() {
            label.toolTip = toggle.locked ? "Pitch Shift Pro" : nil
            guard toggle.locked, let font = label.font, let lock = GradientSlider.lockImage(size: font.pointSize - 2) else {
                if label.stringValue != text { label.stringValue = text }
                label.textColor = toggle.looksEnabled && !toggle.locked ? .secondaryLabelColor : .tertiaryLabelColor
                return
            }
            let words = NSMutableAttributedString(string: text + " ", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])
            let attachment = NSTextAttachment()
            attachment.image = lock
            attachment.bounds = NSRect(x: 0, y: ((font.capHeight - lock.size.height) / 2).rounded(), width: lock.size.width, height: lock.size.height)
            words.append(NSAttributedString(attachment: attachment))
            label.attributedStringValue = words
        }
        label.textColor = toggle.looksEnabled ? .secondaryLabelColor : .tertiaryLabelColor
        toggle.onEnabled = { _ in show() }
        toggle.onLocked = { _ in show() }
        toggle.setAccessibilityLabel(text)
        let left = NSStackView(views: [label] + notes)
        left.spacing = 5
        let row = CardRow(views: [notes.isEmpty ? label : left, toggle])
        row.distribution = .equalSpacing
        row.onScale = { scale in
            label.font = .systemFont(ofSize: 12 + (scale - 1) * 2.5)
            toggle.size = Theme.controlSize(scale) == .large ? NSSize(width: 38, height: 22) : NSSize(width: 32, height: 19)
            if toggle.locked { show() }
        }
        return row
    }

    private func widen(_ view: NSView) {
        let width = view.widthAnchor.constraint(equalToConstant: widths.first?.constant ?? 232)
        width.isActive = true
        widths.append(width)
    }

    // Sizes everything for a scale (1 = smallest window) and clears the extra spacing from `spread`.
    func apply(scale s: CGFloat) {
        if s != scale {
            scale = s
            let size = Theme.controlSize(s)
            title.font = .systemFont(ofSize: 13 + (s - 1) * 2.5, weight: .semibold)
            if locked { showTitle() }
            toggle.size = size == .large ? NSSize(width: 44, height: 26) : NSSize(width: 38, height: 22)
            for button in [minus, zero, plus] { button.useSize(size) }
            buttonWidths.forEach { $0.constant = (48 * s).rounded() }
            buttons.spacing = (8 * s).rounded()
            // − 0 + in the icon's middle color (plain tinting doesn't apply to these buttons).
            let glyph = NSImage.SymbolConfiguration(pointSize: Theme.fontSize(size), weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [Theme.mid]))
            minus.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Lower")?.withSymbolConfiguration(glyph)
            plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Higher")?.withSymbolConfiguration(glyph)
            zero.attributedTitle = NSAttributedString(string: "0", attributes: [
                .foregroundColor: Theme.mid, .font: NSFont.systemFont(ofSize: Theme.fontSize(size), weight: .medium)])
            picker.useSize(size)
            accessoryScale?(s)
            stack.edgeInsets = NSEdgeInsets(top: (14 * s).rounded(), left: 0, bottom: (16 * s).rounded(), right: 0)
            stack.spacing = (12 * s).rounded()
            if showsAmount { stack.setCustomSpacing((8 * s).rounded(), after: amount) }
            tightAfter.forEach { stack.setCustomSpacing((6 * s).rounded(), after: $0) }
            rows.forEach { ($0 as? CardRow)?.onScale(s) }
            needsDisplay = true
        }
        spread(0)
    }

    // Fits the rows to the card's width (in a very wide card they stop growing and stay centered).
    func place(width: CGFloat) {
        column = min(width - 34 * scale, 232 * scale * 1.35).rounded()
        for width in widths where width.constant != column { width.constant = column }
    }

    // Extra height first makes the number bigger (while the widest number, "−23.75", still fits), then the rest
    // goes above the number and below the − 0 + buttons, so a tall card stays balanced. A card without the number
    // keeps its rows at the top.
    func spread(_ extra: CGFloat) {
        guard showsAmount else { return }
        let base = 48 * scale
        amount.setFontSize(base)
        let baseHeight = amount.intrinsicContentSize.height
        amount.setFontSize(max(base, min(base + extra * 0.4, base * 1.5, column / Self.widestNumber)))
        let left = max(0, extra - (amount.intrinsicContentSize.height - baseHeight))
        stack.setCustomSpacing((4 * scale + left / 2).rounded(), after: header)
        stack.setCustomSpacing((16 * scale + left / 2).rounded(), after: buttons)
    }

    private static let widestNumber = ("−23.75" as NSString)
        .size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 100, weight: .bold)]).width / 100

    // The height the card needs at a scale (leaves the card sized for that scale).
    func neededHeight(at s: CGFloat) -> CGFloat {
        let key = Int((s * 100).rounded())
        if let height = heights[key] { return height }
        apply(scale: s)
        let height = stack.fittingSize.height.rounded(.up)
        heights[key] = height
        return height
    }

    // Call when a row is shown or hidden.
    func forgetHeights() { heights = [:] }

    // Updates the number and buttons; `active` shows the card off (everything in it still works then, a little
    // fainter: the settings are used when the card is turned on), `waiting` fades just the number (on, but the
    // chosen app isn't making sound), `amountActive: false` dims just the number and − 0 + (the Voice changer sets
    // the pitch instead).
    func show(on: Bool, value: Float, active: Bool, waiting: Bool = false, amountActive: Bool? = nil) {
        let faded = self.active != nil && active != self.active  // everything crossfades
        show(on: on, active: active)
        amount.value = value
        let numberActive = amountActive ?? true
        if numberActive != self.numberActive {
            if self.numberActive != nil && !faded { Theme.crossfade(buttons, 0.25) }
            self.numberActive = numberActive
        }
        amount.isEnabled = numberActive
        amount.strength = numberActive ? (active ? (waiting ? 0.5 : 1) : Self.offStrength) : 0.4
        minus.isEnabled = numberActive && value > -24
        plus.isEnabled = numberActive && value < 24
        zero.isEnabled = numberActive && value != 0
    }

    // The switch and the purple-pink edge, for a card without the number (`active` dims it when it's off).
    func show(on: Bool, active: Bool) {
        toggle.isOn = on
        guard active != self.active else { return }
        if self.active != nil { ((showsAmount ? [amount, buttons, picker] : [picker]) + rows).forEach { Theme.crossfade($0, 0.25) } }
        self.active = active
        let target: CGFloat = active ? 1 : 0
        if isShowing { Theme.animate(0.25) { animator().glow = target } } else { glow = target }
        // A card with the number that's off: everything in it still works, a little fainter (like the number).
        guard showsAmount else { return }
        let soft = active ? 1 : Self.offStrength
        for view in [buttons, picker] + rows where !keepsLook.contains(view) {
            if isShowing { Theme.animate(0.25) { view.animator().alphaValue = soft } } else { view.alphaValue = soft }
        }
    }

    // The card: rounded, a soft shadow, and the purple-pink edge while on.
    override func draw(_ dirtyRect: NSRect) {
        let radius = 12 + (max(scale, 1) - 1) * 5
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        NSColor.controlBackgroundColor.setFill()
        shape.fill()
        NSColor.separatorColor.setStroke()
        shape.stroke()
        guard glow > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: radius - 0.25, yRadius: radius - 0.25)
        context.saveGState()
        context.setAlpha(glow * 0.55)
        context.addPath(edge.cgPath)
        context.setLineWidth(1.5)
        context.replacePathWithStrokedPath()
        context.clip()
        Theme.gradient.draw(in: bounds, angle: 0)
        context.restoreGState()
    }

    override func layout() {
        super.layout()
        let radius = 12 + (max(scale, 1) - 1) * 5
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateShadow()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateShadow()
        needsDisplay = true
    }

    private func updateShadow() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let depth = NSShadow()
        depth.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.35 : 0.09)
        depth.shadowBlurRadius = dark ? 6 : 5
        depth.shadowOffset = NSSize(width: 0, height: -1)
        shadow = depth
    }

    @objc private func lower() { step(-1) }
    @objc private func higher() { step(1) }
    @objc private func reset() {
        window?.makeFirstResponder(nil)
        onAmount(0)
    }

    private func step(_ by: Float) {
        window?.makeFirstResponder(nil)  // applies anything being typed first
        onAmount(AmountField.clamp(amount.value + by))
    }
}

enum Keys {
    static let hearOn = "hearOn", hearSource = "hearSource", halfSteps = "halfSteps", hearAdvanced = "hearAdvanced"
    static let hearSuper = "hearSuper"
    static let hideAdvancedAlert = "hideAdvancedAlert"  // "Don't show again" was ticked
    // Advanced processing's Bass ↔ Treble for each speakers or headphones: [device UID: −1 (bass) … 0 … 1 (treble)].
    // Only what was picked on the slider is stored.
    static let hearTone = "hearTone"
    // Advanced processing's Auto EQ for each speakers or headphones: [device UID: ["on": Bool, "offsets": five Floats,
    // dB, Sub … Air]]. Only what the owner changed is stored; anything missing is off with no offsets.
    static let hearAutoEQ = "hearAutoEQ"
    static let voiceOn = "voiceOn", voiceSteps = "voiceSteps", voiceMic = "voiceMic"
    static let voiceCartoon = "voiceCartoon"  // voice style, 0 (Natural) to 1 (Cartoon)
    static let voiceNatural = "voiceNatural"  // the old Natural/Cartoon switch (version 2.0), read once to carry over
    static let voiceSlowDeeper = "voiceSlowDeeper"  // "Deeper when slow"
    static let voiceFastHigher = "voiceFastHigher"  // "Higher when fast": 0 (off) ... 8 half-steps (not set: +4)
    // The Voice changer: on/off, the voice's id ("woman", "man", or an added voice), Strength 0 (light) ... 1 (full),
    // and "Faster ↔ More real" 0 ... 1 (ChangerSettings.realism). changerQuality ("natural" / "realistic", the
    // switch before the slider) is read once to carry over, then removed.
    static let changerOn = "changerOn", changerVoice = "changerVoice", changerStrength = "changerStrength"
    static let changerRealism = "changerRealism", changerQuality = "changerQuality"
    // 3.5: the AI voice's second voice for hums, laughs, sighs, singing (not set: on)
    static let changerSounds = "changerSounds"
    // 3.5: "Block background sounds" (not set: off)
    static let changerQuiet = "changerQuiet"
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let defaults = UserDefaults.standard
    // While Pitch Shift Pro is locked, the paid settings use the free version's values (Free); what's saved is kept.
    lazy var hear = HearShifter(
        halfSteps: defaults.object(forKey: Keys.halfSteps) as? Float ?? 2,
        source: HearSource(saved: defaults.string(forKey: Keys.hearSource) ?? defaults.string(forKey: "source")),
        advanced: defaults.bool(forKey: Keys.hearAdvanced), heavy: defaults.bool(forKey: Keys.hearSuper),
        tones: Pro.shared.unlocked ? AppDelegate.savedTones(defaults) : [:],
        autoEQs: Pro.shared.unlocked ? AppDelegate.savedAutoEQs(defaults) : [:])
    lazy var voice = VoiceShifter(
        halfSteps: defaults.object(forKey: Keys.voiceSteps) as? Float ?? 3,
        cartoon: Pro.shared.unlocked ? AppDelegate.savedCartoon(defaults) : Free.cartoon,
        slowDeeper: Pro.shared.unlocked ? defaults.bool(forKey: Keys.voiceSlowDeeper) : Free.slowDeeper,
        fastHigher: Pro.shared.unlocked ? AppDelegate.savedFastHigher(defaults) : Free.fastHigher,
        micUID: defaults.string(forKey: Keys.voiceMic))
    lazy var test = VoiceTest(voice: voice)
    // Sound effects into Pitch Shift Mic. Pictures show example names and change nothing.
    lazy var board = Soundboard(voice: voice, sounds: preview == nil ? Soundboard.saved(defaults) : Soundboard.examples,
                                saves: preview == nil)
    lazy var soundboard = SoundboardPanel(board: board)

    // The saved voice style. Version 2.0 had a Natural/Cartoon switch instead: the first launch of this version turns
    // it into the slider's setting (Natural 0, Cartoon 1) and removes it; from then on only voiceCartoon is used.
    static func savedCartoon(_ defaults: UserDefaults) -> Float {
        if let natural = defaults.object(forKey: Keys.voiceNatural) as? Bool {
            let value: Float = natural ? 0 : 1
            if preview == nil {  // pictures change nothing
                defaults.set(value, forKey: Keys.voiceCartoon)
                defaults.removeObject(forKey: Keys.voiceNatural)
            }
            return value
        }
        guard let value = (defaults.object(forKey: Keys.voiceCartoon) as? NSNumber)?.floatValue, value.isFinite else { return 0 }
        return max(0, min(1, value))
    }

    // "Higher when fast" as saved, in whole half-steps (not set yet: +4).
    static let fastHigherDefault: Float = 4
    static func savedFastHigher(_ defaults: UserDefaults) -> Float {
        guard let value = (defaults.object(forKey: Keys.voiceFastHigher) as? NSNumber)?.floatValue else { return fastHigherDefault }
        return VoiceShifter.cleanFastHigher(value.rounded())
    }

    // The saved Bass ↔ Treble per speakers or headphones (device UID → −1 … 1).
    static func savedTones(_ defaults: UserDefaults) -> [String: Float] {
        var tones: [String: Float] = [:]
        for (uid, saved) in defaults.dictionary(forKey: Keys.hearTone) ?? [:] {
            guard let value = (saved as? NSNumber)?.floatValue, value.isFinite else { continue }
            tones[uid] = max(-1, min(1, value))
        }
        return tones
    }

    // The Voice changer as saved (before the voice starts). Pictures show Woman (Man with changer-man), Strength 1 (or
    // --strength), the AI voice at the slider's default with changer-realistic/-loading/-fallback, the slider at
    // changer-slider-natural / -fast / -default / -max / -NN (NN percent), and save nothing. changer-card-off: the
    // same settings with the card's switch off; changer-quiet-on: "Block background sounds" on (3.5).
    func restoreChanger() {
        if let preview {
            // (off while Pitch Shift Pro is locked)
            voice.changer.on = preview.contains("changer") && !preview.contains("changer-card-off") && Pro.shared.unlocked
            voice.changer.voiceID = arg("--voice").flatMap { VoiceLibrary.shared.voice($0)?.id }
                ?? (preview.contains("changer-man") ? "man" : "woman")  // --voice NAME: that voice (an added one too)
            voice.changer.strength = arg("--strength").flatMap(Float.init).map { max(0, min(1, $0)) } ?? 1
            var realism: Float = ["changer-realistic", "changer-loading", "changer-fallback"].contains { preview.contains($0) }
                ? ChangerSettings.defaultRealism : 0
            if let range = preview.range(of: "changer-slider-") {
                let word = preview[range.upperBound...].prefix { $0.isLetter || $0.isNumber }
                switch word {
                case "natural": realism = 0
                case "fast": realism = ChangerSettings.aiStart
                case "default": realism = ChangerSettings.defaultRealism
                case "max": realism = 1
                default: realism = Float(word).map { max(0, min(1, $0 / 100)) } ?? ChangerSettings.defaultRealism
                }
            }
            voice.changer.realism = realisticOffered ? realism : 0
            voice.changer.second = !preview.contains("changer-second-off")  // 3.5
            voice.changer.quiet = preview.contains("changer-quiet-on")
            previewVoice = preview.contains("voice-on") && !voice.changer.on  // only one at a time: the changer wins
            return
        }
        // The Voice changer is part of Pitch Shift Pro: off while it's locked (what was saved is kept for later).
        voice.changer.on = defaults.bool(forKey: Keys.changerOn) && Pro.shared.unlocked
        // A voice that was removed: Woman is used, and the saved choice is kept.
        let saved = defaults.string(forKey: Keys.changerVoice) ?? "woman"
        voice.changer.voiceID = VoiceLibrary.shared.voice(saved)?.id ?? "woman"
        let strength = (defaults.object(forKey: Keys.changerStrength) as? NSNumber)?.floatValue ?? 1
        voice.changer.strength = strength.isFinite ? max(0, min(1, strength)) : 1
        // The slider; the Realistic switch of the version before becomes its default AI position (or Natural).
        if let quality = defaults.string(forKey: Keys.changerQuality) {
            defaults.set(quality == "realistic" ? ChangerSettings.defaultRealism : 0, forKey: Keys.changerRealism)
            defaults.removeObject(forKey: Keys.changerQuality)
        }
        // Not set yet: the slider's default (the AI voice with the least delay that speaks smoothly).
        let realism = (defaults.object(forKey: Keys.changerRealism) as? NSNumber)?.floatValue ?? ChangerSettings.defaultRealism
        voice.changer.realism = realisticOffered && realism.isFinite ? max(0, min(1, realism)) : 0
        voice.changer.second = defaults.object(forKey: Keys.changerSounds) as? Bool ?? true  // 3.5
        voice.changer.quiet = defaults.bool(forKey: Keys.changerQuiet)
    }

    // Realistic voices need Apple silicon (the Intel half of the app has no AI). Pictures: changer-intel shows the
    // card as on an Intel Mac (the slider stays at Natural).
    var realisticOffered: Bool {
        #if arch(arm64)
        return preview?.contains("changer-intel") != true
        #else
        return false
        #endif
    }

    // The saved Auto EQ per speakers or headphones (device UID → on, and the five offsets in dB).
    static func savedAutoEQs(_ defaults: UserDefaults) -> [String: AutoEQSetting] {
        var settings: [String: AutoEQSetting] = [:]
        for (uid, saved) in defaults.dictionary(forKey: Keys.hearAutoEQ) ?? [:] {
            guard let saved = saved as? [String: Any] else { continue }
            let offsets = (saved["offsets"] as? [Any] ?? []).map { ($0 as? NSNumber)?.floatValue ?? 0 }
            settings[uid] = AutoEQSetting(on: (saved["on"] as? NSNumber)?.boolValue ?? false, offsets: offsets)
        }
        return settings
    }

    var window: NSWindow!
    var hearCard: ShiftCard!
    var voiceCard: ShiftCard!
    var changerCard: ShiftCard!
    private var previewVoice = false  // pictures: Your voice shown on (nothing runs)
    // The Voice changer's Strength (0 = light, 1 = full) and its "Faster ↔ More real" slider (0 = Natural, then the AI
    // voice, Apple silicon, hearing further ahead), with the delay it gives under it.
    let strength = GradientSlider(left: "Light", right: "Full", name: "Strength") { value in
        value <= 0 ? "Light" : value >= 1 ? "Full" : "\(Int((value * 100).rounded())) percent"
    }
    let realism = GradientSlider(left: "Faster", right: "More real", name: "Faster or more real") { _ in "" }
    let delayLabel = NSTextField(labelWithString: "Delay: about 0.1 s")
    let realisticLoading = NSProgressIndicator()  // while the realistic voice is being prepared
    // 3.5 (one place: this switch, its row in the card, Tab order, showSecond, secondPicked): the AI voice's second
    // voice for hums, laughs, sighs and singing; talking always uses the main voice
    let secondSwitch = GradientSwitch()
    static let secondText = "Second voice for laughs & hums"
    // 3.5: off until turned on, because that voice sounds a little different
    let quietSwitch = GradientSwitch()
    var quietRow: CardRow!
    static let quietText = "Block background sounds"
    let realisticWarning = NSImageView()          // it fell behind, or can't run (the tooltip says why)
    var delayRow: CardRow!
    private var realismApply: DispatchWorkItem?   // a slider move is used once the knob rests (no new chain mid-drag)
    lazy var voiceTools = VoiceTools(app: self)  // the voices button next to the voice picker (VoiceTools.swift)
    let advancedSwitch = GradientSwitch()
    let superSwitch = GradientSwitch()
    let style = GradientSlider(left: "Natural", right: "Cartoon", name: "Voice style") { value in
        value <= 0 ? "Natural" : value >= 1 ? "Cartoon" : "\(Int((value * 100).rounded())) percent Cartoon"
    }
    let slowSwitch = GradientSwitch()  // "Deeper when slow"
    // "Higher when fast" (used while Deeper when slow is on): Off, then 1 ... 8 half-steps higher when talking fast.
    let fastSlider = GradientSlider(left: "Off", right: "+8", name: "Higher when fast") { value in
        let steps = Int((value * SpeakingRate.maxUp).rounded())
        return steps == 0 ? "Off" : "\(steps) half-steps higher"
    }
    let fastLabel = NSTextField(labelWithString: "Higher when fast")
    // Advanced processing's tone for the speakers or headphones playing now: 0 = more bass, 0.5 = middle, 1 = more treble.
    let tone = GradientSlider(left: "Bass", right: "Treble", name: "Tone") { value in
        let percent = Int(((value * 2 - 1) * 100).rounded())
        return percent == 0 ? "Middle" : "\(abs(percent)) percent more \(percent < 0 ? "bass" : "treble")"
    }
    // Auto EQ (Advanced processing), also kept for each speakers or headphones: a switch, and while it's on, five
    // small sliders that follow the sound (see updateAutoEQTimer).
    let autoEQSwitch = GradientSwitch()
    let autoEQStrip = AutoEQStrip()
    private var autoEQRow: CardRow!
    private var autoEQTimer: Timer?
    // The speakers or headphones playing now (followed even while What you hear is off).
    private var outputListener: Listener?
    private var outputUID = "", outputName = ""
    let testButton = NSButton(title: "Test", target: nil, action: nil)
    let soundsButton = NSButton(title: "Sounds", target: nil, action: nil)  // opens the Soundboard
    let dot = StatusDot()
    let micName = NSTextField(labelWithString: "Pitch Shift Mic")
    let installButton = NSButton(title: "Install Pitch Shift Mic", target: nil, action: nil)
    var footer: CardRow!
    // "Unlock Pro" in the title bar while Pitch Shift Pro is locked.
    let unlockButton = NSButton(title: "Unlock Pro", target: nil, action: nil)
    let unlockAccessory = NSTitlebarAccessoryViewController()
    private var soundsSize: NSControl.ControlSize = .regular
    private var installed: Bool?
    private var lastPhase: VoiceTest.Phase = .idle
    private var deviceListeners: [Listener] = []  // keep the mic picker right when devices change
    private let deviceDebounce = Debouncer(0.3)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep the colorful icon in the Dock (macOS's dark icon style would otherwise turn it grey).
        // At 256 points: still twice the biggest Dock icon, and ~6 MB less memory than the file's full 512 points.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            icon.size = NSSize(width: 256, height: 256)
            NSApp.applicationIconImage = icon
        }
        buildMenu()
        restoreChanger()
        buildWindow()
        // The tone slider shows the setting of the speakers or headphones playing now, and follows a change.
        outputListener = Listener(system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.outputMoved() }
        outputMoved()
        Pro.shared.onChange = { [weak self] in self?.proChanged() }
        hear.onChange = { [weak self] in self?.refresh() }
        voice.onChange = { [weak self] in self?.refresh() }
        test.onChange = { [weak self] in self?.endTestAlone(); self?.refresh() }
        board.onChange = { [weak self] in self?.soundboard.update() }
        soundboard.onClose = { [weak self] in self?.soundboardClosed() }
        deviceListeners = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice].map {
            Listener(system, $0) { [weak self] in self?.deviceDebounce.call { self?.refresh() } }
        }
        refresh()
        showWindow()
        if preview != nil { showPreview(); return }
        // Show the window first: the first time, macOS asks for permission to grab sound and waits for an answer.
        DispatchQueue.main.async { [self] in
            if defaults.object(forKey: Keys.hearOn) as? Bool ?? true { hear.start() }
            // Each asks for mic permission again if needed (each update looks like a new app to macOS). Saved both on
            // (an older version allowed it): the changer wins, Your voice goes off.
            if voice.changer.on {
                setChanger(true)
            } else if defaults.bool(forKey: Keys.voiceOn) {
                setVoice(true)
            } else {
                DefaultMic.giveBack()  // in case the app didn't close cleanly last time
            }
            refresh()
        }
    }

    // Clicking the app on the Desktop or in the Dock while it's running brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        hear.stop()
        voice.stopAll()
        DefaultMic.giveBack()
    }

    func showWindow() {
        if preview != nil {
            // Pictures: the window stays out of sight under the desktop picture (screencapture -l still sees it), so
            // it never covers what's on screen, can't be clicked, and never switches apps.
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
            window.orderBack(nil)
            window.makeFirstResponder(nil)
            return
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Building

    func buildMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [(String, Selector, String, NSEvent.ModifierFlags)]) {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            for (name, action, key, modifiers) in items {
                if name == "-" { menu.addItem(.separator()); continue }
                let entry = menu.addItem(withTitle: name, action: action, keyEquivalent: key)
                entry.keyEquivalentModifierMask = modifiers
            }
            item.submenu = menu
            main.addItem(item)
        }
        // "Unlock Pitch Shift Pro…" (or "Pitch Shift Pro…" once unlocked) only in builds with the server set up.
        let pro: [(String, Selector, String, NSEvent.ModifierFlags)] = Pro.shared.enabled
            ? [(Pro.shared.unlocked ? "Pitch Shift Pro…" : "Unlock Pitch Shift Pro…", #selector(showUnlock), "", []),
               ("-", #selector(showUnlock), "", [])]
            : []
        submenu("Pitch Shift", pro + [
            ("Hide Pitch Shift", #selector(NSApplication.hide(_:)), "h", .command),
            ("-", #selector(NSApplication.hide(_:)), "", []),
            ("Quit Pitch Shift", #selector(NSApplication.terminate(_:)), "q", .command),
        ])
        submenu("Edit", [
            ("Undo", Selector(("undo:")), "z", .command),
            ("Redo", Selector(("redo:")), "z", [.command, .shift]),
            ("-", #selector(NSText.cut(_:)), "", []),
            ("Cut", #selector(NSText.cut(_:)), "x", .command),
            ("Copy", #selector(NSText.copy(_:)), "c", .command),
            ("Paste", #selector(NSText.paste(_:)), "v", .command),
            ("Select All", #selector(NSText.selectAll(_:)), "a", .command),
        ])
        submenu("Window", [
            ("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", .command),
            ("Zoom", #selector(NSWindow.performZoom(_:)), "", []),
            ("Close", #selector(NSWindow.performClose(_:)), "w", .command),
        ])
        NSApp.mainMenu = main
    }

    func buildWindow() {
        hearCard = ShiftCard(title: "Output pitch shifter")
        hearCard.picker.pullsDown = true  // a menu of apps to tick, not a single choice
        hearCard.picker.menu?.delegate = self
        hearCard.picker.target = self
        hearCard.picker.action = #selector(hearSourcePicked)
        hearCard.picker.setAccessibilityLabel("Apps")
        hearCard.onToggle = { [weak self] on in self?.setHear(on) }
        hearCard.onAmount = { [weak self] value in
            self?.hear.halfSteps = value
            self?.defaults.set(value, forKey: Keys.halfSteps)
            self?.refresh()
        }
        // Advanced processing (music): keeps the song balanced at big shifts. Turning it on asks first.
        advancedSwitch.onChange = { [weak self] on in self?.advancedPicked(on) }
        hearCard.addRow(ShiftCard.switchRow("Advanced processing", advancedSwitch))
        // Super Advanced (heavy songs). Free. It and Advanced processing turn each other off.
        superSwitch.onChange = { [weak self] on in self?.superPicked(on) }
        hearCard.addRow(ShiftCard.switchRow("Super Advanced", superSwitch))
        // Advanced processing's tone, Bass ... Treble, kept for each speakers or headphones.
        tone.mark = 0.5
        tone.onChange = { [weak self] value in self?.tonePicked(value) }
        // Locked controls (Pitch Shift Pro) only open the unlock window.
        for slider in [tone, style, strength, realism, fastSlider] { slider.onLockedClick = { [weak self] in self?.showUnlock() } }
        for toggle in [slowSwitch, autoEQSwitch] { toggle.onLockedClick = { [weak self] in self?.showUnlock() } }
        let toneRow = CardRow(views: [tone])
        toneRow.onScale = { [unowned self] scale in
            tone.scale = scale
            tone.rowHeight = Theme.controlSize(scale) == .large ? 22 : 19  // like the Advanced processing switch
        }
        hearCard.addRow(toneRow, tight: true)
        // Auto EQ: keeps Sub, Bass, Mids, Highs and Air near the song's own balance. While it's on, five small sliders
        // show its gains as they move and take a nudge. Kept for each speakers or headphones.
        autoEQSwitch.onChange = { [weak self] on in self?.autoEQPicked(on: on) }
        hearCard.addRow(ShiftCard.switchRow("Auto EQ", autoEQSwitch))
        autoEQStrip.onChange = { [weak self] offsets in self?.autoEQPicked(offsets: offsets) }
        autoEQRow = CardRow(views: [autoEQStrip])
        autoEQRow.isHidden = true
        autoEQRow.onScale = { [unowned self] scale in autoEQStrip.scale = scale }
        hearCard.addRow(autoEQRow, tight: true)

        style.onChange = { [weak self] value in self?.stylePicked(value) }
        testButton.bezelStyle = .rounded
        testButton.bezelColor = Theme.purple
        testButton.target = self
        testButton.action = #selector(testClicked)
        testButton.toolTip = "Record 5 seconds, then play it back"
        let testWidth = testButton.widthAnchor.constraint(equalToConstant: 72)
        testWidth.isActive = true
        let styleRow = CardRow(views: [style, testButton])
        styleRow.distribution = .fill
        styleRow.alignment = .top  // the slider's track lines up with the middle of Test; its labels hang below
        styleRow.onScale = { [unowned self, unowned styleRow] scale in
            testButton.useSize(Theme.controlSize(scale))
            testWidth.constant = (72 * scale).rounded()
            style.scale = scale
            style.rowHeight = testButton.intrinsicContentSize.height
            styleRow.spacing = (10 * scale).rounded()
        }

        micName.textColor = .secondaryLabelColor
        installButton.bezelStyle = .rounded
        installButton.target = self
        installButton.action = #selector(installDriver)
        // Sounds sits right under Test, the same width.
        soundsButton.bezelStyle = .rounded
        soundsButton.target = self
        soundsButton.action = #selector(soundsClicked)
        let soundsWidth = soundsButton.widthAnchor.constraint(equalToConstant: 72)
        soundsWidth.isActive = true
        footer = CardRow()
        footer.distribution = .gravityAreas
        for view in [dot, micName, installButton] { footer.addView(view, in: .leading) }
        footer.addView(soundsButton, in: .trailing)
        footer.onScale = { [unowned self] scale in
            let size = Theme.controlSize(scale)
            micName.font = .systemFont(ofSize: 11 + (scale - 1) * 2.5)
            installButton.useSize(size)
            soundsButton.useSize(size)
            soundsSize = size
            styleSounds()
            soundsWidth.constant = (72 * scale).rounded()
            footer.spacing = (6 * scale).rounded()
        }

        // Deeper when slow: talking slowly makes the voice lower.
        slowSwitch.onChange = { [weak self] on in self?.slowPicked(on) }
        let slowRow = ShiftCard.switchRow("Deeper when slow", slowSwitch)
        // Higher when fast, right under it (it belongs with it): talking fast makes the voice higher, by up to the
        // slider's amount. The label sits left of the slider; the slider's track lines up with the label's middle.
        fastSlider.steps = SpeakingRate.maxUp  // whole half-steps
        fastSlider.onChange = { [weak self] value in self?.fastPicked(value) }
        fastLabel.setAccessibilityElement(false)  // the slider says it
        fastLabel.setContentHuggingPriority(.required, for: .horizontal)
        fastLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let fastRow = CardRow(views: [fastLabel, fastSlider])
        fastRow.distribution = .fill
        fastRow.alignment = .top
        fastRow.onScale = { [unowned self, unowned fastRow] scale in
            fastLabel.font = .systemFont(ofSize: 12 + (scale - 1) * 2.5)  // like the switch rows' labels
            fastSlider.scale = scale
            fastSlider.rowHeight = fastLabel.intrinsicContentSize.height
            fastRow.spacing = (10 * scale).rounded()
        }

        voiceCard = ShiftCard(title: "Input pitch shifter", extraRows: [styleRow, slowRow])
        voiceCard.addRow(fastRow, tight: true)
        voiceCard.addRow(footer)
        voiceCard.keepsLook = [footer]  // Pitch Shift Mic and the Soundboard work whether the voice is on or off
        voiceCard.picker.menu?.delegate = self
        voiceCard.picker.target = self
        voiceCard.picker.action = #selector(micPicked)
        voiceCard.picker.setAccessibilityLabel("Microphone")
        voiceCard.onToggle = { [weak self] on in self?.setVoice(on) }
        voiceCard.onAmount = { [weak self] value in
            guard let self else { return }
            voice.halfSteps = value
            if preview == nil { defaults.set(value, forKey: Keys.voiceSteps) }
            refresh()
        }

        // The Voice changer: a voice (Woman, Man, then added voices), how strong, and Natural or Realistic.
        strength.onChange = { [weak self] value in self?.strengthPicked(value) }
        let strengthRow = CardRow(views: [strength])
        strengthRow.onScale = { [unowned self] scale in
            strength.scale = scale
            strength.rowHeight = Theme.controlSize(scale) == .large ? 22 : 19  // like the Realistic switch
        }
        realism.onChange = { [weak self] value in self?.realismPicked(value) }
        realism.describe = { [unowned self] value in delayText(for: value, spoken: true) }
        let realismRow = CardRow(views: [realism])
        realismRow.onScale = { [unowned self] scale in
            realism.scale = scale
            realism.rowHeight = Theme.controlSize(scale) == .large ? 22 : 19  // like Strength
        }
        delayLabel.textColor = .secondaryLabelColor
        delayLabel.setAccessibilityElement(false)  // the slider says it
        realisticLoading.style = .spinning
        realisticLoading.controlSize = .small
        realisticLoading.isDisplayedWhenStopped = false
        realisticLoading.isHidden = true
        realisticLoading.setAccessibilityLabel("Getting the realistic voice ready")
        realisticWarning.isHidden = true
        let delayLine = NSStackView(views: [delayLabel, realisticLoading, realisticWarning])
        delayLine.spacing = 5
        delayRow = CardRow(views: [delayLine])
        delayRow.onScale = { [unowned self] scale in
            let points = 11 + (scale - 1) * 2.5
            delayLabel.font = .systemFont(ofSize: points)
            realisticWarning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Natural for now")?
                .withSymbolConfiguration(.init(pointSize: points, weight: .regular).applying(.init(paletteColors: [.secondaryLabelColor])))
        }
        changerCard = ShiftCard(title: "Voice changer", extraRows: [strengthRow, realismRow], showsAmount: false)
        changerCard.addRow(delayRow, tight: true)
        secondSwitch.onChange = { [weak self] on in self?.secondPicked(on) }  // 3.5
        secondSwitch.onLockedClick = { [weak self] in self?.showUnlock() }
        changerCard.addRow(ShiftCard.switchRow(Self.secondText, secondSwitch))
        quietSwitch.onChange = { [weak self] on in self?.quietPicked(on) }
        quietSwitch.onLockedClick = { [weak self] in self?.showUnlock() }
        quietRow = ShiftCard.switchRow(Self.quietText, quietSwitch)
        changerCard.addRow(quietRow)
        changerCard.picker.menu?.delegate = self
        changerCard.picker.target = self
        changerCard.picker.action = #selector(changerVoicePicked)
        changerCard.picker.setAccessibilityLabel("Voice")
        changerCard.onToggle = { [weak self] on in self?.setChanger(on) }
        changerCard.addPickerAccessory(voiceTools.views) { [unowned self] scale in voiceTools.size(for: scale) }
        // Locked (Pitch Shift Pro): its switch and voice picker only open the unlock window.
        changerCard.toggle.onLockedClick = { [weak self] in self?.showUnlock() }
        changerCard.picker.onLockedClick = { [weak self] in self?.showUnlock() }

        let background = BackgroundView()
        background.wantsLayer = true
        background.addSubview(hearCard)
        background.addSubview(voiceCard)
        background.addSubview(changerCard)

        // Tab goes through one card, then the next.
        let autoEQViews: [NSView] = [autoEQSwitch] + autoEQStrip.bands + [autoEQStrip.reset]
        let hearViews: [NSView] = hearCard.keyViews + [advancedSwitch, superSwitch, tone] + autoEQViews
        let voiceViews: [NSView] = voiceCard.keyViews + [style, testButton, slowSwitch, fastSlider, installButton, soundsButton]
        let changerViews: [NSView] = changerCard.keyViews + [strength, realism, secondSwitch, quietSwitch]
        let order: [NSView] = hearViews + voiceViews + changerViews
        background.nextKeyView = order[0]
        for (view, next) in zip(order, order.dropFirst() + [order[0]]) { view.nextKeyView = next }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 588, height: 300),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Pitch Shift"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenNone]
        window.autorecalculatesKeyViewLoop = false
        window.contentView = background
        showDriverState()
        window.setContentSize(minimums[.split] ?? NSSize(width: 588, height: 575))
        window.center()
        if let size = arg("--size")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            window.setContentSize(allowed(NSSize(width: size[0], height: size[1]), from: nil))
            window.center()
        } else if preview == nil {
            window.setFrameAutosaveName("Pitch Shift")  // remembers size and place (not for screenshots)
            window.setContentSize(allowed(background.bounds.size, from: nil))  // an old 588×369 window opens as 588×575
        }
        window.delegate = self
        arrange()
        rebuildHearMenu()
        rebuildMicMenu()
        rebuildChangerMenu()
        buildUnlockButton()
    }

    // "Unlock Pro" at the right end of the title bar, shown only while Pitch Shift Pro is locked.
    private func buildUnlockButton() {
        unlockButton.bezelStyle = .rounded
        unlockButton.controlSize = .small
        unlockButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        unlockButton.attributedTitle = NSAttributedString(string: "Unlock Pro", attributes: [
            .foregroundColor: Theme.mid, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)])
        unlockButton.target = self
        unlockButton.action = #selector(showUnlock)
        unlockButton.toolTip = "Pitch Shift Pro"
        unlockButton.sizeToFit()
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: unlockButton.frame.width + 10, height: unlockButton.frame.height))
        unlockButton.frame.origin = .zero
        holder.addSubview(unlockButton)
        unlockAccessory.view = holder
        unlockAccessory.layoutAttribute = .trailing
        showUnlockButton()
        // Light or dark mode changed: the locked Sounds button's lock gets the new color.
        appearanceWatch = window.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { if Pro.shared.unlocked == false { self?.styleSounds() } }
        }
    }
    private var appearanceWatch: NSKeyValueObservation?

    private func showUnlockButton() {
        let wanted = !Pro.shared.unlocked
        if wanted && unlockAccessory.parent == nil {
            window.addTitlebarAccessoryViewController(unlockAccessory)
        } else if !wanted, let index = window.titlebarAccessoryViewControllers.firstIndex(of: unlockAccessory) {
            window.removeTitlebarAccessoryViewController(at: index)
        }
    }

    // The Sounds button: in the middle color, or dimmed with a small lock while Pitch Shift Pro is locked.
    private func styleSounds() {
        let locked = !Pro.shared.unlocked
        let font = NSFont.systemFont(ofSize: Theme.fontSize(soundsSize), weight: .medium)
        let title = NSMutableAttributedString(string: "Sounds", attributes: [
            .foregroundColor: locked ? NSColor.tertiaryLabelColor : Theme.mid, .font: font])
        // The button draws its title in its own way, so the lock gets the color for the window's light or dark look.
        var color = NSColor.secondaryLabelColor
        soundsButton.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.secondaryLabelColor.usingColorSpace(.sRGB) ?? .gray
        }
        if locked, let lock = GradientSlider.lockImage(size: font.pointSize - 3, color: color) {
            let attachment = NSTextAttachment()
            attachment.image = lock
            attachment.bounds = NSRect(x: 0, y: ((font.capHeight - lock.size.height) / 2).rounded(), width: lock.size.width, height: lock.size.height)
            title.insert(NSAttributedString(string: " ", attributes: [.font: font]), at: 0)
            title.insert(NSAttributedString(attachment: attachment), at: 0)
        }
        soundsButton.attributedTitle = title
        soundsButton.toolTip = locked ? "Pitch Shift Pro" : nil
    }

    // MARK: Pitch Shift Pro

    @objc func showUnlock() {
        guard Pro.shared.enabled else { return }
        ProSheet.shared.show(on: window)
    }

    // Unlocked: the saved paid settings come back. Locked: the free version's values are used (nothing saved changes).
    func proChanged() {
        if Pro.shared.unlocked {
            voice.cartoon = AppDelegate.savedCartoon(defaults)
            voice.slowDeeper = defaults.bool(forKey: Keys.voiceSlowDeeper)
            voice.fastHigher = AppDelegate.savedFastHigher(defaults)
            for (uid, tilt) in AppDelegate.savedTones(defaults) { hear.setTone(tilt, for: uid) }
            for (uid, eq) in AppDelegate.savedAutoEQs(defaults) { hear.setAutoEQ(on: eq.on, offsets: eq.offsets, for: uid) }
            restoreChanger()  // the Voice changer as saved; if it's on, it starts (and Your voice goes off)
            if voice.changer.on && preview == nil { setChanger(true) }
        } else {
            voice.cartoon = Free.cartoon
            voice.slowDeeper = Free.slowDeeper
            voice.fastHigher = Free.fastHigher
            for uid in hear.tones.keys { hear.setTone(Free.tone, for: uid) }
            for uid in hear.autoEQs.keys { hear.setAutoEQ(on: false, offsets: [], for: uid) }
            voice.changer.on = false
            voice.stopChanger()
            if preview == nil && !voice.running { DefaultMic.giveBack() }
            if soundboard.isOpen { soundboard.close() }
        }
        buildMenu()
        showUnlockButton()
        styleSounds()
        refresh()
    }

    // MARK: Layout

    // How the three cards sit: in a row; in two columns (What you hear on the left, Your voice above Voice changer on
    // the right); or all in one column.
    enum Layout: CaseIterable { case row, split, stack }

    private let margin: CGFloat = 20, gap: CGFloat = 16, maxScale: CGFloat = 1.8
    private var layout = Layout.split
    private var minimums: [Layout: NSSize] = [:]  // the smallest window for each layout (no stack if it can't fit the screen)
    private var cards: [ShiftCard] { [hearCard, voiceCard, changerCard] }

    // Works out the smallest window sizes (call again when a row is shown or hidden).
    private func measure() {
        cards.forEach { $0.forgetHeights() }
        let width = ShiftCard.baseWidth
        var sizes: [Layout: NSSize] = [:]
        for layout in Layout.allCases {
            let columns: CGFloat = layout == .row ? 3 : layout == .split ? 2 : 1
            sizes[layout] = NSSize(width: columns * width + (columns - 1) * gap + 2 * margin, height: neededHeight(layout, at: 1) + 2 * margin)
        }
        let screen = (window.screen ?? NSScreen.main).map { window.contentRect(forFrameRect: $0.visibleFrame).size }
            ?? NSSize(width: 1300, height: 1000)
        let biggest = NSSize(width: min(1300, screen.width), height: min(max(640, sizes[.stack]!.height + 96), screen.height))
        if sizes[.stack]!.height > biggest.height { sizes[.stack] = nil }  // a short screen: two or three columns only
        minimums = sizes
        window.contentMinSize = NSSize(width: sizes.values.map(\.width).min()!, height: sizes.values.map(\.height).min()!)
        window.contentMaxSize = biggest
    }

    // A row was shown or hidden (Auto EQ's sliders): works out the smallest sizes again, and makes the window
    // bigger if it's now too small (its top edge stays where it is).
    private func refit() {
        measure()
        let size = window.contentView?.bounds.size ?? .zero
        let fixed = allowed(size, from: nil)
        if fixed != size {
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: fixed))
            frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
            window.setFrame(frame, display: true)
        }
        arrange()
    }

    // The height the cards need at a scale (not counting the margins).
    private func neededHeight(_ layout: Layout, at s: CGFloat) -> CGFloat {
        let hear = hearCard.neededHeight(at: s), voice = voiceCard.neededHeight(at: s), changer = changerCard.neededHeight(at: s)
        switch layout {
        case .row: return max(hear, voice, changer)
        case .split: return max(hear, voice + gap + changer)
        case .stack: return hear + voice + changer + 2 * gap
        }
    }

    // A size where at least one layout fits. Otherwise the window grows to the closest one, preferring a layout the
    // window fits now (`current`), so a drag doesn't flip between them.
    private func allowed(_ size: NSSize, from current: NSSize?) -> NSSize {
        let biggest = window.contentMaxSize
        let size = NSSize(width: min(size.width, biggest.width), height: min(size.height, biggest.height))
        func fits(_ size: NSSize, _ layout: Layout) -> Bool {
            guard let least = minimums[layout] else { return false }
            return size.width >= least.width && size.height >= least.height
        }
        if Layout.allCases.contains(where: { fits(size, $0) }) { return size }
        var choices = ([layout] + Layout.allCases).filter { minimums[$0] != nil }  // the arranged layout first
        if let current, choices.contains(where: { fits(current, $0) }) { choices = choices.filter { fits(current, $0) } }
        let grown = choices.map { NSSize(width: max(size.width, minimums[$0]!.width), height: max(size.height, minimums[$0]!.height)) }
        return grown.min { $0.width + $0.height < $1.width + $1.height } ?? size
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let size = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let fixed = allowed(size, from: sender.contentView?.bounds.size)
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: fixed)).size
    }

    func windowDidResize(_ notification: Notification) { arrange() }

    // The biggest scale at which the cards fit a layout: limited by the card width, then shrunk until they fit the
    // height.
    private func bestScale(_ size: NSSize, _ layout: Layout) -> CGFloat {
        let width: CGFloat
        switch layout {
        case .row: width = (size.width - 2 * margin - 2 * gap) / 3
        case .split: width = (size.width - 2 * margin - gap) / 2
        case .stack: width = size.width - 2 * margin
        }
        let height = size.height - 2 * margin
        func fits(_ s: CGFloat) -> Bool { neededHeight(layout, at: s) <= height }
        let widest = ((min(maxScale, width / ShiftCard.baseWidth)) * 100).rounded(.down) / 100
        if widest <= 1 || fits(widest) { return max(1, widest) }
        var low: CGFloat = 1, high = widest
        while high - low > 0.01 {
            let middle = ((low + high) / 2 * 100).rounded() / 100
            if middle == low || middle == high { break }
            if fits(middle) { low = middle } else { high = middle }
        }
        return low
    }

    // Places the cards in the layout that lets everything be biggest. It keeps the current layout unless another one
    // is clearly bigger (so it doesn't flip back and forth).
    func arrange() {
        guard !minimums.isEmpty, let size = window.contentView?.bounds.size else { return }
        var fitting = Layout.allCases.filter { layout in
            minimums[layout].map { size.width >= $0.width && size.height >= $0.height } ?? false
        }
        if fitting.isEmpty { fitting = [closestLayout(size)] }
        var pick = layout, scale: CGFloat = 0
        if fitting.contains(layout) { scale = bestScale(size, layout) } else { pick = fitting[0]; scale = bestScale(size, pick) }
        for other in fitting where other != pick {
            let s = bestScale(size, other)
            if s > scale + (pick == layout ? 0.05 : 0) { pick = other; scale = s }
        }
        let moved = pick != layout && voiceCard.frame.width > 0
        layout = pick

        let area = NSRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)
        let hear = hearCard.neededHeight(at: scale), voice = voiceCard.neededHeight(at: scale)
        let changer = changerCard.neededHeight(at: scale)
        // Each card: its place, and the extra height it shares out (a bigger number first, see ShiftCard.spread).
        var places: [(ShiftCard, NSRect, CGFloat)]
        switch layout {
        case .row:
            let width = ((area.width - 2 * gap) / 3).rounded(.down)
            let extra = max(0, area.height - max(hear, voice, changer))
            places = [
                (hearCard, NSRect(x: area.minX, y: area.minY, width: width, height: area.height), extra),
                (voiceCard, NSRect(x: (area.midX - width / 2).rounded(), y: area.minY, width: width, height: area.height), extra),
                (changerCard, NSRect(x: area.maxX - width, y: area.minY, width: width, height: area.height), extra),
            ]
        case .split:
            let width = ((area.width - gap) / 2).rounded(.down)
            let right = area.maxX - width
            let changerHeight = changer.rounded(.up)
            places = [
                (hearCard, NSRect(x: area.minX, y: area.minY, width: width, height: area.height), max(0, area.height - hear)),
                (voiceCard, NSRect(x: right, y: area.minY + changerHeight + gap, width: width, height: area.height - changerHeight - gap),
                 max(0, area.height - changerHeight - gap - voice)),
                (changerCard, NSRect(x: right, y: area.minY, width: width, height: changerHeight), 0),
            ]
        case .stack:
            let extra = max(0, (area.height - 2 * gap - hear - voice - changer) / 2)
            let top = (hear + extra).rounded(), bottom = changer.rounded(.up)
            places = [
                (hearCard, NSRect(x: area.minX, y: area.maxY - top, width: area.width, height: top), extra),
                (voiceCard, NSRect(x: area.minX, y: area.minY + bottom + gap, width: area.width, height: area.height - top - bottom - 2 * gap), extra),
                (changerCard, NSRect(x: area.minX, y: area.minY, width: area.width, height: bottom), 0),
            ]
        }
        for (card, frame, extra) in places {
            card.frame = frame
            card.apply(scale: scale)
            card.place(width: frame.width)
            card.spread(extra)
        }
        if moved {
            let offset = layout == .row ? NSPoint(x: 24, y: 0) : NSPoint(x: 0, y: -24)
            settle(voiceCard, from: offset)
            settle(changerCard, from: offset)
        }
    }

    // The layout the window is closest to fitting (for a size where none fits).
    private func closestLayout(_ size: NSSize) -> Layout {
        let short = { (layout: Layout) -> CGFloat in
            guard let least = self.minimums[layout] else { return .infinity }
            return max(0, least.width - size.width) + max(0, least.height - size.height)
        }
        return Layout.allCases.min { short($0) < short($1) } ?? .split
    }

    // When the layout changes, the "Your voice" card fades into its new place, coming up from below (or in from
    // the right). It stays smooth even while the window is still being resized.
    private func settle(_ card: NSView, from offset: NSPoint) {
        guard window.isVisible, let layer = card.layer else { return }
        let slide = CABasicAnimation(keyPath: "position")
        slide.isAdditive = true
        slide.fromValue = NSValue(point: Theme.reduceMotion ? .zero : offset)
        slide.toValue = NSValue(point: .zero)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [slide, fade]
        group.duration = 0.25
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "settle")
    }

    // MARK: Pickers

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === hearCard.picker.menu {
            rebuildHearMenu()
        } else if menu === changerCard.picker.menu {
            rebuildChangerMenu()
        } else {
            rebuildMicMenu()
        }
    }

    private func icon(_ image: NSImage?, dimmed: Bool = false) -> NSImage? {
        guard let image else { return nil }
        let small = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: dimmed ? 0.4 : 1)
            return true
        }
        return small
    }

    // The app picker: tick any number of apps, or All sound. The button shows what's chosen; a green dot marks
    // apps playing sound right now.
    func rebuildHearMenu() {
        let picker = hearCard.picker
        picker.removeAllItems()
        let menu = picker.menu!
        let chosen = hear.source.bundleIDs
        var apps = Apps.scan().map { (bundleID: $0.bundleID, name: $0.name, icon: $0.icon, running: true, playing: $0.isPlaying) }
        for saved in chosen where !apps.contains(where: { $0.bundleID == saved }) {
            let info = Apps.info(for: saved)
            apps.append((saved, info.name, info.icon, false, false))
        }
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let speaker = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)

        // In a pull-down menu the first item is what the button shows.
        let picked = apps.filter { chosen.contains($0.bundleID) }
        let title = hear.source == .all ? "All sound" : picked.isEmpty ? "Choose apps" : picked.map(\.name).joined(separator: ", ")
        let titleItem = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        titleItem.image = hear.source == .all ? speaker : icon(picked.first?.icon)

        let all = menu.addItem(withTitle: "All sound", action: nil, keyEquivalent: "")
        all.image = speaker
        all.representedObject = "all"
        all.state = hear.source == .all ? .on : .off
        menu.addItem(.separator())
        for app in apps {
            let item = menu.addItem(withTitle: app.name, action: nil, keyEquivalent: "")
            item.image = icon(app.icon, dimmed: !app.running)
            item.representedObject = app.bundleID
            item.state = chosen.contains(app.bundleID) ? .on : .off
            let name = NSMutableAttributedString(string: app.name, attributes: [
                .font: NSFont.menuFont(ofSize: 0), .foregroundColor: app.running ? NSColor.labelColor : NSColor.secondaryLabelColor])
            if app.playing {
                name.append(NSAttributedString(string: "  ●", attributes: [
                    .font: NSFont.menuFont(ofSize: 9), .foregroundColor: NSColor.systemGreen, .baselineOffset: 1.5]))
                item.toolTip = "Playing now"
                item.setAccessibilityLabel("\(app.name), playing now")
            }
            item.attributedTitle = name
        }
    }

    func rebuildMicMenu() {
        let picker = voiceCard.picker
        picker.removeAllItems()
        let mics = Mics.list()
        guard !mics.isEmpty else {
            picker.addItem(withTitle: "No microphone")
            picker.lastItem?.isEnabled = false
            return
        }
        let current = voice.currentMic.map(deviceUID)
        for mic in mics {
            picker.addItem(withTitle: mic.name)
            picker.lastItem?.representedObject = mic.uid
            picker.lastItem?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
        }
        picker.selectItem(at: mics.firstIndex { $0.uid == current } ?? 0)
    }

    // The picker shows the mic the voice uses now; with none picked, that changes with the default mic and the
    // headphones in use (a Bluetooth headset's own mic is passed over for the built-in one, see Mics.choose).
    private func showCurrentMic() {
        let picker = voiceCard.picker
        let current = voice.currentMic.map(deviceUID)
        guard (picker.selectedItem?.representedObject as? String) != current else { return }
        if let i = picker.itemArray.firstIndex(where: { $0.representedObject as? String == current }) {
            picker.selectItem(at: i)
        } else {
            rebuildMicMenu()
        }
    }

    // The voice picker: Woman, Man, then added voices. The voice folders are read again each time it opens, so a
    // voice added to ~/Library/Application Support/Pitch Shift/Voices shows up without restarting.
    func rebuildChangerMenu() {
        let picker = changerCard.picker
        picker.removeAllItems()
        let library = VoiceLibrary.shared
        library.rescan()
        let first = ["woman", "man"]
        let voices = library.voices.sorted { a, b in
            let i = first.firstIndex(of: a.id) ?? first.count, j = first.firstIndex(of: b.id) ?? first.count
            return i != j ? i < j : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        guard !voices.isEmpty, let menu = picker.menu else {
            picker.addItem(withTitle: "No voices")
            picker.lastItem?.isEnabled = false
            return
        }
        for voice in voices {
            // Added to the menu itself: two voices may have the same name.
            menu.addItem(withTitle: voice.name, action: nil, keyEquivalent: "").representedObject = voice.id
        }
        showCurrentVoice()
    }

    private func showCurrentVoice() {
        let picker = changerCard.picker
        let current = voice.changer.voiceID
        guard (picker.selectedItem?.representedObject as? String) != current else { return }
        if let i = picker.itemArray.firstIndex(where: { $0.representedObject as? String == current }) { picker.selectItem(at: i) }
    }

    @objc func changerVoicePicked() {
        guard let id = changerCard.picker.selectedItem?.representedObject as? String else { return }
        voice.changer.voiceID = id
        if preview == nil { defaults.set(id, forKey: Keys.changerVoice) }  // pictures change nothing
        refresh()
    }

    // Clicking "All sound" picks everything; clicking an app ticks or unticks it.
    @objc func hearSourcePicked() {
        guard let clicked = hearCard.picker.selectedItem?.representedObject as? String else { return }
        var source = HearSource.all
        if clicked != "all" {
            var bundleIDs = hear.source.bundleIDs
            if let i = bundleIDs.firstIndex(of: clicked) { bundleIDs.remove(at: i) } else { bundleIDs.append(clicked) }
            source = .apps(bundleIDs)
        }
        hear.source = source
        defaults.set(source.saved, forKey: Keys.hearSource)
        rebuildHearMenu()
        refresh()
    }

    @objc func micPicked() {
        guard let uid = voiceCard.picker.selectedItem?.representedObject as? String else { return }
        voice.micUID = uid
        defaults.set(uid, forKey: Keys.voiceMic)
        refresh()
    }

    func stylePicked(_ value: Float) {
        voice.cartoon = value
        guard preview == nil else { return }  // pictures change nothing
        defaults.set(value, forKey: Keys.voiceCartoon)
    }

    // The tone slider moved: it's kept for the speakers or headphones playing now.
    func tonePicked(_ value: Float) {
        guard !outputUID.isEmpty else { return }
        hear.setTone(((value * 2 - 1) * 100).rounded() / 100, for: outputUID)
        guard preview == nil else { return }  // pictures change nothing
        defaults.set(hear.tones, forKey: Keys.hearTone)
    }

    // Auto EQ switched on or off, or a section nudged: kept for the speakers or headphones playing now.
    func autoEQPicked(on: Bool? = nil, offsets: [Float]? = nil) {
        guard !outputUID.isEmpty else { return }
        let now = hear.autoEQ(for: outputUID)
        hear.setAutoEQ(on: on ?? now.on, offsets: offsets ?? now.offsets, for: outputUID)
        if preview == nil {  // pictures change nothing
            defaults.set(hear.autoEQs.mapValues { ["on": $0.on, "offsets": $0.offsets] }, forKey: Keys.hearAutoEQ)
        }
        if on != nil { refresh() }  // shows or hides the sliders (a nudge has already moved its slider)
    }

    // Auto EQ's sliders follow the sound about 15 times a second, but only while they can move and be seen: Auto EQ
    // on for these speakers or headphones, Advanced processing playing, and the window showing.
    private func updateAutoEQTimer() {
        let running = hear.isOn && hear.advanced && hear.autoEQ(for: outputUID).on
        let live = preview == nil && running && window.isVisible && window.occlusionState.contains(.visible)
        if live, autoEQTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in self?.readAutoEQ() }
            timer.tolerance = 0.02
            RunLoop.main.add(timer, forMode: .common)  // also while the window is being resized
            autoEQTimer = timer
            readAutoEQ()
        } else if !live, let timer = autoEQTimer {
            timer.invalidate()
            autoEQTimer = nil
        }
        if !running { autoEQStrip.auto = [Float](repeating: 0, count: 5) }  // nothing automatic now
    }

    private func readAutoEQ() {
        guard window.occlusionState.contains(.visible) else { updateAutoEQTimer(); return }
        autoEQStrip.auto = hear.autoEQReadout?.auto ?? [Float](repeating: 0, count: 5)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) { updateAutoEQTimer() }

    // The speakers or headphones changed: the tone slider and Auto EQ show theirs.
    func outputMoved() {
        let id = defaultOutput()
        outputUID = deviceUID(id)
        outputName = deviceName(id)
        refresh()
    }

    func slowPicked(_ on: Bool) {
        voice.slowDeeper = on
        if preview == nil { defaults.set(on, forKey: Keys.voiceSlowDeeper) }  // pictures change nothing
        refresh()
    }

    func fastPicked(_ value: Float) {
        voice.fastHigher = (value * SpeakingRate.maxUp).rounded()
        if preview == nil { defaults.set(voice.fastHigher, forKey: Keys.voiceFastHigher) }  // pictures change nothing
        refresh()
    }

    @objc func testClicked() {
        guard preview == nil else { return }  // pictures: see setHear
        // With Input pitch shifter off, the voice runs with the card's settings just for the test: the switch stays
        // off, the Mac's default mic is left as it is, and the voice stops again once the test is done. (With the Voice
        // changer on, it's the changer's voice that is recorded, and the changer keeps going afterwards.)
        if test.phase == .idle && !voice.isOn {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                testAlone = true
                testSounds = voice.runsForSounds
                voice.start()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async { granted ? self.testClicked() : self.micDenied() }
                }
                return
            default:
                micDenied()
                return
            }
        }
        test.click()
        endTestAlone()  // (if it couldn't start)
    }

    private var testAlone = false   // the voice runs only for Test (see testClicked)
    private var testSounds = false  // the Soundboard was open when that test started

    private func endTestAlone() {
        guard testAlone, test.phase == .idle else { return }
        testAlone = false
        voice.stop()
        // The Soundboard opened or closed during the test (it leaves the default mic alone while the voice runs):
        // Pitch Shift Mic is the default mic only while something still runs.
        if testSounds && !voice.runsForSounds && voice.state == .off { DefaultMic.giveBack() }
        if !testSounds && voice.runsForSounds { DefaultMic.takeOver() }
    }

    // Opens the Soundboard next to the window, or closes it.
    @objc func soundsClicked() {
        guard Pro.shared.unlocked else { showUnlock(); return }  // the Soundboard is part of Pitch Shift Pro
        if soundboard.isOpen {
            soundboard.close()
            return
        }
        soundboard.open(beside: window)
        guard preview == nil else { return }  // pictures change nothing
        // Sounds go out through the voice chain, so with Your voice and the Voice changer off it runs as if the voice
        // were on with no pitch change, and Pitch Shift Mic becomes the Mac's default mic (like turning the voice on).
        soundsOff?.cancel()
        soundsOff = nil
        voice.keepForSounds(true)
        if !voice.isOn && !voice.changerIsOn { DefaultMic.takeOver() }
        refresh()
    }

    private var soundsOff: DispatchWorkItem?

    // The Soundboard closed: with Your voice and the Voice changer off, the chain stops and the real mic is given back
    // a second later (like when an app stops listening; a sound that was just stopped fades out first).
    func soundboardClosed() {
        guard preview == nil else { return }
        soundsOff?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            soundsOff = nil
            voice.keepForSounds(false)
            if !voice.running { DefaultMic.giveBack() }
            refresh()
        }
        soundsOff = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    // MARK: Advanced processing

    private var advancedAlert: NSAlert?

    // Turning it on shows an alert first (it adds delay), unless "Don't show again" was ticked.
    func advancedPicked(_ on: Bool) {
        if on && !defaults.bool(forKey: Keys.hideAdvancedAlert) {
            askAdvanced()
            return
        }
        setAdvanced(on)
        refresh()  // the tone slider works only with it on
    }

    private func setAdvanced(_ on: Bool) {
        hear.mode = on ? .advanced : .normal
        defaults.set(on, forKey: Keys.hearAdvanced)
        if on { defaults.set(false, forKey: Keys.hearSuper) }
    }

    func superPicked(_ on: Bool) {
        guard preview == nil else { return }  // pictures change nothing
        hear.mode = on ? .heavy : .normal
        defaults.set(on, forKey: Keys.hearSuper)
        if on { defaults.set(false, forKey: Keys.hearAdvanced) }
        refresh()
    }

    // A sheet on the window: Turn On, or Cancel (the switch goes back off and nothing is saved).
    func askAdvanced() {
        guard advancedAlert == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Advanced processing may cause significant audio delay"
        alert.informativeText = "Sound may lag behind video. It's made for music."
        alert.addButton(withTitle: "Turn On").bezelColor = Theme.purple
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't show again"
        advancedAlert = alert
        alert.beginSheetModal(for: window) { [weak self] answer in
            guard let self else { return }
            advancedAlert = nil
            if answer == .alertFirstButtonReturn && preview == nil {  // pictures change nothing
                if alert.suppressionButton?.state == .on { defaults.set(true, forKey: Keys.hideAdvancedAlert) }
                setAdvanced(true)
            }
            refresh()  // shows the switch as it really is (off after Cancel)
        }
    }

    // MARK: Voice changer

    // On its own, the Voice changer runs the mic like Your voice does: Pitch Shift Mic gets the changed voice and
    // becomes the Mac's default mic. Only one at a time: turning it on turns Your voice off, and turning Your voice on
    // turns it off; the card that goes off keeps all its settings.
    func setChanger(_ on: Bool) {
        voice.changer.on = on
        guard preview == nil else {  // pictures change nothing
            if on { previewVoice = false }
            refresh()
            return
        }
        defaults.set(on, forKey: Keys.changerOn)
        guard on else {
            voice.stopChanger()  // with the Soundboard open, its sounds still go out (the voice unchanged)
            if !voice.running { DefaultMic.giveBack() }
            refresh()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            voice.startChanger()
            DefaultMic.takeOver()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { granted ? self.setChanger(true) : self.micDenied() }
            }
        default:
            micDenied()
        }
        // Once the changer runs, so the chain and the default mic carry on. (Also for "both on" saved by an older
        // version.)
        if voice.isOn || defaults.bool(forKey: Keys.voiceOn) { setVoice(false) }
        refresh()
    }

    // 3.5: the second voice for hums, laughs, sighs, singing on or off
    func secondPicked(_ on: Bool) {
        voice.changer.second = on
        guard preview == nil else { refresh(); return }  // pictures change nothing
        defaults.set(on, forKey: Keys.changerSounds)
        refresh()
    }

    func quietPicked(_ on: Bool) {
        voice.changer.quiet = on
        guard preview == nil else { refresh(); return }  // pictures change nothing
        defaults.set(on, forKey: Keys.changerQuiet)
        refresh()
    }

    func strengthPicked(_ value: Float) {
        voice.changer.strength = value
        guard preview == nil else { return }  // pictures change nothing
        defaults.set(value, forKey: Keys.changerStrength)
    }

    // "Faster ↔ More real": the delay under it follows the knob right away; the voice changes once the knob rests
    // for a moment (so dragging across the Natural end doesn't start the voice over and over).
    func realismPicked(_ value: Float) {
        refreshDelay()
        realismApply?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            realismApply = nil
            voice.changer.realism = value
            if preview == nil { defaults.set(value, forKey: Keys.changerRealism) }
            refresh()
        }
        realismApply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // "Delay: about 0.43 s" for a slider position (spoken: for VoiceOver, with the setting's name first).
    func delayText(for value: Float, spoken: Bool = false) -> String {
        var settings = voice.changer
        settings.realism = realisticOffered ? value : 0
        let seconds = voice.changerDelay(for: settings)
        let text = String(format: "%.2f", seconds)
        guard spoken else { return "Delay: about \(text) s" }
        return (settings.realistic ? "Realistic" : "Natural") + ", delay about \(text) seconds"
    }

    private func refreshDelay() {
        // while the plain voice changer stands in for the AI voice (loading, starting, a late piece), the card says so
        let text = delayText(for: realism.value) + (showsBackup ? " · backup voice" : "")
        if delayLabel.stringValue != text { delayLabel.stringValue = text }
        realism.setAccessibilityValueDescription(delayText(for: realism.value, spoken: true) + (showsBackup ? ", backup voice for now" : ""))
    }
    private var showsBackup = false  // set by showChanger

    // MARK: Switches

    // Pictures (--preview) play nothing and save nothing, even if a switch or Test gets pressed: they show Pitch Shift
    // Pro unlocked whatever the key, so they must never start any sound.
    func setHear(_ on: Bool) {
        guard preview == nil else { refresh(); return }
        on ? hear.start() : hear.stop()
        defaults.set(on, forKey: Keys.hearOn)
        refresh()
    }

    func setVoice(_ on: Bool) {
        guard preview == nil else {  // pictures: see setHear
            previewVoice = on
            if on && voice.changer.on { setChanger(false) }  // only one at a time
            refresh()
            return
        }
        guard on else {
            voice.stop()  // with the Voice changer on or the Soundboard open, the chain keeps going
            if !voice.running { DefaultMic.giveBack() }
            defaults.set(false, forKey: Keys.voiceOn)
            refresh()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            testAlone = false  // a test going on keeps going, with the card on now
            voice.start()
            DefaultMic.takeOver()
            defaults.set(true, forKey: Keys.voiceOn)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { granted ? self.setVoice(true) : self.micDenied() }
            }
        default:
            micDenied()
        }
        // Only one at a time: the Voice changer goes off once Your voice runs, so the chain and the default mic carry on.
        if voice.changer.on { setChanger(false) }
        refresh()
    }

    // Without the mic neither Your voice nor the Voice changer can run.
    private func micDenied() {
        defaults.set(false, forKey: Keys.voiceOn)
        if voice.changer.on {
            voice.changer.on = false
            defaults.set(false, forKey: Keys.changerOn)
        }
        refresh()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    // Installs the Pitch Shift Mic driver (asks for the Mac password), for copies installed without the package.
    @objc func installDriver() {
        guard let script = Bundle.main.path(forResource: "install-driver", ofType: "sh") else { NSSound.beep(); return }
        let command = "/bin/bash '\(script)'"
        let source = "do shell script \"\(command)\" with prompt \"Pitch Shift needs your password to add Pitch Shift Mic.\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard error == nil else { return }
        // The Mac's sound system restarted; reconnect everything.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
            let hearOn = hear.isOn, voiceOn = voice.isOn, changerOn = voice.changerIsOn, sounds = voice.runsForSounds
            hear.stop()
            voice.stopAll()
            if hearOn { hear.start() }
            if voiceOn || changerOn || sounds {
                if voiceOn { voice.start() }
                if changerOn { voice.startChanger() }
                voice.keepForSounds(sounds)
                DefaultMic.takeOver()
            }
            rebuildMicMenu()
            refresh()
        }
    }

    // MARK: Showing state

    // For screenshots (--preview hear-on,voice-on,waiting,typing,recording,playing,listening,hover,menu,roll,
    // resize,no-driver,advanced-alert,sounds,rename,volume,drop,light,tone,slow,eq,changer,changer-man,
    // changer-realistic,changer-loading,changer-fallback,changer-slider-natural|fast|default|max|NN,changer-intel,
    // changer-second-off,changer-quiet-on,changer-card-off,pro-locked,pro-unlock,pro-typo,pro-paste,pro-done,pro-alone,
    // pro-unlocked,switch-flip,click-voice,click-vc [--size 800x400] [--steps 3,-2]): shows a state, no sound. With a
    // changer state, Your voice shows off (only one at a time).
    func showPreview() {
        guard let preview else { return }
        // With Pitch Shift Pro locked (pro-locked, pro-unlock), the paid controls keep the free version's values.
        let pro = Pro.shared.unlocked
        if preview.contains("light") {
            window.appearance = NSAppearance(named: .aqua)
            soundboard.panel.appearance = NSAppearance(named: .aqua)
        }
        if preview.contains("sounds"), pro {  // the Soundboard with example names, the second one playing
            board.showAsPlaying(Soundboard.examples[1].file)
            soundboard.open(beside: window)
            if preview.contains("hover") { soundboard.showHover() }
            if preview.contains("rename") { soundboard.showRenaming() }  // the first name being changed
            if preview.contains("volume") { soundboard.showVolume() }  // the first sound's volume slider
            if preview.contains("drop") { soundboard.showDropping() }  // sound files dragged over it
        }
        if let cartoonArg, pro { voice.cartoon = cartoonArg }  // where the style slider is (--cartoon-amount 0.5)
        if let steps = arg("--steps")?.split(separator: ",").compactMap({ Float($0) }), let first = steps.first {
            hear.halfSteps = AmountField.clamp(first)  // the two big numbers (--steps 3,-2)
            voice.halfSteps = AmountField.clamp(steps.last ?? first)
        }
        if preview.contains("tone") { hear.mode = .advanced }  // Advanced processing on (nothing runs in pictures)
        if preview.contains("super") { hear.mode = .heavy }  // Super Advanced on
        if let toneArg, !outputUID.isEmpty, pro { hear.setTone(toneArg, for: outputUID) }  // the tone slider (--tone-amount -0.4)
        if preview.contains("slow"), pro { voice.slowDeeper = true }  // "Deeper when slow" on
        if !outputUID.isEmpty {  // Auto EQ on with "eq" (--eq-offsets 3,-2,0,1,-1 sets its sliders), off without
            hear.setAutoEQ(on: preview.contains("eq") && pro, offsets: pro ? autoEQArg.offsets.map(Float.init) : [], for: outputUID)
        }
        refresh()
        // Half a second in, Your voice's switch (click-voice) or the Voice changer's (click-vc; a name with "changer"
        // in it would start with the changer on) is turned on, as a click would: the other one goes off.
        if preview.contains("click-voice") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.voiceCard.onToggle(true) } }
        if preview.contains("click-vc") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.changerCard.onToggle(true) } }
        // The unlock window (with pro-typo: a key with a typo; pro-paste: a key pasted from an email, line breaks and
        // all; pro-done: unlocked; pro-alone: as its own window).
        if previewStates.contains("pro-unlock") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                ProSheet.shared.show(on: self.window, alone: previewStates.contains("pro-alone"))
                if previewStates.contains("pro-typo") { ProSheet.shared.showTypo() }
                if previewStates.contains("pro-paste") { ProSheet.shared.showPasted() }
                if previewStates.contains("pro-done") { ProSheet.shared.showUnlockedMessage() }
            }
        }
        if preview.contains("typing") {
            window.makeFirstResponder(hearCard.amount)
            DispatchQueue.main.async { self.hearCard.amount.currentEditor()?.string = "2.5" }
        }
        if preview.contains("hover") { hearCard.amount.highlight = 1 }
        if preview.contains("roll") {  // slowed down 10 times, to catch the animations in a screenshot
            window.contentView?.layer?.speed = 0.1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.hearCard.show(on: true, value: self.hear.halfSteps + 1, active: true)
                self.voiceCard.show(on: false, value: self.voice.halfSteps, active: false)
                self.lastPhase = .recording(5)
                Theme.crossfade(self.testButton, 0.2)
                self.testButton.title = "● 5"
                self.testButton.bezelColor = .systemRed
            }
        }
        // Slowed down 10 times: the first card's switch goes on, and turns back halfway (a quick second click); the
        // second card's switch is held down.
        if preview.contains("switch-flip") {
            window.contentView?.layer?.speed = 0.1
            if let press = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                voiceCard.toggle.mouseDown(with: press)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.hearCard.toggle.isOn = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.hearCard.toggle.isOn = false }
        }
        if preview.contains("menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.hearCard.picker.performClick(nil) }
        }
        if preview.contains("advanced-alert") {  // the alert shown when Advanced processing is turned on
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.advancedSwitch.isOn = true
                self.askAdvanced()
            }
        }
        if preview.contains("resize") {  // drags the window's corner through all three layouts, ending one above the other
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let path = [NSSize(width: 900, height: 420), NSSize(width: 620, height: 640),
                            NSSize(width: 1300, height: 640), NSSize(width: 330, height: 880)]
                self.drag(from: self.window.contentView?.bounds.size ?? .zero, through: path)
            }
        }
    }

    // Pictures: moves the window's bottom-right corner like a person dragging it (1 second from point to point, 60
    // steps a second, each step limited by windowWillResize); the top-left corner stays put.
    private func drag(from: NSSize, through path: [NSSize], step: Int = 1) {
        guard let to = path.first else { return }
        let steps = 60, t = CGFloat(step) / CGFloat(steps)
        let mouse = NSSize(width: from.width + (to.width - from.width) * t, height: from.height + (to.height - from.height) * t)
        let size = windowWillResize(window, to: window.frameRect(forContentRect: NSRect(origin: .zero, size: mouse)).size)
        window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - size.height, width: size.width, height: size.height), display: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / Double(steps)) {
            if step < steps { self.drag(from: from, through: path, step: step + 1) } else { self.drag(from: to, through: Array(path.dropFirst())) }
        }
    }

    private var driverInstalled: Bool { Mics.driverInstalled && preview?.contains("no-driver") != true }

    // Shows "Pitch Shift Mic" or the Install button, and resizes the window's limits when that changes.
    private func showDriverState() {
        let now = driverInstalled
        guard now != installed else { return }
        installed = now
        dot.isHidden = !now
        micName.isHidden = !now
        soundsButton.isHidden = !now
        installButton.isHidden = now
        measure()
        let size = window.contentView?.bounds.size ?? .zero
        let fixed = allowed(size, from: nil)
        if fixed != size { window.setContentSize(fixed) }
        arrange()
    }

    private func waitingTip() -> String {
        let names = hear.source.bundleIDs.map { Apps.info(for: $0).name }
        return names.isEmpty ? "Waiting for sound" : "Waiting for sound from \(names.joined(separator: ", "))"
    }

    func refresh() {
        guard hearCard != nil else { return }
        let hearOn = preview.map { $0.contains("hear-on") } ?? hear.isOn
        let voiceOn = preview == nil ? voice.isOn && !testAlone : previewVoice
        let waiting = preview.map { $0.contains("waiting") } ?? (hear.state == .waiting)
        hearCard.show(on: hearOn, value: hear.halfSteps, active: hearOn, waiting: waiting)
        if advancedAlert == nil { advancedSwitch.isOn = hear.advanced }  // stays on while the alert asks
        superSwitch.isOn = hear.mode == .heavy
        // Pitch Shift Pro: locked controls show the free version's value, dimmed with a small lock.
        let locked = !Pro.shared.unlocked
        tone.locked = locked
        style.locked = locked
        slowSwitch.locked = locked
        fastSlider.locked = locked
        tone.value = (((hear.tones[outputUID] ?? 0) + 1) / 2 * 100).rounded() / 100
        tone.isEnabled = hear.advanced
        tone.toolTip = locked ? "Pitch Shift Pro" : outputName.isEmpty ? nil : "For \(outputName)"
        // Auto EQ: off while Pitch Shift Pro is locked (its sliders show only while it's on).
        autoEQSwitch.locked = locked
        let eq = hear.autoEQ(for: outputUID)
        autoEQSwitch.isOn = eq.on
        autoEQSwitch.isEnabled = hear.advanced
        autoEQStrip.offsets = eq.offsets
        autoEQStrip.isEnabled = hear.advanced
        if autoEQRow.isHidden == eq.on {  // the sliders show while Auto EQ is on
            Theme.crossfade(hearCard, 0.2)
            autoEQRow.isHidden = !eq.on
            refit()
        }
        updateAutoEQTimer()
        switch hear.state {
        case .playing(let speakers): hearCard.amount.toolTip = "Playing to \(speakers)"
        case .problem(let message): hearCard.amount.toolTip = message
        case .waiting: hearCard.amount.toolTip = waitingTip()
        case .off: hearCard.amount.toolTip = nil
        }

        showDriverState()
        let installed = driverInstalled
        let hasMic = !Mics.list().isEmpty
        let voiceActive = voiceOn && installed && hasMic
        let changerActive = voice.changer.on && installed && hasMic
        voiceCard.show(on: voiceOn, value: voice.halfSteps, active: voiceActive)
        voiceCard.toggle.isEnabled = installed && hasMic
        voiceCard.picker.isEnabled = installed && hasMic
        if hasMic { showCurrentMic() }
        style.value = voice.cartoon
        style.isEnabled = installed
        style.toolTip = locked ? "Pitch Shift Pro" : nil
        slowSwitch.isOn = voice.slowDeeper
        slowSwitch.isEnabled = installed
        slowSwitch.toolTip = locked ? "Pitch Shift Pro" : nil
        // Higher when fast works only with Deeper when slow on (so never with the Voice changer: only one at a time).
        fastSlider.value = voice.fastHigher / SpeakingRate.maxUp
        fastSlider.isEnabled = installed && voice.slowDeeper
        fastLabel.textColor = fastSlider.isEnabled && !locked ? .secondaryLabelColor : .tertiaryLabelColor
        fastLabel.toolTip = locked ? "Pitch Shift Pro" : nil
        soundsButton.isEnabled = installed && hasMic  // the Soundboard works with the voice off too
        if case .problem(let message) = voice.state { voiceCard.amount.toolTip = message } else { voiceCard.amount.toolTip = nil }
        showChanger(active: changerActive, usable: installed && hasMic, locked: locked)

        let listening = preview.map { $0.contains("listening") } ?? voice.listening
        dot.isLive = (voiceOn || voice.changer.on || voice.runsForSounds) && installed && listening
        footer.toolTip = dot.isLive ? "An app is using Pitch Shift Mic" : "Choose Pitch Shift Mic as the microphone in Discord, Zoom or any app"
        micName.setAccessibilityValue(dot.isLive ? "Pitch Shift Mic, in use" : "Pitch Shift Mic, not in use")

        var phase = test.phase
        if let preview, preview.contains("recording") { phase = .recording(3) }
        if let preview, preview.contains("playing") { phase = .playing }
        if phase != lastPhase {
            Theme.crossfade(testButton, 0.2)
            lastPhase = phase
        }
        switch phase {
        case .idle:
            testButton.title = "Test"
            testButton.bezelColor = Theme.purple
            testButton.setAccessibilityLabel("Test")
            testButton.isEnabled = installed && hasMic
        case .recording(let left):
            testButton.title = "● \(left)"
            testButton.bezelColor = .systemRed
            testButton.setAccessibilityLabel("Recording, \(left) seconds left. Stop")
            testButton.isEnabled = true
        case .playing:
            testButton.title = "■ Stop"
            testButton.bezelColor = Theme.purple
            testButton.setAccessibilityLabel("Stop playing")
            testButton.isEnabled = true
        }
    }

    // The Voice changer card: on while its switch is on (`active`); the switch and picker work while
    // Pitch Shift Mic and a mic are there (`usable`). Under "Faster ↔ More real": the delay, a spinner while the
    // realistic voice gets ready, a small warning sign when Natural is standing in (the tooltip says why). While
    // Pitch Shift Pro is locked (`locked`), it's off and everything in it shows a lock and opens the unlock window.
    private func showChanger(active: Bool, usable: Bool, locked: Bool) {
        changerCard.locked = locked
        strength.locked = locked
        realism.locked = locked
        voiceTools.locked = locked
        changerCard.show(on: voice.changer.on, active: active)
        changerCard.toggle.isEnabled = usable
        changerCard.picker.isEnabled = usable && !locked
        showCurrentVoice()
        strength.value = voice.changer.strength
        strength.isEnabled = active
        let chosen = VoiceLibrary.shared.voice(voice.changer.voiceID)
        let hasRealistic = chosen?.manifest.realistic != nil
        // In Realistic mode the AI voice always sounds like the voice; the slider only moves the pitch, from yours
        // (left) to the voice's (right), so it says so.
        if voice.changer.realistic && hasRealistic && realisticOffered {
            let name = chosen?.name ?? "Voice"
            strength.left = "Your pitch"
            strength.right = "\(name)'s pitch"
            strength.describe = { $0 <= 0 ? "Your pitch" : $0 >= 1 ? "\(name)'s pitch" : "\(Int(($0 * 100).rounded())) percent of the way to \(name)'s pitch" }
            strength.setAccessibilityLabel("Pitch")
        } else {
            strength.left = "Light"
            strength.right = "Full"
            strength.describe = { $0 <= 0 ? "Light" : $0 >= 1 ? "Full" : "\(Int(($0 * 100).rounded())) percent" }
            strength.setAccessibilityLabel("Strength")
        }
        if realismApply == nil { realism.value = realisticOffered ? voice.changer.realism : 0 }  // (not while it moves)
        realism.isEnabled = active && hasRealistic && realisticOffered
        showSecond(active: active, locked: locked, chosen: chosen)
        showQuiet(active: active, usable: usable, locked: locked, chosen: chosen)

        enum Look { case natural, loading, realistic, fallback(Int), unavailable(String) }
        var look: Look
        switch voice.changerState {
        case .off, .natural: look = .natural
        case .loading: look = .loading
        case .realistic: look = .realistic
        case .fallback(let misses): look = .fallback(misses)
        case .unavailable(let reason): look = .unavailable(reason)
        }
        if let preview {  // pictures: changer-loading, changer-realistic, changer-fallback
            if preview.contains("changer-loading") { look = .loading }
            if preview.contains("changer-realistic") { look = .realistic }
            if preview.contains("changer-fallback") { look = .fallback(3) }
        }
        var note: String?, loading = false, warning = false, backup = false
        if !realisticOffered {
            note = "The more real voices need a Mac with Apple silicon"
        } else if let chosen, !hasRealistic {
            note = "\(chosen.name) has no realistic version"
        } else if active && voice.changer.realistic {
            switch look {
            case .loading:
                loading = true
                backup = true
                note = VoiceModelStore.shared.loadingNote(chosen, quiet: voice.changer.quiet) + " The backup voice (Natural) plays meanwhile."
            case .fallback(let misses):
                warning = true
                backup = true
                note = "The realistic voice fell behind \(misses == 1 ? "once" : "\(misses) times"). The backup voice (Natural) filled in."
            case .unavailable(let reason):
                warning = true
                backup = true
                note = reason
            case .natural, .realistic:
                break
            }
        }
        showsBackup = backup
        refreshDelay()
        if realisticLoading.isHidden == loading {
            realisticLoading.isHidden = !loading
            if loading { realisticLoading.startAnimation(nil) } else { realisticLoading.stopAnimation(nil) }
        }
        realisticWarning.isHidden = !warning
        if locked { note = "Pitch Shift Pro" }
        realism.toolTip = note
        delayRow.toolTip = note
        realism.setAccessibilityHelp(note)
    }

    // 3.5: the second voice's switch works with the AI voice (Apple silicon, the slider past Natural) and a voice that
    // has a second voice (Woman, Man).
    private func showSecond(active: Bool, locked: Bool, chosen: VoiceEntry?) {
        let has = chosen?.manifest.realistic?.sounds != nil
        secondSwitch.locked = locked
        secondSwitch.isOn = voice.changer.second
        secondSwitch.isEnabled = active && has && realisticOffered && voice.changer.realistic
        secondSwitch.toolTip = locked ? "Pitch Shift Pro"
            : !realisticOffered ? "The more real voices need a Mac with Apple silicon"
            : chosen != nil && !has ? "\(chosen!.name) has no second voice"
            : !voice.changer.realistic ? "Works with the more real voices (move the slider right)"
            : "A second AI voice for hums, laughs, sighs, breaths and singing. Talking always uses the main voice."
    }

    // Like the pitch cards' controls, it works while the card is off too (drawn fainter; used once the card is on).
    private func showQuiet(active: Bool, usable: Bool, locked: Bool, chosen: VoiceEntry?) {
        let has = chosen?.manifest.realistic?.quiet != nil
        quietSwitch.locked = locked
        quietSwitch.isOn = voice.changer.quiet
        quietSwitch.isEnabled = usable && has && realisticOffered && voice.changer.realistic
        let soft: CGFloat = active || locked ? 1 : ShiftCard.offStrength
        if quietRow.alphaValue != soft {
            if window?.isVisible == true { Theme.animate(0.25) { quietRow.animator().alphaValue = soft } } else { quietRow.alphaValue = soft }
        }
        quietSwitch.toolTip = locked ? "Pitch Shift Pro"
            : !realisticOffered ? "The more real voices need a Mac with Apple silicon"
            : chosen != nil && !has ? "\(chosen!.name) has no version that blocks background sounds"
            : !voice.changer.realistic ? "Works with the more real voices (move the slider right)"
            : "Uses a version of the AI voice that leaves out clicks, typing and room noise. It sounds a little different, and breaths come out quieter."
    }
}
