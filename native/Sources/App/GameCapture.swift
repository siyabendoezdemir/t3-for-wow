import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import BridgeCore

/// Captures ONLY the World of Warcraft window, and ONLY its top 96-point band (where the addon draws
/// its strip), at native pixel scale, 2 frames per second, with the owner's Screen Recording
/// permission. No audio, no cursor, nothing stored.
///
/// Root cause fixed here (af0441a): `SCContentFilter(desktopIndependentWindow:)` IGNORES
/// `SCStreamConfiguration.sourceRect` (Apple documentation), so the whole game window was scaled into
/// a strip-height output and no frame could decode. Now: `SCContentFilter(display:including:[wow])`
/// (only the WoW window's content, on the display that shows its top band) with a display-relative
/// `sourceRect` from BridgeCore.CapturePlanner, whose geometry/privacy invariants are unit-tested.
/// Lifecycle by generation (BridgeCore.CaptureLifecycle): plan changes restart, stale callbacks are ignored.
final class GameCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Info {
        var state = "starting"; var windowID: UInt32?; var windowFrame: CaptureRect?; var plan: CapturePlan?
        // capture-access truth, copied from `access` on main for the diagnostics snapshot
        var preflight = false; var sdkAccess = "unknown"; var sdkAttempts = 0; var sdkErrorDomain: String?; var sdkErrorCode: Int?
        // SDK's own description of the filter actually built (numbers only)
        var filterStyle: String?; var filterContentRect: CaptureRect?; var filterPointPixelScale: Double?
        var configuredColorSpace: String?
    }
    /// Numeric facts about delivered frames (capture queue only). No pixels are kept.
    private struct FrameFacts { var w: Int?; var h: Int?; var fourCC: String?; var contentRect: CaptureRect?; var contentScale: Double?; var scaleFactor: Double?
                                var band: BandInspection?; var lastInspect = -1e18
                                var primaries: String?; var transfer: String?; var colorSpace: String? }
    private var frameFacts = FrameFacts()
    /// Header context when nothing decodes (capture queue only; category only).
    private let context = ContextObserver()

    private let lifecycle = CaptureLifecycle()       // main only
    /// The SDK, not the legacy preflight, decides (BridgeCore.CaptureAccess). Main only.
    let access = CaptureAccess()
    private var streams: [Int: SCStream] = [:]       // main only
    private let queue = DispatchQueue(label: "t3wow.capture")
    private let stats = CaptureStats()               // capture queue only
    private let lock = NSLock()
    private var info = Info()                         // under lock
    var onFrame: ((GameFrame) -> Void)?
    var onState: ((String) -> Void)?

    /// Legacy advisory signal only; ScreenCaptureKit's own result is authoritative.
    static func preflight() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Descriptor for BridgeCore.GameIdentity (bundle, app name, layer, frame; never the window title).
    static func candidate(_ w: SCWindow) -> GameIdentity.Candidate {
        GameIdentity.Candidate(windowID: w.windowID, bundleID: w.owningApplication?.bundleIdentifier, appName: w.owningApplication?.applicationName,
                               layer: w.windowLayer, frame: CaptureRect(x: w.frame.minX, y: w.frame.minY, width: w.frame.width, height: w.frame.height))
    }

    /// Safe metadata for bridge-status.json (any thread).
    func snapshot(now: Double) -> BridgeStatus.Capture {
        lock.lock(); let i = info; lock.unlock()
        var displayID: UInt32?
        if let p = i.plan, case .displayIncludingOnlyWindow(let d, _) = p.filter { displayID = d }
        var c = queue.sync {   // `stats`/`frameFacts` live on the capture queue; never called from that queue
            var x = BridgeStatus.Capture(state: i.state, windowID: i.windowID, windowFrame: i.windowFrame, displayID: displayID, sourceRect: i.plan?.sourceRect,
                                         outputPixels: i.plan.map { [$0.outputWidth, $0.outputHeight] }, scale: i.plan?.scale, stats: stats, now: now)
            x.bufferWidth = frameFacts.w; x.bufferHeight = frameFacts.h; x.pixelFormat = frameFacts.fourCC
            x.frameContentRect = frameFacts.contentRect; x.frameContentScale = frameFacts.contentScale; x.frameScaleFactor = frameFacts.scaleFactor
            x.band = frameFacts.band
            x.context = context.category; x.contextAgeSeconds = context.checkedAt.map { max(0, (now - $0).rounded()) }
            x.bufferColorPrimaries = frameFacts.primaries; x.bufferTransferFunction = frameFacts.transfer; x.bufferColorSpace = frameFacts.colorSpace
            return x
        }
        c.filterStyle = i.filterStyle; c.filterContentRect = i.filterContentRect; c.filterPointPixelScale = i.filterPointPixelScale
        c.configuredColorSpace = i.configuredColorSpace
        c.legacyPreflight = i.preflight; c.sdkAccess = i.sdkAccess; c.sdkAttempts = i.sdkAttempts
        c.sdkErrorDomain = i.sdkErrorDomain; c.sdkErrorCode = i.sdkErrorCode
        return c
    }
    private func setInfo(_ f: (inout Info) -> Void) { lock.lock(); f(&info); lock.unlock() }
    private func report(_ state: String) { syncAccess(); setInfo { $0.state = state }; onState?(state) }
    private func syncAccess() {
        let a = access
        setInfo { $0.sdkAccess = a.state.rawValue; $0.sdkAttempts = a.attempts; $0.sdkErrorDomain = a.lastErrorDomain; $0.sdkErrorCode = a.lastErrorCode }
    }
    /// Diagnostics/UI word for a latched or pending access state.
    private func accessWord() -> String {
        switch access.state { case .denied: return "denied"; case .stopped: return "stoppedByOwner"; case .verifying: return "verifying"; default: return "needsPermission" }
    }
    /// Domain and code only; never userInfo or descriptions.
    private func outcome(_ error: Error) -> CaptureAccess.Outcome { let ns = error as NSError; return CaptureAccess.classify(domain: ns.domain, code: ns.code) }

    /// Explicit owner request ("Check Capture Access", or the one-shot --verify-capture-once launch flag):
    /// asks ScreenCaptureKit itself once, through the normal enumeration path. Main only.
    func verifyOnce() {
        guard let g = access.beginOwnerCheck() else { return }   // single flight: a check is already pending
        report("verifying")
        enumerate(ownerGen: g)
    }

    /// Call on main.
    func refresh() {
        let pre = Self.preflight()
        setInfo { $0.preflight = pre }
        guard access.mayUseSDK(preflight: pre) else {
            if access.state != .verifying { stopAll() }
            report(accessWord())
            return
        }
        enumerate(ownerGen: nil)
    }

    /// The normal ScreenCaptureKit path; the OS enforces Screen Recording here. Only the WoW window is used.
    private func enumerate(ownerGen: Int?) {
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self else { return }
                let result: CaptureAccess.Outcome = (content != nil && error == nil) ? .granted : self.outcome(error ?? NSError(domain: "T3ForWoW.Capture", code: -1, userInfo: nil))
                if let g = ownerGen {
                    // A stale owner check (superseded, or invalidated by a denial/stop meanwhile) must not act.
                    guard self.access.complete(gen: g, result) else { return }
                } else { self.access.observe(result) }
                guard let content, error == nil else {
                    self.stopAll()
                    switch result { case .denied, .stopped: self.report(self.accessWord()); default: self.report("enumerationError") }
                    return
                }
                // A normal success can never unlock a latched denial/stop: only `verified` may capture.
                guard self.access.state == .verified else { self.stopAll(); self.report(self.accessWord()); return }
                let chosen = GameIdentity.choose(content.windows.map(Self.candidate))
                guard let pick = chosen, let wow = content.windows.first(where: { $0.windowID == pick.windowID }) else {
                    self.stopAll(); self.setInfo { $0 = Info() }; self.report("noGame"); return
                }
                let displays = content.displays.map { d in
                    DisplayInfo(id: d.displayID, frame: CaptureRect(x: d.frame.minX, y: d.frame.minY, width: d.frame.width, height: d.frame.height),
                                scale: Double(Self.backingScale(displayID: d.displayID)))
                }
                let wf = CaptureRect(x: wow.frame.minX, y: wow.frame.minY, width: wow.frame.width, height: wow.frame.height)
                guard let plan = CapturePlanner.plan(windowID: wow.windowID, windowFrame: wf, displays: displays),
                      case .displayIncludingOnlyWindow(let displayID, _) = plan.filter,
                      let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    self.stopAll(); self.setInfo { $0.windowID = wow.windowID; $0.windowFrame = wf; $0.plan = nil }; self.report("noPlan"); return
                }
                self.setInfo { $0.windowID = wow.windowID; $0.windowFrame = wf }
                if self.lifecycle.shouldStart(window: wow.windowID, plan: plan.key) { self.start(window: wow, display: display, plan: plan) }
            }
        }
    }

    static func backingScale(displayID: CGDirectDisplayID) -> CGFloat {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }?.backingScaleFactor ?? 2
    }

    private func start(window: SCWindow, display: SCDisplay, plan: CapturePlan) {
        stopAll()
        let gen = lifecycle.begin(window: window.windowID, plan: plan.key)
        setInfo { $0.plan = plan }
        let filter = SCContentFilter(display: display, including: [window])   // only the WoW window's content
        // Record what the SDK says it built (numbers only). A non-display style would mean sourceRect is
        // not honoured: never start such a stream (no silent broadening).
        let style: String
        switch filter.style { case .display: style = "display"; case .window: style = "window"; case .application: style = "application"; default: style = "none" }
        let cr = filter.contentRect
        setInfo { $0.filterStyle = style; $0.filterContentRect = CaptureRect(x: cr.minX, y: cr.minY, width: cr.width, height: cr.height)
                  $0.filterPointPixelScale = Double(filter.pointPixelScale) }
        guard style == "display" else { report("scopeMismatch"); return }
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = CGRect(x: plan.sourceRect.x, y: plan.sourceRect.y, width: plan.sourceRect.width, height: plan.sourceRect.height)
        cfg.width = plan.outputWidth          // native pixels: no scaling of the strip
        cfg.height = plan.outputHeight
        cfg.scalesToFit = false
        // Colour contract: deliver sRGB (what the addon draws) instead of the display's colour space.
        if let name = CaptureColor.requestedColorSpaceName { cfg.colorSpaceName = name as CFString }
        let assigned = cfg.colorSpaceName as String
        setInfo { $0.configuredColorSpace = ColorLabel.configured(assigned) }   // reports what was actually assigned
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        cfg.showsCursor = false
        cfg.capturesAudio = false
        cfg.queueDepth = 3
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        do { try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue) }
        catch { lifecycle.startCompleted(gen: gen, ok: false); report("startError"); return }
        streams[gen] = s
        report("starting")
        s.startCapture { [weak self] err in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.lifecycle.startCompleted(gen: gen, ok: err == nil) else { return } // stale candidate
                if let err {
                    self.streams[gen] = nil
                    let o = self.outcome(err); self.access.observe(o)
                    switch o { case .denied, .stopped: self.report(self.accessWord()); default: self.report("startError") }
                } else {
                    self.access.observe(.granted)
                    guard self.access.state == .verified else { self.stopAll(); self.report(self.accessWord()); return } // latched meanwhile
                    self.report("capturing")
                }
            }
        }
    }

    private func stopAll() {
        for (_, s) in streams { s.stopCapture(completionHandler: nil) }
        streams = [:]
        lifecycle.reset()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            guard let gen = self.streams.first(where: { $0.value === stream })?.key else { return } // an old stream
            self.streams[gen] = nil
            self.lifecycle.stopped(gen: gen)
            let o = self.outcome(error); self.access.observe(o)        // revocation/owner Stop latch: no automatic restart
            switch o { case .denied, .stopped: self.report(self.accessWord()); default: self.report("stopped") }
        }
    }

    // capture queue
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        // Skip idle/blank status frames (no new content) without counting them as decode failures.
        let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first
        if let raw = att?[.status] as? Int, let st = SCFrameStatus(rawValue: raw), st != .complete { return }
        // SDK frame geometry (numbers only)
        if let v = att?[.contentRect], CFGetTypeID(v as CFTypeRef) == CFDictionaryGetTypeID(), let r = CGRect(dictionaryRepresentation: v as! CFDictionary) {
            frameFacts.contentRect = CaptureRect(x: r.minX, y: r.minY, width: r.width, height: r.height)
        }
        frameFacts.contentScale = (att?[.contentScale] as? NSNumber)?.doubleValue
        frameFacts.scaleFactor = (att?[.scaleFactor] as? NSNumber)?.doubleValue
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), stride = CVPixelBufferGetBytesPerRow(pb)
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        frameFacts.w = w; frameFacts.h = h
        frameFacts.fourCC = String(bytes: [24, 16, 8, 0].map { UInt8((fmt >> UInt32($0)) & 0xFF) }, encoding: .ascii)
        // Public-finder inspection of the approved band, at most every 2 s; aggregates only, decode unaffected.
        let now = Date().timeIntervalSince1970
        if fmt == kCVPixelFormatType_32BGRA, now - frameFacts.lastInspect >= 2 {
            frameFacts.lastInspect = now
            frameFacts.band = BandInspector.inspect(bgra: UnsafeRawBufferPointer(start: base, count: stride * h), width: w, height: h, bytesPerRow: stride)
            // Buffer colour tags → whitelisted generic labels only (no profile names or dictionaries).
            frameFacts.primaries = ColorLabel.primaries(CVBufferCopyAttachment(pb, kCVImageBufferColorPrimariesKey, nil) as? String)
            frameFacts.transfer = ColorLabel.transfer(CVBufferCopyAttachment(pb, kCVImageBufferTransferFunctionKey, nil) as? String)
            frameFacts.colorSpace = ColorLabel.space(CVImageBufferGetColorSpace(pb)?.takeUnretainedValue().name as String?)
        }
        let src = base.assumingMemoryBound(to: UInt8.self)
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            let row = src + y * stride
            for x in 0..<w { let o = (y * w + x) * 3; rgb[o] = row[x * 4 + 2]; rgb[o + 1] = row[x * 4 + 1]; rgb[o + 2] = row[x * 4] }
        }
        if let f = stats.process(RGBImage(width: w, height: h, pixels: rgb), now: Date().timeIntervalSince1970) { onFrame?(f); return }
        // Nothing decoded and no finder at all: occasionally classify the header context (logo or not).
        if fmt == kCVPixelFormatType_32BGRA, let b = frameFacts.band, b.finderPrefix < 8, b.looseFinderPrefix < 8 {
            context.maybeObserve(base: UnsafeRawPointer(base), width: w, height: h, bytesPerRow: stride, now: now, reply: queue)
        }
    }
}
