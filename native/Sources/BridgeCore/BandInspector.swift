import Foundation

/// Safe numeric aggregates about the PUBLIC finder pattern inside the already-approved capture band.
/// Never contains pixels, rows, data-cell colours or symbols.
public struct BandInspection: Codable, Equatable {
    public var regionX = 0, regionWidth = 0, regionHeight = 0   // inspected top-centre region (buffer pixels)
    public var opaque = 0, transparent = 0                      // alpha == 255 / alpha == 0 counts
    public var cyan = 0, yellow = 0, black = 0, white = 0       // finder-colour counts (decoder tolerance)
    public var lumaMin = 0, lumaMax = 0                          // brightness range (blank detection)
    public var longestCyanRun = 0
    public var finderPrefix = 0                                  // best consecutive match of C,Y,C,Y,K,W,K,W (0…8)
    public var bestX: Int?, bestY: Int?
    public var bestPitch: Double?
    public var pitchKind = "none"                                // none | integer | fractional
    public var verdict = "notInspected"                          // see BandInspector.inspect
    // Diagnostic-only loose chromatic matcher (never used by the decoder)
    public var looseCyan = 0, looseYellow = 0
    public var looseFinderPrefix = 0
    public var looseBestPitch: Double?
    public init() {}
}

public enum BandInspector {
    public static let maxRegionWidth = 1200

    static let maxRuns = 4000          // bound the finder search per inspection

    /// Diagnostic-only chromatic classes (tolerant of display colour-space conversion), never used to decode:
    /// cyan = high G and B with lowish R; yellow = high R and G with lowish B.
    @inline(__always) static func looseCyan(_ c: (Int, Int, Int)) -> Bool { c.1 >= 180 && c.2 >= 180 && c.0 <= 170 }
    @inline(__always) static func looseYellow(_ c: (Int, Int, Int)) -> Bool { c.0 >= 180 && c.1 >= 180 && c.2 <= 170 }

    /// Inspects the top-centre region (≤ 1200 px wide, full band height) of a BGRA buffer.
    /// Verdicts: transparent · blank · noFinderColors · finderColorsNoPattern · finderPartial ·
    /// finderIntegerPitch · finderFractionalPitch. Reporting only: never affects decoding.
    public static func inspect(bgra p: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int) -> BandInspection {
        var r = BandInspection()
        guard width > 0, height > 0, bytesPerRow >= width * 4, p.count >= bytesPerRow * height else { r.verdict = "badBuffer"; return r }
        let rw = min(maxRegionWidth, width), rx = (width - rw) / 2
        r.regionX = rx; r.regionWidth = rw; r.regionHeight = height
        @inline(__always) func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let o = y * bytesPerRow + x * 4
            return (Int(p[o + 2]), Int(p[o + 1]), Int(p[o]))
        }
        let F = PixelDecoder.finder
        var lmin = 255, lmax = 0
        var runs: [(x: Int, y: Int, len: Int)] = [], looseRuns: [(x: Int, y: Int, len: Int)] = []
        for y in 0..<height {
            var runStart = -1, looseStart = -1
            for x in rx..<(rx + rw) {
                let o = y * bytesPerRow + x * 4
                let a = p[o + 3]
                if a == 255 { r.opaque += 1 } else if a == 0 { r.transparent += 1 }
                let c = (Int(p[o + 2]), Int(p[o + 1]), Int(p[o]))
                let l = (c.0 * 299 + c.1 * 587 + c.2 * 114) / 1000
                lmin = min(lmin, l); lmax = max(lmax, l)
                let isCyan = PixelDecoder.near(c, F[0])
                if isCyan { r.cyan += 1 } else if PixelDecoder.near(c, F[1]) { r.yellow += 1 }
                else if PixelDecoder.near(c, F[4]) { r.black += 1 } else if PixelDecoder.near(c, F[5]) { r.white += 1 }
                if isCyan { if runStart < 0 { runStart = x } }
                else if runStart >= 0 {
                    let len = x - runStart; r.longestCyanRun = max(r.longestCyanRun, len)
                    if len <= 40, runs.count < maxRuns { runs.append((runStart, y, len)) }
                    runStart = -1
                }
                let lc = looseCyan(c)
                if lc { r.looseCyan += 1 } else if looseYellow(c) { r.looseYellow += 1 }
                if lc { if looseStart < 0 { looseStart = x } }
                else if looseStart >= 0 {
                    let len = x - looseStart
                    if len <= 40, looseRuns.count < maxRuns { looseRuns.append((looseStart, y, len)) }
                    looseStart = -1
                }
            }
            if runStart >= 0 { let len = rx + rw - runStart; r.longestCyanRun = max(r.longestCyanRun, len) }
        }
        r.lumaMin = lmin; r.lumaMax = lmax

