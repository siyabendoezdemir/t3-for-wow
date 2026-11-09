import Foundation

/// Finds WoW: Forever installations and installs/updates the addon and its delivery slots.
/// Touches only `Interface/AddOns/T3ForWoW` and `Interface/AddOns/T3ForWoW_SlotNNNN`; never any other
/// addon, SavedVariables, keybinds or game files.
public enum Installer {
    public static let addonName = "T3ForWoW"
    public static let defaultSlots = 480

    public struct Candidate: Equatable { public var addOnsDir: URL; public var label: String }

    /// Looks for `<root>/<flavor>/Interface/AddOns` under the usual install roots. `_classic_` style
    /// flavor folders are listed separately so the owner chooses when several exist.
    public static func discover(roots: [URL]) -> [Candidate] {
        var out: [Candidate] = []
        let fm = FileManager.default
        for root in roots {
            guard let flavors = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for f in flavors.sorted() where f.hasPrefix("_") && f.hasSuffix("_") {
                let base = root.appendingPathComponent(f)
                // A real game folder has a WTF or Interface directory next to the executable bundle.
                guard fm.fileExists(atPath: base.appendingPathComponent("Interface").path) || fm.fileExists(atPath: base.appendingPathComponent("WTF").path) else { continue }
                out.append(Candidate(addOnsDir: base.appendingPathComponent("Interface/AddOns"), label: "\(root.lastPathComponent) \(f)"))
            }
        }
        return out
    }

    public static var macRoots: [URL] {
        [URL(fileURLWithPath: "/Applications/World of Warcraft"), URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/World of Warcraft")]
    }

    public enum Change: String, Equatable { case none, reload, restart }
    public struct Result: Equatable {
        public var slotsCreated: Int; public var addonUpdated: Bool; public var change: Change
        public var restartNeeded: Bool { change != .none }
    }

    /// Written next to the installed addon (not listed in the .toc, never loaded by the game).
    public struct Manifest: Codable, Equatable { public var contentHash: String; public var slotCount: Int; public var interface: String; public var tocFiles: [String] }
    public static let manifestName = "t3wow-install.json"
    /// Folder holding the previous state while an install is in progress (and kept if a rollback fails).
    public static let recoveryName = ".T3ForWoW.recovery"
    /// Test-only fault injection at named steps ("slot:N", "restore"). Always nil in the app.
    static var faultHook: ((String) throws -> Void)?

    /// SHA-256 over every file (sorted relative path + bytes), excluding the manifest.
    public static func contentHash(of dir: URL) throws -> String {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { throw CocoaError(.fileNoSuchFile) }
        var files: [String] = []
        let e = fm.enumerator(atPath: dir.path)
        while let f = e?.nextObject() as? String {
            var d: ObjCBool = false
            if fm.fileExists(atPath: dir.appendingPathComponent(f).path, isDirectory: &d), !d.boolValue, f != manifestName { files.append(f) }
        }
        var acc: [UInt8] = []
        for f in files.sorted() { acc += Array(f.utf8) + [0] + Hashing.sha256(Array(try Data(contentsOf: dir.appendingPathComponent(f)))) }
        return Hashing.sha256Hex(acc)
    }

    static func readManifest(_ addon: URL) -> Manifest? {
        guard let d = FileManager.default.contents(atPath: addon.appendingPathComponent(manifestName).path) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: d)
    }

    public enum Health: Equatable { case notInstalled, ok, outdated, damaged(String) }

