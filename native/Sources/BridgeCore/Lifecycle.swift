import Foundation

// MARK: - 1. A grant is bound to the exact T3 origin the owner approved

public enum OriginBinding {
    /// scheme://host:port, lowercased, default ports explicit; path/query ignored.
    public static func normalized(_ u: URL) -> String? {
        guard let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = u.host?.lowercased(), !host.isEmpty else { return nil }
        let port = u.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }

    public enum Decision: Equatable { case connect(URL), needsApproval(approved: URL, current: URL) }

    /// `current` is what config/discovery says now. Different host, scheme or port (even another
    /// localhost port) is a different environment and needs the owner's fresh approval.
    public static func decide(grant: T3Grant, current: URL?) -> Decision {
        guard let current else { return .connect(grant.origin) }
        if let a = normalized(grant.origin), let b = normalized(current), a == b { return .connect(grant.origin) }
        return .needsApproval(approved: grant.origin, current: current)
    }
}

public enum LinkPlanner {
    /// The only place an MCP client is built from a grant: the endpoint is always the APPROVED
    /// origin, and no client (so no token) exists when the environment changed.
    public static func plan(grant: T3Grant, current: URL?, transport: HTTPTransport) -> (client: MCPClient?, state: Engine.LinkState) {
        switch OriginBinding.decide(grant: grant, current: current) {
        case .connect(let origin):
            let token = grant.accessToken
            return (MCPClient(endpoint: origin.appendingPathComponent("mcp"), transport: transport, token: { token }), .verifying)
        case .needsApproval:
            return (nil, .originChanged)
        }
    }
}

// MARK: - 2. Install target: the owner's selection wins; several flavors → the owner chooses

public enum InstallTarget {
    public enum Resolution: Equatable { case use(URL), choose(String) }

    /// nil if `addOns` is `<existing game flavor folder>/Interface/AddOns` (Interface/AddOns may not exist yet).
    public static func validate(_ addOns: URL) -> String? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard addOns.lastPathComponent == "AddOns", addOns.deletingLastPathComponent().lastPathComponent == "Interface" else {
            return "\(addOns.path) is not a game Interface/AddOns folder"
        }
        let flavor = addOns.deletingLastPathComponent().deletingLastPathComponent()
        guard fm.fileExists(atPath: flavor.path, isDirectory: &isDir), isDir.boolValue else { return "\(flavor.path) does not exist" }
        do { try PathSafety.requireGameTree(addOns) } catch { return "\(error)" }
        return nil
    }

    public static func resolve(configured: URL?, candidates: [Installer.Candidate]) -> Resolution {
        if let configured {
            if let why = validate(configured) { return .choose("The selected game folder is no longer valid: \(why). Choose it again.") }
            return .use(configured)
        }
        if candidates.count == 1 { return .use(candidates[0].addOnsDir) }
        return .choose(candidates.isEmpty ? "No World of Warcraft folder was found. Choose your WoW: Forever folder."
                                          : "Several game folders were found (\(candidates.map { $0.addOnsDir.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent }.joined(separator: ", "))). Choose WoW: Forever.")
    }

    /// Folder picker result → AddOns folder (nil = cancelled: change nothing).
    public static func selection(fromPicked u: URL?) -> URL? {
        guard let u else { return nil }
        if u.lastPathComponent == "AddOns" { return u }
        if u.lastPathComponent == "Interface" { return u.appendingPathComponent("AddOns") }
        return u.appendingPathComponent("Interface/AddOns")
    }
}

// MARK: - 4. Keychain vault (one record for this app), with injectable backend for tests

public enum SecStatus {
    public static let success: Int32 = 0
    public static let itemNotFound: Int32 = -25300
    public static let authFailed: Int32 = -25293
    public static let interactionNotAllowed: Int32 = -25308
}

public protocol SecretBackend {
    func read() -> (status: Int32, data: Data?)
    /// Atomic single-record update-or-add.
    func write(_ data: Data) -> Int32
    func delete() -> Int32
}

public struct GrantVault {
    public enum ReadResult: Equatable { case found(T3Grant), absent, malformed, unavailable(Int32) }
    public enum DeleteResult: Equatable { case removed, failed(Int32) }
    let backend: SecretBackend
    public init(backend: SecretBackend) { self.backend = backend }

    public func read() -> ReadResult {
        let (st, data) = backend.read()
        if st == SecStatus.itemNotFound { return .absent }
        guard st == SecStatus.success else { return .unavailable(st) }   // denied, locked, cancelled…
        guard let data, let g = try? JSONDecoder().decode(T3Grant.self, from: data) else { return .malformed }
        return .found(g)
    }
    public func save(_ g: T3Grant) -> Int32 {
        guard let d = try? JSONEncoder().encode(g) else { return -50 }
        return backend.write(d)
    }
    /// Only ever on the owner's explicit Disconnect / confirmed Reset.
    public func delete() -> DeleteResult {
        let st = backend.delete()
        return st == SecStatus.success || st == SecStatus.itemNotFound ? .removed : .failed(st)
    }
}

