import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import BridgeCore

/// Destructive-path safety (SYNTHETIC temp trees only; never a real game, Keychain or account).
/// Every case puts sentinels OUTSIDE the game tree and proves they survive, and that failures are
/// reported as failures. Regressions for the destructive-path issues found by independent review of 0.9.0.
func runReleaseSafetyTests() {
    let fm = FileManager.default
    struct Tree { let base: URL; let addOns: URL; let external: URL }
    func tree() -> Tree {
        let base = tmpDir()
        let addOns = base.appendingPathComponent("World of Warcraft/_forever_/Interface/AddOns")
        let external = base.appendingPathComponent("elsewhere")
        try! fm.createDirectory(at: addOns, withIntermediateDirectories: true)
        try! fm.createDirectory(at: external, withIntermediateDirectories: true)
        return Tree(base: base, addOns: addOns, external: external)
    }
    func put(_ u: URL, _ s: String) { try! fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true); try! Data(s.utf8).write(to: u) }
    func text(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "<missing>" }
    func bundled() -> URL {
        let src = tmpDir().appendingPathComponent("T3ForWoW")
        try! fm.copyItem(at: repoRoot.appendingPathComponent("addon/T3ForWoW"), to: src)
        return src
    }
    func link(_ at: URL, to: URL) { try! fm.createSymbolicLink(at: at, withDestinationURL: to) }
    func isLink(_ u: URL) -> Bool { (try? PathSafety.kind(u)) == .symlink }
    let isRoot = geteuid() == 0   // root ignores permission bits; permission cases are skipped then

    // Interface/AddOns replaced by a link to an external folder
    test("safety: a linked AddOns folder is refused by validation, install, health, slot writes and uninstall; external owned-name folder survives") {
        let t = tree(), src = bundled()
        put(t.external.appendingPathComponent("T3ForWoW/sentinel"), "EXTERNAL")
        put(t.external.appendingPathComponent("T3ForWoW_Slot0001/Slot.lua"), "EXTERNAL SLOT")
        try fm.removeItem(at: t.addOns)
        link(t.addOns, to: t.external)
        try expect(InstallTarget.validate(t.addOns)?.contains("link") == true, "validation must reject a linked AddOns folder")
        do { _ = try Installer.uninstall(addOnsDir: t.addOns); throw Failure(description: "uninstall through a link succeeded") }
        catch let e as Installer.UninstallFailure { try expect(e.description.contains("link"), e.description); try eq(e.removed, 0) }
        do { _ = try Installer.install(bundledAddon: src, addOnsDir: t.addOns, slotCount: 2, interface: "16001"); throw Failure(description: "install through a link succeeded") }
        catch is PathSafety.Failure {}
        do { try SlotWriter(addOnsDir: t.addOns).write(slot: 1, payload: [1, 2, 3]); throw Failure(description: "slot write through a link succeeded") }
        catch is PathSafety.Failure {}
        guard case .damaged = Installer.health(bundled: src, addOnsDir: t.addOns) else { throw Failure(description: "health must report a linked AddOns folder") }
        try eq(text(t.external.appendingPathComponent("T3ForWoW/sentinel")), "EXTERNAL")
        try eq(text(t.external.appendingPathComponent("T3ForWoW_Slot0001/Slot.lua")), "EXTERNAL SLOT")
        try expect(isLink(t.addOns), "the link itself is left alone")
    }

    test("safety: a linked Interface folder (parent of AddOns) is refused the same way") {
        let t = tree(), src = bundled()
        let iface = t.addOns.deletingLastPathComponent()
        put(t.external.appendingPathComponent("AddOns/T3ForWoW/sentinel"), "EXTERNAL")
        try fm.removeItem(at: iface)
        link(iface, to: t.external)
        try expect(InstallTarget.validate(t.addOns) != nil)
        do { _ = try Installer.uninstall(addOnsDir: t.addOns); throw Failure(description: "uninstall via linked Interface succeeded") } catch is Installer.UninstallFailure {}
        do { _ = try Installer.install(bundledAddon: src, addOnsDir: t.addOns, slotCount: 1, interface: "16001"); throw Failure(description: "install via linked Interface succeeded") } catch is PathSafety.Failure {}
        try eq(text(t.external.appendingPathComponent("AddOns/T3ForWoW/sentinel")), "EXTERNAL")
    }

    // exact-name slot entry is a link (fresh install, repair, runtime write)
    test("safety: fresh install refuses an exact-name slot link before ANY change; external Slot.lua/TOC untouched") {
        let t = tree(), src = bundled()
        put(t.external.appendingPathComponent("T3ForWoW_Slot0002.toc"), "OLD TOC\n")
        put(t.external.appendingPathComponent("Slot.lua"), "EXTERNAL SENTINEL\n")
        link(t.addOns.appendingPathComponent("T3ForWoW_Slot0002"), to: t.external)
        do { _ = try Installer.install(bundledAddon: src, addOnsDir: t.addOns, slotCount: 3, interface: "16001"); throw Failure(description: "install accepted a slot link") }
        catch let e as PathSafety.Failure { try expect("\(e)".contains("T3ForWoW_Slot0002"), "\(e)") }
        try eq(text(t.external.appendingPathComponent("Slot.lua")), "EXTERNAL SENTINEL\n")
        try eq(text(t.external.appendingPathComponent("T3ForWoW_Slot0002.toc")), "OLD TOC\n")
        try eq(try fm.contentsOfDirectory(atPath: t.addOns.path).sorted(), ["T3ForWoW_Slot0002"], "nothing created or moved")
    }

    test("safety: repair over an existing install refuses a slot replaced by a link; previous install intact; health says why") {
        let t = tree(), src = bundled()
        _ = try Installer.install(bundledAddon: src, addOnsDir: t.addOns, slotCount: 3, interface: "16001")
        put(t.external.appendingPathComponent("Slot.lua"), "EXTERNAL SENTINEL\n")
        try fm.removeItem(at: t.addOns.appendingPathComponent("T3ForWoW_Slot0003"))
        link(t.addOns.appendingPathComponent("T3ForWoW_Slot0003"), to: t.external)
        guard case .damaged(let why) = Installer.health(bundled: src, addOnsDir: t.addOns) else { throw Failure(description: "link not reported") }
        try expect(why.contains("T3ForWoW_Slot0003") && why.contains("link"), why)
        do { _ = try Installer.install(bundledAddon: src, addOnsDir: t.addOns, slotCount: 3, interface: "16001"); throw Failure(description: "repair accepted a slot link") } catch is PathSafety.Failure {}
        try eq(text(t.external.appendingPathComponent("Slot.lua")), "EXTERNAL SENTINEL\n")
        try expect(fm.fileExists(atPath: t.addOns.appendingPathComponent("T3ForWoW/T3ForWoW.toc").path), "previous addon still installed")
        try expect(!fm.fileExists(atPath: t.addOns.appendingPathComponent(Installer.recoveryName).path), "no transaction left behind")
    }

    test("safety: a Slot.lua or TOC file replaced by a link is refused (install and runtime); the linked file is untouched") {
        let t = tree(), src = bundled()
        _ = try Installer.install(bundledAddon: src, addOnsDir: t.addOns, slotCount: 2, interface: "16001")
        let target = t.external.appendingPathComponent("victim.txt"); put(target, "EXTERNAL FILE\n")
        let slotLua = t.addOns.appendingPathComponent("T3ForWoW_Slot0001/Slot.lua")
        try fm.removeItem(at: slotLua); link(slotLua, to: target)
        do { try SlotWriter(addOnsDir: t.addOns).write(slot: 1, payload: [9]); throw Failure(description: "runtime write accepted a linked Slot.lua") } catch is PathSafety.Failure {}
        do { _ = try Installer.install(bundledAddon: src, addOnsDir: t.addOns, slotCount: 2, interface: "16001"); throw Failure(description: "install accepted a linked Slot.lua") } catch is PathSafety.Failure {}
        let toc = t.addOns.appendingPathComponent("T3ForWoW_Slot0002/T3ForWoW_Slot0002.toc")
        try fm.removeItem(at: toc); link(toc, to: target)
        do { _ = try Installer.install(bundledAddon: src, addOnsDir: t.addOns, slotCount: 2, interface: "16001"); throw Failure(description: "install accepted a linked TOC") } catch is PathSafety.Failure {}
        try eq(text(target), "EXTERNAL FILE\n")
    }

    test("safety: runtime slot write refuses a slot folder swapped for a link after install; engine surfaces it; normal writes still work") {
        let t = tree(), src = bundled()
        _ = try Installer.install(bundledAddon: src, addOnsDir: t.addOns, slotCount: 3, interface: "16001")
        let w = SlotWriter(addOnsDir: t.addOns)
        try w.write(slot: 1, payload: Array("ok".utf8))
        try expect(text(t.addOns.appendingPathComponent("T3ForWoW_Slot0001/Slot.lua")).contains("T3ForWoW_Deliver(1,"), "normal write works")
        put(t.external.appendingPathComponent("Slot.lua"), "EXTERNAL SENTINEL\n")
        try fm.removeItem(at: t.addOns.appendingPathComponent("T3ForWoW_Slot0002"))
        link(t.addOns.appendingPathComponent("T3ForWoW_Slot0002"), to: t.external)
        do { try w.write(slot: 2, payload: [1]); throw Failure(description: "runtime write through a slot link") } catch is PathSafety.Failure {}
        try eq(text(t.external.appendingPathComponent("Slot.lua")), "EXTERNAL SENTINEL\n")
        try w.write(slot: 3, payload: [2])   // other slots unaffected
    }

    test("safety: rollback never restores through a slot folder swapped for a link mid-install; recovery copy kept; external untouched") {
        let t = tree(), src = bundled()
        _ = try Installer.install(bundledAddon: src, addOnsDir: t.addOns, slotCount: 3, interface: "16001")
        put(t.external.appendingPathComponent("Slot.lua"), "EXTERNAL SENTINEL\n")
        put(t.external.appendingPathComponent("T3ForWoW_Slot0001.toc"), "EXTERNAL TOC\n")
        try Data("-- changed\n".utf8).write(to: src.appendingPathComponent("T3ForWoW.lua"), options: .atomic)
        Installer.faultHook = { step in
            if step == "slot:2" {   // an attacker/other process swaps an already-processed slot for a link, then the install fails
                let s1 = t.addOns.appendingPathComponent("T3ForWoW_Slot0001")
                try fm.removeItem(at: s1); try fm.createSymbolicLink(at: s1, withDestinationURL: t.external)
                throw Failure(description: "injected failure")
            }
        }
        defer { Installer.faultHook = nil }
        do { _ = try Installer.install(bundledAddon: src, addOnsDir: t.addOns, slotCount: 3, interface: "16001"); throw Failure(description: "no error") }
        catch let e as Installer.InstallError {
            guard case .rollbackFailed(_, let rec) = e else { throw Failure(description: "expected rollbackFailed, got \(e)") }
            try expect(fm.fileExists(atPath: rec), "recovery copy kept")
        }
        try eq(text(t.external.appendingPathComponent("Slot.lua")), "EXTERNAL SENTINEL\n")
        try eq(text(t.external.appendingPathComponent("T3ForWoW_Slot0001.toc")), "EXTERNAL TOC\n")
        guard case .damaged = Installer.health(bundled: src, addOnsDir: t.addOns) else { throw Failure(description: "interrupted install must show as damaged") }
    }

    // kept behaviour: an owned entry that is a link is removed as a link; also links INSIDE owned folders
    test("safety: uninstall removes an owned-name link as a link and never enters links inside owned folders") {
        let t = tree(), src = bundled()
        _ = try Installer.install(bundledAddon: src, addOnsDir: t.addOns, slotCount: 2, interface: "16001")
        put(t.external.appendingPathComponent("deep/sentinel"), "KEEP")
        link(t.addOns.appendingPathComponent("T3ForWoW/innerLink"), to: t.external.appendingPathComponent("deep"))
        try fm.removeItem(at: t.addOns.appendingPathComponent("T3ForWoW_Slot0002"))
        link(t.addOns.appendingPathComponent("T3ForWoW_Slot0002"), to: t.external.appendingPathComponent("deep"))
        put(t.addOns.appendingPathComponent("TelegramWoW/keep"), "KEEP")
        try eq(try Installer.uninstall(addOnsDir: t.addOns), 3)
        try eq(text(t.external.appendingPathComponent("deep/sentinel")), "KEEP")
        try eq(try fm.contentsOfDirectory(atPath: t.addOns.path), ["TelegramWoW"])
    }

    // missing vs unreadable vs partial
    test("safety: missing AddOns → 0; unreadable AddOns → truthful failure, owned folder kept") {
        let t = tree()
        try eq(try Installer.uninstall(addOnsDir: t.base.appendingPathComponent("nope/Interface/AddOns")), 0)
        if isRoot { return }
        put(t.addOns.appendingPathComponent("T3ForWoW/sentinel"), "KEEP")
        try expect(chmod(t.addOns.path, 0) == 0)
        defer { _ = chmod(t.addOns.path, 0o755) }
        do { _ = try Installer.uninstall(addOnsDir: t.addOns); throw Failure(description: "unreadable folder reported as success") }
        catch let e as Installer.UninstallFailure { try eq(e.removed, 0); try expect(e.description.contains("could not be read"), e.description) }
        _ = chmod(t.addOns.path, 0o755)
        try eq(text(t.addOns.appendingPathComponent("T3ForWoW/sentinel")), "KEEP")
    }

    test("safety: a folder that cannot be removed → partial failure naming what remains (read back), others removed") {
        if isRoot { return }
        let t = tree(), src = bundled()
        _ = try Installer.install(bundledAddon: src, addOnsDir: t.addOns, slotCount: 3, interface: "16001")
        let stuck = t.addOns.appendingPathComponent("T3ForWoW_Slot0002")
        try expect(chmod(stuck.path, 0o555) == 0)   // its files cannot be unlinked
        defer { _ = chmod(stuck.path, 0o755) }
        do { _ = try Installer.uninstall(addOnsDir: t.addOns); throw Failure(description: "partial uninstall reported as success") }
        catch let e as Installer.UninstallFailure {
            try eq(e.remaining, ["T3ForWoW_Slot0002"]); try eq(e.removed, 3)
            try expect(e.description.contains("remain"), e.description)
        }
        _ = chmod(stuck.path, 0o755)
        try eq(try Installer.uninstall(addOnsDir: t.addOns), 1, "retry after fixing permissions completes")
    }

    // game-running refusal at the destructive boundary (injected provider)
    test("safety: Uninstaller refuses while the game runs — at entry AND when it starts during the dialog; nothing removed") {
        let t = tree(), src = bundled()
        _ = try Installer.install(bundledAddon: src, addOnsDir: t.addOns, slotCount: 2, interface: "16001")
        var calls: [String] = []
        func steps(_ running: @escaping () -> Bool) -> Uninstaller.Steps {
            Uninstaller.Steps(gameRunning: running, addOnsDir: t.addOns,
                              removeAddonFolders: { calls.append("addons"); return try Installer.uninstall(addOnsDir: $0) },
                              removeApproval: { calls.append("approval"); return .done("approval") },
                              disableOpenAtLogin: { calls.append("login"); return .skipped("login") },
                              removeAppData: { calls.append("data"); return .done("data") })
        }
        var r = Uninstaller.run(steps { true })
        try expect(r.refused && !r.ok); try eq(calls, []); try expect(r.text.contains("Nothing was removed"))
        var n = 0   // not running when called, started right before files would be removed
        r = Uninstaller.run(steps { n += 1; return n > 1 })
        try expect(r.refused); try eq(calls, [])
        try eq(Installer.health(bundled: src, addOnsDir: t.addOns), .ok, "install untouched")
        r = Uninstaller.run(steps { false })
        try expect(r.ok && !r.refused, r.text); try eq(calls, ["addons", "approval", "login", "data"])
        try eq(Installer.health(bundled: src, addOnsDir: t.addOns), .notInstalled)
    }

    test("safety: Uninstaller reports a failed folder removal as partial, still completes the other steps") {
        let t = tree()
        let r = Uninstaller.run(Uninstaller.Steps(gameRunning: { false }, addOnsDir: t.addOns,
                                                  removeAddonFolders: { _ in throw Installer.UninstallFailure(removed: 1, remaining: ["T3ForWoW_Slot0007"], reason: "permission denied") },
                                                  removeApproval: { .done("approval") }, disableOpenAtLogin: { .skipped("login") }, removeAppData: { .done("data") }))
        try expect(!r.ok && !r.refused)
        try expect(r.text.contains("Not done: Game folders") && r.text.contains("T3ForWoW_Slot0007"), r.text)
        try eq(r.outcomes.count, 4)
    }
}
