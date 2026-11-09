import Foundation

/// A captured RGB image (any source: ScreenCaptureKit on macOS, PPM files in tests).
public struct RGBImage {
    public let width: Int, height: Int
    public var pixels: [UInt8] // RGB, row-major, 3 bytes per pixel
    public init(width: Int, height: Int, pixels: [UInt8]) { self.width = width; self.height = height; self.pixels = pixels }
    public init(width: Int, height: Int, fill: (UInt8, UInt8, UInt8) = (40, 30, 20)) {
        self.width = width; self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) { pixels[i * 3] = fill.0; pixels[i * 3 + 1] = fill.1; pixels[i * 3 + 2] = fill.2 }
    }
    @inline(__always) public func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * width + x) * 3
        return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
    }

    /// Binary PPM (P6) reader/writer for fixtures.
    public static func readPPM(_ data: [UInt8]) -> RGBImage? {
        var fields: [String] = [], i = 0, cur = ""
        while fields.count < 4 && i < data.count {
            let c = data[i]
            if c == 35 { while i < data.count && data[i] != 10 { i += 1 } }
            else if c == 32 || c == 10 || c == 13 || c == 9 { if !cur.isEmpty { fields.append(cur); cur = "" } }
            else { cur.append(Character(UnicodeScalar(c))) }
            i += 1
        }
        guard fields.count == 4, fields[0] == "P6", let w = Int(fields[1]), let h = Int(fields[2]), fields[3] == "255", data.count - i >= w * h * 3 else { return nil }
        return RGBImage(width: w, height: h, pixels: Array(data[i..<(i + w * h * 3)]))
    }
    public func ppm() -> [UInt8] { Array("P6\n\(width) \(height)\n255\n".utf8) + pixels }
}

/// Finds and decodes the T3 for WoW strip (docs/PROTOCOL.md section 1) anywhere in an image.
public enum PixelDecoder {
    public static let cols = 80
    static let finder: [(Int, Int, Int)] = [(0, 255, 255), (255, 255, 0), (0, 255, 255), (255, 255, 0), (0, 0, 0), (255, 255, 255), (0, 0, 0), (255, 255, 255)]

    public enum DecodeError: Error, Equatable { case notFound, unreadable(String) }

    @inline(__always) static func near(_ a: (Int, Int, Int), _ b: (Int, Int, Int), _ tol: Int = 70) -> Bool {
        abs(a.0 - b.0) <= tol && abs(a.1 - b.1) <= tol && abs(a.2 - b.2) <= tol
    }
    @inline(__always) static func dist(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
        let d0 = a.0 - b.0, d1 = a.1 - b.1, d2 = a.2 - b.2
        return d0 * d0 + d1 * d1 + d2 * d2
    }

    struct Geometry { var x0: Double; var y0: Double; var pitch: Double }

    /// Locate the strip using its own public calibration, tolerant of fractional pitch and of a consistent
    /// colour transform (e.g. wide-gamut delivery), with stronger structural checks than before:
    /// 1. candidates: a cyan-LIKE run (G and B ≥ 60 above R; no absolute level) immediately followed
    ///    by a yellow-like pixel;
    /// 2. pitch: from that run's left edge to the right edge of a cyan-like run ending where the end
    ///    marker's last cell must end (x0 + 80·pitch), searched for pitch in [run−1, run+1];
    /// 3. accept only if, at that one geometry, the finder cells match each other AND their palette cells
    ///    (cyan = symbol 15, yellow = 60, black = 0, white = 63), the 8-cell end marker matches, the four
    ///    colours are mutually distinct and the 64-cell palette is distinct along its length.
    /// Decoding then classifies data cells by the observed palette, as before. Work is bounded.
    static let maxCandidates = 20_000

    /// Candidate prefilters use chromatic DIFFERENCES only (no absolute brightness floor): a consistent
    /// colour transform (wide gamut, warm white balance) keeps cyan's G,B well above R and yellow's R,G
    /// well above B even when the absolute levels drop. Acceptance is decided by `validate`.
    @inline(__always) static func cyanLike(_ c: (Int, Int, Int)) -> Bool { c.1 - c.0 >= 60 && c.2 - c.0 >= 60 }
    @inline(__always) static func yellowLike(_ c: (Int, Int, Int)) -> Bool { c.0 - c.2 >= 60 && c.1 - c.2 >= 60 }
    /// Adjacent palette symbols differ by one level in one channel: 85 in sRGB, but as little as ~37 after
    /// a strong (valid) channel scaling. Separation above this still rejects flat/repeated palettes.
    static let paletteStepTolerance = 18
    @inline(__always) static func luma(_ c: (Int, Int, Int)) -> Int { (c.0 * 299 + c.1 * 587 + c.2 * 114) / 1000 }

