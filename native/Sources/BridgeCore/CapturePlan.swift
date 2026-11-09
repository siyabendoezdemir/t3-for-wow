import Foundation

/// Rectangle in ScreenCaptureKit's global coordinate space: points, origin at the top-left of the
/// main display, y growing downwards (SCWindow.frame / SCDisplay.frame). Other displays may have
/// negative origins.
public struct CaptureRect: Equatable, Codable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public func intersection(_ o: CaptureRect) -> CaptureRect {
        let nx = max(x, o.x), ny = max(y, o.y), mx = min(maxX, o.maxX), my = min(maxY, o.maxY)
        return mx > nx && my > ny ? CaptureRect(x: nx, y: ny, width: mx - nx, height: my - ny) : CaptureRect(x: 0, y: 0, width: 0, height: 0)
    }
    public func offset(by dx: Double, _ dy: Double) -> CaptureRect { CaptureRect(x: x + dx, y: y + dy, width: width, height: height) }
}

public struct DisplayInfo: Equatable {
    public var id: UInt32
    public var frame: CaptureRect     // global points
    public var scale: Double          // physical pixels per point (2 on Retina, 1 otherwise)
    public init(id: UInt32, frame: CaptureRect, scale: Double) { self.id = id; self.frame = frame; self.scale = scale }
}

/// What the Mac app asks ScreenCaptureKit for. Pure, so geometry and privacy invariants are tested
/// without capture permission.
public struct CapturePlan: Equatable {
    public enum Filter: Equatable {
        /// `SCContentFilter(desktopIndependentWindow:)`. Apple: `sourceRect` is IGNORED for this
        /// filter; the whole window is captured and scaled into the output size.
        case singleWindow(windowID: UInt32)
        /// `SCContentFilter(display:including:[window])`: only that window's content, on one display;
        /// `sourceRect` (display-relative points) IS honoured.
        case displayIncludingOnlyWindow(displayID: UInt32, windowID: UInt32)
    }
    public var filter: Filter
    public var sourceRect: CaptureRect     // in the filter's coordinate space
    public var outputWidth: Int, outputHeight: Int
    public var scale: Double
    public var honorsSourceRect: Bool { if case .displayIncludingOnlyWindow = filter { return true }; return false }
    /// Restart the stream when this changes (window moved/resized, display change).
    public var key: String { "\(filter)|\(sourceRect.x),\(sourceRect.y),\(sourceRect.width),\(sourceRect.height)|\(outputWidth)x\(outputHeight)" }
}

public enum CapturePlanner {
    /// The approved capture scope: the top band of the WoW window, where the addon draws its strip
    /// (≤ 16 rows × 3 physical px, below a windowed-mode title bar).
    public static let bandPoints = 96.0

    /// The plan GameCapture used up to af0441a (kept only so the regression test documents it).
    public static func legacySingleWindow(windowID: UInt32, windowFrame: CaptureRect, scale: Double) -> CapturePlan {
        let h = min(bandPoints, windowFrame.height)
        return CapturePlan(filter: .singleWindow(windowID: windowID), sourceRect: CaptureRect(x: 0, y: 0, width: windowFrame.width, height: h),
                           outputWidth: Int(windowFrame.width * scale), outputHeight: Int(h * scale), scale: scale)
    }

    /// Top band of the window, clipped to the display it is on (the display with the largest
    /// intersection with that band), as a display-relative sourceRect; output at native pixel scale.
    public static func plan(windowID: UInt32, windowFrame: CaptureRect, displays: [DisplayInfo]) -> CapturePlan? {
        let band = CaptureRect(x: windowFrame.x, y: windowFrame.y, width: windowFrame.width, height: min(bandPoints, windowFrame.height))
        guard !band.isEmpty else { return nil }
        // The display showing the largest part of the band (ties: lowest id, deterministic).
        var best: (display: DisplayInfo, clipped: CaptureRect, area: Double)?
        for d in displays.sorted(by: { $0.id < $1.id }) {
            let c = band.intersection(d.frame)
            if c.isEmpty { continue }
            let area = c.width * c.height
            if best == nil || area > best!.area { best = (d, c, area) }
        }
        guard let display = best?.display, let clipped = best?.clipped else { return nil }
        // Display-relative, whole points so the crop lands on physical pixel boundaries.
        let local = clipped.offset(by: -display.frame.x, -display.frame.y)
        let x0: Double = local.x.rounded(.up), y0: Double = local.y.rounded(.up)
        let x1: Double = local.maxX.rounded(.down), y1: Double = local.maxY.rounded(.down)
        guard x1 > x0, y1 > y0 else { return nil }
        let src = CaptureRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        return CapturePlan(filter: .displayIncludingOnlyWindow(displayID: display.id, windowID: windowID), sourceRect: src,
                           outputWidth: Int((src.width * display.scale).rounded()), outputHeight: Int((src.height * display.scale).rounded()),
                           scale: display.scale)
    }
}
