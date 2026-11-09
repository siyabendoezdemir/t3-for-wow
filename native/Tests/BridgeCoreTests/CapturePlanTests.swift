import Foundation
@testable import BridgeCore

/// Model of what ScreenCaptureKit delivers for a plan, per Apple's SCStreamConfiguration.sourceRect
/// documentation: a single-window filter ignores sourceRect and fits the WHOLE window into the output
/// size (aspect-preserving, letterboxed); a display filter crops sourceRect (display-relative points)
/// and scales it to the output size. Everything outside the included window is black. SYNTHETIC.
enum SCKModel {
    /// `screen`: what the display shows for the included window only, in physical pixels of `display`.
    static func deliver(_ plan: CapturePlan, window: CaptureRect, windowPixels: RGBImage, display: DisplayInfo) -> RGBImage {
        var out = RGBImage(width: plan.outputWidth, height: plan.outputHeight, fill: (0, 0, 0))
        func sampleWindow(_ px: Double, _ py: Double) -> (Int, Int, Int)? {   // window pixel coords
            let x = Int(px), y = Int(py)
            guard x >= 0, y >= 0, x < windowPixels.width, y < windowPixels.height else { return nil }
            return windowPixels.px(x, y)
        }
        switch plan.filter {
        case .singleWindow:
            // sourceRect ignored: the whole window, aspect-fit into the output.
            let s = min(Double(plan.outputWidth) / Double(windowPixels.width), Double(plan.outputHeight) / Double(windowPixels.height))
            let w = Double(windowPixels.width) * s, h = Double(windowPixels.height) * s
            let ox = (Double(plan.outputWidth) - w) / 2, oy = (Double(plan.outputHeight) - h) / 2
            for y in 0..<plan.outputHeight { for x in 0..<plan.outputWidth {
                let wx = (Double(x) + 0.5 - ox) / s, wy = (Double(y) + 0.5 - oy) / s
                if let c = sampleWindow(wx, wy) { let o = (y * out.width + x) * 3; out.pixels[o] = UInt8(c.0); out.pixels[o + 1] = UInt8(c.1); out.pixels[o + 2] = UInt8(c.2) }
            } }
        case .displayIncludingOnlyWindow:
            let k = Double(plan.outputWidth) / plan.sourceRect.width     // output px per point
            for y in 0..<plan.outputHeight { for x in 0..<plan.outputWidth {
                // output pixel → display-relative point → global point → window pixel
                let gx = display.frame.x + plan.sourceRect.x + (Double(x) + 0.5) / k
                let gy = display.frame.y + plan.sourceRect.y + (Double(y) + 0.5) / k
                if let c = sampleWindow((gx - window.x) * display.scale, (gy - window.y) * display.scale) {
                    let o = (y * out.width + x) * 3; out.pixels[o] = UInt8(c.0); out.pixels[o + 1] = UInt8(c.1); out.pixels[o + 2] = UInt8(c.2)
                }
            } }
        }
        return out
    }

    /// A game window (physical pixels) with the addon strip drawn where the Lua strip draws it:
    /// top-centre, 3 physical px per cell, `titleBarPoints` below the window top.
    static func gameWindow(_ frame: CaptureRect, scale: Double, titleBarPoints: Double, bytes: [UInt8]) -> RGBImage {
        var img = RGBImage(width: Int(frame.width * scale), height: Int(frame.height * scale), fill: (90, 70, 50))
        let stripW = PixelDecoder.cols * 3
        PixelDecoder.render(bytes, cellPx: 3, into: &img, at: (img.width - stripW) / 2, Int(titleBarPoints * scale))
        return img
    }
}

