import Foundation

/// Graphite Blue values and T3 component metrics used by the Mac window.
/// Colours are the published "Graphite Blue" T3 theme roles; geometry follows T3's own UI source
/// (apps/web/src/components/ui/{button,input,standalone-page}.tsx, index.css) at commit
/// 322f6544dfad0a3c8a0c8cbecf2c7f7874b14268. T3 Code is © 2026 T3 Tools Inc., MIT License (see
/// THIRD-PARTY-NOTICES.md). Values only; no T3 source or assets are copied.
public enum T3Theme {
    public struct RGB: Equatable { public let r: Double, g: Double, b: Double
        public init(_ hex: UInt32) { r = Double((hex >> 16) & 0xFF) / 255; g = Double((hex >> 8) & 0xFF) / 255; b = Double(hex & 0xFF) / 255 }
        public func mixed(with o: RGB, _ t: Double) -> RGB { RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t) }
        init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
        /// WCAG relative luminance.
        public var luminance: Double {
            func c(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * c(r) + 0.7152 * c(g) + 0.0722 * c(b)
        }
        public func contrast(_ o: RGB) -> Double { let a = luminance, b = o.luminance; return (max(a, b) + 0.05) / (min(a, b) + 0.05) }
    }

    // Graphite Blue roles
    public static let canvas = RGB(0x131418), chrome = RGB(0x101115), surface = RGB(0x1A1C23), surfaceRaised = RGB(0x20222B)
    public static let surfaceOverlay = RGB(0x1D1F27), border = RGB(0x292C35), input = RGB(0x353A47)
    public static let text = RGB(0xE9EDF5), textMuted = RGB(0xA3AAB8), placeholder = RGB(0x8D95A6), iconMuted = RGB(0x9098AA)
    public static let focus = RGB(0x7B9CFF)                 // accent / focus ring — NOT the button fill
    public static let action = RGB(0x6489E8), actionForeground = RGB(0x10182C), actionHover = RGB(0x779CFA) // messageAction
    public static let secondary = RGB(0x22252F), muted = RGB(0x1C1E26)
    public static let warning = RGB(0xE5B878), warningForeground = RGB(0xF2CE97), warningSurface = RGB(0x30291C)
    public static let error = RGB(0xEC7082), errorForeground = RGB(0xFF9AAA), errorSurface = RGB(0x351F28)
    public static let success = RGB(0x10B981)               // T3 --success = Tailwind emerald-500 (index.css)
    public static let accentSurface = RGB(0x1B2640), accentSurfaceForeground = RGB(0xB6CBFF)

    // Derived exactly like T3's utilities
    /// outline button fill: `dark:bg-input/32` over the canvas; hover `dark:bg-input/64`.
    public static let outlineFill = canvas.mixed(with: input, 0.32), outlineHover = canvas.mixed(with: input, 0.64)
    /// help/context box: `border-border/70 bg-background/55` (dialog surface ≈ canvas).
    public static let contextFill = canvas, contextBorder = canvas.mixed(with: border, 0.70)

    // Geometry (points)
    public static let controlRadius = 8.0          // --control-radius: 0.5rem
    public static let panelPadding = 24.0          // p-6
    public static let buttonHeight = 28.0, buttonPaddingX = 9.0, buttonFontSize = 14.0 // measured pairing button (sm: h-7 px-[2.5*4-1])
    public static let titleSize = 20.0, titleLine = 25.0, bodySize = 14.0, bodyLine = 20.0, smallSize = 12.0
    public static let brandToTitle = 24.0, titleToSupport = 8.0, sectionGap = 24.0
    public static let disabledAlpha = 0.64          // disabled:opacity-64
    public static let windowWidth = 520.0
}
