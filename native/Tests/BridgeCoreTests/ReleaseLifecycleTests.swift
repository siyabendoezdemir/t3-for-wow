import Foundation
@testable import BridgeCore

/// Release-candidate lifecycle in a clean, fake game folder (SYNTHETIC: a temp directory shaped like
/// `World of Warcraft/_forever_`, never a real game install): discover → install → update → repair →
/// uninstall, next to another product's addon (Telegram for WoW) and look-alike folder names.
func runReleaseLifecycleTests() {
    let fm = FileManager.default
    func gameFolder() -> (root: URL, addOns: URL, wtf: URL) {
        let root = tmpDir().appendingPathComponent("World of Warcraft")
        let addOns = root.appendingPathComponent("_forever_/Interface/AddOns")
        let wtf = root.appendingPathComponent("_forever_/WTF/Account/ACC/SavedVariables")
        try! fm.createDirectory(at: addOns, withIntermediateDirectories: true)
        try! fm.createDirectory(at: wtf, withIntermediateDirectories: true)
        return (root, addOns, wtf)
    }
    func bundled() -> URL {
        let src = tmpDir().appendingPathComponent("T3ForWoW")
        try! fm.copyItem(at: repoRoot.appendingPathComponent("addon/T3ForWoW"), to: src)
        return src
    }
    func put(_ dir: URL, _ name: String, _ text: String) {
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    test("release: owned-folder predicate matches only this app's exact folders") {
        for n in ["T3ForWoW", "T3ForWoW_Slot0001", "T3ForWoW_Slot0480", "T3ForWoW_Slot9999", ".T3ForWoW.recovery", ".T3ForWoW.installing"] {
            try expect(Installer.isOwnedFolder(n), n)
        }
        for n in ["T3ForWoW_Probe", "T3ForWoWExtras", "T3ForWoW_Slot01", "T3ForWoW_Slot00001", "T3ForWoW_SlotABCD", "T3ForWoW_Slot0001 copy",
                  "TelegramWoW", "TelegramWoW_Slot001", "t3forwow", "Blizzard_AuctionUI", ".T3ForWoW.other"] {
            try expect(!Installer.isOwnedFolder(n), n)
        }
    }

    test("release: clean folder → install → update → repair → uninstall; neighbours and SavedVariables survive") {
        let g = gameFolder(), src = bundled()
        // neighbours: another product's addon + slots, a look-alike, a user addon, SavedVariables of both products
        put(g.addOns.appendingPathComponent("TelegramWoW"), "TelegramWoW.toc", "## Title: Telegram for WoW\n")
        put(g.addOns.appendingPathComponent("TelegramWoW_Slot001"), "Slot.lua", "-- telegram slot\n")
        put(g.addOns.appendingPathComponent("T3ForWoW_Probe"), "T3ForWoW_Probe.toc", "## Title: probe\n")
        put(g.addOns.appendingPathComponent("SomeUserAddon"), "SomeUserAddon.toc", "## Title: user\n")
        put(g.wtf, "T3ForWoW.lua", "T3ForWoWDB = { tracker = { x = 1 } }\n")
        put(g.wtf, "TelegramWoW.lua", "TelegramWoWDB = {}\n")
        func neighboursIntact() throws {
            try eq(try String(contentsOf: g.addOns.appendingPathComponent("TelegramWoW_Slot001/Slot.lua"), encoding: .utf8), "-- telegram slot\n")
            for d in ["TelegramWoW/TelegramWoW.toc", "T3ForWoW_Probe/T3ForWoW_Probe.toc", "SomeUserAddon/SomeUserAddon.toc"] {
                try expect(fm.fileExists(atPath: g.addOns.appendingPathComponent(d).path), d)
            }
            try expect(fm.fileExists(atPath: g.wtf.appendingPathComponent("TelegramWoW.lua").path))
        }

        // discover exactly one candidate
        let found = Installer.discover(roots: [g.root])
        try eq(found.count, 1); try eq(found[0].addOnsDir.standardizedFileURL.path, g.addOns.standardizedFileURL.path)
        try eq(Installer.health(bundled: src, addOnsDir: g.addOns), .notInstalled)

        // first install: restart needed (new addon + slot folders)
        let first = try Installer.install(bundledAddon: src, addOnsDir: g.addOns, slotCount: Installer.defaultSlots, interface: "16001")
        try eq(first.change, .restart); try eq(first.slotsCreated, Installer.defaultSlots)
        try eq(Installer.health(bundled: src, addOnsDir: g.addOns), .ok)
        let fp = Installer.footprint(addOnsDir: g.addOns)
        try eq(fp.folders, Installer.defaultSlots + 1, "footprint counts only this app's folders")
        try neighboursIntact()

        // a newer app bundles changed Lua → outdated → one-click update → /reload is enough
        try Data("-- release candidate update\n".utf8).write(to: src.appendingPathComponent("T3ForWoW.lua"), options: .atomic)
        try eq(Installer.health(bundled: src, addOnsDir: g.addOns), .outdated)
        try eq(try Installer.install(bundledAddon: src, addOnsDir: g.addOns, slotCount: Installer.defaultSlots, interface: "16001").change, .reload)
        try eq(Installer.health(bundled: src, addOnsDir: g.addOns), .ok)

        // damage (a deleted slot and an interrupted-install leftover) → Repair restores health
        try fm.removeItem(at: g.addOns.appendingPathComponent("T3ForWoW_Slot0200"))
        guard case .damaged = Installer.health(bundled: src, addOnsDir: g.addOns) else { throw Failure(description: "missing slot not reported") }
        _ = try Installer.install(bundledAddon: src, addOnsDir: g.addOns, slotCount: Installer.defaultSlots, interface: "16001")
        try eq(Installer.health(bundled: src, addOnsDir: g.addOns), .ok)
        try neighboursIntact()

        // uninstall: every owned folder (incl. a leftover staging folder) goes; nothing else does
        try fm.createDirectory(at: g.addOns.appendingPathComponent(".T3ForWoW.installing"), withIntermediateDirectories: true)
        let removed = try Installer.uninstall(addOnsDir: g.addOns)
        try eq(removed, Installer.defaultSlots + 2)
        try eq(Installer.health(bundled: src, addOnsDir: g.addOns), .notInstalled)
        let left = try fm.contentsOfDirectory(atPath: g.addOns.path).sorted()
        try eq(left, ["SomeUserAddon", "T3ForWoW_Probe", "TelegramWoW", "TelegramWoW_Slot001"])
        try neighboursIntact()
        // SavedVariables hold only tracker positions; uninstall leaves the game's own files alone
        try expect(fm.fileExists(atPath: g.wtf.appendingPathComponent("T3ForWoW.lua").path))
        // uninstall twice / on a missing folder is harmless
        try eq(try Installer.uninstall(addOnsDir: g.addOns), 0)
        try eq(try Installer.uninstall(addOnsDir: g.root.appendingPathComponent("nope")), 0)
        // reinstall after uninstall works from scratch
        try eq(try Installer.install(bundledAddon: src, addOnsDir: g.addOns, slotCount: 8, interface: "16001").change, .restart)
        try eq(Installer.health(bundled: src, addOnsDir: g.addOns), .ok)
    }

    test("release: the installed addon carries no private material and matches the bundled bytes exactly") {
        let g = gameFolder(), src = bundled()
        _ = try Installer.install(bundledAddon: src, addOnsDir: g.addOns, slotCount: 2, interface: "16001")
        try eq(try Installer.contentHash(of: g.addOns.appendingPathComponent("T3ForWoW")), try Installer.contentHash(of: src))
        let e = fm.enumerator(atPath: g.addOns.path)
        while let f = e?.nextObject() as? String {
            var d: ObjCBool = false
            guard fm.fileExists(atPath: g.addOns.appendingPathComponent(f).path, isDirectory: &d), !d.boolValue else { continue }
            let s = (try? String(contentsOf: g.addOns.appendingPathComponent(f), encoding: .utf8)) ?? ""
            for bad in ["/Users/", "/home/", "Bearer ", "access_token", "BEGIN PRIVATE KEY", "127.0.0.1:"] { try expect(!s.contains(bad), "\(f) contains \(bad)") }
        }
    }

    test("release: one version everywhere (VERSION, addon .toc, app Info.plist, bridge clientInfo)") {
        let v = try String(contentsOf: repoRoot.appendingPathComponent("VERSION"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let toc = try String(contentsOf: repoRoot.appendingPathComponent("addon/T3ForWoW/T3ForWoW.toc"), encoding: .utf8)
        let plist = try String(contentsOf: repoRoot.appendingPathComponent("packaging/Info.plist"), encoding: .utf8)
        try expect(toc.contains("## Version: \(v)\n"), "toc version")
        try expect(plist.contains("<key>CFBundleShortVersionString</key><string>\(v)</string>"), "Info.plist version")
        try eq(BridgeVersion.string, v)
    }
}
