import Foundation
@testable import BridgeCore

/// Fake T3 replaying the shapes recorded from a real T3 v0.1.7 server (tests/fixtures/t3-0.1.7),
/// with idempotency keyed like T3 (namespace + clientRequestId). SYNTHETIC.
final class FakeT3: T3API {
    var calls: [(String, [String: Any])] = []
    var failNext: Error?
    var sentKeys: [String: [String: Any]] = [:]
    var threads = fixture("t3_thread_list")
    var projects = fixture("t3_project_list")
    var readActivity = fixture("t3_thread_read-activity")
    func call(_ tool: String, _ args: [String: Any]) throws -> [String: Any] {
        calls.append((tool, args))
        if let e = failNext { failNext = nil; throw e }
        switch tool {
        case "t3_thread_list": return threads
        case "t3_project_list": return projects
        case "t3_thread_read": return readActivity
        case "t3_thread_send", "t3_thread_launch":
            let key = args["clientRequestId"] as! String
            if let prior = sentKeys[key] { return prior }
            var r = fixture(tool == "t3_thread_send" ? "t3_thread_send" : "t3_thread_launch")
            r["messageId"] = "message:\(key)"
            if tool == "t3_thread_send" { r["threadId"] = args["threadId"] }
            sentKeys[key] = r
            return r
        default: throw T3Error.tool(code: "unknown", message: tool)
        }
    }
    func count(_ tool: String) -> Int { calls.filter { $0.0 == tool }.count }
}

final class MemorySlots: SlotSink {
    var written: [Int: [UInt8]] = [:]
    func write(slot: Int, payload: [UInt8]) throws { written[slot] = payload }
}

let grantA = T3Grant(accessToken: "token-A-not-real", expiresAt: 4_000_000_000, scope: "orchestration:read orchestration:operate", origin: URL(string: "http://127.0.0.1:1")!)
let grantB = T3Grant(accessToken: "token-B-not-real", expiresAt: 4_000_000_000, scope: "orchestration:read orchestration:operate", origin: URL(string: "http://127.0.0.1:1")!)

func frame(session: UInt32 = 77, epochAck: UInt32 = 0, ack: UInt32 = 0, next: Int = 1, _ reqs: [(UInt32, [String])] = []) -> GameFrame {
    GameFrame(rows: 0, gameSession: session, frameSeq: 1, epochAck: epochAck, deliveryAck: ack, nextSlot: next, slotCount: 480, flags: 4,
              chunks: reqs.map { .init(reqId: $0.0, index: 0, count: 1, data: Codec.netstrings($0.1)) })
}

/// Decode a delivery the way the addon does (header + record netstrings).
func decodeDelivery(_ p: [UInt8]) throws -> (version: UInt32, records: [[String]]) {
    guard let f = Codec.parseStrings(p), f.count >= 8, f[0] == "T3D1" else { throw Failure(description: "bad delivery") }
    let recs = try f.dropFirst(8).map { (b: String) -> [String] in
        guard let r = Codec.parseStrings(Array(b.utf8)) else { throw Failure(description: "bad record") }; return r
    }
    try eq(Int(f[7])!, recs.count)
    return (UInt32(f[4])!, recs)
}

func makeEngine(_ t3: FakeT3, ledger: URL? = nil, grant: T3Grant = grantA, clock: @escaping () -> Double = { 1_794_160_000 }) -> (Engine, MemorySlots) {
    let slots = MemorySlots()
    let e = Engine(epoch: 5, ledger: SendLedger(url: ledger), slots: slots, clock: clock)
    e.setLink(t3, grant: grant)
    return (e, slots)
}

