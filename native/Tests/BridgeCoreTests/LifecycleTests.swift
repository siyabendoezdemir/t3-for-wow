import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import BridgeCore

/// Pre-owner correction pass: origin binding, install target/health, Keychain vault outcomes,
/// capture lifecycle, truthful link verification, preview check. SYNTHETIC seams only — no real
/// Keychain, capture, network or owner account.
final class FakeSecrets: SecretBackend {
    var readResult: (Int32, Data?) = (SecStatus.itemNotFound, nil)
    var writeStatus: Int32 = SecStatus.success
    var deleteStatus: Int32 = SecStatus.success
    var writes: [Data] = []
    var deletes = 0
    func read() -> (status: Int32, data: Data?) { readResult }
    func write(_ d: Data) -> Int32 { writes.append(d); if writeStatus == SecStatus.success { readResult = (SecStatus.success, d) }; return writeStatus }
    func delete() -> Int32 { deletes += 1; if deleteStatus == SecStatus.success || deleteStatus == SecStatus.itemNotFound { readResult = (SecStatus.itemNotFound, nil) }; return deleteStatus }
}

func runLifecycleTests() {
    let approved = URL(string: "http://127.0.0.1:3773")!
    let g = T3Grant(accessToken: "OLD-GRANT-TOKEN", expiresAt: 4_000_000_000, scope: "orchestration:read orchestration:operate", origin: approved)

    // 1. origin binding
    test("binding: same normalized origin connects to the APPROVED origin") {
        try eq(OriginBinding.decide(grant: g, current: URL(string: "HTTP://127.0.0.1:3773/")!), .connect(approved))
        try eq(OriginBinding.decide(grant: g, current: nil), .connect(approved))
        try eq(OriginBinding.normalized(URL(string: "https://Example.com")!), "https://example.com:443")
    }
    test("binding: changed config host or a different localhost port needs fresh approval") {
        try eq(OriginBinding.decide(grant: g, current: URL(string: "https://changed-environment.example")!),
               .needsApproval(approved: approved, current: URL(string: "https://changed-environment.example")!))
        try eq(OriginBinding.decide(grant: g, current: URL(string: "http://127.0.0.1:3774")!),
               .needsApproval(approved: approved, current: URL(string: "http://127.0.0.1:3774")!))
        try eq(OriginBinding.decide(grant: g, current: URL(string: "http://localhost:3773")!),
               .needsApproval(approved: approved, current: URL(string: "http://localhost:3773")!), "localhost ≠ 127.0.0.1")
    }
    test("binding: no request carrying the token reaches a changed environment; the saved grant is untouched") {
        var hosts: [String] = []
        let http = ScriptedHTTP { r in hosts.append(r.url.host ?? ""); return HTTPResponse(status: 401, headers: [:], body: Data()) }
        let vault = GrantVault(backend: FakeSecrets())
        _ = vault.save(g)
        let slots = MemorySlots()
        let e = Engine(epoch: 1, ledger: SendLedger(url: nil), slots: slots, clock: { 1_794_160_000 })
        let plan = LinkPlanner.plan(grant: g, current: URL(string: "https://changed-environment.example")!, transport: http)
        try expect(plan.client == nil)
        try eq(plan.state, .originChanged)
        e.setLink(plan.client, grant: plan.client == nil ? nil : g)
        e.onFrame(frame()); e.tick()
        try eq(hosts, [], "nothing sent anywhere")
        guard case .found(let kept) = vault.read() else { throw Failure(description: "grant lost") }
        try eq(kept, g)
        let same = LinkPlanner.plan(grant: g, current: approved, transport: http)
        try eq(same.client?.endpoint, URL(string: "http://127.0.0.1:3773/mcp"))
    }

    // 2. install target
    let root = tmpDir().appendingPathComponent("World of Warcraft")
    for f in ["_forever_", "_retail_"] { try! FileManager.default.createDirectory(at: root.appendingPathComponent("\(f)/Interface/AddOns"), withIntermediateDirectories: true) }
    let custom = tmpDir().appendingPathComponent("Games/WoW Forever/Interface/AddOns")
    try! FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
    test("target: a valid selected custom path wins even with no standard candidate") {
        try eq(InstallTarget.resolve(configured: custom, candidates: []), .use(custom))
        try eq(InstallTarget.resolve(configured: custom, candidates: Installer.discover(roots: [root])), .use(custom))
    }
    test("target: several flavors and no selection → owner chooses; never the first one") {
        let c = Installer.discover(roots: [root])
        try eq(c.count, 2)
        guard case .choose = InstallTarget.resolve(configured: nil, candidates: c) else { throw Failure(description: "picked a flavor silently") }
        try eq(InstallTarget.resolve(configured: nil, candidates: [c[0]]), .use(c[0].addOnsDir))
    }
    test("target: invalid or vanished selection is refused, not replaced by another flavor") {
        let bogus = tmpDir().appendingPathComponent("Downloads")
        try expect(InstallTarget.validate(bogus) != nil)
        guard case .choose(let why) = InstallTarget.resolve(configured: bogus, candidates: Installer.discover(roots: [root])) else { throw Failure(description: "fell back") }
        try expect(why.contains("no longer valid"))
        try eq(InstallTarget.selection(fromPicked: custom.deletingLastPathComponent().deletingLastPathComponent())?.standardizedFileURL.path, custom.standardizedFileURL.path, "picking the flavor folder means its Interface/AddOns")
        try eq(InstallTarget.selection(fromPicked: nil), nil, "cancel changes nothing")
    }

    // 3. install health / update
    func freshAddon() -> URL {
        let src = tmpDir().appendingPathComponent("T3ForWoW")
        try! FileManager.default.copyItem(at: repoRoot.appendingPathComponent("addon/T3ForWoW"), to: src)
        return src
    }
    test("health: not installed, TOC-only, missing slot, tampered file → damaged/notInstalled") {
        let src = freshAddon(), dir = tmpDir().appendingPathComponent("AddOns")
        try eq(Installer.health(bundled: src, addOnsDir: dir), .notInstalled)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("T3ForWoW"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: src.appendingPathComponent("T3ForWoW.toc"), to: dir.appendingPathComponent("T3ForWoW/T3ForWoW.toc"))
        guard case .damaged = Installer.health(bundled: src, addOnsDir: dir) else { throw Failure(description: "TOC-only accepted") }
        try FileManager.default.removeItem(at: dir.appendingPathComponent("T3ForWoW"))
        _ = try Installer.install(bundledAddon: src, addOnsDir: dir, slotCount: 4, interface: "16001")
        try eq(Installer.health(bundled: src, addOnsDir: dir), .ok)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("T3ForWoW_Slot0003/Slot.lua"))
        guard case .damaged(let why) = Installer.health(bundled: src, addOnsDir: dir) else { throw Failure(description: "missing slot accepted") }
        try expect(why.contains("slot"))
        _ = try Installer.install(bundledAddon: src, addOnsDir: dir, slotCount: 4, interface: "16001")
        try Data("-- edited".utf8).write(to: dir.appendingPathComponent("T3ForWoW/Core/Model.lua"))
        guard case .damaged = Installer.health(bundled: src, addOnsDir: dir) else { throw Failure(description: "tampered file accepted") }
    }
    test("update: unchanged reinstall needs nothing; changed Lua under the same TOC needs a reload; new files need a restart") {
        let src = freshAddon(), dir = tmpDir().appendingPathComponent("AddOns")
        try eq(try Installer.install(bundledAddon: src, addOnsDir: dir, slotCount: 3, interface: "16001").change, .restart)
        try eq(try Installer.install(bundledAddon: src, addOnsDir: dir, slotCount: 3, interface: "16001").change, .none)
        try Data("-- v2\n".utf8).write(to: src.appendingPathComponent("T3ForWoW.lua"), options: .atomic)
        try eq(Installer.health(bundled: src, addOnsDir: dir), .outdated)
        try eq(try Installer.install(bundledAddon: src, addOnsDir: dir, slotCount: 3, interface: "16001").change, .reload)
        try Data("-- extra\n".utf8).write(to: src.appendingPathComponent("Extra.lua"))
        try String(contentsOf: src.appendingPathComponent("T3ForWoW.toc"), encoding: .utf8).appending("Extra.lua\n").write(to: src.appendingPathComponent("T3ForWoW.toc"), atomically: true, encoding: .utf8)
        try eq(try Installer.install(bundledAddon: src, addOnsDir: dir, slotCount: 3, interface: "16001").change, .restart)
        try eq(try Installer.install(bundledAddon: src, addOnsDir: dir, slotCount: 4, interface: "16001").change, .restart, "new slot addons are indexed at startup")
    }
    test("update: a failed copy leaves the previous install intact; other addons and SavedVariables untouched") {
        let src = freshAddon(), base = tmpDir(), dir = base.appendingPathComponent("Interface/AddOns")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("WTF/Account/X/SavedVariables"), withIntermediateDirectories: true)
        try Data("T3ForWoWDB = {}".utf8).write(to: base.appendingPathComponent("WTF/Account/X/SavedVariables/T3ForWoW.lua"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Other"), withIntermediateDirectories: true)
        _ = try Installer.install(bundledAddon: src, addOnsDir: dir, slotCount: 2, interface: "16001")
        let missingSrc = src.deletingLastPathComponent().appendingPathComponent("does-not-exist")
        do { _ = try Installer.install(bundledAddon: missingSrc, addOnsDir: dir, slotCount: 2, interface: "16001"); throw Failure(description: "no error") } catch is Failure { throw Failure(description: "no error") } catch {}
        try eq(Installer.health(bundled: src, addOnsDir: dir), .ok, "previous install survives a failed update")
        try expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Other").path))
        try eq(try String(contentsOf: base.appendingPathComponent("WTF/Account/X/SavedVariables/T3ForWoW.lua"), encoding: .utf8), "T3ForWoWDB = {}")
    }
    test("engine surfaces slot write failures instead of failing silently") {
        let dir = tmpDir()
        let e = Engine(epoch: 1, ledger: SendLedger(url: nil), slots: SlotWriter.Sink(SlotWriter(addOnsDir: dir)), clock: { 1 })
        e.onFrame(frame(next: 7))
        try expect(!e.flush())
        try expect(e.slotWriteError?.contains("7") == true)
    }

    // 4. Keychain vault
    test("vault: malformed record is distinct from denied/locked; nothing auto-deleted") {
        let s = FakeSecrets(); s.readResult = (SecStatus.success, Data("not json".utf8))
        let v = GrantVault(backend: s)
        try eq(v.read(), .malformed)
        s.readResult = (SecStatus.interactionNotAllowed, nil)
        try eq(v.read(), .unavailable(SecStatus.interactionNotAllowed))
        try eq(s.deletes, 0)
    }
    test("vault: delete success or not-found = disconnected; any other status is reported, state kept") {
        let s = FakeSecrets(); let v = GrantVault(backend: s)
        _ = v.save(g)
        try eq(v.delete(), .removed)
        s.deleteStatus = SecStatus.itemNotFound; try eq(v.delete(), .removed)
        s.readResult = (SecStatus.success, try JSONEncoder().encode(g)); s.deleteStatus = SecStatus.authFailed
        try eq(v.delete(), .failed(SecStatus.authFailed))
        guard case .found = v.read() else { throw Failure(description: "record lost after failed delete") }
    }
    test("setup: malformed → explicit owner-confirmed reset; Disconnect available whenever a record exists") {
        let v = Setup.evaluate(.init(t3Origin: approved, grant: .malformed))
        try eq(v.action, .resetSavedApproval); try expect(v.actionTitle.contains("Reset"))
        try expect(v.showDisconnect)
        try expect(!Setup.evaluate(.init(t3Origin: approved, grant: .none)).showDisconnect)
        try expect(Setup.evaluate(.init(t3Origin: approved, grant: .keychainUnavailable)).showDisconnect)
        try eq(Setup.evaluate(.init(t3Origin: approved, grant: .keychainUnavailable)).action, .retryKeychain)
    }

    // 5. capture lifecycle
    test("capture: failed start clears only that candidate and allows a retry") {
        let c = CaptureLifecycle()
        try expect(c.shouldStart(window: 9))
        let g1 = c.begin(window: 9)
        try expect(!c.shouldStart(window: 9), "pending start not duplicated")
        c.startCompleted(gen: g1, ok: false)
        try expect(c.shouldStart(window: 9), "retry allowed after failure")
    }
    test("capture: an old stream's callbacks cannot clear or mutate the replacement") {
        let c = CaptureLifecycle()
        let g1 = c.begin(window: 9); c.startCompleted(gen: g1, ok: true)
        let g2 = c.begin(window: 10); c.startCompleted(gen: g2, ok: true)
        c.stopped(gen: g1)
        c.startCompleted(gen: g1, ok: false)
        try eq(c.active?.gen, g2); try expect(c.active?.started == true)
        try expect(!c.shouldStart(window: 10))
        c.stopped(gen: g2); try expect(c.shouldStart(window: 10))
    }
    test("capture: permission loss resets; recovery starts fresh") {
        let c = CaptureLifecycle()
        _ = c.begin(window: 3)
        c.reset()
        try expect(c.active == nil && c.shouldStart(window: 3))
    }

    // 6. truthful link status
    test("link: a saved grant is 'verifying' until a harmless read succeeds, even with no game running") {
        var now = 1_794_160_000.0
        let t3 = FakeT3()
        let (e, _) = makeEngine(t3, clock: { now })
        try eq(e.link, .verifying)
        e.tick() // no game frames at all
        try eq(e.link, .connected)
        try expect(t3.calls.allSatisfy { $0.0 == "t3_project_list" }, "verification is read-only")
        let rev = FakeT3(); rev.failNext = T3Error.unauthorized
        let (e2, _) = makeEngine(rev, clock: { now })
        e2.tick()
        try eq(e2.link, .revoked)
        let down = FakeT3(); down.failNext = T3Error.unreachable("down")
        let (e3, _) = makeEngine(down, clock: { now })
        e3.tick(); try eq(e3.link, .unreachable)
        now += 61; e3.tick(); try eq(e3.link, .connected, "re-verified while the game is closed")
    }
    test("setup: verifying shows checking, not Connected") {
        let v = Setup.evaluate(.init(t3Origin: approved, grant: .valid(daysLeft: 20), link: "verifying"))
        try expect(v.rows[0].detail.contains("checking")); try expect(!v.rows[0].ok)
        let o = Setup.evaluate(.init(t3Origin: approved, grant: .valid(daysLeft: 20), link: "originChanged"))
        try eq(o.action, .connectT3); try expect(o.rows[0].detail.contains("different T3"))
    }

    // preview self-check
    test("preview check: opaque, ≥2x and visible content required") {
        let w = 880, h = 600
        var px = [UInt8](repeating: 255, count: w * h * 4)
        try expect(!PreviewCheck.evaluate(rgba: px, pixelsWide: w, pixelsHigh: h, bytesPerRow: w * 4, pointsWide: 440).pass, "blank fails")
        for i in stride(from: 0, to: 40_000 * 4, by: 4) { px[i] = 0; px[i + 1] = 0; px[i + 2] = 0 }
        try expect(PreviewCheck.evaluate(rgba: px, pixelsWide: w, pixelsHigh: h, bytesPerRow: w * 4, pointsWide: 440).pass)
        try expect(!PreviewCheck.evaluate(rgba: px, pixelsWide: w, pixelsHigh: h, bytesPerRow: w * 4, pointsWide: 880).pass, "1x fails")
        px[3] = 0
        try expect(!PreviewCheck.evaluate(rgba: px, pixelsWide: w, pixelsHigh: h, bytesPerRow: w * 4, pointsWide: 440).pass, "transparent pixel fails")
    }
    test("preview fixtures: every state is synthetic and evaluates") {
        let states = PreviewFixtures.all
        try expect(states.count >= 5)
        for s in states { try expect(s.name.hasPrefix("SYNTHETIC-")); _ = Setup.evaluate(s.facts) }
        try expect(states.contains { Setup.evaluate($0.facts).secondaryAction == .reconnectFullAccess })
        try expect(states.contains { Setup.evaluate($0.facts).action == .resetSavedApproval })
    }
}

