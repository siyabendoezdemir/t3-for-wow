import AppKit
import Security
import ServiceManagement
import BridgeCore

/// Owns the bridge engine and every side effect of the Mac app.
/// Threads: the engine, discovery, install health and all network work run on `queue`; the UI reads
/// only the values published to main (`published`). Nothing on main blocks on `queue`.
final class AppController {
    let queue = DispatchQueue(label: "t3wow.engine")
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("T3ForWoW", isDirectory: true)
    let vault = GrantVault(backend: KeychainBackend())
    let capture = GameCapture()
    var onChange: (() -> Void)?

    // main-thread state
    private(set) var grant: T3Grant?
    private(set) var grantState: Setup.GrantState = .none
    private(set) var lastStripAt = Date.distantPast
    private(set) var restartNeeded = false, restartIsReload = false
    struct Published { var origin: URL?; var resolution: InstallTarget.Resolution = .choose(""); var health: Installer.Health = .notInstalled
                       var candidates = 0; var link = "unpaired"; var aboveAccess = 0; var slotError: String?; var gameAcked = false }
    private(set) var published = Published()

    // queue-only state
    private var engine: Engine!
    private var queueGrant: T3Grant?
    private var bound: String?          // "<fingerprint>|<decision>" the engine is currently set up for
    private var engineAddOns: URL?
    private var timer: DispatchSourceTimer?
    private var tickCount = 0
    private var installState = "noTarget"   // queue-side copy for diagnostics
    /// Private local diagnostics (safe metadata only; see BridgeCore.BridgeStatus).
    private lazy var statusWriter = StatusWriter(url: support.appendingPathComponent("bridge-status.json"))

    var bundledAddon: URL? { Bundle.main.resourceURL?.appendingPathComponent("AddOn/T3ForWoW") }

