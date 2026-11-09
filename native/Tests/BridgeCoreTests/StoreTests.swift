import Foundation
@testable import BridgeCore

func runStoreTests() {
    test("store: unchanged put does not bump; changes are ascending and size-capped") {
        let s = RecordStore()
        try expect(s.put("a", ["p", "a", "A"]))
        try expect(!s.put("a", ["p", "a", "A"]))
        s.put("b", ["p", "b", String(repeating: "x", count: 500)])
        s.put("c", ["p", "c", "C"])
        let all = s.changes(since: 0, maxBytes: 100_000)
        try eq(all.records.map { $0[1] }, ["a", "b", "c"]); try eq(all.version, 3); try expect(!all.more)
        let capped = s.changes(since: 0, maxBytes: 100)
        try eq(capped.records.count, 1); try expect(capped.more); try eq(capped.version, 1)
        let rest = s.changes(since: capped.version, maxBytes: 100_000)
        try eq(rest.records.map { $0[1] }, ["b", "c"])
    }
    test("store: tombstones are delivered then pruned after ack") {
        let s = RecordStore()
        s.put("t:1", ["t"]); s.remove("t:1")
        let ch = s.changes(since: 0, maxBytes: 1000)
        try eq(ch.records, [["x", "t:1"]])
        s.pruneTombstones(acked: ch.version)
        try eq(s.changes(since: 0, maxBytes: 1000).records.count, 0)
    }
    test("ledger persists across instances and stays bounded") {
        let dir = tmpDir(), url = dir.appendingPathComponent("ledger.json")
        let a = SendLedger(url: url)
        try a.set("k", .init(state: "accepted", namespace: "n", threadId: "t", messageId: "m", detail: nil, updatedAt: 1))
        try eq(SendLedger(url: url).get("k")?.state, "accepted")
        for i in 0..<(SendLedger.maxEntries + 20) { try a.set("x\(i)", .init(state: "accepted", namespace: "n", threadId: nil, messageId: nil, detail: nil, updatedAt: Double(i + 2))) }
        try eq(a.entries.count, SendLedger.maxEntries)
    }
    test("slot writer: atomic single-call file, refuses missing slot folders") {
        let dir = tmpDir()
        let w = SlotWriter(addOnsDir: dir)
        do { try w.write(slot: 1, payload: [1]); throw Failure(description: "wrote without folder") } catch is CocoaError {}
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("T3ForWoW_Slot0001"), withIntermediateDirectories: true)
        try w.write(slot: 1, payload: Array("hi\"\\".utf8))
        let s = try String(contentsOf: dir.appendingPathComponent("T3ForWoW_Slot0001/Slot.lua"), encoding: .utf8)
        try eq(s, "T3ForWoW_Deliver(1,\"hi\\034\\092\")\n")
    }
}

func runDiscoveryTests() {
    test("discovery reads only the origin from T3's runtime file; absent/garbled → nil") {
        let home = tmpDir()
        try eq(T3Discovery.localOrigin(home: home), nil)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("userdata"), withIntermediateDirectories: true)
        try Data("{\"version\":1,\"pid\":1,\"port\":3773,\"origin\":\"http://127.0.0.1:3773\",\"startedAt\":\"x\"}".utf8).write(to: home.appendingPathComponent("userdata/server-runtime.json"))
        try eq(T3Discovery.localOrigin(home: home), URL(string: "http://127.0.0.1:3773"))
        try Data("{\"version\":1,\"origin\":\"file:///etc\"}".utf8).write(to: home.appendingPathComponent("userdata/server-runtime.json"))
        try eq(T3Discovery.localOrigin(home: home), nil)
    }
    test("installer: discovers flavor folders, installs addon + grouped LoD slots, never touches other addons") {
        let root = tmpDir().appendingPathComponent("World of Warcraft")
        let flavor = root.appendingPathComponent("_forever_")
        try FileManager.default.createDirectory(at: flavor.appendingPathComponent("Interface/AddOns/TelegramWoW"), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: flavor.appendingPathComponent("Interface/AddOns/TelegramWoW/x.lua"))
        let cands = Installer.discover(roots: [root])
        try eq(cands.count, 1)
        let src = repoRoot.appendingPathComponent("addon/T3ForWoW")
        let r = try Installer.install(bundledAddon: src, addOnsDir: cands[0].addOnsDir, slotCount: 5, interface: "16001")
        try eq(r.slotsCreated, 5); try expect(r.restartNeeded)
        let toc = try String(contentsOf: cands[0].addOnsDir.appendingPathComponent("T3ForWoW_Slot0003/T3ForWoW_Slot0003.toc"), encoding: .utf8)
        try expect(toc.contains("## LoadOnDemand: 1") && toc.contains("## Group: T3ForWoW") && toc.contains("## Dependencies: T3ForWoW"))
        try eq(try String(contentsOf: cands[0].addOnsDir.appendingPathComponent("T3ForWoW_Slot0003/Slot.lua"), encoding: .utf8), "T3ForWoW_Deliver(3,\"\")\n")
        let again = try Installer.install(bundledAddon: src, addOnsDir: cands[0].addOnsDir, slotCount: 5, interface: "16001")
        try eq(again.slotsCreated, 0); try expect(!again.restartNeeded, "same files: /reload is enough")
        try eq(try String(contentsOf: flavor.appendingPathComponent("Interface/AddOns/TelegramWoW/x.lua"), encoding: .utf8), "keep")
        try eq(try Installer.uninstall(addOnsDir: cands[0].addOnsDir), 6)
        try expect(FileManager.default.fileExists(atPath: flavor.appendingPathComponent("Interface/AddOns/TelegramWoW/x.lua").path))
    }
    test("grant access levels from scopes") {
        func g(_ s: String) -> String { T3Grant(accessToken: "t", expiresAt: 0, scope: s, origin: URL(string: "http://x")!).access }
        try eq(g("orchestration:read"), "read-only")
        try eq(g("orchestration:read orchestration:operate"), "operate")
        try eq(g("orchestration:read orchestration:operate settings:write source-control:write"), "full-access")
    }
}

