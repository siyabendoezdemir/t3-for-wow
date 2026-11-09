import Foundation

/// Coarse, privacy-safe context for an UNDECODABLE band: does local OCR of the already-approved top band
/// show the public game logo (e.g. login / character select / loading), or not? Only a category leaves
/// this function; recognised strings are discarded by the caller immediately. This is a hint, never
/// proof that the owner is logged out or that the game is ready.
public enum ScreenContext {
    public static let knownLogo = "knownWarcraftLogo", noKnownText = "noKnownText"
    public static let unchecked = "notChecked", unavailable = "ocrUnavailable"

    /// Public terms only: "Warcraft", or "World" together with "Forever"/"Warcraft".
    public static func classify(_ strings: [String]) -> String {
        let all = strings.map { $0.lowercased() }
        if all.contains(where: { $0.contains("warcraft") }) { return knownLogo }
        let world = all.contains { $0.contains("world") }, forever = all.contains { $0.contains("forever") }
        return world && forever ? knownLogo : noKnownText
    }
}