    static func locate(_ img: RGBImage) -> Geometry? {
        var candidates = 0
        for y in 0..<img.height {
            var x = 0
            while x < img.width - 8 {
                guard cyanLike(img.px(x, y)) else { x += 1; continue }
                var e = x
                while e < img.width && cyanLike(img.px(e, y)) { e += 1 }
                let len = e - x
                if len <= 40, e < img.width, yellowLike(img.px(e, y)) {
                    candidates += 1
                    if candidates > maxCandidates { return nil }
                    if finderPlausible(img, x0: x, y: y, runLength: len), let g = tryCandidate(img, x0: x, y: y, runLength: len) { return g }
                }
                x = e
            }
        }
        return nil
    }

    /// Cheap structural gate (bounds work on busy or noisy images): at some pitch near the run length, the
    /// first 8 cells already look like the finder relative to each other: cells 0≈2, 1≈3 (yellow-like),
    /// 4≈6, 5≈7, with black/white distinct and contrasted. A 0.25 px pitch step keeps the sampling error
    /// below half a cell for pitches ≥ 2.5 px. Full acceptance is still `validate`.
    static func finderPlausible(_ img: RGBImage, x0: Int, y: Int, runLength l: Int) -> Bool {
        var q = max(1.0, Double(l) - 1)
        while q <= Double(l) + 1.0001 {
            func at(_ k: Int) -> (Int, Int, Int)? {
                let sx = Int(Double(x0) + (Double(k) + 0.5) * q)
                return sx < img.width ? img.px(sx, y) : nil
            }
            if let c0 = at(0), let c1 = at(1), let c2 = at(2), let c3 = at(3), let c4 = at(4), let c5 = at(5), let c6 = at(6), let c7 = at(7),
               cyanLike(c0), yellowLike(c1), near(c0, c2), near(c1, c3), near(c4, c6), near(c5, c7), !near(c4, c5), luma(c5) - luma(c4) >= 100 {
                return true
            }
            q += 0.25
        }
        return false
    }

    /// Search for the end of the end marker's last (cyan) cell on this row, then validate that geometry.
    static func tryCandidate(_ img: RGBImage, x0: Int, y: Int, runLength l: Int) -> Geometry? {
        let lo = Double(x0) + 80 * max(1, Double(l) - 1), hi = Double(x0) + 80 * (Double(l) + 1)
        var x = max(x0 + l, Int(lo) - 2 * l - 2)
        let xmax = min(img.width, Int(hi) + 2)
        while x < xmax {
            guard cyanLike(img.px(x, y)) else { x += 1; continue }
            var e = x
            while e < img.width && cyanLike(img.px(e, y)) { e += 1 }
            if Double(e) >= lo && Double(e) <= hi {
                let pitch = Double(e - x0) / 80
                if let g = validate(img, x0: x0, y: y, pitch: pitch) { return g }
            }
            x = e
        }
        return nil
    }