// MARK: installer transaction (parent repro at faecfed: fault AFTER the addon swap)

/// Every path under `dir` → bytes ("<dir>" for directories). Byte-exact tree snapshot.
func snapshot(_ dir: URL) -> [String: Data] {
    var out: [String: Data] = [:]
    let fm = FileManager.default
    let e = fm.enumerator(atPath: dir.path)
    while let f = e?.nextObject() as? String {
        var d: ObjCBool = false
        _ = fm.fileExists(atPath: dir.appendingPathComponent(f).path, isDirectory: &d)
        out[f] = d.boolValue ? Data("<dir>".utf8) : (try? Data(contentsOf: dir.appendingPathComponent(f))) ?? Data("<unreadable>".utf8)
    }
    return out
}
func fakeBundle(_ main: String) -> URL {
    let d = tmpDir().appendingPathComponent("T3ForWoW")
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    try! Data("## Interface: 16001\n## Title: T3 for WoW\nMain.lua\n".utf8).write(to: d.appendingPathComponent("T3ForWoW.toc"))
    try! Data(main.utf8).write(to: d.appendingPathComponent("Main.lua"))
    return d
}

func runInstallerTransactionTests() {
    test("txn: parent repro — slot2 blocked by a file after the swap → addon v1 and old slot1 data preserved, error thrown") {
        let v1 = fakeBundle("-- version1\n"), v2 = fakeBundle("-- version2\n")
        let dir = tmpDir().appendingPathComponent("fault/_forever_/Interface/AddOns")
        _ = try Installer.install(bundledAddon: v1, addOnsDir: dir, slotCount: 2, interface: "16001")
        try Data("-- SYNTHETIC_OLD_SLOT_DATA\n".utf8).write(to: dir.appendingPathComponent("T3ForWoW_Slot0001/Slot.lua"))
        let slot2 = dir.appendingPathComponent("T3ForWoW_Slot0002")
        try FileManager.default.removeItem(at: slot2); try Data("SYNTHETIC_BLOCKING_FILE".utf8).write(to: slot2)
        let before = snapshot(dir)
        var threw = false
        do { _ = try Installer.install(bundledAddon: v2, addOnsDir: dir, slotCount: 2, interface: "16001") } catch { threw = true }
        try expect(threw)
        try eq(try String(contentsOf: dir.appendingPathComponent("T3ForWoW/Main.lua"), encoding: .utf8), "-- version1\n")
        try eq(try String(contentsOf: dir.appendingPathComponent("T3ForWoW_Slot0001/Slot.lua"), encoding: .utf8), "-- SYNTHETIC_OLD_SLOT_DATA\n")
        try eq(snapshot(dir), before, "whole tree byte-identical")
    }
    test("txn: failure after several slot writes (incl. new slots) rolls back every byte and path; unrelated data untouched") {
        let v1 = fakeBundle("-- version1\n"), v2 = fakeBundle("-- version2\n")
        let base = tmpDir().appendingPathComponent("_forever_"), dir = base.appendingPathComponent("Interface/AddOns")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("WTF/Account/A/SavedVariables"), withIntermediateDirectories: true)
        try Data("T3ForWoWDB = { x = 1 }".utf8).write(to: base.appendingPathComponent("WTF/Account/A/SavedVariables/T3ForWoW.lua"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("OtherAddon"), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: dir.appendingPathComponent("OtherAddon/x.lua"))
        _ = try Installer.install(bundledAddon: v1, addOnsDir: dir, slotCount: 2, interface: "16001")
        try Data("-- OLD 1\n".utf8).write(to: dir.appendingPathComponent("T3ForWoW_Slot0001/Slot.lua"))
        try Data("-- OLD 2\n".utf8).write(to: dir.appendingPathComponent("T3ForWoW_Slot0002/Slot.lua"))
        let before = snapshot(base)
        Installer.faultHook = { step in if step == "slot:4" { throw CocoaError(.fileWriteUnknown) } }
        defer { Installer.faultHook = nil }
        do { _ = try Installer.install(bundledAddon: v2, addOnsDir: dir, slotCount: 5, interface: "16001"); throw Failure(description: "no error") }
        catch is Failure { throw Failure(description: "no error") } catch {}
        try eq(snapshot(base), before, "addon, old slots, new slot folders, other addon and SavedVariables all as before")
        try expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("T3ForWoW_Slot0003").path), "slot created by the failed attempt removed")
        try eq(Installer.health(bundled: v1, addOnsDir: dir), .ok)
    }
    test("txn: a rollback that itself fails keeps the recovery copy, says where, and the next install recovers") {
        let v1 = fakeBundle("-- version1\n"), v2 = fakeBundle("-- version2\n")
        let dir = tmpDir().appendingPathComponent("_forever_/Interface/AddOns")
        _ = try Installer.install(bundledAddon: v1, addOnsDir: dir, slotCount: 2, interface: "16001")
        try Data("-- OLD 1\n".utf8).write(to: dir.appendingPathComponent("T3ForWoW_Slot0001/Slot.lua"))
        Installer.faultHook = { step in if step == "slot:2" || step == "restore" { throw CocoaError(.fileWriteUnknown) } }
        var message = ""
        do { _ = try Installer.install(bundledAddon: v2, addOnsDir: dir, slotCount: 2, interface: "16001") } catch { message = "\(error)" }
        Installer.faultHook = nil
        try expect(message.contains(Installer.recoveryName), "error names the kept recovery copy: \(message)")
        try expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(Installer.recoveryName).path), "recovery copy not deleted")
        guard case .damaged(let why) = Installer.health(bundled: v1, addOnsDir: dir) else { throw Failure(description: "interrupted install looked healthy") }
        try expect(why.contains("interrupted"))
        // Next attempt restores the previous state first, then installs.
        let r = try Installer.install(bundledAddon: v2, addOnsDir: dir, slotCount: 2, interface: "16001")
        try eq(r.change, .reload)
        try expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(Installer.recoveryName).path))
        try eq(Installer.health(bundled: v2, addOnsDir: dir), .ok)
    }
    test("txn: a successful install leaves no transaction or backup folders behind") {
        let v1 = fakeBundle("-- version1\n")
        let dir = tmpDir().appendingPathComponent("_forever_/Interface/AddOns")
        _ = try Installer.install(bundledAddon: v1, addOnsDir: dir, slotCount: 2, interface: "16001")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        try eq(names, ["T3ForWoW", "T3ForWoW_Slot0001", "T3ForWoW_Slot0002"])
    }
}