func runEngineTests() {
    let tid = ((fixture("t3_thread_list")["threads"] as! [[String: Any]]).first { ($0["title"] as? String) == "Fixture thread" }!)["threadId"] as! String

    test("tracker records come from the real thread list shape") {
        let t3 = FakeT3(); let (e, slots) = makeEngine(t3)
        e.onFrame(frame()); e.tick(); try expect(e.flush())
        let d = try decodeDelivery(slots.written[1]!)
        let t = d.records.first { $0[0] == "t" }!
        try eq(t[1], tid); try eq(t[4], "failed"); try eq(t[8], "approval-required"); try eq(t[9], "1")
        try expect(!AccessRank.canReply(linkAccess: "operate", threadMode: "full-access"))
        try expect(AccessRank.canReply(linkAccess: "operate", threadMode: "auto"), "ambiguous cases are left to T3")
        try expect(!AccessRank.canReply(linkAccess: "read-only", threadMode: "approval-required"))
        try expect(d.records.contains { $0[0] == "p" && $0[2] == "Contract Fixture" })
        try expect(d.records.contains { $0[0] == "tl" && $0[1] == tid })
        let st = d.records.first { $0[0] == "st" }!
        try eq(st[2], "connected"); try eq(st[6], "operate")
    }

    test("a send reaches T3 once with the game identity as clientRequestId") {
        let t3 = FakeT3(); let (e, slots) = makeEngine(t3)
        e.onFrame(frame([(3, ["S", tid, "hello from WoW"])]))
        e.onFrame(frame([(3, ["S", tid, "hello from WoW"])])) // game re-shows until acked
        try eq(t3.count("t3_thread_send"), 1)
        let args = t3.calls.first { $0.0 == "t3_thread_send" }!.1
        try eq(args["clientRequestId"] as? String, "wow:0000004d:3")
        try eq(args["mode"] as? String, "queue"); try eq(args["threadId"] as? String, tid)
        e.flush()
        let r = try decodeDelivery(slots.written[1]!).records.first { $0[0] == "r" }!
        try eq(r[1], "3"); try eq(r[2], "accepted"); try eq(r[4], tid)
    }

    test("bridge restart: a re-shown request is answered from the ledger, not re-sent") {
        let dir = tmpDir(), url = dir.appendingPathComponent("ledger.json")
        let t3 = FakeT3()
        let (e1, _) = makeEngine(t3, ledger: url)
        e1.onFrame(frame([(9, ["S", tid, "once"])]))
        let (e2, slots2) = makeEngine(t3, ledger: url) // new process, same ledger + bearer
        e2.onFrame(frame([(9, ["S", tid, "once"])]))
        try eq(t3.count("t3_thread_send"), 1)
        e2.flush()
        try eq(try decodeDelivery(slots2.written[1]!).records.first { $0[0] == "r" }![2], "accepted")
    }

    test("T3 unreachable mid-send: retried with the SAME key; T3 dedupes; one message") {
        let dir = tmpDir(), url = dir.appendingPathComponent("ledger.json")
        let t3 = FakeT3(); t3.failNext = T3Error.unreachable("timeout")
        let (e, slots) = makeEngine(t3, ledger: url)
        e.onFrame(frame([(4, ["S", tid, "retry me"])]))
        e.flush()
        try eq(try decodeDelivery(slots.written[1]!).records.first { $0[0] == "r" }![2], "sending")
        e.tick() // T3 answers again -> link recovers -> pending send retried
        let keys = t3.calls.filter { $0.0 == "t3_thread_send" }.map { $0.1["clientRequestId"] as! String }
        try eq(Set(keys), ["wow:0000004d:4"]); try eq(t3.sentKeys.count, 1)
        try eq(SendLedger(url: url).get("wow:0000004d:4")?.state, "accepted")
    }

    test("after re-pairing, an in-flight send from the old bearer becomes unknown and is never re-sent") {
        let dir = tmpDir(), url = dir.appendingPathComponent("ledger.json")
        let t3 = FakeT3(); t3.failNext = T3Error.unreachable("down")
        let (e1, _) = makeEngine(t3, ledger: url, grant: grantA)
        e1.onFrame(frame([(5, ["S", tid, "maybe"])]))
        let (e2, slots2) = makeEngine(t3, ledger: url, grant: grantB)
        e2.onFrame(frame([(5, ["S", tid, "maybe"])]))
        try eq(t3.count("t3_thread_send"), 1, "only the original attempt")
        e2.flush()
        try eq(try decodeDelivery(slots2.written[1]!).records.first { $0[0] == "r" }![2], "unknown")
    }

    test("permission ceiling refusal is surfaced as rejected with guidance") {
        let t3 = FakeT3()
        t3.failNext = T3Error.tool(code: "runtime_mode_escalation_denied", message: "Child runtime mode full-access is broader than parent mode approval-required.")
        let (e, slots) = makeEngine(t3)
        e.onFrame(frame([(6, ["S", tid, "x"])])); e.flush()
        let r = try decodeDelivery(slots.written[1]!).records.first { $0[0] == "r" }!
        try eq(r[2], "rejected"); try expect(r[3].contains("Full access") && r[3].contains("Reconnect with Full access"))
    }

    test("new thread uses t3_thread_launch with project and key") {
        let t3 = FakeT3(); let (e, _) = makeEngine(t3)
        e.onFrame(frame([(8, ["N", "proj-1", "Title", "Start this"])]))
        let a = t3.calls.first { $0.0 == "t3_thread_launch" }!.1
        try eq(a["projectId"] as? String, "proj-1"); try eq(a["clientRequestId"] as? String, "wow:0000004d:8"); try eq(a["title"] as? String, "Title")
    }

    test("not connected: send fails explicitly and nothing is sent") {
        let slots = MemorySlots()
        let e = Engine(epoch: 5, ledger: SendLedger(url: nil), slots: slots, clock: { 1 })
        e.onFrame(frame([(1, ["S", tid, "x"])])); e.flush()
        let d = try decodeDelivery(slots.written[1]!)
        try eq(d.records.first { $0[0] == "r" }![2], "failed")
        try eq(d.records.first { $0[0] == "st" }![2], "unpaired")
    }

    test("revoked bearer → revoked state; expired grant → expired state") {
        let t3 = FakeT3(); t3.failNext = T3Error.unauthorized
        let (e, _) = makeEngine(t3)
        e.onFrame(frame()); e.tick()
        try eq(e.link, .revoked)
        let t3b = FakeT3(); var now = 1_794_160_000.0
        let g = T3Grant(accessToken: "t", expiresAt: now + 10, scope: "orchestration:read orchestration:operate", origin: URL(string: "http://x")!)
        let (e2, _) = makeEngine(t3b, grant: g, clock: { now })
        e2.onFrame(frame()); now += 11; e2.tick()
        try eq(e2.link, .expired)
    }

    test("watch delivers bounded recent history with authors; activity is compact") {
        let t3 = FakeT3(); let (e, slots) = makeEngine(t3)
        e.onFrame(frame([(2, ["W", tid])])); e.flush()
        let ms = try decodeDelivery(slots.written[1]!).records.filter { $0[0] == "m" }
        try expect(ms.count >= 4)
        let user = ms.first { $0[4] == "user" }!; try eq(user[8], "fixture: hello from the contract test")
        let act = ms.first { $0[4] == "activity" }!; try eq(act[8], "Workspace ready: $ Preparing workspace")
        try expect(ms.contains { $0[4] == "error" })
        try expect(ms.contains { $0[4] == "user" && $0[6] == "agent" }, "MCP-created messages are attributed honestly")
    }

    test("acks advance: a delivery after ack carries only newer records; new game session resets") {
        let t3 = FakeT3(); let (e, slots) = makeEngine(t3)
        e.onFrame(frame()); e.tick(); e.flush()
        let v = try decodeDelivery(slots.written[1]!).version
        e.onFrame(frame(epochAck: 5, ack: v, next: 2)); e.flush()
        try eq(try decodeDelivery(slots.written[2]!).records.count, 0)
        e.onFrame(frame(session: 78, next: 1)); e.flush()
        try expect(try decodeDelivery(slots.written[1]!).records.count > 3, "full state for the new UI session")
    }

    test("a stale epoch ack (bridge restarted) gets the full state") {
        let t3 = FakeT3(); let (e, slots) = makeEngine(t3)
        e.onFrame(frame()); e.tick()
        e.onFrame(frame(epochAck: 999, ack: 1_000_000, next: 4)); e.flush()
        try expect(try decodeDelivery(slots.written[4]!).records.count > 3)
    }

    test("game idle → no T3 polling") {
        var now = 1_794_160_000.0
        let t3 = FakeT3(); let (e, _) = makeEngine(t3, clock: { now })
        e.onFrame(frame()); e.tick()
        let n = t3.calls.count
        now += 120; e.tick()
        try eq(t3.calls.count, n + 1, "only one periodic verification while the game is closed")
        try eq(t3.calls.last!.0, "t3_project_list")
    }
}
