import Foundation

/// Byte helpers shared with the addon (docs/PROTOCOL.md). Mirrors addon/T3ForWoW/Core/Bytes.lua.
public enum Codec {
    static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
        return c
    }

    public static func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    public static func netstrings(_ fields: [String]) -> [UInt8] {
        var out: [UInt8] = []
        for f in fields { let b = Array(f.utf8); out += Array("\(b.count):".utf8); out += b }
        return out
    }

    public static func netstringsBytes(_ fields: [[UInt8]]) -> [UInt8] {
        var out: [UInt8] = []
        for b in fields { out += Array("\(b.count):".utf8); out += b }
        return out
    }

    /// Exact netstring sequence → fields, or nil.
    public static func parseNetstrings(_ s: [UInt8], maxFields: Int = 4096) -> [[UInt8]]? {
        var out: [[UInt8]] = []
        var i = 0
        while i < s.count {
            var len = 0, digits = 0
            while i < s.count, s[i] >= 48, s[i] <= 57 {
                len = len * 10 + Int(s[i] - 48); digits += 1; i += 1
                if digits > 8 { return nil }
            }
            guard digits > 0, i < s.count, s[i] == 58 else { return nil }
            i += 1
            guard i + len <= s.count else { return nil }
            out.append(Array(s[i..<(i + len)]))
            if out.count > maxFields { return nil }
            i += len
        }
        return out
    }

    public static func parseStrings(_ s: [UInt8], maxFields: Int = 4096) -> [String]? {
        guard let f = parseNetstrings(s, maxFields: maxFields) else { return nil }
        var out: [String] = []
        for b in f { guard let str = String(bytes: b, encoding: .utf8) else { return nil }; out.append(str) }
        return out
    }

    public static func fromSymbols(_ syms: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i + 3 < syms.count {
            let v = (UInt32(syms[i]) << 18) | (UInt32(syms[i + 1]) << 12) | (UInt32(syms[i + 2]) << 6) | UInt32(syms[i + 3])
            out += [UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
            i += 4
        }
        return out
    }

    public static func toSymbols(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            let a = UInt32(bytes[i]), b = i + 1 < bytes.count ? UInt32(bytes[i + 1]) : 0, c = i + 2 < bytes.count ? UInt32(bytes[i + 2]) : 0
            let v = (a << 16) | (b << 8) | c
            out += [UInt8((v >> 18) & 63), UInt8((v >> 12) & 63), UInt8((v >> 6) & 63), UInt8(v & 63)]
            i += 3
        }
        return out
    }

    static func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]) }

    /// Slot literal: printable ASCII except `"` and `\`; everything else `\ddd`.
    public static func luaLiteral(_ bytes: [UInt8]) -> String {
        var s = ""
        s.reserveCapacity(bytes.count)
        for b in bytes {
            if b >= 32 && b <= 126 && b != 34 && b != 92 { s.unicodeScalars.append(UnicodeScalar(b)) }
            else { s += "\\" + String(format: "%03d", Int(b)) }
        }
        return s
    }
}

/// One parsed game → bridge frame.
public struct GameFrame: Equatable {
    public struct Chunk: Equatable {
        public var reqId: UInt32; public var index: Int; public var count: Int; public var data: [UInt8]
        public init(reqId: UInt32, index: Int, count: Int, data: [UInt8]) { self.reqId = reqId; self.index = index; self.count = count; self.data = data }
    }
    public var rows: Int
    public var gameSession: UInt32
    public var frameSeq: Int
    public var epochAck: UInt32
    public var deliveryAck: UInt32
    public var nextSlot: Int
    public var slotCount: Int
    public var flags: Int
    public var chunks: [Chunk]
    public init(rows: Int, gameSession: UInt32, frameSeq: Int, epochAck: UInt32, deliveryAck: UInt32, nextSlot: Int, slotCount: Int, flags: Int, chunks: [Chunk]) {
        self.rows = rows; self.gameSession = gameSession; self.frameSeq = frameSeq; self.epochAck = epochAck; self.deliveryAck = deliveryAck
        self.nextSlot = nextSlot; self.slotCount = slotCount; self.flags = flags; self.chunks = chunks
    }
    public var windowOpen: Bool { flags & 1 != 0 }
    public var exhausted: Bool { flags & 2 != 0 }

    public enum ParseError: Error, Equatable { case short, magic, version, crc, payload }

    public static func parse(_ b: [UInt8]) throws -> GameFrame {
        guard b.count >= 29 else { throw ParseError.short }
        guard b[0] == 0x33, b[1] == 0x57 else { throw ParseError.magic }
        guard b[2] == 1 else { throw ParseError.version }
        let payloadLen = Codec.u16(b, 23)
        let end = 25 + payloadLen
        guard end + 4 <= b.count else { throw ParseError.short }
        guard Codec.crc32(b[0..<end]) == Codec.u32(b, end) else { throw ParseError.crc }
        var chunks: [Chunk] = []
        var i = 25
        while i < end {
            guard i + 8 <= end else { throw ParseError.payload }
            let len = Codec.u16(b, i + 6)
            guard i + 8 + len <= end else { throw ParseError.payload }
            let c = Chunk(reqId: Codec.u32(b, i), index: Int(b[i + 4]), count: Int(b[i + 5]), data: Array(b[(i + 8)..<(i + 8 + len)]))
            guard c.count > 0, c.index < c.count else { throw ParseError.payload }
            chunks.append(c)
            i += 8 + len
        }
        return GameFrame(rows: Int(b[3]), gameSession: Codec.u32(b, 4), frameSeq: Codec.u16(b, 8), epochAck: Codec.u32(b, 10),
                         deliveryAck: Codec.u32(b, 14), nextSlot: Codec.u16(b, 18), slotCount: Codec.u16(b, 20), flags: Int(b[22]), chunks: chunks)
    }

    /// Encoder used only by tests and the synthetic game harness.
    public func encode() -> [UInt8] {
        var payload: [UInt8] = []
        for c in chunks {
            payload += be32(c.reqId) + [UInt8(c.index), UInt8(c.count)] + be16(c.data.count) + c.data
        }
        let total = 25 + payload.count + 4
        let rows = max(2, Int((Double(total) / 60).rounded(.up)) + 1)
        var b: [UInt8] = [0x33, 0x57, 1, UInt8(rows)] + be32(gameSession) + be16(frameSeq & 0xFFFF) + be32(epochAck) + be32(deliveryAck)
        b += be16(nextSlot) + be16(slotCount) + [UInt8(flags & 0xFF)] + be16(payload.count) + payload
        return b + be32(Codec.crc32(b))
    }
}

func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