    static func validate(_ img: RGBImage, x0: Int, y: Int, pitch: Double) -> Geometry? {
        guard pitch >= 1 else { return nil }
        // top edge of row 0 (walk up while still the same cyan-like cell)
        let cx = Int(Double(x0) + pitch / 2)
        var y0 = y
        while y0 > 0 && Double(y - y0) < pitch && cyanLike(img.px(cx, y0 - 1)) { y0 -= 1 }
        let sy = Int(Double(y0) + pitch / 2)
        guard sy < img.height else { return nil }
        var c: [(Int, Int, Int)] = []
        c.reserveCapacity(cols)
        for k in 0..<cols {
            let sx = Int(Double(x0) + (Double(k) + 0.5) * pitch)
            guard sx < img.width else { return nil }
            c.append(img.px(sx, sy))
        }
        let C = c[0], Y = c[1], K = c[4], W = c[5]
        // finder self-consistency + calibration anchors + end marker (W K W K Y C Y C)
        let pairs: [(Int, (Int, Int, Int))] = [(2, C), (3, Y), (6, K), (7, W), (8 + 15, C), (8 + 60, Y), (8 + 0, K), (8 + 63, W),
                                                (72, W), (73, K), (74, W), (75, K), (76, Y), (77, C), (78, Y), (79, C)]
        for (i, ref) in pairs where !near(c[i], ref) { return nil }
        // the four calibration colours must be clearly different, with real contrast
        let four = [C, Y, K, W]
        for i in 0..<4 { for j in (i + 1)..<4 where near(four[i], four[j]) { return nil } }
        guard luma(W) - luma(K) >= 100 else { return nil }
        // the palette must be a real 64-step calibration row, not a flat or repeated area
        var distinct = 0
        for s in 0..<63 where !near(c[8 + s], c[8 + s + 1], paletteStepTolerance) { distinct += 1 }
        guard distinct >= 48 else { return nil }
        return Geometry(x0: Double(x0), y0: Double(y0), pitch: pitch)
    }

    public static func decode(_ img: RGBImage) throws -> [UInt8] {
        guard let g = locate(img) else { throw DecodeError.notFound }
        func sample(_ col: Int, _ row: Int) -> (Int, Int, Int)? {
            let sx = Int(g.x0 + (Double(col) + 0.5) * g.pitch), sy = Int(g.y0 + (Double(row) + 0.5) * g.pitch)
            guard sx >= 0, sy >= 0, sx < img.width, sy < img.height else { return nil }
            return img.px(sx, sy)
        }
        var palette: [(Int, Int, Int)] = []
        for s in 0..<64 { guard let c = sample(8 + s, 0) else { throw DecodeError.unreadable("palette off image") }; palette.append(c) }
        func classify(_ c: (Int, Int, Int)) -> UInt8 {
            var best = 0, bestD = Int.max
            for (i, p) in palette.enumerated() { let d = dist(c, p); if d < bestD { bestD = d; best = i } }
            return UInt8(best)
        }
        func readRows(_ count: Int) throws -> [UInt8] {
            var syms: [UInt8] = []
            for r in 1...count { for c in 0..<cols {
                guard let px = sample(c, r) else { throw DecodeError.unreadable("strip cut off") }
                syms.append(classify(px))
            } }
            return Codec.fromSymbols(syms)
        }
        let first = try readRows(1)
        guard first.count >= 4, first[0] == 0x33, first[1] == 0x57 else { throw DecodeError.unreadable("bad magic") }
        let rows = Int(first[3])
        guard rows >= 2, rows <= 16 else { throw DecodeError.unreadable("bad rows") }
        return rows == 2 ? first : try readRows(rows - 1)
    }

    public static func decodeFrame(_ img: RGBImage) throws -> GameFrame {
        try GameFrame.parse(try decode(img))
    }

    /// Test/harness renderer: draws a frame exactly like the addon's strip does.
    public static func render(_ bytes: [UInt8], cellPx: Int, into img: inout RGBImage, at x0: Int, _ y0: Int) {
        let rows = Int(bytes[3])
        var cells: [(Int, Int, Int)] = finder
        let L = [0, 85, 170, 255]
        func color(_ s: Int) -> (Int, Int, Int) { (L[(s / 16) % 4], L[(s / 4) % 4], L[s % 4]) }
        for s in 0..<64 { cells.append(color(s)) }
        cells += [finder[5], finder[4], finder[5], finder[4], finder[1], finder[0], finder[1], finder[0]]
        let syms = Codec.toSymbols(bytes)
        for i in 0..<((rows - 1) * cols) { cells.append(color(i < syms.count ? Int(syms[i]) : 0)) }
        for (i, c) in cells.enumerated() {
            let cx = x0 + (i % cols) * cellPx, cy = y0 + (i / cols) * cellPx
            for dy in 0..<cellPx { for dx in 0..<cellPx {
                let x = cx + dx, y = cy + dy
                guard x < img.width, y < img.height else { continue }
                let o = (y * img.width + x) * 3
                img.pixels[o] = UInt8(c.0); img.pixels[o + 1] = UInt8(c.1); img.pixels[o + 2] = UInt8(c.2)
            } }
        }
    }
}
