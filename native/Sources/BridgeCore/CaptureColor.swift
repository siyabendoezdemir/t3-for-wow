import Foundation

/// The colour contract between the addon strip and the bridge's capture.
public enum CaptureColor {
    /// What the app assigns to `SCStreamConfiguration.colorSpaceName` (a CGColorSpace name; nil would mean
    /// "not set" = the display's colour space). The addon draws sRGB protocol colours; without an explicit
    /// sRGB stream, a wide-gamut display delivers them converted (e.g. cyan → R≈117) and nothing decodes.
    /// Value of `CGColorSpace.sRGB`.
    public static let requestedColorSpaceName: String? = "kCGColorSpaceSRGB"
}
