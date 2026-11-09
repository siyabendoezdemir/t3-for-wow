import AppKit
import BridgeCore

/// The one status view used by the app AND by `--export-previews` (same code, synthetic input).
/// T3 standalone grammar (standalone-page.tsx): wordmark row with quiet status context → 24 → title
/// 20/25 semibold → 8 → support 14/20 muted → 24 → actions → 24 → quiet context box (details on
/// demand; real warnings always visible) → hairline footer with the login switch and Disconnect.
final class StatusView: NSView {
    static let width = CGFloat(T3Theme.windowWidth)
    private let pad = CGFloat(T3Theme.panelPadding)
    private var inner: CGFloat { Self.width - pad * 2 }

    let status = StatusMark()
    let headline = T3Type.label("", size: T3Theme.titleSize, weight: .semibold, color: NSColor(T3Theme.text), line: T3Theme.titleLine, width: CGFloat(T3Theme.windowWidth - 48))
    let support = T3Type.label("", size: T3Theme.bodySize, color: NSColor(T3Theme.textMuted), line: T3Theme.bodyLine, width: CGFloat(T3Theme.windowWidth - 48))
    let action = T3Button("", style: .primary)
    let secondary = T3Button("", style: .outline)
    let message = T3Type.label("", size: T3Theme.smallSize, color: NSColor(T3Theme.textMuted), line: 16, width: CGFloat(T3Theme.windowWidth - 48))
    let warnings = NSStackView()
    let contextBox = T3Box(fill: NSColor(T3Theme.contextFill), stroke: NSColor(T3Theme.contextBorder))
    let detailsToggle = T3Button("Show details", style: .ghost)
    let login = T3Switch("Open at login")
    let disconnect = T3Button("Disconnect", style: .ghost)
    let uninstall = T3Button("Uninstall…", style: .ghost)
    private(set) var detailsOpen = false
    private var lastView: Setup.View?
    private let stack = NSStackView(), actions = NSStackView(), footer = NSStackView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 300))
        // Brand row: "T3" wordmark text + product name, context on the right (no T3 artwork copied).
        let brand = NSStackView(views: [T3Type.label("T3", size: 15, weight: .bold, color: NSColor(T3Theme.text)),
                                        T3Type.label("for WoW", size: 18, weight: .medium, color: NSColor(T3Theme.textMuted))])
        brand.orientation = .horizontal; brand.alignment = .firstBaseline; brand.spacing = 6
        brand.setAccessibilityElement(true); brand.setAccessibilityLabel("T3 for WoW")
        let brandRow = NSStackView(views: [brand, NSView(), status]); brandRow.orientation = .horizontal; brandRow.alignment = .centerY
        actions.orientation = .horizontal; actions.spacing = 8; actions.addArrangedSubview(action); actions.addArrangedSubview(secondary)
        warnings.orientation = .vertical; warnings.alignment = .leading; warnings.spacing = 8
        let hair = FillView(NSColor(T3Theme.border))
        footer.orientation = .horizontal; footer.alignment = .centerY
        footer.addArrangedSubview(login); footer.addArrangedSubview(NSView()); footer.addArrangedSubview(disconnect); footer.addArrangedSubview(uninstall)
        detailsToggle.target = self; detailsToggle.action = #selector(toggleDetails)
        action.keyEquivalent = "\r"            // Return triggers the one current action

        for v in [brandRow, headline, support, actions, message, warnings, contextBox, hair, footer] as [NSView] { stack.addArrangedSubview(v) }
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        stack.setCustomSpacing(CGFloat(T3Theme.brandToTitle), after: brandRow)
        stack.setCustomSpacing(CGFloat(T3Theme.titleToSupport), after: headline)
        stack.setCustomSpacing(CGFloat(T3Theme.sectionGap), after: support)
        stack.setCustomSpacing(12, after: actions)
        stack.setCustomSpacing(CGFloat(T3Theme.sectionGap), after: message)
        stack.setCustomSpacing(12, after: warnings)
        stack.setCustomSpacing(CGFloat(T3Theme.sectionGap), after: contextBox)
        stack.setCustomSpacing(14, after: hair)
        stack.edgeInsets = NSEdgeInsets(top: 44, left: pad, bottom: 18, right: pad) // 44: below the window's traffic lights
        stack.translatesAutoresizingMaskIntoConstraints = false
        let ground = FillView(NSColor(T3Theme.canvas)); ground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ground); addSubview(stack)
        NSLayoutConstraint.activate([
            ground.leadingAnchor.constraint(equalTo: leadingAnchor), ground.trailingAnchor.constraint(equalTo: trailingAnchor),
            ground.topAnchor.constraint(equalTo: topAnchor), ground.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
            brandRow.widthAnchor.constraint(equalToConstant: inner), contextBox.widthAnchor.constraint(equalToConstant: inner),
            warnings.widthAnchor.constraint(equalToConstant: inner), footer.widthAnchor.constraint(equalToConstant: inner),
            hair.widthAnchor.constraint(equalToConstant: inner), hair.heightAnchor.constraint(equalToConstant: 1),
        ])
    }
    required init?(coder: NSCoder) { nil }

    @objc func toggleDetails() { detailsOpen.toggle(); if let v = lastView { rebuildContext(v) }; if let w = window { fit(in: w) } }
    func setDetails(open: Bool) { detailsOpen = open; if let v = lastView { rebuildContext(v) } }

    private func rebuildContext(_ v: Setup.View) {
        contextBox.stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let labelW: CGFloat = 112
        func line(_ label: String, _ value: String, tone: Setup.Tone? = nil) -> NSView {
            let l = T3Type.label(label, size: 12, weight: .medium, color: NSColor(T3Theme.textMuted))
            l.widthAnchor.constraint(equalToConstant: labelW).isActive = true
            let val = T3Type.label(value, size: 12, color: NSColor(T3Theme.text), line: 16, width: inner - 24 - labelW - 22)
            var views: [NSView] = []
            if let tone { let d = DotView(StatusMark.color(tone)); views.append(d) }
            views += [l, val]
            let h = NSStackView(views: views); h.orientation = .horizontal; h.alignment = .firstBaseline; h.spacing = 8
            return h
        }
        for c in v.context { contextBox.stack.addArrangedSubview(line(c.label, c.value)) }
        if detailsOpen {
            let sep = FillView(NSColor(T3Theme.border)); sep.heightAnchor.constraint(equalToConstant: 1).isActive = true
            sep.widthAnchor.constraint(equalToConstant: inner - 24).isActive = true
            contextBox.stack.addArrangedSubview(sep)
            for r in v.rows { contextBox.stack.addArrangedSubview(line(r.label, r.detail, tone: r.ok ? .good : .neutral)) }
        }
        detailsToggle.title = detailsOpen ? "Hide details" : "Show details"
        contextBox.stack.addArrangedSubview(detailsToggle)
        contextBox.stack.setCustomSpacing(4, after: contextBox.stack.arrangedSubviews[contextBox.stack.arrangedSubviews.count - 2])
    }

    func apply(_ v: Setup.View, loginOn: Bool, note: String) {
        lastView = v
        status.set(v.statusLabel, v.tone)
        T3Type.set(headline, v.headline, size: T3Theme.titleSize, weight: .semibold, color: NSColor(T3Theme.text), line: T3Theme.titleLine)
        T3Type.set(support, v.summary, size: T3Theme.bodySize, color: NSColor(T3Theme.textMuted), line: T3Theme.bodyLine)
        action.title = v.actionTitle; action.isHidden = v.actionTitle.isEmpty
        secondary.title = v.secondaryTitle; secondary.isHidden = v.secondaryAction == nil
        actions.isHidden = action.isHidden && secondary.isHidden
        T3Type.set(message, note, size: T3Theme.smallSize, color: NSColor(T3Theme.textMuted), line: 16); message.isHidden = note.isEmpty
        warnings.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for w in v.warnings {
            let box = T3Box(fill: NSColor(T3Theme.warningSurface), stroke: NSColor(T3Theme.warning, alpha: 0.32))
            box.stack.addArrangedSubview(T3Type.label(w, size: 12, color: NSColor(T3Theme.warningForeground), line: 16, width: inner - 24))
            box.widthAnchor.constraint(equalToConstant: inner).isActive = true
            warnings.addArrangedSubview(box)
        }
        warnings.isHidden = v.warnings.isEmpty
        rebuildContext(v)
        login.state = loginOn ? .on : .off
        disconnect.isHidden = !v.showDisconnect
    }

    /// Resizes the window so all wrapped content fits.
    func fit(in window: NSWindow) {
        layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: Self.width, height: ceil(fittingSize.height)))
    }
}