func runInstallerRealFaultTest() {
    test("txn: REAL filesystem fault after the swap (slot2/Slot.lua is a directory) → full byte-exact rollback, no hook") {
        let v1 = fakeBundle("-- version1\n"), v2 = fakeBundle("-- version2\n")
        let dir = tmpDir().appendingPathComponent("_forever_/Interface/AddOns")
        _ = try Installer.install(bundledAddon: v1, addOnsDir: dir, slotCount: 2, interface: "16001")
        try Data("-- SYNTHETIC_OLD_SLOT_DATA\n".utf8).write(to: dir.appendingPathComponent("T3ForWoW_Slot0001/Slot.lua"))
        let s2 = dir.appendingPathComponent("T3ForWoW_Slot0002/Slot.lua")
        try FileManager.default.removeItem(at: s2)
        try FileManager.default.createDirectory(at: s2.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: s2.appendingPathComponent("inner/file"))
        let before = snapshot(dir)
        var message = ""
        do { _ = try Installer.install(bundledAddon: v2, addOnsDir: dir, slotCount: 2, interface: "16001") } catch { message = "\(error)" }
        // validated up front (no-follow checks): refused before ANY change
        try expect(message.contains("nothing was changed"), message)
        try eq(snapshot(dir), before, "addon v1, slot1 old bytes, slot2 contents and no leftovers")
        try eq(try String(contentsOf: dir.appendingPathComponent("T3ForWoW/Main.lua"), encoding: .utf8), "-- version1\n")
    }
    test("txn: REAL filesystem fault mid-transaction (read-only slot folder) → truthful 'not fully undone', recovery kept, next install recovers") {
        if geteuid() == 0 { return }   // root ignores permission bits
        let v1 = fakeBundle("-- version1\n"), v2 = fakeBundle("-- version2\n")
        let dir = tmpDir().appendingPathComponent("_forever_/Interface/AddOns")
        _ = try Installer.install(bundledAddon: v1, addOnsDir: dir, slotCount: 3, interface: "16001")
        let s2 = dir.appendingPathComponent("T3ForWoW_Slot0002")
        try expect(chmod(s2.path, 0o555) == 0)
        defer { _ = chmod(s2.path, 0o755) }
        var message = ""
        do { _ = try Installer.install(bundledAddon: v2, addOnsDir: dir, slotCount: 3, interface: "16001") } catch { message = "\(error)" }
        try expect(message.contains("could not be fully undone") && message.contains(Installer.recoveryName), message)
        guard case .damaged = Installer.health(bundled: v2, addOnsDir: dir) else { throw Failure(description: "interrupted install must read as damaged") }
        _ = chmod(s2.path, 0o755)
        _ = try Installer.install(bundledAddon: v2, addOnsDir: dir, slotCount: 3, interface: "16001")
        try eq(Installer.health(bundled: v2, addOnsDir: dir), .ok)
        try eq(try String(contentsOf: dir.appendingPathComponent("T3ForWoW/Main.lua"), encoding: .utf8), "-- version2\n")
        try expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(Installer.recoveryName).path))
    }
}

