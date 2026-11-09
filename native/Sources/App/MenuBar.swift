import AppKit
import BridgeCore

/// Compact Graphite Blue content of the menu-bar popover (same view in the app and in previews).
/// One current action; context quiet; details on demand; warnings always visible; Settings… and Quit.
final class MenuView: NSView {
    static let width: CGFloat = 340
    private let pad: CGFloat = 16
    private var inner: CGFloat { Self.width - pad * 2 }

    let status = StatusMark()
    let headline = T3Type.label("", size: 15, weight: .semibold, color: NSColor(T3Theme.text), line: 20, width: 308)
    let support = T3Type.label("", size: 13, color: NSColor(T3Theme.textMuted), line: 18, width: 308)
    let action = T3Button("", style: .primary)
    let secondary = T3Button("", style: .outline)
    let message = T3Type.label("", size: 12, color: NSColor(T3Theme.textMuted), line: 16, width: 308)
    let warnings = NSStackView()
    let contextBox = T3Box(fill: NSColor(T3Theme.contextFill), stroke: NSColor(T3Theme.contextBorder))
    let details = T3Button("Details", style: .ghost)
    let settings = T3Button("Settings…", style: .ghost)
    let quit = T3Button("Quit", style: .ghost)
    private(set) var expanded = false
    private var lastView: Setup.View?
    private let stack = NSStackView(), actions = NSStackView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        let brand = NSStackView(views: [T3Type.label("T3", size: 13, weight: .bold, color: NSColor(T3Theme.text)),
                                        T3Type.label("for WoW", size: 14, weight: .medium, color: NSColor(T3Theme.textMuted))])
        brand.orientation = .horizontal; brand.alignment = .firstBaseline; brand.spacing = 5
        brand.setAccessibilityElement(true); brand.setAccessibilityLabel("T3 for WoW")
        let header = NSStackView(views: [brand, NSView(), status]); header.orientation = .horizontal; header.alignment = .centerY
        actions.orientation = .horizontal; actions.spacing = 8; actions.addArrangedSubview(action); actions.addArrangedSubview(secondary)
        action.keyEquivalent = "\r"
        warnings.orientation = .vertical; warnings.alignment = .leading; warnings.spacing = 8
        let hair = FillView(NSColor(T3Theme.border))
        let footer = NSStackView(views: [details, NSView(), settings, quit]); footer.orientation = .horizontal; footer.alignment = .centerY; footer.spacing = 4
        quit.keyEquivalent = "q"; quit.keyEquivalentModifierMask = [.command]
        details.target = self; details.action = #selector(toggleExpanded)
        for v in [header, headline, support, actions, message, warnings, contextBox, hair, footer] as [NSView] { stack.addArrangedSubview(v) }
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        stack.setCustomSpacing(14, after: header); stack.setCustomSpacing(4, after: headline); stack.setCustomSpacing(14, after: support)
        stack.setCustomSpacing(10, after: actions); stack.setCustomSpacing(14, after: message); stack.setCustomSpacing(10, after: warnings)
        stack.setCustomSpacing(14, after: contextBox); stack.setCustomSpacing(8, after: hair)
        stack.edgeInsets = NSEdgeInsets(top: pad, left: pad, bottom: 10, right: pad)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let ground = FillView(NSColor(T3Theme.canvas))
        addSubview(ground); addSubview(stack)
        NSLayoutConstraint.activate([
            ground.leadingAnchor.constraint(equalTo: leadingAnchor), ground.trailingAnchor.constraint(equalTo: trailingAnchor),
            ground.topAnchor.constraint(equalTo: topAnchor), ground.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
            header.widthAnchor.constraint(equalToConstant: inner), warnings.widthAnchor.constraint(equalToConstant: inner),
            contextBox.widthAnchor.constraint(equalToConstant: inner), hair.widthAnchor.constraint(equalToConstant: inner),
            hair.heightAnchor.constraint(equalToConstant: 1), footer.widthAnchor.constraint(equalToConstant: inner),
        ])
    }
    required init?(coder: NSCoder) { nil }

    var onResize: (() -> Void)?
    @objc func toggleExpanded() { setExpanded(!expanded); onResize?() }
    func setExpanded(_ e: Bool) { expanded = e; if let v = lastView { rebuildContext(v) } }

    private func rebuildContext(_ v: Setup.View) {
        contextBox.stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let labelW: CGFloat = 92
        func line(_ label: String, _ value: String, tone: Setup.Tone? = nil) -> NSView {
            // The 92 pt column fits short names; the full name stays the accessibility label.
            let shown = ["World of Warcraft": "WoW", "Screen Recording": "Capture"][label] ?? label
            let l = T3Type.label(shown, size: 12, weight: .medium, color: NSColor(T3Theme.textMuted))
            l.setAccessibilityLabel(label)
            l.widthAnchor.constraint(equalToConstant: labelW).isActive = true
            let val = T3Type.label(value, size: 12, color: NSColor(T3Theme.text), line: 16, width: inner - 24 - labelW - 22)
            var views: [NSView] = []
            if let tone { views.append(DotView(StatusMark.color(tone))) }
            views += [l, val]
            let h = NSStackView(views: views); h.orientation = .horizontal; h.alignment = .firstBaseline; h.spacing = 8
            return h
        }
        for c in v.context { contextBox.stack.addArrangedSubview(line(c.label, c.value)) }
        if expanded {
            let sep = FillView(NSColor(T3Theme.border)); sep.heightAnchor.constraint(equalToConstant: 1).isActive = true
            sep.widthAnchor.constraint(equalToConstant: inner - 24).isActive = true
            contextBox.stack.addArrangedSubview(sep)
            for r in v.rows { contextBox.stack.addArrangedSubview(line(r.label, r.detail, tone: r.ok ? .good : .neutral)) }
        }
        details.title = expanded ? "Hide details" : "Details"
    }

    func apply(_ v: Setup.View, note: String) {
        lastView = v
        status.set(v.statusLabel, v.tone)
        T3Type.set(headline, v.headline, size: 15, weight: .semibold, color: NSColor(T3Theme.text), line: 20)
        T3Type.set(support, v.summary, size: 13, color: NSColor(T3Theme.textMuted), line: 18)
        action.title = v.actionTitle; action.isHidden = v.actionTitle.isEmpty
        secondary.title = v.secondaryTitle; secondary.isHidden = v.secondaryAction == nil
        actions.isHidden = action.isHidden && secondary.isHidden
        T3Type.set(message, note, size: 12, color: NSColor(T3Theme.textMuted), line: 16); message.isHidden = note.isEmpty
        warnings.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for w in v.warnings {
            let box = T3Box(fill: NSColor(T3Theme.warningSurface), stroke: NSColor(T3Theme.warning, alpha: 0.32))
            box.stack.addArrangedSubview(T3Type.label(w, size: 12, color: NSColor(T3Theme.warningForeground), line: 16, width: inner - 24))
            box.widthAnchor.constraint(equalToConstant: inner).isActive = true
            warnings.addArrangedSubview(box)
        }
        warnings.isHidden = v.warnings.isEmpty
        rebuildContext(v)
    }

    var fittedSize: NSSize { layoutSubtreeIfNeeded(); return NSSize(width: Self.width, height: ceil(fittingSize.height)) }
}

/// Menu-bar item title: "T3" plus a tone dot when the owner should look (no permanent window, no Dock icon).
enum MenuBarTitle {
    static func make(_ v: Setup.View) -> NSAttributedString {
        let s = NSMutableAttributedString(string: "T3", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
        if (v.tone != .good && v.tone != .neutral) || (v.action != .none && v.action != .startGame) {
            s.append(NSAttributedString(string: " ●", attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: StatusMark.color(v.tone == .neutral ? .warn : v.tone), .baselineOffset: 1]))
        }
        return s
    }
}