final class DotView: NSView {
    let color: NSColor
    init(_ c: NSColor) { color = c; super.init(frame: .zero); translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 6).isActive = true; heightAnchor.constraint(equalToConstant: 6).isActive = true }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirty: NSRect) { color.setFill(); NSBezierPath(ovalIn: bounds).fill() }
}

/// Menu-bar utility: an NSStatusItem with a transient popover; no Dock icon (LSUIElement + .accessory)
/// and no permanent window. The full Settings/recovery window opens only on the owner's request.
/// Clicking elsewhere closes the popover, never the bridge; Quit (popover button or ⌘Q) quits.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    lazy var ctl = AppController()   // created only in normal mode, never by the preview exporter
    var item: NSStatusItem!
    let popover = NSPopover()
    let menu = MenuView()
    var window: NSWindow?            // Settings/recovery window, created on demand
    let status = StatusView()
    var note = ""

    static func makeWindow(_ content: NSView) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: StatusView.width, height: 300),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "T3 for WoW Settings"       // kept for the Window menu and accessibility
        w.titleVisibility = .hidden; w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.appearance = NSAppearance(named: .darkAqua)   // Graphite Blue is a dark theme
        w.backgroundColor = NSColor(T3Theme.canvas)
        w.isReleasedWhenClosed = false; w.contentView = content
        return w
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self; item.button?.action = #selector(togglePopover(_:))
        item.button?.setAccessibilityLabel("T3 for WoW")
        let vc = NSViewController(); vc.view = menu
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        menu.action.target = self; menu.action.action = #selector(doAction)
        menu.secondary.target = self; menu.secondary.action = #selector(doSecondary)
        menu.settings.target = self; menu.settings.action = #selector(openSettings)
        menu.quit.target = NSApp; menu.quit.action = #selector(NSApplication.terminate(_:))
        menu.onResize = { [weak self] in self?.fitPopover() }
        status.action.target = self; status.action.action = #selector(doAction)
        status.secondary.target = self; status.secondary.action = #selector(doSecondary)
        status.login.target = self; status.login.action = #selector(toggleLogin)
        status.disconnect.target = self; status.disconnect.action = #selector(disconnect)
        status.uninstall.target = self; status.uninstall.action = #selector(confirmUninstall)
        ctl.onChange = { [weak self] in self?.render() }
        ctl.start()
        render()
        // Private deployment diagnostic: one explicit, owner-requested ScreenCaptureKit check at launch.
        // Takes no credentials or message input; never repeats on its own.
        if CommandLine.arguments.contains("--verify-capture-once") { ctl.verifyCapture() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    func buildMenu() {
        // Kept although the menu bar is hidden for an accessory app: it provides ⌘C/⌘V/⌘A/⌘Q/⌘W
        // key equivalents to the popover, the Settings window and system dialogs.
        let main = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "About T3 for WoW", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit T3 for WoW", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; main.addItem(appItem)
        let editItem = NSMenuItem(), edit = NSMenu(title: "Edit")
        for (t, s, k) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: t, action: s, keyEquivalent: k)
        }
        editItem.submenu = edit; main.addItem(editItem)
        let winItem = NSMenuItem(), win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win; main.addItem(winItem)
        NSApp.mainMenu = main
    }

    func render() {
        let v = Setup.evaluate(ctl.facts())
        item?.button?.attributedTitle = MenuBarTitle.make(v)
        item?.button?.setAccessibilityLabel("T3 for WoW: \(v.statusLabel)")
        menu.apply(v, note: note)
        if popover.isShown { fitPopover() }
        if let w = window {
            status.apply(v, loginOn: ctl.openAtLogin, note: note)
            status.fit(in: w)
        }
    }
    func fitPopover() { popover.contentSize = menu.fittedSize }
    func say(_ s: String) { note = s; render() }

    @objc func togglePopover(_ sender: Any?) {
        if popover.isShown { popover.performClose(sender); return }
        guard let b = item.button else { return }
        render(); fitPopover()
        NSApp.activate()                       // keyboard focus for Return / ⌘Q in the popover
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
    }

    /// Owner-only Settings/recovery: details, Open at login (off unless the owner turns it on), Disconnect.
    @objc func openSettings() {
        popover.performClose(nil)
        if window == nil { let w = Self.makeWindow(status); w.delegate = self; window = w }
        render(); window?.center()
        NSApp.activate(); window?.makeKeyAndOrderFront(nil)
    }

    /// System dialogs need the app active to take focus (accessory apps are not activated by default).
    private func prepareForDialog() { popover.performClose(nil); NSApp.activate() }

    @objc func doAction() {
        switch Setup.evaluate(ctl.facts()).action {
        case .findT3: askForT3Address()
        case .connectT3: startPairing(upgrade: false)
        case .retryKeychain: ctl.loadGrant(); render()
        case .resetSavedApproval: confirmReset()
        case .chooseWoW: chooseFolder()
        case .installAddon: say(ctl.install())
        case .allowScreenRecording:
            // Owner click: ask ScreenCaptureKit itself (the OS may show its own prompt). No other API path.
            prepareForDialog()
            say("Checking capture access with macOS…")
            ctl.verifyCapture()
        default: break
        }
    }

    @objc func doSecondary() {
        if Setup.evaluate(ctl.facts()).secondaryAction == .reconnectFullAccess { startPairing(upgrade: true) }
    }

    /// Always the owner's click; T3's own page asks, the owner chooses the access level there.
    func startPairing(upgrade: Bool) {
        say((upgrade ? "On the T3 page that just opened, choose Full access and Approve. Afterwards you can revoke the older link in T3 → Settings → Connections. " : "")
            + Setup.accessExplanation
            + " If T3's page asks for a pairing code, see \"Pairing code\" in the install guide; type the code into T3's page, never into this app.")
        ctl.pair { [weak self] err in DispatchQueue.main.async { self?.say(err ?? "Approved. Checking T3…") } }
    }

    func confirmReset() {
        prepareForDialog()
        let a = NSAlert()
        a.messageText = "Reset the saved T3 approval?"
        a.informativeText = "The approval saved by T3 for WoW in your Keychain cannot be read. Resetting deletes only that one item; nothing else in your Keychain or in T3 changes. You will approve T3 again afterwards."
        a.addButton(withTitle: "Reset"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        say(ctl.removeSavedApproval())
    }

    func chooseFolder() {
        prepareForDialog()
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
        p.message = "Choose your WoW: Forever game folder (the one containing Interface and WTF), or its Interface/AddOns folder."
        guard p.runModal() == .OK, let picked = p.url else { return }   // cancelled: nothing changes
        if let why = ctl.select(picked: picked) { say("That folder cannot be used: \(why).") } else { say("Game folder selected.") }
    }

    func askForT3Address() {
        prepareForDialog()
        let a = NSAlert(); a.messageText = "Where is your T3?"; a.informativeText = "T3 is not running on this Mac. Start T3, or enter the address of your own T3 (for example http://127.0.0.1:3773)."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24)); a.accessoryView = f
        a.addButton(withTitle: "Use Address"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn, let u = URL(string: f.stringValue.trimmingCharacters(in: .whitespaces)), u.scheme == "http" || u.scheme == "https" else { return }
        ctl.setT3Address(u); render()
    }

    @objc func toggleLogin() {
        do { try ctl.setOpenAtLogin(status.login.state == .on); render() } catch { say("macOS did not allow it: \(error.localizedDescription). You can approve it in System Settings → General → Login Items.") }
    }

    @objc func disconnect() { say(ctl.removeSavedApproval()) }

    /// Owner-confirmed removal of everything this app put on the Mac. Refused while the game runs.
    @objc func confirmUninstall() {
        prepareForDialog()
        if ctl.gameRunning { say("Quit World of Warcraft first, then choose Uninstall again. Nothing was removed."); return }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Uninstall T3 for WoW?"
        a.informativeText = "This removes the T3 for WoW addon and its delivery folders from your game, this app's saved T3 approval from your Keychain, its Open at login setting, and its local settings and logs. Other addons, your game settings and your T3 stay untouched. Afterwards, revoke the connection in T3 → Settings → Connections and move this app to the Trash."
        a.addButton(withTitle: "Uninstall"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        // The game may have been started while the dialog was open; uninstallEverything re-checks too.
        let report = ctl.uninstallEverything()
        if report.refused { say(report.text); return }
        let done = NSAlert()
        done.messageText = report.ok ? "T3 for WoW was removed" : "T3 for WoW was only partly removed"
        done.informativeText = report.text + "\n\nNext: revoke the connection in T3 → Settings → Connections, then move \"T3 for WoW\" from Applications to the Trash. The app quits now."
        done.addButton(withTitle: "Quit")
        done.runModal()
        NSApp.terminate(nil)
    }
}