func runSetupTests() {
    let o = URL(string: "http://127.0.0.1:3773")!
    test("setup: fresh friend path is one action at a time in a fixed order") {
        var f = Setup.Facts(t3Origin: o, wowCandidates: 1)
        var actions: [Setup.Action] = []
        actions.append(Setup.evaluate(f).action); f.grant = .valid(daysLeft: 30); f.link = "connected"
        actions.append(Setup.evaluate(f).action); f.addonInstalled = true; f.restartNeeded = true
        actions.append(Setup.evaluate(f).action); f.capturePermission = true
        actions.append(Setup.evaluate(f).action); f.gameRunning = true
        actions.append(Setup.evaluate(f).action); f.stripSeen = true; f.gameAcked = true; f.restartNeeded = false
        let done = Setup.evaluate(f)
        try eq(actions, [.connectT3, .installAddon, .allowScreenRecording, .startGame, .restartGame])
        try eq(done.headline, "Connected to the game"); try eq(done.action, .none)
    }
    test("setup: undiscovered T3, ambiguous game folders, Keychain denial and revocation are explicit") {
        try eq(Setup.evaluate(.init()).action, .findT3)
        try eq(Setup.evaluate(.init(t3Origin: o, grant: .valid(daysLeft: 9), wowCandidates: 2, link: "connected")).action, .chooseWoW)
        try eq(Setup.evaluate(.init(t3Origin: o, wowCandidates: 0)).action, .connectT3)
        try eq(Setup.evaluate(.init(t3Origin: o, grant: .keychainUnavailable)).action, .retryKeychain)
        let revoked = Setup.evaluate(.init(t3Origin: o, grant: .valid(daysLeft: 20), link: "revoked"))
        try eq(revoked.action, .connectT3); try eq(revoked.actionTitle, "Reconnect T3…")
        try expect(Setup.evaluate(.init(t3Origin: o, grant: .valid(daysLeft: 2), link: "connected")).rows[0].detail.contains("expires in 2"))
    }
}

func runAccessTests() {
    let o = URL(string: "http://127.0.0.1:3773")!
    func ready(_ access: String, blocked: Int) -> Setup.Facts {
        Setup.Facts(t3Origin: o, grant: .valid(daysLeft: 20), wowCandidates: 1, addonInstalled: true, capturePermission: true,
                    gameRunning: true, stripSeen: true, link: "connected", linkAccess: access, threadsAboveAccess: blocked)
    }
    test("access: full-access threads with an operate link → explicit, optional reconnect offer with the scope cost stated") {
        let v = Setup.evaluate(ready("operate", blocked: 2))
        try eq(v.action, .none, "never forced: the owner may keep the narrower link")
        try eq(v.secondaryAction, .reconnectFullAccess)
        try expect(v.rows.contains { $0.label == "Replies" && !$0.ok && $0.detail.contains("2 threads") && $0.detail.contains("Full access") })
        try expect(v.secondaryNote.contains("settings") && v.secondaryNote.contains("source control"))
    }
    test("access: nothing offered when every thread is repliable or the link is already full-access") {
        try eq(Setup.evaluate(ready("operate", blocked: 0)).secondaryAction, nil)
        try eq(Setup.evaluate(ready("full-access", blocked: 0)).secondaryAction, nil)
    }
    test("engine counts visible threads above the link's access") {
        let t3 = FakeT3()
        var list = t3.threads; var ts = list["threads"] as! [[String: Any]]
        var full = ts[0]; full["threadId"] = "full-1"; full["runtimeMode"] = "full-access"; ts.append(full); list["threads"] = ts; t3.threads = list
        let (e, _) = makeEngine(t3)
        e.onFrame(frame()); e.tick()
        try eq(e.threadsAboveAccess, 1)
    }
}