func runPresentationTests() {
    let o = URL(string: "http://127.0.0.1:3773")!
    test("presentation: every state has one title, one support line, a tone and a short status label") {
        for s in PreviewFixtures.all {
            let v = Setup.evaluate(s.facts)
            try expect(!v.headline.isEmpty && !v.summary.isEmpty && !v.statusLabel.isEmpty, s.name)
            try expect(v.summary.count <= 160, "support line stays short: \(s.name)")
        }
        try eq(Setup.evaluate(PreviewFixtures.all[0].facts).tone, .neutral)
        try eq(Setup.evaluate(PreviewFixtures.all[1].facts).tone, .good)
        try eq(Setup.evaluate(PreviewFixtures.all[1].facts).statusLabel, "Connected")
    }
    test("presentation: fixtures export unpaired and connected first") {
        try eq(PreviewFixtures.all[0].name, "SYNTHETIC-unpaired"); try eq(PreviewFixtures.all[1].name, "SYNTHETIC-connected")
    }
    test("presentation: quiet context names environment and game; diagnostics rows stay available") {
        var f = Setup.Facts(t3Origin: o, wowCandidates: 1); f.gameFolder = "_forever_"
        let v = Setup.evaluate(f)
        try eq(v.context.map(\.label), ["T3", "Game"])
        try eq(v.context[0].value, "127.0.0.1:3773"); try eq(v.context[1].value, "_forever_")
        try eq(v.rows.count, 4)
    }
    test("presentation: consequential warnings are never hidden behind details") {
        let access = Setup.evaluate(PreviewFixtures.all.first { $0.name == "SYNTHETIC-full-access-note" }!.facts)
        try expect(access.warnings.contains { $0.contains("Full access") })
        var f = PreviewFixtures.all[1].facts; f.slotWriteError = "slot 3 could not be written"
        try expect(Setup.evaluate(f).warnings.contains { $0.contains("slot 3") })
        var g = PreviewFixtures.all[1].facts; g.grant = .valid(daysLeft: 2)
        try expect(Setup.evaluate(g).warnings.contains { $0.contains("2 days") })
        try eq(Setup.evaluate(PreviewFixtures.all[1].facts).warnings, [])
        try eq(Setup.evaluate(PreviewFixtures.all.first { $0.name == "SYNTHETIC-revoked" }!.facts).tone, .bad)
    }
}