    private func readConfig() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: support.appendingPathComponent("config.json")))) ?? [:]
    }
    private func writeConfig(_ c: [String: String]) {
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try? atomicWrite(try JSONEncoder().encode(c), to: support.appendingPathComponent("config.json"))
    }

    func start() {
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        queue.sync { self.makeEngine(addOns: nil) } // before anything else touches the engine
        loadGrant()
        capture.onFrame = { [weak self] f in
            DispatchQueue.main.async { self?.lastStripAt = Date() }
            self?.queue.async { self?.engine.onFrame(f); self?.engine.flush() }
        }
        capture.onState = { [weak self] _ in self?.onChange?() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.tickCount += 1
            if self.tickCount % 5 == 0 { self.refreshBackground() }
            self.engine.tick(); self.engine.flush()
            self.publish()
            self.writeStatus()
            if self.tickCount % 3 == 0 { DispatchQueue.main.async { self.capture.refresh(); self.onChange?() } }
        }
        t.resume(); timer = t
    }

    // MARK: queue side

    private func makeEngine(addOns: URL?) {
        engineAddOns = addOns
        let sink = SlotWriter.Sink(SlotWriter(addOnsDir: addOns ?? support.appendingPathComponent("no-game")))
        engine = Engine(ledger: SendLedger(url: support.appendingPathComponent("send-ledger.json")), slots: sink)
        bound = nil
    }

    /// Discovery, install target/health and the grant ↔ origin binding. Runs on `queue`.
    private func refreshBackground() {
        let cfg = readConfig()
        let origin = cfg["t3Origin"].flatMap(URL.init(string:)) ?? T3Discovery.localOrigin()
        let candidates = Installer.discover(roots: Installer.macRoots)
        let resolution = InstallTarget.resolve(configured: cfg["addOnsDir"].map { URL(fileURLWithPath: $0) }, candidates: candidates)
        var health = Installer.Health.notInstalled
        installState = "noTarget"
        if case .use(let dir) = resolution {
            if let b = bundledAddon { health = Installer.health(bundled: b, addOnsDir: dir) }
            if engineAddOns != dir { makeEngine(addOns: dir) }
            switch health { case .ok: installState = "ok"; case .outdated: installState = "outdated"; case .damaged: installState = "damaged"; case .notInstalled: installState = "notInstalled" }
        }
        bind(origin: origin)
        DispatchQueue.main.async {
            self.published.origin = origin; self.published.resolution = resolution
            self.published.health = health; self.published.candidates = candidates.count
            self.onChange?()
        }
    }

    /// The token is only ever paired with the origin it was approved for (BridgeCore.LinkPlanner).
    private func bind(origin: URL?) {
        guard let g = queueGrant else {
            if bound != nil || engine.link != .unpaired { engine.setLink(nil, grant: nil) }
            bound = nil
            return
        }
        let decision = OriginBinding.decide(grant: g, current: origin)
        let key = "\(g.fingerprint)|\(decision)"
        guard key != bound else { return }
        bound = key
        let plan = LinkPlanner.plan(grant: g, current: origin, transport: URLSessionTransport())
        if let client = plan.client { engine.setLink(client, grant: g) } else { engine.setOriginChanged() }
    }

    private func publish() {
        let l = engine.link.rawValue, n = engine.threadsAboveAccess, err = engine.slotWriteError, acked = engine.gameAcked
        DispatchQueue.main.async { self.published.link = l; self.published.aboveAccess = n; self.published.slotError = err; self.published.gameAcked = acked }
    }

    /// Runs on `queue`; throttled to one atomic write every 2 s.
    private func writeStatus() {
        let now = Date().timeIntervalSince1970
        let d = engine.diagnostics(now: now)
        let status = BridgeStatus(writtenAt: now.rounded(), app: BridgeVersion.string, capture: capture.snapshot(now: now),
                                  link: d.link, delivery: d.delivery, install: installState)
        statusWriter.write(status, now: now)
    }

    private func setQueueGrant(_ g: T3Grant?) { queue.async { self.queueGrant = g; self.bound = nil; self.refreshBackground() } }

    // MARK: T3 (main side)

    func loadGrant() {
        switch vault.read() {
        case .found(let g):
            grant = g
            let left = g.expiresAt - Date().timeIntervalSince1970
            grantState = left <= 0 ? .expired : .valid(daysLeft: Int(left / 86400))
            setQueueGrant(left > 0 ? g : nil)
        case .absent: grant = nil; grantState = .none; setQueueGrant(nil)
        case .malformed: grant = nil; grantState = .malformed; setQueueGrant(nil)        // owner decides (Reset)
        case .unavailable: grant = nil; grantState = .keychainUnavailable; setQueueGrant(nil) // never re-pair on our own
        }
        onChange?()
    }

    /// Opens T3's own approval page in the owner's browser and waits for its redirect.
    func pair(completion: @escaping (String?) -> Void) {
        guard let origin = published.origin else { completion("T3 was not found on this Mac. Start T3, or enter its address."); return }
        DispatchQueue.global().async {
            do {
                let cb = try LoopbackCallback()
                let http = URLSessionTransport()
                let p = try OAuthPairing.begin(origin: origin, redirectPort: cb.port, transport: http)
                DispatchQueue.main.async { NSWorkspace.shared.open(p.authorizeURL) }
                guard let q = cb.wait(timeout: 600, page: "T3 for WoW: done. You can close this tab and return to the game.") else { completion("Timed out waiting for approval in T3."); return }
                let g = try OAuthPairing.complete(p, callbackQuery: q, transport: http, now: Date().timeIntervalSince1970)
                let st = self.vault.save(g)
                guard st == SecStatus.success else { completion("Approved, but the Keychain refused to store it (status \(st)). Nothing was connected."); return }
                DispatchQueue.main.async { self.grant = g; self.grantState = .valid(daysLeft: 30); self.setQueueGrant(g); completion(nil) }
            } catch PairingError.denied { completion("You chose Deny in T3. Nothing was connected.") }
            catch { completion("Could not connect: \(error)") }
        }
    }

    /// Owner's Disconnect, or the confirmed Reset of an unreadable record. Truthful about the outcome.
    func removeSavedApproval() -> String {
        switch vault.delete() {
        case .removed:
            grant = nil; grantState = .none; setQueueGrant(nil)
            return "Disconnected here. To revoke it in T3 too, use T3 → Settings → Connections."
        case .failed(let st):
            return "macOS did not allow removing the saved approval (status \(st)). Nothing changed."
        }
    }

    func setT3Address(_ u: URL) { var c = readConfig(); c["t3Origin"] = u.absoluteString; writeConfig(c); queue.async { self.refreshBackground() } }

    // MARK: WoW (main side)

    /// Installs only into the resolved target (the owner's validated selection wins).
    func install() -> String {
        guard case .use(let dir) = published.resolution else { return "Choose your WoW: Forever folder first." }
        guard let bundled = bundledAddon else { return "The addon is missing from this app bundle." }
        do {
            let r = try Installer.install(bundledAddon: bundled, addOnsDir: dir, interface: "16001")
            if gameRunning && r.change != .none { restartNeeded = true; restartIsReload = r.change == .reload }
            queue.async { self.refreshBackground() }
            return "Installed into \(dir.path). Only the T3ForWoW folders were changed."
        } catch {
            queue.async { self.refreshBackground() }
            return "Install failed: \(error.localizedDescription)" // InstallError says whether the previous install was restored
        }
    }

    /// From the folder picker. Cancel (nil) changes nothing; an invalid folder is refused.
    func select(picked: URL?) -> String? {
        guard let dir = InstallTarget.selection(fromPicked: picked) else { return nil }
        if let why = InstallTarget.validate(dir) { return why }
        var c = readConfig(); c["addOnsDir"] = dir.path; writeConfig(c)
        published.resolution = .use(dir)
        queue.async { self.refreshBackground() }
        return nil
    }

    var gameRunning: Bool { NSWorkspace.shared.runningApplications.contains { GameIdentity.isGameApp(bundleID: $0.bundleIdentifier, appName: $0.localizedName) } }

    /// Cheap on main: only published values and NSWorkspace.
    func facts() -> Setup.Facts {
        let running = gameRunning
        if !running { restartNeeded = false }
        var f = Setup.Facts(t3Origin: published.origin, grant: grantState, wowCandidates: 0, addonInstalled: false, restartNeeded: restartNeeded,
                            capturePermission: capture.access.capturePermitted(preflight: GameCapture.preflight()), gameRunning: running, stripSeen: Date().timeIntervalSince(lastStripAt) < 10,
                            link: published.link, linkAccess: grant?.access ?? "none", threadsAboveAccess: published.aboveAccess)
        f.restartIsReload = restartIsReload
        f.slotWriteError = published.slotError
        f.gameAcked = published.gameAcked
        f.captureStopped = capture.access.state == .stopped
        if capture.access.state == .denied {
            f.captureDenied = "\(capture.access.lastErrorDomain ?? "?") \(capture.access.lastErrorCode.map(String.init) ?? "?")"
        }
        switch published.resolution {
        case .use: f.wowCandidates = 1
        case .choose(let why): f.wowCandidates = published.candidates == 1 ? 2 : published.candidates; f.targetProblem = why.isEmpty ? nil : why
        }
        switch published.health {
        case .ok: f.addonInstalled = true
        case .outdated: f.addonInstalled = true; f.installOutdated = true
        case .damaged(let why): f.installIssue = why
        case .notInstalled: break
        }
        return f
    }

    /// Owner-initiated capture-access check through ScreenCaptureKit (main).
    func verifyCapture() { capture.verifyOnce() }

    /// Uninstall (owner-confirmed). The rules live in BridgeCore.Uninstaller (tested with injected
    /// providers): refused while the game runs — re-checked at this boundary and right before any game
    /// file is removed — and every step is reported truthfully.
    func uninstallEverything() -> Uninstaller.Report {
        var dir: URL? = nil
        if case .use(let d) = published.resolution { dir = d }
        let steps = Uninstaller.Steps(
            gameRunning: { [weak self] in self?.gameRunning ?? true },
            addOnsDir: dir,
            removeApproval: { [weak self] in
                guard let self else { return .failed("The app is shutting down.") }
                switch self.vault.delete() {
                case .removed: self.grant = nil; self.grantState = .none; return .done("Removed the saved T3 approval from your Keychain.")
                case .failed(let st): return .failed("macOS did not allow removing the saved approval (status \(st)).")
                }
            },
            disableOpenAtLogin: { [weak self] in
                guard let self, self.openAtLogin else { return .skipped("Open at login was off.") }
                do { try self.setOpenAtLogin(false); return .done("Turned off Open at login.") }
                catch { return .failed("Could not turn off Open at login: \(error.localizedDescription)") }
            },
            removeAppData: { [weak self] in
                guard let self else { return .failed("The app is shutting down.") }
                self.queue.sync { self.timer?.cancel(); self.timer = nil }   // stop status/ledger writes first
                do {
                    if FileManager.default.fileExists(atPath: self.support.path) { try FileManager.default.removeItem(at: self.support) }
                    return .done("Removed this app's settings and logs.")
                } catch { return .failed("Could not remove \(self.support.path): \(error.localizedDescription)") }
            })
        return Uninstaller.run(steps)
    }

    // MARK: login item (only when the owner ticks it)

    var openAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    func setOpenAtLogin(_ on: Bool) throws { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
}
