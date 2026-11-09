import Foundation
@testable import BridgeCore

/// Parent-proven RED classes (FRACTIONAL-PITCH-PARENT-RED, COLOR-SPACE-SYNTHETIC-REGRESSION): the exact
/// protocol frame at fractional pitch, and under a wide-gamut colour transform. SYNTHETIC frames only.
enum Raster {
    /// Draw a frame exactly like the addon, but with a (possibly fractional) cell pitch in pixels.
    static func render(_ bytes: [UInt8], pitch: Double, into img: inout RGBImage, at x0: Double, _ y0: Double,
                       colour: ((Int, Int, Int)) -> (Int, Int, Int) = { $0 }, maxCols: Int = PixelDecoder.cols, dropPalette: Bool = false, dropTail: Bool = false) {
        let rows = Int(bytes[3])
        let L = [0, 85, 170, 255]
        func sym(_ s: Int) -> (Int, Int, Int) { (L[(s / 16) % 4], L[(s / 4) % 4], L[s % 4]) }
        let F = PixelDecoder.finder
        var cells: [(Int, Int, Int)?] = F.map { $0 }
        for s in 0..<64 { cells.append(dropPalette ? nil : sym(s)) }
        let tail = [F[5], F[4], F[5], F[4], F[1], F[0], F[1], F[0]]
        cells += tail.map { dropTail ? nil : $0 }
        let syms = Codec.toSymbols(bytes)
        for i in 0..<((rows - 1) * PixelDecoder.cols) { cells.append(sym(i < syms.count ? Int(syms[i]) : 0)) }
        for (i, c) in cells.enumerated() {
            guard let c, i % PixelDecoder.cols < maxCols else { continue }
            let col = Double(i % PixelDecoder.cols), row = Double(i / PixelDecoder.cols)
            let xa = Int((x0 + col * pitch).rounded(.down)), xb = Int((x0 + (col + 1) * pitch).rounded(.down))
            let ya = Int((y0 + row * pitch).rounded(.down)), yb = Int((y0 + (row + 1) * pitch).rounded(.down))
            let v = colour(c)
            for y in max(0, ya)..<min(img.height, yb) { for x in max(0, xa)..<min(img.width, xb) {
                let o = (y * img.width + x) * 3; img.pixels[o] = UInt8(v.0); img.pixels[o + 1] = UInt8(v.1); img.pixels[o + 2] = UInt8(v.2)
            } }
        }
    }
    /// sRGB → Display P3 (as the capture would deliver on a wide-gamut display without an sRGB contract).
    static func p3(_ c: (Int, Int, Int)) -> (Int, Int, Int) {
        var img = RGBImage(width: 1, height: 1, fill: (UInt8(c.0), UInt8(c.1), UInt8(c.2)))
        img = ColorModel.convert(img, ColorModel.srgbToP3)
        return (Int(img.pixels[0]), Int(img.pixels[1]), Int(img.pixels[2]))
    }
    static func warm(_ c: (Int, Int, Int)) -> (Int, Int, Int) { (min(255, c.0 + 6), Int(Double(c.1) * 0.94), Int(Double(c.2) * 0.82)) }
}

func runDecoderRobustTests() {
    let req = GameFrame.Chunk(reqId: 11, index: 0, count: 1, data: Codec.netstrings(["S", "thread:abc", String(repeating: "fractional ", count: 20)]))
    var want = sampleFrame(chunks: [req]); want.rows = 0
    let bytes = sampleFrame(chunks: [req]).encode()
    func decodes(_ img: RGBImage, _ line: UInt = #line) throws {
        var got = try PixelDecoder.decodeFrame(img); got.rows = 0
        try eq(got, want, "line \(line)")
    }
    func rejects(_ img: RGBImage, _ what: String) throws {
        do { _ = try PixelDecoder.decodeFrame(img); throw Failure(description: "accepted: \(what)") } catch is PixelDecoder.DecodeError {} catch is GameFrame.ParseError {}
    }

    for pitch in [3.0, 4.0, 6.0, 2.5, 3.25, 3.75, 3.79, 4.25] {
        test("decoder: exact protocol frame at \(pitch) px pitch (fractional phase .37) decodes") {
            var img = RGBImage(width: Int(80 * pitch) + 200, height: Int(16 * pitch) + 40)
            Raster.render(bytes, pitch: pitch, into: &img, at: 61.37, 7.62)
            try decodes(img)
        }
    }
    test("decoder: wide-gamut (Display P3) delivery decodes via the frame's own calibration palette") {
        var img = RGBImage(width: 700, height: 100)
        Raster.render(bytes, pitch: 3, into: &img, at: 40, 5, colour: Raster.p3)
        try decodes(img)
    }
    test("decoder: P3 colours AND fractional 3.75 px pitch together") {
        var img = RGBImage(width: 600, height: 120)
        Raster.render(bytes, pitch: 3.75, into: &img, at: 33.5, 9.25, colour: Raster.p3)
        try decodes(img)
    }
    test("decoder: warm white balance (consistent tint) decodes") {
        var img = RGBImage(width: 700, height: 100)
        Raster.render(bytes, pitch: 4, into: &img, at: 12, 3, colour: Raster.warm)
        try decodes(img)
    }
    test("decoder rejects: clipped marker (strip cut at column 70)") {
        var img = RGBImage(width: 700, height: 100)
        Raster.render(bytes, pitch: 3, into: &img, at: 20, 4, maxCols: 70)
        try rejects(img, "clipped")
    }
    test("decoder rejects: finder + tail but no calibration palette") {
        var img = RGBImage(width: 700, height: 100)
        Raster.render(bytes, pitch: 3, into: &img, at: 20, 4, dropPalette: true)
        try rejects(img, "no palette")
    }
    test("decoder rejects: missing end marker") {
        var img = RGBImage(width: 700, height: 100)
        Raster.render(bytes, pitch: 3, into: &img, at: 20, 4, dropTail: true)
        try rejects(img, "no tail")
    }
    test("decoder rejects: random noise, quickly") {
        var img = RGBImage(width: 1200, height: 192)
        var g = SystemRandomNumberGenerator()
        for i in 0..<img.pixels.count { img.pixels[i] = UInt8.random(in: 0...255, using: &g) }
        let t0 = Date()
        try rejects(img, "noise")
        try expect(Date().timeIntervalSince(t0) < 2.0, "bounded work")
    }
    test("decoder rejects: noise blocks in game colours that happen to be cyan/yellow") {
        var img = RGBImage(width: 900, height: 120)
        for k in 0..<40 { let c: (Int, Int, Int) = k % 2 == 0 ? (0, 255, 255) : (255, 255, 0)
            Raster.render([0x33, 0x57, 1, 2] + [UInt8](repeating: 0, count: 30), pitch: 1, into: &img, at: 0, 0, colour: { _ in c }, maxCols: 0)
            for y in 10..<20 { for x in (k * 20)..<(k * 20 + 7) { let o = (y * 900 + x) * 3; img.pixels[o] = UInt8(c.0); img.pixels[o + 1] = UInt8(c.1); img.pixels[o + 2] = UInt8(c.2) } }
        }
        try rejects(img, "cyan/yellow blocks")
    }
    test("decoder: a full 6400×192 band with the strip at top centre decodes within budget") {
        var img = RGBImage(width: 6400, height: 192)
        Raster.render(bytes, pitch: 3.79, into: &img, at: 3050.3, 0)
        let t0 = Date(); try decodes(img); try expect(Date().timeIntervalSince(t0) < 2.0)
    }
}

