import Foundation
@testable import BridgeCore

/// Model of ScreenCaptureKit's output colour conversion (sRGB-authored game pixels delivered in the
/// stream's colour space). Standard sRGB ↔ Display P3 linear matrices around the sRGB transfer curve;
/// reproduces the parent's measured cyan (117,251,253) on the owner's display. SYNTHETIC frames only.
enum ColorModel {
    static func toLinear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    static func toGamma(_ v: Double) -> Double { let c = min(1, max(0, v)); return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }
    static let srgbToP3: [[Double]] = [[0.8225, 0.1774, 0.0000], [0.0332, 0.9669, 0.0000], [0.0171, 0.0724, 0.9108]]
    static let p3ToSrgb: [[Double]] = [[1.2249, -0.2247, 0.0000], [-0.0420, 1.0419, 0.0000], [-0.0197, -0.0786, 1.0979]]
    static func convert(_ img: RGBImage, _ m: [[Double]]) -> RGBImage {
        var out = img
        for i in 0..<(img.width * img.height) {
            let l = (0..<3).map { toLinear(Double(img.pixels[i * 3 + $0]) / 255) }
            for c in 0..<3 {
                let v = m[c][0] * l[0] + m[c][1] * l[1] + m[c][2] * l[2]
                out.pixels[i * 3 + c] = UInt8((toGamma(v) * 255).rounded())
            }
        }
        return out
    }
    /// What the stream delivers for a requested colour space on a Display-P3 display.
    static func deliver(_ srgbFrame: RGBImage, requested: String?) -> RGBImage {
        requested == "kCGColorSpaceSRGB" ? srgbFrame : convert(srgbFrame, srgbToP3)   // nil = display colour space
    }
}

func runCaptureColorTests() {
    var frame = RGBImage(width: 600, height: 60)
    PixelDecoder.render(sampleFrame(chunks: [.init(reqId: 2, index: 0, count: 1, data: Codec.netstrings(["S", "t", "hello"]))]).encode(),
                        cellPx: 3, into: &frame, at: 60, 4)
    test("colour model reproduces the measured shift: cyan → (117,251,253) in Display P3") {
        var px = RGBImage(width: 1, height: 1, fill: (0, 255, 255))
        px = ColorModel.convert(px, ColorModel.srgbToP3)
        try expect(abs(Int(px.pixels[0]) - 117) <= 2 && px.pixels[1] >= 249 && px.pixels[2] >= 251, "\(px.pixels)")
    }
    test("colour control: wide-gamut delivery breaks the ABSOLUTE finder colours, yet decodes via the frame's own calibration") {
        let delivered = ColorModel.deliver(frame, requested: nil)
        // what the strict absolute finder (BandInspector strict / the old locate) saw: cyan no longer (0,255,255)±70
        var cyanCell: (Int, Int, Int)?
        for y in 0..<delivered.height { for x in 0..<delivered.width where cyanCell == nil {
            let c = delivered.px(x, y); if PixelDecoder.cyanLike(c) { cyanCell = c } } }
        let cc = try unwrap(cyanCell)
        try expect(!PixelDecoder.near(cc, (0, 255, 255)), "absolute cyan check fails on P3: \(cc)")
        _ = try PixelDecoder.decodeFrame(delivered)                                            // calibrated decoder: OK
        _ = try PixelDecoder.decodeFrame(ColorModel.convert(delivered, ColorModel.p3ToSrgb))   // and in sRGB
    }
    test("colour contract: the app requests sRGB, and the same protocol frame decodes at that output colour space") {
        try eq(CaptureColor.requestedColorSpaceName, "kCGColorSpaceSRGB")
        try eq(ColorLabel.configured(CaptureColor.requestedColorSpaceName), "sRGB", "metadata reports what is assigned")
        _ = try PixelDecoder.decodeFrame(ColorModel.deliver(frame, requested: CaptureColor.requestedColorSpaceName))
    }
}