// MARK: - 5. Capture lifecycle: generations so stale callbacks cannot touch a newer stream

public final class CaptureLifecycle {
    public struct Active: Equatable { public var gen: Int; public var window: UInt32; public var plan: String; public var started: Bool }
    public private(set) var active: Active?
    private var nextGen = 0
    public init() {}

    /// Start when there is no stream, or the window or its capture plan (position/size/display) changed.
    public func shouldStart(window: UInt32, plan: String = "") -> Bool { active?.window != window || active?.plan != plan }
    public func begin(window: UInt32, plan: String = "") -> Int { nextGen += 1; active = Active(gen: nextGen, window: window, plan: plan, started: false); return nextGen }
    /// Returns true if this completion belongs to the current candidate.
    @discardableResult public func startCompleted(gen: Int, ok: Bool) -> Bool {
        guard active?.gen == gen else { return false }
        if ok { active?.started = true } else { active = nil }
        return true
    }
    public func stopped(gen: Int) { if active?.gen == gen { active = nil } }
    public func reset() { active = nil }
}

// MARK: - Preview check + synthetic fixtures for the real AppKit status view

public enum PreviewCheck {
    public struct Report { public var opaque: Bool; public var scale: Double; public var contentFraction: Double; public var pass: Bool }
    public static func evaluate(rgba: [UInt8], pixelsWide: Int, pixelsHigh: Int, bytesPerRow: Int, pointsWide: Double) -> Report {
        var opaque = true, differing = 0
        let bg = (rgba[0], rgba[1], rgba[2])
        for y in 0..<pixelsHigh {
            let row = y * bytesPerRow
            for x in 0..<pixelsWide {
                let o = row + x * 4
                if rgba[o + 3] != 255 { opaque = false }
                if abs(Int(rgba[o]) - Int(bg.0)) + abs(Int(rgba[o + 1]) - Int(bg.1)) + abs(Int(rgba[o + 2]) - Int(bg.2)) > 48 { differing += 1 }
            }
        }
        let scale = Double(pixelsWide) / pointsWide
        let frac = Double(differing) / Double(max(1, pixelsWide * pixelsHigh))
        return Report(opaque: opaque, scale: scale, contentFraction: frac, pass: opaque && scale >= 2 && frac >= 0.01)
    }
}

public enum PreviewFixtures {
    public struct State { public var name: String; public var facts: Setup.Facts }
    static let o = URL(string: "http://127.0.0.1:3773")!
    static func ready(_ f: (inout Setup.Facts) -> Void) -> Setup.Facts {
        var x = Setup.Facts(t3Origin: o, grant: .valid(daysLeft: 27), wowCandidates: 1, addonInstalled: true, capturePermission: true,
                            gameRunning: true, stripSeen: true, link: "connected", linkAccess: "operate", threadsAboveAccess: 0)
        x.gameFolder = "_forever_"
        x.gameAcked = true
        f(&x); return x
    }
    /// Every value here is SYNTHETIC; no state is read from this Mac.
    public static let all: [State] = [
        State(name: "SYNTHETIC-unpaired", facts: Setup.Facts(t3Origin: o, wowCandidates: 1)),
        State(name: "SYNTHETIC-connected", facts: ready { _ in }),
        State(name: "SYNTHETIC-full-access-note", facts: ready { $0.threadsAboveAccess = 3 }),
        State(name: "SYNTHETIC-revoked", facts: ready { $0.link = "revoked" }),
        State(name: "SYNTHETIC-keychain-repair", facts: Setup.Facts(t3Origin: o, grant: .malformed, wowCandidates: 1, addonInstalled: true)),
        State(name: "SYNTHETIC-origin-changed", facts: ready { $0.link = "originChanged" }),
        State(name: "SYNTHETIC-repair-addon", facts: ready { $0.addonInstalled = false; $0.installIssue = "2 delivery slots missing" }),
        State(name: "SYNTHETIC-capture-unconfirmed", facts: ready { $0.capturePermission = false; $0.stripSeen = false; $0.gameAcked = false }),
        State(name: "SYNTHETIC-capture-stopped", facts: ready { $0.capturePermission = false; $0.stripSeen = false; $0.gameAcked = false; $0.captureStopped = true }),
        State(name: "SYNTHETIC-capture-denied", facts: ready { $0.capturePermission = false; $0.stripSeen = false; $0.gameAcked = false
                                                               $0.captureDenied = "com.apple.ScreenCaptureKit.SCStreamErrorDomain -3801" }),
    ]
}