func runThemeTests() {
    typealias T = T3Theme
    test("theme: Graphite Blue roles are the published values; primary action is not the accent/focus role") {
        try eq(T.canvas, T.RGB(0x131418)); try eq(T.action, T.RGB(0x6489E8)); try eq(T.focus, T.RGB(0x7B9CFF))
        try expect(T.action != T.focus); try eq(T.actionForeground, T.RGB(0x10182C))
        try eq(T.controlRadius, 8); try eq(T.buttonHeight, 28); try eq(T.panelPadding, 24)
    }
    test("theme: every text/background pair the window uses is readable (WCAG)") {
        try expect(T.text.contrast(T.canvas) >= 7, "title/body on canvas")
        try expect(T.textMuted.contrast(T.canvas) >= 4.5, "support text on canvas")
        try expect(T.textMuted.contrast(T.contextFill) >= 4.5, "context text")
        try expect(T.actionForeground.contrast(T.action) >= 4.5, "primary button label")
        try expect(T.actionForeground.contrast(T.actionHover) >= 4.5, "primary button label on hover")
        try expect(T.text.contrast(T.outlineHover) >= 4.5, "outline button label on hover")
        try expect(T.warningForeground.contrast(T.warningSurface) >= 4.5, "warning text")
        try expect(T.errorForeground.contrast(T.errorSurface) >= 4.5, "error text")
        try expect(T.focus.contrast(T.canvas) >= 3, "focus ring is visible (non-text 3:1)")
    }
}