func runCapturePlanTests() {
    let bytes = sampleFrame(chunks: [.init(reqId: 4, index: 0, count: 1, data: Codec.netstrings(["S", "thread:x", "hello"]))]).encode()
    var want = sampleFrame(chunks: [.init(reqId: 4, index: 0, count: 1, data: Codec.netstrings(["S", "thread:x", "hello"]))]); want.rows = 0
    let retina = DisplayInfo(id: 1, frame: CaptureRect(x: 0, y: 0, width: 1728, height: 1117), scale: 2)

    test("capture REGRESSION (af0441a plan): single-window filter downsizes the whole game into a strip-height output → undecodable") {
        let win = CaptureRect(x: 0, y: 0, width: 1728, height: 1117)
        let img = SCKModel.gameWindow(win, scale: 2, titleBarPoints: 0, bytes: bytes)
        let legacy = CapturePlanner.legacySingleWindow(windowID: 7, windowFrame: win, scale: 2)
        let out = SCKModel.deliver(legacy, window: win, windowPixels: img, display: retina)
        do { _ = try PixelDecoder.decodeFrame(out); throw Failure(description: "legacy plan decoded — model wrong") } catch is PixelDecoder.DecodeError {}
    }
    test("capture: the planned crop decodes at native scale (fullscreen Retina)") {
        let win = CaptureRect(x: 0, y: 0, width: 1728, height: 1117)
        let img = SCKModel.gameWindow(win, scale: 2, titleBarPoints: 0, bytes: bytes)
        let p = try unwrap(CapturePlanner.plan(windowID: 7, windowFrame: win, displays: [retina]))
        try expect(p.honorsSourceRect, "plan must use a filter that honours sourceRect")
        var got = try PixelDecoder.decodeFrame(SCKModel.deliver(p, window: win, windowPixels: img, display: retina)); got.rows = 0
        try eq(got, want)
    }
    test("capture: windowed mode with title bar, window not at the display origin, 1x display") {
        let d = DisplayInfo(id: 2, frame: CaptureRect(x: 0, y: 0, width: 1920, height: 1080), scale: 1)
        let win = CaptureRect(x: 300, y: 140, width: 1280, height: 800)
        let img = SCKModel.gameWindow(win, scale: 1, titleBarPoints: 28, bytes: bytes)
        let p = try unwrap(CapturePlanner.plan(windowID: 9, windowFrame: win, displays: [d]))
        var got = try PixelDecoder.decodeFrame(SCKModel.deliver(p, window: win, windowPixels: img, display: d)); got.rows = 0
        try eq(got, want)
    }
    test("capture: secondary display with NEGATIVE origin; display chosen by the window's top band") {
        let main = DisplayInfo(id: 1, frame: CaptureRect(x: 0, y: 0, width: 1728, height: 1117), scale: 2)
        let left = DisplayInfo(id: 3, frame: CaptureRect(x: -2560, y: -300, width: 2560, height: 1440), scale: 1)
        let win = CaptureRect(x: -2200, y: -250, width: 1600, height: 900)
        let img = SCKModel.gameWindow(win, scale: 1, titleBarPoints: 28, bytes: bytes)
        let p = try unwrap(CapturePlanner.plan(windowID: 5, windowFrame: win, displays: [main, left]))
        try eq(p.filter, .displayIncludingOnlyWindow(displayID: 3, windowID: 5))
        try eq(p.sourceRect, CaptureRect(x: 360, y: 50, width: 1600, height: 96), "display-relative")
        var got = try PixelDecoder.decodeFrame(SCKModel.deliver(p, window: win, windowPixels: img, display: left)); got.rows = 0
        try eq(got, want)
    }
    test("capture privacy invariants: only the WoW window, only its top 96 pt, inside one display, native pixels") {
        let displays = [retina, DisplayInfo(id: 3, frame: CaptureRect(x: -1920, y: 0, width: 1920, height: 1080), scale: 1)]
        let cases = [CaptureRect(x: 0, y: 0, width: 1728, height: 1117), CaptureRect(x: 100, y: 200, width: 800, height: 600),
                     CaptureRect(x: -1500, y: 40, width: 1400, height: 900), CaptureRect(x: 1500, y: 300, width: 900, height: 60),
                     CaptureRect(x: -300, y: 10, width: 1000, height: 700)]
        for w in cases {
            let p = try unwrap(CapturePlanner.plan(windowID: 1, windowFrame: w, displays: displays))
            guard case .displayIncludingOnlyWindow(let did, let wid) = p.filter else { throw Failure(description: "not a window-only display filter") }
            try eq(wid, 1)
            let d = displays.first { $0.id == did }!
            let global = p.sourceRect.offset(by: d.frame.x, d.frame.y)
            try expect(p.sourceRect.height <= CapturePlanner.bandPoints, "band only")
            try expect(global.y >= w.y - 1e-9 && global.maxY <= w.y + CapturePlanner.bandPoints + 1e-9, "starts at the window top")
            try expect(global.x >= w.x - 1e-9 && global.maxX <= w.maxX + 1e-9, "never wider than the window")
            try expect(p.sourceRect.x >= 0 && p.sourceRect.y >= 0 && p.sourceRect.maxX <= d.frame.width + 1e-9 && p.sourceRect.maxY <= d.frame.height + 1e-9, "inside the display")
            try eq(p.outputWidth, Int((p.sourceRect.width * d.scale).rounded())); try eq(p.outputHeight, Int((p.sourceRect.height * d.scale).rounded()))
        }
    }
    test("capture: no plan when the window's top band is on no display; plan key changes when the window moves or resizes") {
        try expect(CapturePlanner.plan(windowID: 1, windowFrame: CaptureRect(x: 5000, y: 5000, width: 800, height: 600), displays: [retina]) == nil)
        let a = try unwrap(CapturePlanner.plan(windowID: 1, windowFrame: CaptureRect(x: 0, y: 0, width: 800, height: 600), displays: [retina]))
        let b = try unwrap(CapturePlanner.plan(windowID: 1, windowFrame: CaptureRect(x: 10, y: 0, width: 800, height: 600), displays: [retina]))
        let c = try unwrap(CapturePlanner.plan(windowID: 1, windowFrame: CaptureRect(x: 0, y: 0, width: 900, height: 600), displays: [retina]))
        try expect(a.key != b.key && a.key != c.key)
        try eq(a.key, try unwrap(CapturePlanner.plan(windowID: 1, windowFrame: CaptureRect(x: 0, y: 0, width: 800, height: 600), displays: [retina])).key)
    }
    test("capture lifecycle: a changed plan for the same window restarts; the same plan does not") {
        let c = CaptureLifecycle()
        let g = c.begin(window: 1, plan: "A"); c.startCompleted(gen: g, ok: true)
        try expect(!c.shouldStart(window: 1, plan: "A"))
        try expect(c.shouldStart(window: 1, plan: "B"))
    }
}

