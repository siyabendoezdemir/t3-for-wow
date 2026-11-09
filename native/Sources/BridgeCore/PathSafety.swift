import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// No-follow checks for every path this app mutates (install, repair, rollback, delivery-slot writes,
/// uninstall). Policy: the game flavor folder (e.g. `_forever_`) may live anywhere the player put it,
/// but `Interface`, `Interface/AddOns`, every owned entry inside it and every file written there must be
/// a real directory/file — never a symbolic link — so no write or delete can land outside the selected
/// game tree. Checks are repeated immediately before each mutation, not only when a folder is chosen.
public enum PathSafety {
    public enum Kind: Equatable { case missing, directory, file, symlink, other }

    public enum Failure: Error, Equatable, CustomStringConvertible, LocalizedError {
        case symlink(String)
        case wrongType(String)
        case unreadable(String, Int32)
        public var description: String {
            switch self {
            case .symlink(let p): return "\(p) is a link to another location; nothing was changed there. Remove the link (or choose the real game folder) and try again"
            case .wrongType(let p): return "\(p) is in the way (not a folder); nothing was changed"
            case .unreadable(let p, let e): return "\(p) could not be read (\(String(cString: strerror(e)))); nothing was changed"
            }
        }
        public var errorDescription: String? { description }
    }

    /// lstat: never follows a final symlink. Missing (ENOENT/ENOTDIR) is not an error; any other failure
    /// (permission, I/O) throws so callers can never mistake "unreadable" for "absent".
    public static func kind(_ u: URL) throws -> Kind {
        var st = stat()
        if lstat(u.path, &st) != 0 {
            let e = errno
            if e == ENOENT || e == ENOTDIR { return .missing }
            throw Failure.unreadable(u.path, e)
        }
        let t = Int(st.st_mode) & Int(S_IFMT)
        if t == Int(S_IFDIR) { return .directory }
        if t == Int(S_IFREG) { return .file }
        if t == Int(S_IFLNK) { return .symlink }
        return .other
    }

    /// The AddOns folder and its parent (`Interface`) must be real folders (or not exist yet).
    public static func requireGameTree(_ addOnsDir: URL) throws {
        for u in [addOnsDir.deletingLastPathComponent(), addOnsDir] {
            switch try kind(u) {
            case .directory, .missing: continue
            case .symlink: throw Failure.symlink(u.path)
            case .file, .other: throw Failure.wrongType(u.path)
            }
        }
    }

    /// An owned folder we may write into: a real folder, or absent (we create it).
    public static func requireDirectoryOrMissing(_ u: URL) throws {
        switch try kind(u) {
        case .directory, .missing: return
        case .symlink: throw Failure.symlink(u.path)
        case .file, .other: throw Failure.wrongType(u.path)
        }
    }

    /// A file we may replace: a real file, or absent.
    public static func requireFileOrMissing(_ u: URL) throws {
        switch try kind(u) {
        case .file, .missing: return
        case .symlink: throw Failure.symlink(u.path)
        case .directory, .other: throw Failure.wrongType(u.path)
        }
    }
}