        // Finder search from each cyan run: integer pitch = run length, then fractional pitches nearby.
        func search(_ runs: [(x: Int, y: Int, len: Int)], _ match: (Int, (Int, Int, Int)) -> Bool) -> (prefix: Int, x: Int?, y: Int?, pitch: Double?, integer: Bool) {
            func prefix(_ x0: Int, _ y: Int, _ pitch: Double) -> Int {
                var k = 0
                while k < 8 {
                    let sx = Int(Double(x0) + (Double(k) + 0.5) * pitch)
                    if sx >= rx + rw || !match(k, rgb(sx, y)) { break }
                    k += 1
                }
                return k
            }
            var out: (prefix: Int, x: Int?, y: Int?, pitch: Double?, integer: Bool) = (0, nil, nil, nil, true)
            for run in runs {
                let ip = Double(run.len)
                var bestHere = prefix(run.x, run.y, ip), pitchHere = ip, integer = true
                if bestHere < 8 {
                    var matching: [Double] = []
                    var best = bestHere
                    var q = max(1.0, ip - 1)
                    while q <= ip + 1.0001 {
                        let k = prefix(run.x, run.y, q)
                        if k > best { best = k; matching = [q] } else if k == best && k > bestHere { matching.append(q) }
                        q += 0.01
                    }
                    if best > bestHere, let lo = matching.first, let hi = matching.last {
                        bestHere = best; pitchHere = ((lo + hi) / 2 * 100).rounded() / 100; integer = pitchHere == pitchHere.rounded()
                    }
                }
                if bestHere > out.prefix {
                    out = (bestHere, run.x, run.y, pitchHere, integer)
                    if bestHere == 8 && integer { break }
                }
            }
            return out
        }
        let strict = search(runs) { k, c in PixelDecoder.near(c, F[k]) }   // the decoder's own tolerance
        r.finderPrefix = strict.prefix; r.bestX = strict.x; r.bestY = strict.y; r.bestPitch = strict.pitch
        r.pitchKind = strict.prefix == 0 ? "none" : (strict.integer ? "integer" : "fractional")
        let loose = search(looseRuns) { k, c in
            switch k { case 0, 2: return looseCyan(c); case 1, 3: return looseYellow(c); default: return PixelDecoder.near(c, F[k]) }
        }
        r.looseFinderPrefix = loose.prefix; r.looseBestPitch = loose.pitch

        let total = rw * height
        if r.transparent * 10 > total * 9 { r.verdict = "transparent" }
        else if lmax - lmin < 8 { r.verdict = "blank" }
        else if r.finderPrefix == 8 { r.verdict = r.pitchKind == "integer" ? "finderIntegerPitch" : "finderFractionalPitch" }
        else if r.cyan == 0 && r.yellow == 0 { r.verdict = "noFinderColors" }
        else if r.finderPrefix >= 2 { r.verdict = "finderPartial" }
        else { r.verdict = "finderColorsNoPattern" }
        if r.finderPrefix == 0 { r.bestX = nil; r.bestY = nil; r.bestPitch = nil; r.pitchKind = "none" }
        if r.looseFinderPrefix == 0 { r.looseBestPitch = nil }
        return r
    }
}

/// Whitelisted generic colour-space labels for diagnostics (no profile names, paths or dictionaries).
public enum ColorLabel {
    /// CVImageBuffer colour primaries / transfer function values (kCVImageBuffer…_ constants' string values).
    static let knownPrimaries: Set<String> = ["ITU_R_709_2", "EBU_3213", "SMPTE_C", "P22", "DCI_P3", "P3_D65", "ITU_R_2020"]
    static let knownTransfer: Set<String> = ["ITU_R_709_2", "SMPTE_240M_1995", "UseGamma", "ITU_R_2020", "SMPTE_ST_428_1",
                                             "SMPTE_ST_2084_PQ", "ITU_R_2100_HLG", "Linear", "IEC_sRGB"]
    /// CGColorSpace names → short generic labels.
    static let knownSpaces: [String: String] = [
        "kCGColorSpaceSRGB": "sRGB", "kCGColorSpaceDisplayP3": "displayP3", "kCGColorSpaceExtendedSRGB": "extendedSRGB",
        "kCGColorSpaceLinearSRGB": "linearSRGB", "kCGColorSpaceExtendedLinearSRGB": "extendedLinearSRGB",
        "kCGColorSpaceGenericRGB": "genericRGB", "kCGColorSpaceGenericRGBLinear": "genericRGBLinear",
        "kCGColorSpaceDCIP3": "dciP3", "kCGColorSpaceITUR_709": "itur709", "kCGColorSpaceITUR_2020": "itur2020",
        "kCGColorSpaceAdobeRGB1998": "adobeRGB1998", "kCGColorSpaceExtendedDisplayP3": "extendedDisplayP3",
    ]
    public static func primaries(_ s: String?) -> String? { s.map { knownPrimaries.contains($0) ? $0 : "other" } }
    public static func transfer(_ s: String?) -> String? { s.map { knownTransfer.contains($0) ? $0 : "other" } }
    /// nil name (e.g. an ICC-profile-based space) → "custom"; unknown names → "other".
    public static func space(_ s: String?) -> String { guard let s else { return "custom" }; return knownSpaces[s] ?? "other" }
    /// What SCStreamConfiguration.colorSpaceName was set to (nil = not set: the display's colour space).
    public static func configured(_ s: String?) -> String { guard let s else { return "unset (display colour space)" }; return knownSpaces[s] ?? "other" }
}
