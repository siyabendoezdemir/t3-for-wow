import AppKit
import BridgeCore

// T3-family controls for the Mac window, drawn to T3's own component geometry and Graphite Blue
// roles (BridgeCore.T3Theme; source references and MIT notice there and in THIRD-PARTY-NOTICES.md).
// Every control stays a native NSButton/NSView underneath: keyboard, key equivalents, accessibility
// and responder behaviour are AppKit's own. Hover changes tint only — nothing moves or scales.

extension NSColor {
    convenience init(_ c: T3Theme.RGB, alpha: CGFloat = 1) { self.init(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: alpha) }
}

enum T3Type {
    static func font(_ size: Double, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: CGFloat(size), weight: weight) }

    /// Wrapping or single-line label with T3's exact size / line height / colour.
    static func label(_ s: String, size: Double, weight: NSFont.Weight = .regular, color: NSColor, line: Double? = nil, width: CGFloat? = nil) -> NSTextField {
        let f = width == nil ? NSTextField(labelWithString: "") : NSTextField(wrappingLabelWithString: "")
        set(f, s, size: size, weight: weight, color: color, line: line)
        if let width { f.preferredMaxLayoutWidth = width }
        f.isSelectable = false
        return f
    }
    static func set(_ f: NSTextField, _ s: String, size: Double, weight: NSFont.Weight = .regular, color: NSColor, line: Double? = nil) {
        let p = NSMutableParagraphStyle()
        if let line { p.minimumLineHeight = CGFloat(line); p.maximumLineHeight = CGFloat(line) }
        p.lineBreakMode = .byWordWrapping
        f.attributedStringValue = NSAttributedString(string: s, attributes: [.font: font(size, weight), .foregroundColor: color, .paragraphStyle: p])
    }
}

/// Visual state forced by the preview exporter only (never in the live app).
enum ForcedState { case none, hover, pressed, focus, disabled }

final class T3Button: NSButton {
    enum Style { case primary, outline, ghost }
    let style: Style
    var forced: ForcedState = .none { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }

    init(_ title: String, style: Style) {
        self.style = style
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryPushIn)
        focusRingType = .none            // we draw T3's inset focus ring ourselves
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { nil }

    override var title: String { didSet { invalidateIntrinsicContentSize(); setAccessibilityLabel(title) } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }

    private var labelFont: NSFont { T3Type.font(T3Theme.buttonFontSize, .medium) }
    override var intrinsicContentSize: NSSize {
        let w = (title as NSString).size(withAttributes: [.font: labelFont]).width
        return NSSize(width: ceil(w) + CGFloat(T3Theme.buttonPaddingX) * 2 + 2, height: CGFloat(T3Theme.buttonHeight))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }

