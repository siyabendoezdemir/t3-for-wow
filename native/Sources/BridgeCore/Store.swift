import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Versioned key → record store of game-visible state (docs/PROTOCOL.md section 2).
/// Every change bumps a global version; a delivery carries all records newer than the game's ack.
public final class RecordStore {
    struct Entry { var version: UInt32; var fields: [String]? } // nil fields = tombstone
    private var entries: [String: Entry] = [:]
    public private(set) var version: UInt32 = 0

    public init() {}

    @discardableResult
    public func put(_ key: String, _ fields: [String]) -> Bool {
        if let e = entries[key], e.fields == fields { return false }
        version += 1
        entries[key] = Entry(version: version, fields: fields)
        return true
    }

    public func remove(_ key: String) {
        guard let e = entries[key], e.fields != nil else { return }
        version += 1
        entries[key] = Entry(version: version, fields: nil)
    }

    public func get(_ key: String) -> [String]? { entries[key]?.fields }
    public func keys(prefix: String) -> [String] { entries.compactMap { $0.value.fields != nil && $0.key.hasPrefix(prefix) ? $0.key : nil } }

    /// Drop everything under a prefix without tombstones (used when the game session changes and
    /// the new game starts from an empty model anyway).
    public func purge(prefix: String) { for k in entries.keys where k.hasPrefix(prefix) { entries[k] = nil } }

    /// Records with version > since, ascending, until maxBytes. Returns (records, lastVersion, more).
    public func changes(since: UInt32, maxBytes: Int) -> (records: [[String]], version: UInt32, more: Bool) {
        let pending = entries.filter { $0.value.version > since }.sorted { $0.value.version < $1.value.version }
        var out: [[String]] = [], used = 0, last = since
        for (key, e) in pending {
            let rec = e.fields ?? ["x", key]
            let size = Codec.netstrings(rec).count + 8
            if !out.isEmpty && used + size > maxBytes { return (out, last, true) }
            out.append(rec); used += size; last = e.version
        }
        return (out, pending.isEmpty ? version : last, false)
    }

    /// Tombstones the game has acknowledged are no longer needed.
    public func pruneTombstones(acked: UInt32) {
        for (k, e) in entries where e.fields == nil && e.version <= acked { entries[k] = nil }
    }
}

/// Writes delivery slots: `T3ForWoW_SlotNNNN/Slot.lua`, atomically, in the single safe form.
public struct SlotWriter {
    public let addOnsDir: URL
    public static let prefix = "T3ForWoW_Slot"
    public init(addOnsDir: URL) { self.addOnsDir = addOnsDir }

    public static func folderName(_ slot: Int) -> String { prefix + String(format: "%04d", slot) }

    public static func luaSource(slot: Int, payload: [UInt8]) -> String {
        "T3ForWoW_Deliver(\(slot),\"\(Codec.luaLiteral(payload))\")\n"
    }

    public func write(slot: Int, payload: [UInt8]) throws {
        let dir = addOnsDir.appendingPathComponent(Self.folderName(slot))
        // No-follow, every write: a slot folder (or its AddOns/Interface parents) replaced by a link is
        // refused instead of written through.
        try PathSafety.requireGameTree(addOnsDir)
        switch try PathSafety.kind(dir) {
        case .directory: break
        case .missing: throw CocoaError(.fileNoSuchFile)
        case .symlink: throw PathSafety.Failure.symlink(dir.path)
        case .file, .other: throw PathSafety.Failure.wrongType(dir.path)
        }
        try PathSafety.requireFileOrMissing(dir.appendingPathComponent("Slot.lua"))
        try atomicWrite(Data(Self.luaSource(slot: slot, payload: payload).utf8), to: dir.appendingPathComponent("Slot.lua"))
    }
}

public func atomicWrite(_ data: Data, to url: URL) throws {
    let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UInt32.random(in: 0...UInt32.max)).tmp")
    try data.write(to: tmp)
    // POSIX rename(2) atomically replaces the destination on both macOS and Linux.
    if rename(tmp.path, url.path) != 0 {
        let err = errno
        try? FileManager.default.removeItem(at: tmp)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
    }
}

/// Persistent exactly-once ledger for sends/new threads, keyed by game request identity.
public final class SendLedger {
    public struct Entry: Codable, Equatable {
        public var state: String          // sending | accepted | queued | failed | rejected | unknown
        public var namespace: String      // fingerprint of the T3 bearer session the key was sent under
        public var threadId: String?
        public var messageId: String?
        public var detail: String?
        public var updatedAt: Double
    }
    private let url: URL?
    public private(set) var entries: [String: Entry] = [:]
    public static let maxEntries = 500

    public init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let e = try? JSONDecoder().decode([String: Entry].self, from: data) { entries = e }
    }

    public func get(_ key: String) -> Entry? { entries[key] }

    public func set(_ key: String, _ e: Entry) throws {
        entries[key] = e
        if entries.count > Self.maxEntries {
            for k in entries.sorted(by: { $0.value.updatedAt < $1.value.updatedAt }).prefix(entries.count - Self.maxEntries).map(\.key) { entries[k] = nil }
        }
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try atomicWrite(try JSONEncoder().encode(entries), to: url)
    }
}
