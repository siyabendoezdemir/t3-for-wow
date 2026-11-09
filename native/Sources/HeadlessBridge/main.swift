import Foundation
import BridgeCore

// Headless bridge for tests, diagnostics and the cross-process harness. Friends use the Mac app;
// this binary stores its grant in a 0600 file given explicitly with --grant-file (test/dev only).
let args = Array(CommandLine.arguments.dropFirst())

/// The grant-file path is for throwaway isolated test servers ONLY. Owner onboarding is the Mac app,
/// which keeps the grant in the Keychain. Refuse unless explicitly in isolated-test mode, against a
/// loopback T3, with the grant file in a temporary directory.
func requireIsolatedTest(origin: URL?, grantFile: String) {
    let tmp = NSTemporaryDirectory()
    let okEnv = ProcessInfo.processInfo.environment["T3WOW_ISOLATED_TEST"] == "1"
    let okHost = origin.map { ["127.0.0.1", "localhost", "[::1]", "::1"].contains($0.host ?? "") } ?? true
    let path = URL(fileURLWithPath: grantFile).standardizedFileURL.path
    let okPath = path.hasPrefix(URL(fileURLWithPath: tmp).standardizedFileURL.path) || path.hasPrefix("/tmp/") || path.contains("/.build/")
    guard okEnv, okHost, okPath else {
        FileHandle.standardError.write(Data("refused: --grant-file is only for isolated test servers (set T3WOW_ISOLATED_TEST=1, loopback T3, grant file under a temp or .build directory). Owners connect with the T3 for WoW app, which stores the approval in the Keychain.\n".utf8))
        exit(77)
    }
}
func opt(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
func die(_ s: String, _ code: Int32 = 2) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(code) }
func say(_ s: String) { print(s); fflush(stdout) }

func loadGrant(_ path: String) -> T3Grant? {
    guard let d = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONDecoder().decode(T3Grant.self, from: d)
}

switch args.first {
case "pair":
    // Prints the T3 approval URL for the owner to open, then waits for T3 to redirect back.
    guard let origin = opt("--origin").flatMap(URL.init(string:)), let grantFile = opt("--grant-file") else { die("usage: pair --origin URL --grant-file PATH") }
    requireIsolatedTest(origin: origin, grantFile: grantFile)
    let http = URLSessionTransport()
    do {
        let cb = try LoopbackCallback()
        let p = try OAuthPairing.begin(origin: origin, redirectPort: cb.port, transport: http)
        say("APPROVE_URL=\(p.authorizeURL.absoluteString)")
        guard let q = cb.wait(timeout: Double(opt("--timeout") ?? "600") ?? 600) else { die("PAIR_RESULT=timeout", 3) }
        let g = try OAuthPairing.complete(p, callbackQuery: q, transport: http, now: Date().timeIntervalSince1970)
        _ = FileManager.default.createFile(atPath: grantFile, contents: try JSONEncoder().encode(g), attributes: [.posixPermissions: 0o600])
        say("PAIR_RESULT=approved scope=\(g.scope) expiresIn=\(Int(g.expiresAt - Date().timeIntervalSince1970))")
    } catch PairingError.denied { die("PAIR_RESULT=denied", 4) }
    catch { die("PAIR_RESULT=error \(error)", 5) }

case "install":
    guard let addon = opt("--addon"), let dir = opt("--addons") else { die("usage: install --addon SRC --addons DIR [--slots N] [--interface V]") }
    do {
        let r = try Installer.install(bundledAddon: URL(fileURLWithPath: addon), addOnsDir: URL(fileURLWithPath: dir),
                                      slotCount: Int(opt("--slots") ?? "") ?? Installer.defaultSlots, interface: opt("--interface") ?? "16001")
        let fp = Installer.footprint(addOnsDir: URL(fileURLWithPath: dir))
        say("INSTALLED slotsCreated=\(r.slotsCreated) restartNeeded=\(r.restartNeeded) change=\(r.change.rawValue) folders=\(fp.folders) files=\(fp.files) bytes=\(fp.bytes)")
    } catch { die("install failed: \(error)") }

case "run":
    // Watches a frame source (PPM file written by the synthetic game), answers through slot files.
    guard let frameFile = opt("--frame-file"), let addons = opt("--addons"), let ledger = opt("--ledger") else {
        die("usage: run --frame-file F.ppm --addons DIR --ledger F [--grant-file F] [--access LEVEL] [--seconds N] [--stats F]")
    }
    let seconds = Double(opt("--seconds") ?? "3600") ?? 3600
    let engine = Engine(ledger: SendLedger(url: URL(fileURLWithPath: ledger)), slots: SlotWriter.Sink(SlotWriter(addOnsDir: URL(fileURLWithPath: addons))))
    engine.config.listEverySeconds = Double(opt("--list-every") ?? "2") ?? 2
    engine.config.watchEverySeconds = 1
    if let gf = opt("--grant-file") { requireIsolatedTest(origin: loadGrant(gf)?.origin, grantFile: gf) }
    if let gf = opt("--grant-file"), let g = loadGrant(gf) {
        engine.setLink(MCPClient(endpoint: g.origin.appendingPathComponent("mcp"), transport: URLSessionTransport(), token: { g.accessToken }), grant: g)
    }
    let captureStats = CaptureStats()
    say("BRIDGE_EPOCH=\(engine.epoch)")
    let start = Date()
    var lastMod: Date?
    while Date().timeIntervalSince(start) < seconds {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: frameFile), let m = attrs[.modificationDate] as? Date, m != lastMod,
           let data = FileManager.default.contents(atPath: frameFile), let img = RGBImage.readPPM(Array(data)) {
            lastMod = m
            if let f = captureStats.process(img, now: Date().timeIntervalSince1970) { engine.onFrame(f) } // failures counted, not hidden
        }
        engine.tick()
        engine.flush()
        if let sf = opt("--stats"), let d = try? JSONEncoder().encode(engine.stats) { try? d.write(to: URL(fileURLWithPath: sf)) }
        usleep(100_000)
    }