    override func draw(_ dirty: NSRect) {
        let disabled = !isEnabled || forced == .disabled
        let pressed = !disabled && ((cell?.isHighlighted ?? isHighlighted) || forced == .pressed)
        let hover = !disabled && (hovering || forced == .hover)
        let focused = !disabled && (window?.firstResponder === self || forced == .focus)
        let r = CGFloat(T3Theme.controlRadius)
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
        NSGraphicsContext.saveGraphicsState()
        if disabled { NSGraphicsContext.current?.cgContext.setAlpha(CGFloat(T3Theme.disabledAlpha)) }

        let fill: NSColor?, stroke: NSColor?, text: NSColor
        switch style {
        case .primary:
            let c = pressed ? NSColor(T3Theme.action.mixed(with: T3Theme.RGB(0x000000), 0.08)) : NSColor(hover ? T3Theme.actionHover : T3Theme.action)
            fill = c; stroke = c; text = NSColor(T3Theme.actionForeground)
        case .outline:
            fill = NSColor(hover || pressed ? T3Theme.outlineHover : T3Theme.outlineFill); stroke = NSColor(T3Theme.input); text = NSColor(T3Theme.text)
        case .ghost:
            fill = hover || pressed ? NSColor(T3Theme.secondary) : nil; stroke = nil; text = NSColor(hover || pressed ? T3Theme.text : T3Theme.textMuted)
        }
        if let fill { fill.setFill(); path.fill() }
        if let stroke { stroke.setStroke(); path.lineWidth = 1; path.stroke() }
        // T3's 1px inner top highlight (inset-shadow white/16% on primary, white/6% on outline), not when pressed.
        if !pressed && !disabled && style != .ghost {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            NSColor(white: 1, alpha: style == .primary ? 0.16 : 0.06).setFill()
            NSRect(x: rect.minX, y: isFlipped ? rect.minY + 0.5 : rect.maxY - 1.5, width: rect.width, height: 1).fill() // visual top either way
            NSGraphicsContext.restoreGraphicsState()
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: text]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
        if focused { // focus-visible:ring-2 ring-inset ring-ring
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: r - 1, yRadius: r - 1)
            ring.lineWidth = 2; NSColor(T3Theme.focus).setStroke(); ring.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// On/off control (checkbox semantics for accessibility), T3-styled track + knob + label.
final class T3Switch: NSButton {
    var forced: ForcedState = .none { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    init(_ title: String) {
        super.init(frame: .zero)
        setButtonType(.switch)
        self.title = title
        isBordered = false
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { nil }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
    private var labelFont: NSFont { T3Type.font(13) }
    override var intrinsicContentSize: NSSize {
        NSSize(width: 30 + 8 + ceil((title as NSString).size(withAttributes: [.font: labelFont]).width), height: 20)
    }
    override func draw(_ dirty: NSRect) {
        let disabled = !isEnabled || forced == .disabled
        let on = state == .on
        let hover = !disabled && (hovering || forced == .hover)
        NSGraphicsContext.saveGraphicsState()
        if disabled { NSGraphicsContext.current?.cgContext.setAlpha(CGFloat(T3Theme.disabledAlpha)) }
        let track = NSRect(x: 0.5, y: (bounds.height - 18) / 2, width: 30, height: 18)
        let tp = NSBezierPath(roundedRect: track, xRadius: 9, yRadius: 9)
        NSColor(on ? (hover ? T3Theme.actionHover : T3Theme.action) : (hover ? T3Theme.outlineHover : T3Theme.input)).setFill(); tp.fill()
        let knob = NSRect(x: on ? track.maxX - 16 : track.minX + 2, y: track.minY + 2, width: 14, height: 14)
        NSColor(on ? T3Theme.actionForeground : T3Theme.text).setFill(); NSBezierPath(ovalIn: knob).fill()
        if window?.firstResponder === self || forced == .focus {
            let ring = NSBezierPath(roundedRect: track.insetBy(dx: -2, dy: -2), xRadius: 11, yRadius: 11)
            ring.lineWidth = 2; NSColor(T3Theme.focus).setStroke(); ring.stroke()
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor(T3Theme.textMuted)]
        let s = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: track.maxX + 8, y: bounds.midY - s.height / 2), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// 8px status dot + label (T3 ConnectionStatusDot grammar), used as the header context.
final class StatusMark: NSView {
    private let label = T3Type.label("", size: 13, weight: .medium, color: NSColor(T3Theme.textMuted))
    private var tone: Setup.Tone = .neutral
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), label.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     label.centerYAnchor.constraint(equalTo: centerYAnchor), heightAnchor.constraint(equalToConstant: 18)])
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { nil }
    func set(_ text: String, _ tone: Setup.Tone) {
        self.tone = tone
        T3Type.set(label, text, size: 13, weight: .medium, color: NSColor(T3Theme.textMuted))
        setAccessibilityLabel("Status: \(text)")
        needsDisplay = true
    }
    static func color(_ t: Setup.Tone) -> NSColor {
        switch t { case .good: return NSColor(T3Theme.success); case .warn: return NSColor(T3Theme.warning); case .bad: return NSColor(T3Theme.error); case .neutral: return NSColor(T3Theme.textMuted, alpha: 0.4) }
    }
    override func draw(_ dirty: NSRect) {
        Self.color(tone).setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: bounds.midY - 4, width: 8, height: 8)).fill()
    }
}

/// Rounded box with fill/border (T3 help box: rounded-lg border-border/70 bg-background/55, px-3 py-3;
/// warning Alert: warning-surface + warning/32 border).
final class T3Box: NSView {
    let stack = NSStackView()
    private let fill: NSColor, stroke: NSColor
    init(fill: NSColor, stroke: NSColor) {
        self.fill = fill; self.stroke = stroke
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                                     stack.topAnchor.constraint(equalTo: topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)])
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirty: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: CGFloat(T3Theme.controlRadius), yRadius: CGFloat(T3Theme.controlRadius))
        fill.setFill(); p.fill(); stroke.setStroke(); p.lineWidth = 1; p.stroke()
    }
}

/// Flat view filled with a theme colour (window ground, footer hairline).
final class FillView: NSView {
    var color: NSColor { didSet { needsDisplay = true } }
    init(_ c: NSColor) { color = c; super.init(frame: .zero); translatesAutoresizingMaskIntoConstraints = false }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirty: NSRect) { color.setFill(); bounds.fill() }
}