    /// More than a TOC marker: installed files must match their manifest, every slot must exist,
    /// and the content must equal what this app bundles.
    public static func health(bundled: URL, addOnsDir: URL) -> Health {
        let fm = FileManager.default
        let dest = addOnsDir.appendingPathComponent(addonName)
        do { try PathSafety.requireGameTree(addOnsDir); try PathSafety.requireDirectoryOrMissing(dest) }
        catch { return .damaged("\(error)") }
        if fm.fileExists(atPath: addOnsDir.appendingPathComponent(recoveryName).path) {
            return .damaged("a previous install was interrupted; its recovery copy (\(recoveryName)) is restored by Repair")
        }
        guard fm.fileExists(atPath: dest.appendingPathComponent("\(addonName).toc").path) else { return .notInstalled }
        guard let m = readManifest(dest) else { return .damaged("installation incomplete or from an older version") }
        guard let installed = try? contentHash(of: dest), installed == m.contentHash else { return .damaged("addon files are missing or changed") }
        var missing = 0
        for i in 1...max(1, m.slotCount) {
            let d = addOnsDir.appendingPathComponent(SlotWriter.folderName(i))
            if (try? PathSafety.kind(d)) == .symlink { return .damaged("\(d.lastPathComponent) is a link to another location; remove that link, then Repair") }
            if !fm.fileExists(atPath: d.appendingPathComponent("\(SlotWriter.folderName(i)).toc").path) || !fm.fileExists(atPath: d.appendingPathComponent("Slot.lua").path) { missing += 1 }
        }
        if missing > 0 { return .damaged("\(missing) delivery slot\(missing == 1 ? "" : "s") missing") }
        if let b = try? contentHash(of: bundled), b != m.contentHash { return .outdated }
        return .ok
    }

    public enum InstallError: Error, CustomStringConvertible, LocalizedError {
        case blocked(String)
        case rolledBack(String)
        case rollbackFailed(String, recovery: String)
        public var description: String {
            switch self {
            case .blocked(let p): return "\(p) is in the way (not a folder); nothing was changed"
            case .rolledBack(let e): return "install failed (\(e)); the previous install was restored"
            case .rollbackFailed(let e, let r): return "install failed (\(e)) and could not be fully undone; the previous state is kept in \(r) and is restored on the next install attempt"
            }
        }
        public var errorDescription: String? { description }
    }

    /// Written before every mutation, so a rollback (now or on the next attempt) knows exactly what to undo.
    struct Journal: Codable {
        var hadOld = false, movedOld = false, swapped = false, committed = false
        struct Slot: Codable { var name: String; var created: Bool; var existed: [String] }
        var slots: [Slot] = []
    }

    static func saveJournal(_ j: Journal, _ rec: URL) throws { try atomicWrite(try JSONEncoder().encode(j), to: rec.appendingPathComponent("journal.json")) }

    /// Puts back exactly what was saved (file bytes atomically, or a whole directory), whatever is there now.
    static func restoreEntry(_ saved: URL, to target: URL) throws {
        let fm = FileManager.default
        var savedIsDir: ObjCBool = false, targetIsDir: ObjCBool = false
        guard fm.fileExists(atPath: saved.path, isDirectory: &savedIsDir) else { throw CocoaError(.fileNoSuchFile) }
        let targetExists = fm.fileExists(atPath: target.path, isDirectory: &targetIsDir)
        if savedIsDir.boolValue {
            if targetExists { try fm.removeItem(at: target) }
            try fm.copyItem(at: saved, to: target)
        } else {
            if targetExists && targetIsDir.boolValue { try fm.removeItem(at: target) }
            try atomicWrite(try Data(contentsOf: saved), to: target)
        }
    }

