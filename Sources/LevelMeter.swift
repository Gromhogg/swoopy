// The volume bar in the Output pitch shifter card: how loud the sound Swoopy plays is, in dB below the loudest digital
// sound (0 dB). It's measured after the pitch change and Bass ↔ Treble / Auto EQ, before the Mac's own volume.
import Accelerate
import AppKit

// Measures the sound on its way to the speakers or headphones: its loudness (RMS, both sides together), rising
// quickly and falling slowly so it reads well with music. The sound side calls `measure`: it only reads the sound,
// takes no lock and makes no memory. The window reads `db`.
final class LevelMeter {
    private let sampleRate: Float
    private var power: Float = 0  // the smoothed loudness (mean square), only used by the sound side
    private let shown = UnsafeMutablePointer<Float>.allocate(capacity: 1)  // a copy of it for the window

    init(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)
        shown.initialize(to: 0)
    }

    deinit { shown.deallocate() }

    func measure(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        var l: Float = 0, r: Float = 0
        vDSP_measqv(left, 1, &l, vDSP_Length(frames))
        vDSP_measqv(right, 1, &r, vDSP_Length(frames))
        let now = (l + r) / 2
        guard now.isFinite else { return }
        let seconds: Float = now > power ? 0.05 : 0.25  // rises in about 0.05 s, falls about 17 dB a second
        power = now + (power - now) * exp(-Float(frames) / (sampleRate * seconds))
        if power < 1e-12 { power = 0 }  // below −120 dB: silence
        shown.pointee = power
    }

    // The loudness now in dB (−∞ while silent).
    var db: Float { 10 * log10(shown.pointee) }
}

// The bar: a thin track like the sliders', lit from the left in the icon's purple → pink up to the level (−60 dB at the
// left end, 0 dB at the right end), with the level beside it in small grey numbers ("−14 dB", or "Silent"). The number
// changes at most 4 times a second, so it can be read. VoiceOver reads it as a level indicator.
final class LevelBar: NSView {
    static let lowest: Float = -60
    private var db = -Float.infinity
    private var number: Int?  // the number shown (nil: Silent)
    private var numberChanged: CFTimeInterval = 0
    var scale: CGFloat = 1 {
        didSet {
            guard oldValue != scale else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel("Volume")
        setAccessibilityMinValue(NSNumber(value: Self.lowest))
        setAccessibilityMaxValue(NSNumber(value: 0))
        toolTip = "How loud it plays, in dB (0 is the loudest)"
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        showNumber()
    }

    convenience init() { self.init(frame: NSRect(x: 0, y: 0, width: 200, height: 14)) }

    required init?(coder: NSCoder) { fatalError() }

    // The level now, in dB (−∞ for silence). The bar follows it at once, the number at most 4 times a second.
    func show(db new: Float) {
        let before = litWidth
        db = new
        let value = new.rounded() >= Self.lowest ? Int(new.rounded()) : nil
        let now = CACurrentMediaTime()
        if value != number, now - numberChanged >= 0.25 || (value == nil) != (number == nil) {
            number = value
            numberChanged = now
            showNumber()
            needsDisplay = true
        }
        if litWidth != before { needsDisplay = true }
    }

    private var text: String { number.map { ($0 < 0 ? "−" : "") + "\(abs($0)) dB" } ?? "Silent" }

    private func showNumber() {
        setAccessibilityValue(NSNumber(value: number ?? Int(Self.lowest)))
        setAccessibilityValueDescription(number.map { "\($0) decibels" } ?? "Silent")
    }

    // Like the small grey lines under the Voice changer's slider.
    private var font: NSFont { .monospacedDigitSystemFont(ofSize: 11 + (scale - 1) * 2.5, weight: .regular) }
    private var attributes: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: NSColor.secondaryLabelColor] }
    private var thickness: CGFloat { Theme.controlSize(scale) == .large ? 5 : 4 }
    private var numberWidth: CGFloat {
        ["−60 dB", "Silent"].map { ($0 as NSString).size(withAttributes: attributes).width }.max()!.rounded(.up)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: (font.ascender - font.descender).rounded(.up))
    }

    private var track: NSRect {
        let middle = (bounds.height - (font.ascender - font.descender)) / 2 - font.descender + font.capHeight / 2
        return NSRect(x: bounds.minX, y: (middle - thickness / 2).rounded(), width: max(0, bounds.width - numberWidth - (8 * scale).rounded()), height: thickness)
    }

    // How much of the track is lit, in whole points.
    private var litWidth: CGFloat {
        let part = max(0, min(1, (db - Self.lowest) / -Self.lowest))
        return part.isFinite ? (CGFloat(part) * track.width).rounded() : 0
    }

    override func draw(_ dirtyRect: NSRect) {
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: bounds.maxX - size.width, y: ((bounds.height - size.height) / 2).rounded()), withAttributes: attributes)
        let t = track
        NSColor.quaternaryLabelColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: t, xRadius: t.height / 2, yRadius: t.height / 2).fill()
        let lit = litWidth
        guard lit > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: NSRect(x: t.minX, y: t.minY, width: max(lit, t.height), height: t.height), xRadius: t.height / 2, yRadius: t.height / 2).addClip()
        Theme.gradient.draw(in: t, angle: 0)  // the colors stay put along the track: louder reaches further into the pink
        NSGraphicsContext.restoreGraphicsState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