func unwrap<T>(_ v: T?, line: UInt = #line) throws -> T { guard let v else { throw Failure(description: "nil (line \(line))") }; return v }

func runDiagnosticsTests() {
    test("capture stats: every sample is counted with a category; valid frames timestamped") {
        let st = CaptureStats()
        var img = RGBImage(width: 400, height: 60)
        try expect(st.process(img, now: 1) == nil)
        PixelDecoder.render(sampleFrame().encode(), cellPx: 3, into: &img, at: 10, 4)
        try expect(st.process(img, now: 5) != nil)
        try eq(st.samples, 2); try eq(st.decoded, 1); try eq(st.notFound, 1); try eq(st.lastValidAt, 5)
        try eq(st.lastError, "strip-not-found")
    }
    test("engine: gameAcked only after the game acknowledges a delivery from THIS bridge epoch") {
        let t3 = FakeT3(); let (e, _) = makeEngine(t3)
        try expect(!e.gameAcked)
        e.onFrame(frame()); try expect(!e.gameAcked, "frame seen but nothing applied")
        e.tick(); e.flush()
        e.onFrame(frame(epochAck: 999, ack: 5, next: 2)); try expect(!e.gameAcked, "ack from another bridge run")
        e.onFrame(frame(epochAck: 5, ack: 3, next: 2)); try expect(e.gameAcked)
    }
    test("diagnostics JSON: whitelisted keys only, no secrets, titles, ids or text") {
        let t3 = FakeT3(); let (e, _) = makeEngine(t3)
        let tid = ((fixture("t3_thread_list")["threads"] as! [[String: Any]]).first!)["threadId"] as! String
        e.onFrame(frame([(3, ["S", tid, "secret reply text"])])); e.tick(); e.flush()
        e.onFrame(frame(epochAck: 5, ack: e.store.version, next: 2))
        let st = CaptureStats()
        let d = e.diagnostics(now: 1_794_160_010)
        let s = BridgeStatus(writtenAt: 1_794_160_010, app: BridgeVersion.string,
                             capture: .init(state: "capturing", windowID: 42, windowFrame: CaptureRect(x: 0, y: 0, width: 1728, height: 1117), displayID: 1,
                                            sourceRect: CaptureRect(x: 0, y: 0, width: 1728, height: 96), outputPixels: [3456, 192], scale: 2, stats: st, now: 1_794_160_010),
                             link: d.link, delivery: d.delivery, install: "ok")
        let text = String(decoding: s.json(), as: UTF8.self)
        for bad in [grantA.accessToken, grantA.fingerprint, "Bearer", "Fixture thread", "Contract Fixture", tid, "secret reply", "wow:", "message:", "clientRequestId", "Owner"] {
            try expect(!text.contains(bad), "leaked \(bad)")
        }
        let obj = try JSONSerialization.jsonObject(with: s.json()) as! [String: Any]
        try eq(Set(obj.keys), ["schema", "writtenAt", "app", "capture", "link", "delivery", "install"])
        try eq(Set((obj["delivery"] as! [String: Any]).keys), ["gameSessionSeen", "epochMatches", "storeVersion", "gameAckVersion", "nextSlot", "slotWrites", "slotWriteFailing", "requestsReceived", "sendsAttempted"])
        try expect(d.delivery.epochMatches); try expect(d.link.threadCount >= 1)
    }
    test("status writer: atomic and throttled") {
        let url = tmpDir().appendingPathComponent("bridge-status.json"); let w = StatusWriter(url: url, minInterval: 2)
        let st = CaptureStats()
        let s = BridgeStatus(writtenAt: 1, app: "x", capture: .init(state: "noGame", stats: st, now: 1),
                             link: .init(state: "unpaired", access: "none", threadCount: 0, lastT3OkAgeSeconds: nil),
                             delivery: .init(gameSessionSeen: false, epochMatches: false, storeVersion: 0, gameAckVersion: 0, nextSlot: 0, slotWrites: 0, slotWriteFailing: false, requestsReceived: 0, sendsAttempted: 0), install: "noTarget")
        try expect(w.write(s, now: 10)); try expect(!w.write(s, now: 11)); try expect(w.write(s, now: 12))
        try eq(try JSONDecoder().decode(BridgeStatus.self, from: Data(contentsOf: url)), s)
    }
    test("setup: a decoded strip without a delivery ACK is NOT 'Connected to the game'") {
        var f = PreviewFixtures.all[1].facts
        f.gameAcked = false
        let v = Setup.evaluate(f)
        try expect(v.headline != "Connected to the game"); try eq(v.tone, .warn)
        f.gameAcked = true
        try eq(Setup.evaluate(f).headline, "Connected to the game")
    }
}