    /// Undo an uncommitted install described by `rec/journal.json`. Throws (keeping `rec`) if it cannot.
    static func rollback(addOnsDir: URL, rec: URL) throws {
        let fm = FileManager.default
        guard let d = fm.contents(atPath: rec.appendingPathComponent("journal.json").path), let j = try? JSONDecoder().decode(Journal.self, from: d) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if j.committed { try fm.removeItem(at: rec); return }
        try faultHook?("restore")
        try PathSafety.requireGameTree(addOnsDir)
        for s in j.slots.reversed() {
            let dir = addOnsDir.appendingPathComponent(s.name)
            // removeItem on a link removes only the link; restoring files requires a real folder
            if s.created { if (try PathSafety.kind(dir)) != .missing { try fm.removeItem(at: dir) }; continue }
            try PathSafety.requireDirectoryOrMissing(dir)
            for f in ["\(s.name).toc", "Slot.lua"] {
                let target = dir.appendingPathComponent(f), saved = rec.appendingPathComponent("slots/\(s.name)/\(f)")
                try PathSafety.requireFileOrMissing(target)
                if s.existed.contains(f) { try restoreEntry(saved, to: target) }
                else if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            }
        }
        let dest = addOnsDir.appendingPathComponent(addonName)
        if j.swapped, fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        if j.movedOld { try fm.moveItem(at: rec.appendingPathComponent(addonName), to: dest) }
        try? fm.removeItem(at: addOnsDir.appendingPathComponent(".\(addonName).installing"))
        try fm.removeItem(at: rec)
    }

