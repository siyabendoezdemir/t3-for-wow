import Foundation

/// The whole "Uninstall…" side effect, kept portable so the safety rules are tested with injected
/// (synthetic) providers. The app supplies the real Keychain / login-item / file operations.
///
/// Fail-closed: it refuses while World of Warcraft runs — checked when called AND again immediately
/// before any game file is removed — whatever UI path invoked it. Every step's outcome is reported;
/// a partial result is never reported as success.
public enum Uninstaller {
    public enum Outcome: Equatable { case done(String), skipped(String), failed(String) }

    public struct Steps {
        public var gameRunning: () -> Bool
        public var addOnsDir: URL?
        public var removeAddonFolders: (URL) throws -> Int
        public var removeApproval: () -> Outcome
        public var disableOpenAtLogin: () -> Outcome
        public var removeAppData: () -> Outcome
        public init(gameRunning: @escaping () -> Bool, addOnsDir: URL?,
                    removeAddonFolders: @escaping (URL) throws -> Int = { try Installer.uninstall(addOnsDir: $0) },
                    removeApproval: @escaping () -> Outcome, disableOpenAtLogin: @escaping () -> Outcome, removeAppData: @escaping () -> Outcome) {
            self.gameRunning = gameRunning; self.addOnsDir = addOnsDir; self.removeAddonFolders = removeAddonFolders
            self.removeApproval = removeApproval; self.disableOpenAtLogin = disableOpenAtLogin; self.removeAppData = removeAppData
        }
    }

    public struct Report: Equatable {
        public var refused: Bool
        public var outcomes: [Outcome]
        public var ok: Bool { !refused && !outcomes.contains { if case .failed = $0 { return true }; return false } }
        public var text: String {
            outcomes.map { switch $0 { case .done(let s), .skipped(let s): return s; case .failed(let s): return "Not done: " + s } }.joined(separator: "\n")
        }
    }

    public static let refusal = "World of Warcraft is running. Quit the game first, then choose Uninstall again. Nothing was removed."

    public static func run(_ s: Steps) -> Report {
        if s.gameRunning() { return Report(refused: true, outcomes: [.failed(refusal)]) }
        var out: [Outcome] = []
        if let dir = s.addOnsDir {
            // re-check at the boundary: the game may have been started while a dialog was open
            if s.gameRunning() { return Report(refused: true, outcomes: [.failed(refusal)]) }
            do {
                let n = try s.removeAddonFolders(dir)
                out.append(.done("Removed \(n) T3 for WoW folder\(n == 1 ? "" : "s") from \(dir.path)."))
            } catch {
                out.append(.failed("Game folders: \(error)"))
            }
        } else {
            out.append(.skipped("No game folder was chosen, so no addon folders were removed."))
        }
        out.append(s.removeApproval())
        out.append(s.disableOpenAtLogin())
        out.append(s.removeAppData())
        return Report(refused: false, outcomes: out)
    }
}
