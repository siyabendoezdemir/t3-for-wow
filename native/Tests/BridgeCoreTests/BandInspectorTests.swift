import Foundation
@testable import BridgeCore

/// SYNTHETIC rasters only (public finder pattern; no user data). Reporting tests: the decoder is not changed.
struct BGRA {
    var w: Int, h: Int, px: [UInt8]
    init(_ w: Int, _ h: Int, fill: (UInt8, UInt8, UInt8, UInt8) = (40, 30, 20, 255)) {
        self.w = w; self.h = h; px = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) { px[i * 4] = fill.2; px[i * 4 + 1] = fill.1; px[i * 4 + 2] = fill.0; px[i * 4 + 3] = fill.3 }
    }
    mutating func rect(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: (Int, Int, Int)) {
        for y in max(0, y0)..<min(h, y1) { for x in max(0, x0)..<min(w, x1) {
            let o = (y * w + x) * 4; px[o] = UInt8(c.2); px[o + 1] = UInt8(c.1); px[o + 2] = UInt8(c.0); px[o + 3] = 255 } }
    }
    /// Draw the first `cells` finder cells at `x`,`y` with (possibly fractional) `pitch`.
    mutating func finder(x: Double, y: Int, pitch: Double, cells: Int = 8) {
        for k in 0..<cells {
            let a = Int((x + Double(k) * pitch).rounded(.down)), b = Int((x + Double(k + 1) * pitch).rounded(.down))
            rect(a, y, b, y + Int(pitch.rounded(.up)), PixelDecoder.finder[k])
        }
    }
    func inspect() -> BandInspection { px.withUnsafeBytes { BandInspector.inspect(bgra: $0, width: w, height: h, bytesPerRow: w * 4) } }
}

func runBandInspectorTests() {
    test("band: blank opaque buffer → blank, no finder") {
        let r = BGRA(6400, 192).inspect()
        try eq(r.verdict, "blank"); try eq(r.finderPrefix, 0); try eq(r.regionWidth, 1200); try eq(r.regionX, 2600)
        try eq(r.opaque, 1200 * 192); try eq(r.transparent, 0)
    }
    test("band: fully transparent buffer → transparent") {
        try eq(BGRA(6400, 192, fill: (0, 0, 0, 0)).inspect().verdict, "transparent")
    }
    test("band: whole-pixel protocol finder (3 px) at top centre → full match, integer pitch, location") {
        var b = BGRA(6400, 192)
        b.finder(x: 3200 - 120, y: 0, pitch: 3)
        let r = b.inspect()
        try eq(r.finderPrefix, 8); try eq(r.pitchKind, "integer"); try eq(r.bestPitch, 3); try eq(r.bestX, 3080); try eq(r.bestY, 0)
        try eq(r.verdict, "finderIntegerPitch")
        try expect(r.cyan > 0 && r.yellow > 0 && r.black > 0 && r.white > 0); try eq(r.longestCyanRun, 3)
    }
    test("band: fractional 3.75 px pitch finder → matches only at a fractional pitch") {
        var b = BGRA(6400, 192)
        b.finder(x: 3100.5, y: 10, pitch: 3.75)
        let r = b.inspect()
        try eq(r.finderPrefix, 8); try eq(r.pitchKind, "fractional"); try eq(r.verdict, "finderFractionalPitch")
        try expect(abs((r.bestPitch ?? 0) - 3.75) <= 0.06, "pitch \(String(describing: r.bestPitch))")
    }
    test("band: partial finder (3 cells) → finderPartial with prefix 3") {
        var b = BGRA(6400, 192)
        b.finder(x: 3000, y: 4, pitch: 3, cells: 3)
        let r = b.inspect(); try eq(r.finderPrefix, 3); try eq(r.verdict, "finderPartial")
    }
    test("band: finder outside the inspected top-centre region → noFinderColors (region bounded)") {
        var b = BGRA(6400, 192)
        b.finder(x: 40, y: 0, pitch: 3)
        b.rect(2700, 20, 3600, 120, (120, 60, 30))   // non-finder game content inside the region
        let r = b.inspect(); try eq(r.verdict, "noFinderColors"); try eq(r.cyan, 0); try eq(r.finderPrefix, 0)
    }
    test("band: serialized diagnostics carry only numeric aggregates (no pixel arrays)") {
        var b = BGRA(6400, 192); b.finder(x: 3080, y: 0, pitch: 3)
        var c = BridgeStatus.Capture(state: "capturing", stats: CaptureStats(), now: 0)
        c.band = b.inspect(); c.bufferWidth = 6400; c.bufferHeight = 192; c.pixelFormat = "BGRA"
        c.filterStyle = "display"; c.filterContentRect = CaptureRect(x: 0, y: 0, width: 3200, height: 1350); c.filterPointPixelScale = 2
        c.frameContentRect = CaptureRect(x: 0, y: 0, width: 3200, height: 96); c.frameContentScale = 1; c.frameScaleFactor = 2
        let data = try JSONEncoder().encode(c)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let band = obj["band"] as! [String: Any]
        try eq(Set(band.keys), ["regionX", "regionWidth", "regionHeight", "opaque", "transparent", "cyan", "yellow", "black", "white", "lumaMin", "lumaMax",
                                 "longestCyanRun", "finderPrefix", "bestX", "bestY", "bestPitch", "pitchKind", "verdict",
                                 "looseCyan", "looseYellow", "looseFinderPrefix", "looseBestPitch"])
        for v in band.values { try expect(!(v is [Any]), "no arrays in band") }
        try expect(obj["outputPixels"] == nil || (obj["outputPixels"] as? [Int])?.count == 2)
        _ = try JSONDecoder().decode(BridgeStatus.Capture.self, from: data)
        // older snapshots without the new keys still decode
        _ = try JSONDecoder().decode(BridgeStatus.Capture.self, from: try JSONEncoder().encode(BridgeStatus.Capture(state: "x", stats: CaptureStats(), now: 0)))
    }
    test("band: the inspector does not change decoding (decoder result identical before/after inspection)") {
        var img = RGBImage(width: 800, height: 60)
        PixelDecoder.render(sampleFrame().encode(), cellPx: 3, into: &img, at: 300, 3)
        let before = try PixelDecoder.decodeFrame(img)
        var b = BGRA(800, 60); _ = b.inspect()
        try eq(try PixelDecoder.decodeFrame(img), before)
    }
}