case "decode":
    // Prints what the bridge decodes from a captured image (diagnostics / cross-language test).
    guard let file = args.dropFirst().first, let d = FileManager.default.contents(atPath: file), let img = RGBImage.readPPM(Array(d)) else { die("usage: decode FILE.ppm") }
    do {
        let f = try PixelDecoder.decodeFrame(img)
        say("session=\(f.gameSession) seq=\(f.frameSeq) nextSlot=\(f.nextSlot) slotCount=\(f.slotCount) flags=\(f.flags) epochAck=\(f.epochAck) ack=\(f.deliveryAck)")
        for c in f.chunks { say("chunk req=\(c.reqId) \(c.index)/\(c.count) fields=\((Codec.parseStrings(c.data) ?? []).joined(separator: "|"))") }
    } catch { die("decode failed: \(error)", 1) }

case "write-test-slot":
    // Writes one delivery through the real store/engine encoder with adversarial text (cross-language test).
    guard let dir = opt("--addons"), let slot = Int(opt("--slot") ?? ""), let session = UInt32(opt("--session") ?? "") else { die("usage: write-test-slot --addons DIR --slot N --session S") }
    let sink = SlotWriter.Sink(SlotWriter(addOnsDir: URL(fileURLWithPath: dir)))
    let e = Engine(epoch: 77, ledger: SendLedger(url: nil), slots: sink, clock: { 1_794_160_000 })
    e.onFrame(GameFrame(rows: 0, gameSession: session, frameSeq: 1, epochAck: 0, deliveryAck: 0, nextSlot: slot, slotCount: slot, flags: 0, chunks: []))
    e.store.put("m:t:i", ["m", "t", "i", "1", "assistant", "completed", "t3", "1", "quote\" back\\slash ]] --[[ é 日本 |TInterface\\x|t \u{0}nul\nline2", "0"])
    guard e.flush() else { die("no slot written", 1) }
    say("WROTE slot=\(slot)")