/// `T3ForWoW --export-previews DIR`: renders the REAL menu popover and Settings views for SYNTHETIC
/// states to opaque 2x PNGs, then exits. Runs before (and instead of) any controller, Keychain,
/// config, capture, permission, pairing, network, status-item or login-item code.
@MainActor enum PreviewExporter {
    static func run(_ dir: URL) -> Int32 {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var ok = true
        func menuShot(_ name: String, _ facts: Setup.Facts, expanded: Bool) {
            let view = MenuView()
            view.apply(Setup.evaluate(facts), note: "")
            view.setExpanded(expanded)
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittedSize), styleMask: [.borderless], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: .darkAqua); w.backgroundColor = NSColor(T3Theme.canvas); w.contentView = view
            w.setContentSize(view.fittedSize)
            ok = export(w, to: dir.appendingPathComponent("\(name).png")) && ok
        }
        func settingsShot(_ name: String, _ facts: Setup.Facts, details: Bool = false) {
            let view = StatusView()
            let w = AppDelegate.makeWindow(view)
            view.apply(Setup.evaluate(facts), loginOn: false, note: "")
            view.setDetails(open: details)
            view.fit(in: w)
            ok = export(w, to: dir.appendingPathComponent("\(name).png")) && ok
        }
        let short = { (s: PreviewFixtures.State) in s.name.replacingOccurrences(of: "SYNTHETIC-", with: "") }
        // Menu popover first: unpaired and connected collapsed + expanded, then every recovery/access state.
        for s in PreviewFixtures.all.prefix(2) {
            menuShot("SYNTHETIC-menu-\(short(s))", s.facts, expanded: false)
            menuShot("SYNTHETIC-menu-\(short(s))-expanded", s.facts, expanded: true)
        }
        for s in PreviewFixtures.all.dropFirst(2) { menuShot("SYNTHETIC-menu-\(short(s))", s.facts, expanded: false) }
        // Settings/recovery window (opened only from "Settings…").
        for s in PreviewFixtures.all { settingsShot("SYNTHETIC-settings-\(short(s))", s.facts) }
        settingsShot("SYNTHETIC-settings-unpaired-details-open", PreviewFixtures.all[0].facts, details: true)
        ok = exportControlStates(dir.appendingPathComponent("SYNTHETIC-control-states.png")) && ok
        return ok ? 0 : 1
    }

    /// Every control style in idle / hover / pressed / focus / disabled, drawn by the real controls.
    static func exportControlStates(_ url: URL) -> Bool {
        let states: [(String, ForcedState)] = [("Idle", .none), ("Hover", .hover), ("Pressed", .pressed), ("Focus", .focus), ("Disabled", .disabled)]
        let grid = NSStackView(); grid.orientation = .vertical; grid.alignment = .leading; grid.spacing = 14
        grid.edgeInsets = NSEdgeInsets(top: 44, left: 24, bottom: 24, right: 24); grid.translatesAutoresizingMaskIntoConstraints = false
        for (name, st) in states {
            let primary = T3Button("Connect T3…", style: .primary), outline = T3Button("Reconnect with Full access…", style: .outline), ghost = T3Button("Disconnect", style: .ghost)
            let sw = T3Switch("Open at login"); sw.state = name == "Idle" ? .off : .on
            for b in [primary, outline, ghost] { b.forced = st }; sw.forced = st
            let label = T3Type.label(name, size: 12, weight: .medium, color: NSColor(T3Theme.textMuted)); label.widthAnchor.constraint(equalToConstant: 64).isActive = true
            let row = NSStackView(views: [label, primary, outline, ghost, sw]); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 12
            grid.addArrangedSubview(row)
        }
        let root = NSView(); let ground = FillView(NSColor(T3Theme.canvas)); ground.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(ground); root.addSubview(grid)
        NSLayoutConstraint.activate([ground.leadingAnchor.constraint(equalTo: root.leadingAnchor), ground.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                                     ground.topAnchor.constraint(equalTo: root.topAnchor), ground.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                                     grid.leadingAnchor.constraint(equalTo: root.leadingAnchor), grid.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                                     grid.topAnchor.constraint(equalTo: root.topAnchor), grid.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        let w = AppDelegate.makeWindow(root)
        w.setContentSize(NSSize(width: 820, height: 420))   // wider than the status window: five controls per row
        root.layoutSubtreeIfNeeded()
        w.setContentSize(root.fittingSize)
        return export(w, to: url)
    }

    static func export(_ window: NSWindow, to url: URL) -> Bool {
        guard let view = window.contentView else { return false }
        window.layoutIfNeeded(); view.layoutSubtreeIfNeeded(); view.needsDisplay = true; view.displayIfNeeded()
        let size = view.bounds.size, scale: CGFloat = 2
        func rep() -> NSBitmapImageRep? {
            let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)
            r?.size = size
            return r
        }
        guard let content = rep(), let final = rep(), let ctx = NSGraphicsContext(bitmapImageRep: final) else { return false }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: content)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            (window.backgroundColor ?? NSColor(T3Theme.canvas)).setFill()
            NSRect(origin: .zero, size: size).fill()
            content.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            ctx.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let data = final.bitmapData, let png = final.representation(using: .png, properties: [:]) else { return false }
        let report = PreviewCheck.evaluate(rgba: [UInt8](UnsafeBufferPointer(start: data, count: final.bytesPerRow * final.pixelsHigh)),
                                           pixelsWide: final.pixelsWide, pixelsHigh: final.pixelsHigh, bytesPerRow: final.bytesPerRow, pointsWide: Double(size.width))
        do { try png.write(to: url) } catch { print("preview: cannot write \(url.path)"); return false }
        print("preview: \(url.lastPathComponent) \(final.pixelsWide)x\(final.pixelsHigh)px (\(Int(size.width))x\(Int(size.height))pt) " +
              "check \(report.pass ? "PASS" : "FAIL") opaque=\(report.opaque) scale=\(report.scale) content=\(String(format: "%.1f%%", report.contentFraction * 100))")
        return report.pass
    }
}

MainActor.assumeIsolated {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--export-previews"), i + 1 < args.count {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        exit(PreviewExporter.run(URL(fileURLWithPath: args[i + 1])))
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu-bar utility: no Dock icon
    withExtendedLifetime(delegate) { app.run() }
}
