import Foundation

/// Which on-screen window is the game. Pure, so the App adapter and tests share one implementation.
public enum GameIdentity {
    /// One candidate window as ScreenCaptureKit describes it (no title: a title never identifies an app).
    public struct Candidate: Equatable {
        public var windowID: UInt32
        public var bundleID: String?
        public var appName: String?
        public var layer: Int
        public var frame: CaptureRect
        public init(windowID: UInt32, bundleID: String?, appName: String?, layer: Int, frame: CaptureRect) {
            self.windowID = windowID; self.bundleID = bundleID; self.appName = appName; self.layer = layer; self.frame = frame
        }
    }

    /// Exact bundle identifiers of the game client (compared case-insensitively). The display name is
    /// NOT used: it can be short ("Wow") or localized. A missing/unknown bundle never matches, so no
    /// name or window title can grant capture authority. Add other verified game bundle IDs explicitly.
    public static let gameBundleIDs: Set<String> = ["com.blizzard.worldofwarcraft"]

    public static func isGameApp(bundleID: String?, appName: String?) -> Bool {
        guard let b = bundleID?.lowercased(), !b.isEmpty else { return false }
        return gameBundleIDs.contains(b)
    }

    /// Largest eligible game window: the game app's normal-level (layer 0) window with the biggest area.
    /// Helper/overlay windows are smaller or on other layers.
    public static func choose(_ candidates: [Candidate]) -> Candidate? {
        candidates.filter { isGameApp(bundleID: $0.bundleID, appName: $0.appName) && $0.layer == 0 && !$0.frame.isEmpty }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }
}