    /// Copies the bundled addon and makes sure `slotCount` slot folders exist (slot files reset to
    /// the empty placeholder) as ONE transaction: everything is validated first; then the previous
    /// addon and the previous bytes of every touched slot are kept in `.T3ForWoW.recovery` until the
    /// whole install succeeds. Any failure restores the previous addon and slots and removes slot
    /// folders this attempt created. If that restore fails, the recovery copy is kept (never deleted)
    /// and the next install restores it first. Touches nothing outside T3ForWoW* folders.
    public static func install(bundledAddon: URL, addOnsDir: URL, slotCount: Int = defaultSlots, interface: String) throws -> Result {
        let fm = FileManager.default
        // 1. validate (no changes yet)
        let newHash = try contentHash(of: bundledAddon)
        let newToc = try String(contentsOf: bundledAddon.appendingPathComponent("\(addonName).toc"), encoding: .utf8)
        // No-follow validation of everything this install could touch, before any change.
        try PathSafety.requireGameTree(addOnsDir)
        try fm.createDirectory(at: addOnsDir, withIntermediateDirectories: true)
        try PathSafety.requireGameTree(addOnsDir)
        let rec = addOnsDir.appendingPathComponent(recoveryName)
        try PathSafety.requireDirectoryOrMissing(rec)
        if (try PathSafety.kind(rec)) == .directory { try rollback(addOnsDir: addOnsDir, rec: rec) } // finish an interrupted attempt first
        for i in 1...slotCount {
            let p = addOnsDir.appendingPathComponent(SlotWriter.folderName(i))
            do { try PathSafety.requireDirectoryOrMissing(p) } catch PathSafety.Failure.wrongType { throw InstallError.blocked(p.path) }
            if (try PathSafety.kind(p)) == .directory {
                for f in ["\(SlotWriter.folderName(i)).toc", "Slot.lua"] { try PathSafety.requireFileOrMissing(p.appendingPathComponent(f)) }
            }
        }
        let dest = addOnsDir.appendingPathComponent(addonName)
        try PathSafety.requireDirectoryOrMissing(dest)
        try PathSafety.requireDirectoryOrMissing(addOnsDir.appendingPathComponent(".\(addonName).installing"))
        let prevManifest = readManifest(dest)
        let oldToc = try? String(contentsOf: dest.appendingPathComponent("\(addonName).toc"), encoding: .utf8)
        let staging = addOnsDir.appendingPathComponent(".\(addonName).installing")
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: bundledAddon, to: staging)
        let manifest = Manifest(contentHash: newHash, slotCount: slotCount, interface: interface, tocFiles: tocFiles(newToc))
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent(manifestName))

        // 2. transaction
        try fm.createDirectory(at: rec, withIntermediateDirectories: false)
        var j = Journal()
        var created = 0, newSlotAddons = false
        do {
            j.hadOld = fm.fileExists(atPath: dest.path)
            if j.hadOld { j.movedOld = true; try saveJournal(j, rec); try fm.moveItem(at: dest, to: rec.appendingPathComponent(addonName)) }
            j.swapped = true; try saveJournal(j, rec)
            try fm.moveItem(at: staging, to: dest)
            for i in 1...slotCount {
                let name = SlotWriter.folderName(i)
                let dir = addOnsDir.appendingPathComponent(name)
                let tocURL = dir.appendingPathComponent("\(name).toc")
                try PathSafety.requireDirectoryOrMissing(dir)
                if (try PathSafety.kind(dir)) == .directory {
                    let existed = ["\(name).toc", "Slot.lua"].filter { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
                    let keep = rec.appendingPathComponent("slots/\(name)")
                    try fm.createDirectory(at: keep, withIntermediateDirectories: true)
                    for f in existed { try fm.copyItem(at: dir.appendingPathComponent(f), to: keep.appendingPathComponent(f)) }
                    j.slots.append(.init(name: name, created: false, existed: existed)); try saveJournal(j, rec)
                    if !existed.contains("\(name).toc") { newSlotAddons = true }
                } else {
                    j.slots.append(.init(name: name, created: true, existed: [])); try saveJournal(j, rec)
                    try fm.createDirectory(at: dir, withIntermediateDirectories: false)
                    created += 1; newSlotAddons = true
                }
                try faultHook?("slot:\(i)")
                guard (try PathSafety.kind(dir)) == .directory else { throw PathSafety.Failure.symlink(dir.path) }
                try PathSafety.requireFileOrMissing(tocURL); try PathSafety.requireFileOrMissing(dir.appendingPathComponent("Slot.lua"))
                try atomicWrite(Data(slotToc(i, interface: interface).utf8), to: tocURL)
                try atomicWrite(Data(SlotWriter.luaSource(slot: i, payload: []).utf8), to: dir.appendingPathComponent("Slot.lua"))
            }
            j.committed = true; try saveJournal(j, rec)
        } catch {
            do { try rollback(addOnsDir: addOnsDir, rec: rec) }
            catch let rbErr { throw InstallError.rollbackFailed("\(error); undo: \(rbErr)", recovery: rec.path) }
            throw InstallError.rolledBack("\(error)")
        }
        try? fm.removeItem(at: rec) // committed: a leftover copy is discarded (never restored) next time

        let change: Change
        if oldToc == nil || newSlotAddons || tocFiles(oldToc ?? "") != tocFiles(newToc) { change = .restart }
        else if prevManifest?.contentHash != newHash { change = .reload }
        else { change = .none }
        return Result(slotsCreated: created, addonUpdated: oldToc != nil, change: change)
    }

    /// Exactly the folders this app creates in an AddOns folder: the addon, its numbered delivery slots
    /// (`T3ForWoW_Slot` + 4 digits) and its own install-transaction folders. Nothing else matches, so
    /// another addon whose name merely starts with "T3ForWoW" (or "TelegramWoW_Slot…") is never touched.
    public static func isOwnedFolder(_ name: String) -> Bool {
        if name == addonName || name == recoveryName || name == ".\(addonName).installing" { return true }
        guard name.hasPrefix(SlotWriter.prefix) else { return false }
        let digits = name.utf8.dropFirst(SlotWriter.prefix.utf8.count)
        return digits.count == 4 && digits.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    /// Uninstall that could not complete. `removed` folders are gone; `remaining` owned names are still there.
    public struct UninstallFailure: Error, Equatable, CustomStringConvertible, LocalizedError {
        public var removed: Int; public var remaining: [String]; public var reason: String
        public var description: String {
            remaining.isEmpty ? "\(reason)" : "removed \(removed) folder\(removed == 1 ? "" : "s"), but \(remaining.count) T3 for WoW folder\(remaining.count == 1 ? "" : "s") remain (\(remaining.prefix(3).joined(separator: ", "))\(remaining.count > 3 ? ", …" : "")): \(reason)"
        }
        public var errorDescription: String? { description }
    }

    /// Removes only `isOwnedFolder` entries (never SavedVariables, settings or other addons) inside a REAL
    /// AddOns folder (a linked AddOns/Interface folder is refused, so nothing outside the game tree is
    /// deleted). An owned entry that is itself a link is removed as a link; its target is never entered.
    /// Missing AddOns folder → 0. Unreadable folder, or anything left behind → throws UninstallFailure
    /// (verified by reading the folder back), so a partial result is never reported as success.
    public static func uninstall(addOnsDir: URL) throws -> Int {
        let fm = FileManager.default
        do {
            if (try PathSafety.kind(addOnsDir)) == .missing { return 0 }
            try PathSafety.requireGameTree(addOnsDir)
        } catch { throw UninstallFailure(removed: 0, remaining: [], reason: "\(error)") }
        let names: [String]
        do { names = try fm.contentsOfDirectory(atPath: addOnsDir.path) }
        catch { throw UninstallFailure(removed: 0, remaining: [], reason: "\(addOnsDir.path) could not be read (\(error.localizedDescription)); nothing was removed") }
        var removed = 0, problems: [String] = []
        for name in names.sorted() where isOwnedFolder(name) {
            do { try fm.removeItem(at: addOnsDir.appendingPathComponent(name)); removed += 1 }
            catch { problems.append("\(name): \(error.localizedDescription)") }
        }
        let after: [String]
        do { after = try fm.contentsOfDirectory(atPath: addOnsDir.path) }
        catch { throw UninstallFailure(removed: removed, remaining: [], reason: "could not check \(addOnsDir.path) afterwards (\(error.localizedDescription))") }
        let remaining = after.filter(isOwnedFolder).sorted()
        if !remaining.isEmpty || !problems.isEmpty {
            throw UninstallFailure(removed: removed, remaining: remaining, reason: problems.first ?? "they could not be removed")
        }
        return removed
    }

    public static func slotToc(_ i: Int, interface: String) -> String {
        """
        ## Interface: \(interface)
        ## Title: T3 for WoW delivery \(i)
        ## Notes: Data slot for T3 for WoW. Loaded by the T3 for WoW addon only when needed.
        ## LoadOnDemand: 1
        ## Dependencies: \(addonName)
        ## Group: \(addonName)
        Slot.lua

        """
    }

    static func tocFiles(_ toc: String) -> [String] {
        toc.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Size of what an install puts on disk (startup footprint evidence).
    public static func footprint(addOnsDir: URL) -> (folders: Int, files: Int, bytes: Int) {
        let fm = FileManager.default
        var folders = 0, files = 0, bytes = 0
        for name in (try? fm.contentsOfDirectory(atPath: addOnsDir.path)) ?? [] where name == addonName || (isOwnedFolder(name) && name.hasPrefix(SlotWriter.prefix)) {
            folders += 1
            let e = fm.enumerator(atPath: addOnsDir.appendingPathComponent(name).path)
            while let f = e?.nextObject() as? String {
                let p = addOnsDir.appendingPathComponent(name).appendingPathComponent(f).path
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue {
                    files += 1; bytes += ((try? fm.attributesOfItem(atPath: p))?[.size] as? Int) ?? 0
                }
            }
        }
        return (folders, files, bytes)
    }
}

/// Finds the owner's local T3 without touching credentials: T3 writes a non-secret runtime file
/// (`<T3 home>/userdata/server-runtime.json`: pid, port, origin) while its server runs.
public enum T3Discovery {
    public static func defaultHome() -> URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".t3") }

    public static func localOrigin(home: URL = defaultHome()) -> URL? {
        let f = home.appendingPathComponent("userdata/server-runtime.json")
        guard let d = FileManager.default.contents(atPath: f.path),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              (o["version"] as? Int) == 1, let s = o["origin"] as? String, let u = URL(string: s),
              u.scheme == "http" || u.scheme == "https" else { return nil }
        return u
    }
}