func runBandColorTests() {
    test("band (colour): a P3-shifted finder fails the strict tolerance but matches the loose chromatic counter") {
        var b = BGRA(6400, 192)
        let shifted: [(Int, Int, Int)] = [(117, 245, 250), (250, 250, 95), (117, 245, 250), (250, 250, 95), (0, 0, 0), (255, 255, 255), (0, 0, 0), (255, 255, 255)]
        for k in 0..<8 { b.rect(3000 + k * 3, 0, 3000 + (k + 1) * 3, 3, shifted[k]) }
        let r = b.inspect()
        try expect(r.finderPrefix < 8, "strict (decoder) tolerance rejects it: \(r.finderPrefix)")
        try eq(r.looseFinderPrefix, 8); try eq(r.looseBestPitch, 3)
        try expect(r.looseCyan > 0 && r.looseYellow > 0)
    }
    test("band (colour): exact protocol colours match both strict and loose") {
        var b = BGRA(6400, 192); b.finder(x: 3000, y: 0, pitch: 3)
        let r = b.inspect(); try eq(r.finderPrefix, 8); try eq(r.looseFinderPrefix, 8)
    }
    test("colour labels: only whitelisted generic names; anything else is other/custom") {
        try eq(ColorLabel.primaries("P3_D65"), "P3_D65"); try eq(ColorLabel.primaries("ITU_R_709_2"), "ITU_R_709_2")
        try eq(ColorLabel.primaries("/Library/ColorSync/Profiles/Mine.icc"), "other"); try eq(ColorLabel.primaries(nil), nil)
        try eq(ColorLabel.transfer("IEC_sRGB"), "IEC_sRGB"); try eq(ColorLabel.transfer("weird"), "other")
        try eq(ColorLabel.space("kCGColorSpaceDisplayP3"), "displayP3"); try eq(ColorLabel.space("kCGColorSpaceSRGB"), "sRGB")
        try eq(ColorLabel.space(nil), "custom"); try eq(ColorLabel.space("Some Monitor Profile"), "other")
        try eq(ColorLabel.configured(nil), "unset (display colour space)"); try eq(ColorLabel.configured("kCGColorSpaceSRGB"), "sRGB")
    }
}
