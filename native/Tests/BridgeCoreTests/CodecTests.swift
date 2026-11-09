import Foundation
@testable import BridgeCore

func sampleFrame(chunks: [GameFrame.Chunk] = []) -> GameFrame {
    GameFrame(rows: 0, gameSession: 0x0102_0304, frameSeq: 7, epochAck: 9, deliveryAck: 11, nextSlot: 3, slotCount: 480, flags: 5, chunks: chunks)
}

func runCodecTests() {
    test("crc32 reference vector") { try eq(Codec.crc32(Array("123456789".utf8)), 0xCBF4_3926) }
    test("sha256 reference vector (portable and platform)") {
        try eq(Hashing.sha256Hex(Array("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        try eq(SHA256Portable.hash(Array("abc".utf8)), Hashing.sha256(Array("abc".utf8)))
    }
    test("netstrings round trip and reject malformed") {
        let b = Codec.netstrings(["S", "thread:1", "héllo:\n"])
        try eq(String(decoding: b, as: UTF8.self), "1:S8:thread:18:h\u{e9}llo:\n")
        try eq(Codec.parseStrings(b)!, ["S", "thread:1", "héllo:\n"])
        try expect(Codec.parseNetstrings(Array("3:ab".utf8)) == nil)
        try expect(Codec.parseNetstrings(Array("x:ab".utf8)) == nil)
    }
    test("symbols round trip") {
        let bytes = (0..<256).map { UInt8($0) }
        try eq(Array(Codec.fromSymbols(Codec.toSymbols(bytes)).prefix(256)), bytes)
    }
    test("frame encode/parse round trip; CRC tamper detected") {
        let f = sampleFrame(chunks: [.init(reqId: 42, index: 0, count: 1, data: Array("1:Z".utf8))])
        let bytes = f.encode()
        var p = try GameFrame.parse(bytes)
        p.rows = 0
        try eq(p, f)
        var bad = bytes; bad[30] ^= 1
        do { _ = try GameFrame.parse(bad); throw Failure(description: "accepted tampered frame") } catch GameFrame.ParseError.crc {}
    }
    test("lua literal uses only the safe alphabet and round trips through the Lua unescape rules") {
        let all = (0..<256).map { UInt8($0) } + Array("\"\\]]--[[".utf8)
        let lit = Codec.luaLiteral(all)
        for u in lit.unicodeScalars { try expect(u.value >= 32 && u.value <= 126 && u != "\"", "bad char \(u)") }
        // decode per the documented rules
        var out: [UInt8] = [], i = lit.startIndex
        while i < lit.endIndex {
            if lit[i] == "\\" { let d = lit[lit.index(after: i)..<lit.index(i, offsetBy: 4)]; out.append(UInt8(d)!); i = lit.index(i, offsetBy: 4) }
            else { out.append(UInt8(lit[i].asciiValue!)); i = lit.index(after: i) }
        }
        try eq(out, all)
        try expect(!SlotWriter.luaSource(slot: 1, payload: all).contains("\n\n"))
    }
}
