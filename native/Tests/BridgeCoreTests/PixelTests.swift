import Foundation
@testable import BridgeCore

func runPixelTests() {
    let big = sampleFrame(chunks: [.init(reqId: 7, index: 0, count: 1, data: Array(Codec.netstrings(["S", "thread:abc", String(repeating: "é and text ", count: 40)])))])
    for cell in [1, 2, 3, 4, 6] {
        test("pixel decode at \(cell)px cells with offset") {
            var img = RGBImage(width: 900, height: 200)
            PixelDecoder.render(big.encode(), cellPx: cell, into: &img, at: 37, 11)
            var got = try PixelDecoder.decodeFrame(img); got.rows = 0
            var want = big; want.rows = 0
            try eq(got, want)
        }
    }
    test("pixel decode survives a colour transform (gamma + tint) and mild noise") {
        var img = RGBImage(width: 600, height: 120)
        PixelDecoder.render(big.encode(), cellPx: 4, into: &img, at: 5, 5)
        var g = SystemRandomNumberGenerator()
        for i in 0..<img.pixels.count {
            let v = pow(Double(img.pixels[i]) / 255, 1.2) * 235 + 10 + Double(Int.random(in: -6...6, using: &g))
            img.pixels[i] = UInt8(max(0, min(255, v)))
        }
        var got = try PixelDecoder.decodeFrame(img); got.rows = 0
        var want = big; want.rows = 0
        try eq(got, want)
    }
    test("pixel decode of a 0.75x downscaled capture (4px cells -> 3px)") {
        var src = RGBImage(width: 800, height: 160)
        PixelDecoder.render(big.encode(), cellPx: 4, into: &src, at: 40, 8)
        var dst = RGBImage(width: 600, height: 120)
        for y in 0..<120 { for x in 0..<600 {
            let (r, gg, b) = src.px(Int(Double(x) / 0.75), Int(Double(y) / 0.75))
            let o = (y * 600 + x) * 3; dst.pixels[o] = UInt8(r); dst.pixels[o + 1] = UInt8(gg); dst.pixels[o + 2] = UInt8(b)
        } }
        var got = try PixelDecoder.decodeFrame(dst); got.rows = 0
        var want = big; want.rows = 0
        try eq(got, want)
    }
    test("no strip → notFound; another addon's finder is not mistaken for ours") {
        var img = RGBImage(width: 400, height: 50)
        // Telegram-for-WoW-like finder (magenta/green) must not match.
        let tg: [(UInt8, UInt8, UInt8)] = [(255, 0, 255), (0, 255, 0), (255, 0, 255), (0, 255, 0), (0, 0, 0), (255, 255, 255), (0, 0, 0), (255, 255, 255)]
        for (k, c) in tg.enumerated() { for x in (k * 4)..<(k * 4 + 4) { for y in 0..<4 { let o = (y * 400 + x) * 3; img.pixels[o] = c.0; img.pixels[o + 1] = c.1; img.pixels[o + 2] = c.2 } } }
        do { _ = try PixelDecoder.decodeFrame(img); throw Failure(description: "decoded nothing") } catch PixelDecoder.DecodeError.notFound {}
    }
    test("PPM round trip") {
        var img = RGBImage(width: 3, height: 2); img.pixels[0] = 9
        let r = RGBImage.readPPM(img.ppm())!
        try eq(r.pixels, img.pixels)
    }
}
