import Foundation
import CoreGraphics
import Vision
import BridgeCore

/// Local, in-memory OCR of the centre (≤ 1200 px) of the ALREADY-APPROVED top band, used only when no
/// strip is decoded, at most once every 10 s. Produces one category (BridgeCore.ScreenContext); recognised
/// strings are discarded inside `run` and never stored, logged or sent. No capture API, no image files.
final class ContextObserver {
    static let minInterval = 10.0
    private let work = DispatchQueue(label: "t3wow.context", qos: .utility)
    private var busy = false                  // capture queue only
    private var lastStart = -1e18             // capture queue only
    private(set) var category: String = ScreenContext.unchecked   // capture queue only
    private(set) var checkedAt: Double?       // capture queue only

    /// Capture queue. `base` is the locked BGRA band buffer; only the centre crop is copied.
    func maybeObserve(base: UnsafeRawPointer, width w: Int, height h: Int, bytesPerRow stride: Int, now: Double, reply: DispatchQueue) {
        guard !busy, now - lastStart >= Self.minInterval, w > 0, h > 0 else { return }
        let rw = min(BandInspector.maxRegionWidth, w), rx = (w - rw) / 2
        var crop = Data(count: rw * 4 * h)
        crop.withUnsafeMutableBytes { dst in
            for y in 0..<h { memcpy(dst.baseAddress! + y * rw * 4, base + y * stride + rx * 4, rw * 4) }
        }
        busy = true; lastStart = now
        work.async { [weak self] in
            let result = Self.run(crop, width: rw, height: h)
            reply.async { self?.busy = false; self?.category = result; self?.checkedAt = Date().timeIntervalSince1970 }
        }
    }

    private static func run(_ crop: Data, width: Int, height: Int) -> String {
        guard let provider = CGDataProvider(data: crop as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return ScreenContext.unavailable }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { return ScreenContext.unavailable }
        let strings = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return ScreenContext.classify(strings)   // strings go out of scope here
    }
}