case "measure-sync":
    // Slots needed to bring a fresh UI session up to date, and per-update cost, for synthetic
    // T3 shapes driven through the REAL engine/store/delivery encoder. Prints JSON.
    final class SynthT3: T3API {
        let threads: Int, items: Int, chars: Int
        init(threads: Int, items: Int, chars: Int) { self.threads = threads; self.items = items; self.chars = chars }
        var tick = 0
        func call(_ tool: String, _ a: [String: Any]) throws -> [String: Any] {
            switch tool {
            case "t3_project_list": return ["projects": (0..<5).map { ["id": "p\($0)", "title": "Project \($0) with a realistic name"] }]
            case "t3_thread_list":
                return ["threads": (0..<threads).map { i -> [String: Any] in
                    ["threadId": "thread-\(i)-0123456789abcdef", "projectId": "p\(i % 5)", "title": "Thread \(i): a typical sixty character title for some work",
                     "status": i < 3 ? "running" : "completed", "pendingRequestCount": i == 3 ? 1 : 0, "runtimeMode": "approval-required",
                     "settled": false, "updatedAt": "2026-11-08T16:\(10 + (i == 0 ? tick % 50 : 0)):00.000Z", "providerInstanceId": "claudeAgent", "model": "m", "createdAt": "2026-11-08T10:00:00Z"] }]
            case "t3_thread_read":
                let lim = (a["limit"] as? Int) ?? 1
                let tid = a["threadId"] as! String
                let base = items - min(items, lim)
                let text = String(repeating: "x", count: max(1, (a["maxCharsPerItem"] as? Int ?? chars) >= chars ? chars : 1))
                return ["thread": ["threadId": tid, "projectId": "p0", "title": "t", "status": "running", "itemCount": items, "pendingRequestCount": 0, "runtimeMode": "approval-required", "updatedAt": "2026-11-08T16:00:00Z"],
                        "items": (0..<min(items, lim)).map { j -> [String: Any] in
                            ["itemId": "item-\(base + j)", "position": base + j, "type": j % 3 == 2 ? "command_execution" : (j % 2 == 0 ? "assistant_message" : "user_message"),
                             "status": "completed", "title": "Ran a command", "text": text, "updatedAt": "2026-11-08T16:00:00Z"] }]
            default: return [:]
            }
        }
    }
    func scenario(_ name: String, threads: Int, watched: Int, items: Int, chars: Int) -> [String: Any] {
        let sink = MemoryCount(); let t3 = SynthT3(threads: threads, items: items, chars: chars)
        var now = 1_794_160_000.0
        let e = Engine(epoch: 1, ledger: SendLedger(url: nil), slots: sink, clock: { now })
        e.setLink(t3, grant: T3Grant(accessToken: "synthetic", expiresAt: now + 86400, scope: "orchestration:read orchestration:operate", origin: URL(string: "http://127.0.0.1:1")!))
        var reqs: [GameFrame.Chunk] = []
        for w in 0..<watched { reqs.append(.init(reqId: UInt32(w + 1), index: 0, count: 1, data: Codec.netstrings(["W", "thread-\(w)-0123456789abcdef"]))) }
        var ack: UInt32 = 0, slot = 1, sizes: [Int] = []
        e.onFrame(GameFrame(rows: 0, gameSession: 9, frameSeq: 0, epochAck: 0, deliveryAck: 0, nextSlot: slot, slotCount: 480, flags: 4, chunks: reqs))
        e.tick()
        while slot < 100 {  // initial catch-up: keep loading until a delivery says more=0
            e.flush(); let p = sink.last[slot]!; sizes.append(p.count)
            let f = Codec.parseStrings(p)!; ack = UInt32(f[4])!
            slot += 1
            e.onFrame(GameFrame(rows: 0, gameSession: 9, frameSeq: slot, epochAck: 1, deliveryAck: ack, nextSlot: slot, slotCount: 480, flags: 4, chunks: []))
            if f[5] == "0" { break }
        }
        let initialSlots = sizes.count
        t3.tick += 1; now += 60; e.onFrame(GameFrame(rows: 0, gameSession: 9, frameSeq: 99, epochAck: 1, deliveryAck: ack, nextSlot: slot, slotCount: 480, flags: 4, chunks: [])); e.tick(); e.flush()
        let steady = sink.last[slot]?.count ?? 0
        return ["scenario": name, "threads": threads, "watchedThreads": watched, "historyItemsPerWatched": min(items, 30), "charsPerItem": chars,
                "initialSyncSlots": initialSlots, "initialSyncBytes": sizes.reduce(0, +), "largestDeliveryBytes": sizes.max() ?? 0, "steadyUpdateBytes": steady]
    }
    final class MemoryCount: SlotSink { var last: [Int: [UInt8]] = [:]; func write(slot: Int, payload: [UInt8]) throws { last[slot] = payload } }
    let out = [scenario("tracker only, 20 threads", threads: 20, watched: 0, items: 0, chars: 1),
               scenario("typical: 60 threads, 1 open conversation, 30 items x 600 chars", threads: 60, watched: 1, items: 200, chars: 600),
               scenario("worst case: 60 threads, 3 conversations, 30 items x 4000 chars", threads: 60, watched: 3, items: 200, chars: 4000)]
    say(String(data: try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)

default:
    die("usage: t3wow-bridge pair|install|run|decode|write-test-slot|measure-sync …")
}