func runScreenContextTests() {
    test("context: only public logo terms classify; everything else is noKnownText; strings never returned") {
        try eq(ScreenContext.classify(["WORLD", "WARCRAFT"]), ScreenContext.knownLogo)
        try eq(ScreenContext.classify(["World of Warcraft"]), ScreenContext.knownLogo)
        try eq(ScreenContext.classify(["WORLD", "FOREVER"]), ScreenContext.knownLogo)
        try eq(ScreenContext.classify(["World"]), ScreenContext.noKnownText)
        try eq(ScreenContext.classify(["Thrall", "Orgrimmar", "Quest log"]), ScreenContext.noKnownText)
        try eq(ScreenContext.classify([]), ScreenContext.noKnownText)
    }
    test("context: diagnostics carry only the category and its age") {
        var c = BridgeStatus.Capture(state: "capturing", stats: CaptureStats(), now: 0)
        c.context = ScreenContext.knownLogo; c.contextAgeSeconds = 3
        let obj = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(c)) as! [String: Any]
        try eq(obj["context"] as? String, "knownWarcraftLogo"); try eq(obj["contextAgeSeconds"] as? Double, 3)
        _ = try JSONDecoder().decode(BridgeStatus.Capture.self, from: try JSONEncoder().encode(BridgeStatus.Capture(state: "x", stats: CaptureStats(), now: 0)))
    }
}

/// Parent CALIBRATED-F09-PARENT-CHECK: exact warm matrix on ALL calibration + data cells.
func runWarmMatrixTests() {
    let req = GameFrame.Chunk(reqId: 11, index: 0, count: 1, data: Codec.netstrings(["S", "thread:abc", String(repeating: "fractional ", count: 20)]))
    var want = sampleFrame(chunks: [req]); want.rows = 0
    let bytes = sampleFrame(chunks: [req]).encode()
    func warm(_ c: (Int, Int, Int)) -> (Int, Int, Int) {
        (Int((0.86 * Double(c.0)).rounded()), Int((0.72 * Double(c.1)).rounded()), Int((0.44 * Double(c.2)).rounded()))
    }
    for pitch in [3.0, 3.75] {
        test("decoder: parent warm matrix (0.86R, 0.72G, 0.44B) at \(pitch) px decodes") {
            var img = RGBImage(width: 600, height: 120)
            Raster.render(bytes, pitch: pitch, into: &img, at: 21.37, 6.4, colour: warm)
            var got = try PixelDecoder.decodeFrame(img); got.rows = 0
            try eq(got, want)
        }
    }
    test("decoder rejects: warm matrix with a collapsed (repeated) palette") {
        var img = RGBImage(width: 600, height: 120)
        Raster.render(bytes, pitch: 3, into: &img, at: 21, 6, colour: warm)
        // overwrite palette symbols 1…62 with one repeated colour (keeping the four anchor cells)
        let flat = warm((85, 85, 85))
        for s in 1..<63 where s != 15 && s != 60 {
            let x0 = 21 + (8 + s) * 3
            for y in 6..<9 { for x in x0..<(x0 + 3) { let o = (y * 600 + x) * 3; img.pixels[o] = UInt8(flat.0); img.pixels[o + 1] = UInt8(flat.1); img.pixels[o + 2] = UInt8(flat.2) } }
        }
        do { _ = try PixelDecoder.decodeFrame(img); throw Failure(description: "accepted a collapsed palette") } catch is PixelDecoder.DecodeError {}
    }
}
