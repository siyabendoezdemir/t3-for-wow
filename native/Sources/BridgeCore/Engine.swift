import Foundation

/// What the engine needs from T3. Implemented by `T3Tools` (real MCP) and by fakes in tests.
public protocol T3API: AnyObject {
    func call(_ tool: String, _ args: [String: Any]) throws -> [String: Any]
}
extension MCPClient: T3API {}

/// Where deliveries go (slot files in production, memory in tests).
public protocol SlotSink: AnyObject { func write(slot: Int, payload: [UInt8]) throws }
extension SlotWriter {
    public final class Sink: SlotSink {
        let w: SlotWriter
        public init(_ w: SlotWriter) { self.w = w }
        public func write(slot: Int, payload: [UInt8]) throws { try w.write(slot: slot, payload: payload) }
    }
}

public enum AccessRank {
    /// linkAccess is `T3Grant.access`. Only refusals T3 would certainly make are predicted here;
    /// everything else is left to T3, which enforces its own ceiling and explains refusals.
    public static func canReply(linkAccess: String, threadMode: String) -> Bool {
        switch linkAccess {
        case "full-access": return true
        case "operate": return threadMode != "full-access"
        default: return false
        }
    }
}

public final class Engine {
    public struct Config {
        public var threadLimit = 60
        public var historyPage = 30
        public var maxMessageChars = 4000
        public var maxActivityChars = 300
        public var maxItemsPerThread = 80
        public var listEverySeconds = 5.0
        public var watchEverySeconds = 3.0
        public var projectsEverySeconds = 60.0
        public var maxDeliveryBytes = 60_000
        public var gameIdleAfter = 30.0
        public init() {}
    }

    /// verifying = saved grant, not yet confirmed by T3; originChanged = the grant belongs to another T3 address.
    public enum LinkState: String { case verifying, connected, unreachable, unpaired, revoked, expired, originChanged }
    public var verifyEverySeconds = 60.0
    var lastVerify: Double = -1e18
    /// Last slot write failure (nil after a successful write). Surfaced to the owner, never swallowed.
    public private(set) var slotWriteError: String?

    public let epoch: UInt32
    public var config = Config()
    public let store = RecordStore()
    let ledger: SendLedger
    let slots: SlotSink
    let clock: () -> Double
    public var t3: T3API?
    public var grant: T3Grant?

    // game state
    public private(set) var gameSession: UInt32?
    public internal(set) var ackVersion: UInt32 = 0
    public internal(set) var nextSlot = 0
    var lastFrameAt: Double = -1e18
    var lastWritten: (slot: Int, version: UInt32, session: UInt32)?
    var partial: [UInt32: (count: Int, parts: [Int: [UInt8]], firstSeen: Double)] = [:]
    var handled: Set<UInt32> = []
    var watched: [String] = []

    // T3 state
    public private(set) var link: LinkState = .unpaired
    var notice = ""
    public internal(set) var t3CheckedAt: Double = 0
    var lastList: Double = -1e18, lastProjects: Double = -1e18, lastWatch: Double = -1e18
    var threadUpdated: [String: String] = [:]
    var latestModel: [String: (instance: String, model: String, at: String)] = [:]
    public private(set) var stats = Stats()

    public struct Stats: Codable { public var frames = 0, badFrames = 0, requests = 0, sends = 0, slotWrites = 0, t3Calls = 0, t3Errors = 0 }

    public init(epoch: UInt32 = UInt32.random(in: 1...UInt32.max), ledger: SendLedger, slots: SlotSink, clock: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.epoch = epoch; self.ledger = ledger; self.slots = slots; self.clock = clock
        publishStatus()
    }

    public func setLink(_ api: T3API?, grant: T3Grant?) {
        t3 = api; self.grant = grant
        link = api == nil ? .unpaired : .verifying
        notice = api == nil ? "Open the T3 for WoW app on this Mac to connect your T3." : ""
        lastVerify = -1e18
        publishStatus()
    }

    /// The saved approval is for a different T3 address: no client, no token sent, owner must approve.
    public func setOriginChanged() {
        t3 = nil; grant = nil
        link = .originChanged
        notice = "Your T3's address changed. Open the T3 for WoW app and approve this T3."
        publishStatus()
    }

    // MARK: status

    func publishStatus() {
        let access = grant?.access ?? "none"
        store.put("st", ["st", "online", link.rawValue, String(Int(t3CheckedAt)), notice, String(Int(grant?.expiresAt ?? 0)), access, "0"])
    }

    // MARK: frames

    public func onFrame(_ f: GameFrame) {
        let now = clock()
        stats.frames += 1
        lastFrameAt = now
        if gameSession != f.gameSession {
            // New UI session: the game's model is empty; its reqIds restart.
            gameSession = f.gameSession
            store.purge(prefix: "r:")
            partial = [:]; handled = []; watched = []
            ackVersion = 0
            retryPendingSends()
        }
        ackVersion = f.epochAck == epoch ? f.deliveryAck : 0
        store.pruneTombstones(acked: ackVersion)
        nextSlot = f.nextSlot
        for c in f.chunks { accept(c, now: now) }
        partial = partial.filter { now - $0.value.firstSeen < 60 }
    }

    func accept(_ c: GameFrame.Chunk, now: Double) {
        if handled.contains(c.reqId) { return }
        var p = partial[c.reqId] ?? (count: c.count, parts: [:], firstSeen: now)
        guard p.count == c.count, partial.count < 16 || partial[c.reqId] != nil else { return }
        p.parts[c.index] = c.data
        partial[c.reqId] = p
        guard p.parts.count == p.count else { return }
        partial[c.reqId] = nil
        handled.insert(c.reqId)
        let body = (0..<p.count).flatMap { p.parts[$0]! }
        guard body.count <= 4096 + 512, let fields = Codec.parseStrings(body, maxFields: 8), let kind = fields.first else {
            reply(c.reqId, "rejected", "Unreadable request", nil, nil); return
        }
        stats.requests += 1
        handle(reqId: c.reqId, kind: kind, fields: Array(fields.dropFirst()))
    }

    func reply(_ reqId: UInt32, _ state: String, _ detail: String, _ threadId: String?, _ messageId: String?) {
        store.put("r:\(reqId)", ["r", String(reqId), state, detail, threadId ?? "", messageId ?? ""])
    }

    func key(_ reqId: UInt32) -> String { String(format: "wow:%08x:%u", gameSession ?? 0, reqId) }

    func handle(reqId: UInt32, kind: String, fields: [String]) {
        switch (kind, fields.count) {
        case ("W", 1):
            let id = fields[0]
            watched.removeAll { $0 == id }
            watched.insert(id, at: 0)
            if watched.count > 3 { watched.removeLast() }
            reply(reqId, "done", "", id, nil)
            refreshThreadItems(id, force: true)
        case ("H", 2):
            reply(reqId, "done", "", fields[0], nil)
            olderPage(fields[0], before: Int(fields[1]) ?? 0)
        case ("Z", 0):
            ackVersion = 0
            reply(reqId, "done", "", nil, nil)
        case ("S", 2):
            sendOnce(reqId: reqId, kind: "S", target: fields[0], title: nil, text: fields[1])
        case ("N", 3):
            sendOnce(reqId: reqId, kind: "N", target: fields[0], title: fields[1], text: fields[2])
        default:
            reply(reqId, "rejected", "Unknown request", nil, nil)
        }
    }

    // MARK: exactly-once mutations

    func sendOnce(reqId: UInt32, kind: String, target: String, title: String?, text: String) {
        let k = key(reqId)
        guard let grant, t3 != nil else {
            reply(reqId, "failed", "Not connected to T3 — nothing was sent.", kind == "S" ? target : nil, nil); return
        }
        if let e = ledger.get(k) {
            if e.state != "sending" || e.namespace != grant.fingerprint {
                reply(reqId, e.namespace == grant.fingerprint ? e.state : "unknown", e.detail ?? "", e.threadId, e.messageId)
                return
            }
        } else {
            try? ledger.set(k, .init(state: "sending", namespace: grant.fingerprint, threadId: kind == "S" ? target : nil, messageId: nil,
                                     detail: kind == "N" ? "new:\(target)\u{1F}\(title ?? "")\u{1F}\(text)" : text, updatedAt: clock()))
        }
        reply(reqId, "sending", "", kind == "S" ? target : nil, nil)
        stats.sends += 1
        perform(k, reqId: reqId, kind: kind, target: target, title: title, text: text)
    }

    func perform(_ k: String, reqId: UInt32?, kind: String, target: String, title: String?, text: String) {
        guard let t3, let grant else { return }
        let args: [String: Any]
        let tool: String
        if kind == "S" { tool = "t3_thread_send"; args = ["threadId": target, "message": text, "mode": "queue", "clientRequestId": k] }
        else {
            tool = "t3_thread_launch"
            var a: [String: Any] = ["projectId": target, "message": text, "clientRequestId": k]
            if let title, !title.isEmpty { a["title"] = String(title.prefix(80)) }
            args = a
        }
        stats.t3Calls += 1
        do {
            var modelNote = ""
            let r: [String: Any]
            do { r = try t3.call(tool, args) }
            catch T3Error.tool(_, let message) where kind == "N" && message.contains("no default model") {
                // Never pick a model silently: reuse the owner's own latest choice in this project, and say so.
                guard let m = latestModel[target] else {
                    throw T3Error.tool(code: "no_default_model", message: "This project has no default model and no earlier thread to copy one from. Set a default model for it in T3.")
                }
                var a2 = args; a2["modelSelection"] = ["instanceId": m.instance, "model": m.model]
                r = try t3.call(tool, a2)
                modelNote = " Using \(m.model), like your latest thread in this project."
            }
            let threadId = (r["threadId"] as? String) ?? (kind == "S" ? target : nil)
            let delivery = r["delivery"] as? String
            let state = delivery == "queued" ? "queued" : "accepted"
            let detail = delivery == "queued" ? "Queued — T3 runs it after the current turn." : (kind == "N" ? "Thread created." + modelNote : "Delivered to T3.")
            try? ledger.set(k, .init(state: state, namespace: grant.fingerprint, threadId: threadId, messageId: r["messageId"] as? String, detail: detail, updatedAt: clock()))
            if let reqId { reply(reqId, state, detail, threadId, r["messageId"] as? String) }
            lastList = -1e18 // refresh the list soon
            if let threadId, kind == "N" { watched.insert(threadId, at: 0) }
        } catch T3Error.tool(let code, let message) {
            let state = code == "runtime_mode_escalation_denied" || code.hasPrefix("capability") ? "rejected" : "failed"
            let detail = code == "runtime_mode_escalation_denied"
                ? "This thread runs with Full access and your WoW link does not. Reply in T3, or use \"Reconnect with Full access…\" in the T3 for WoW app."
                : message
            try? ledger.set(k, .init(state: state, namespace: grant.fingerprint, threadId: kind == "S" ? target : nil, messageId: nil, detail: detail, updatedAt: clock()))
            if let reqId { reply(reqId, state, detail, kind == "S" ? target : nil, nil) }
            stats.t3Errors += 1
        } catch T3Error.unauthorized {
            linkLost(.revoked)
            if let reqId { reply(reqId, "sending", "Waiting for T3 access — will retry with the same key.", kind == "S" ? target : nil, nil) }
        } catch {
            // Outcome unknown at T3, but retrying with the same clientRequestId is idempotent there.
            link = .unreachable; notice = "T3 is not answering."; publishStatus()
            if let reqId { reply(reqId, "sending", "T3 not reachable — will retry with the same key.", kind == "S" ? target : nil, nil) }
            stats.t3Errors += 1
        }
    }

    /// Ledger entries still `sending` under the current bearer are retried (idempotent at T3);
    /// entries from a previous bearer become `unknown` and are never re-sent.
    func retryPendingSends() {
        guard let grant else { return }
        for (k, e) in ledger.entries where e.state == "sending" {
            if e.namespace != grant.fingerprint {
                try? ledger.set(k, .init(state: "unknown", namespace: e.namespace, threadId: e.threadId, messageId: nil,
                                         detail: "Sent before T3 was re-approved; it may or may not have arrived. Check the thread.", updatedAt: clock()))
                continue
            }
            if let tid = e.threadId, let text = e.detail { perform(k, reqId: nil, kind: "S", target: tid, title: nil, text: text) }
            else if let d = e.detail, d.hasPrefix("new:") {
                let parts = d.dropFirst(4).split(separator: "\u{1F}", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                if parts.count == 3 { perform(k, reqId: nil, kind: "N", target: parts[0], title: parts[1], text: parts[2]) }
            }
        }
    }

    func linkLost(_ s: LinkState) {
        link = s
        t3 = nil // stop calling T3 with a dead credential until the owner reconnects
        notice = s == .expired ? "Your WoW link to T3 expired. Open the T3 for WoW app and approve it again."
                               : "T3 no longer accepts this WoW link. Open the T3 for WoW app to reconnect."
        publishStatus()
    }

    // MARK: polling T3

    public var gameActive: Bool { clock() - lastFrameAt < config.gameIdleAfter }

    /// Call regularly (e.g. every second). Polls T3 only while the game is active.
    public func tick() {
        let now = clock()
        if let g = grant, now >= g.expiresAt, link != .expired { linkLost(.expired); t3 = nil }
        // Verify the link with a harmless read even when the game is closed, so a saved but revoked or
        // unreachable approval is never shown as connected.
        if t3 != nil, link == .verifying || (!gameActive && now - lastVerify >= verifyEverySeconds) {
            lastVerify = now
            _ = t3call("t3_project_list", ["limit": 1])
        }
        guard t3 != nil, gameActive else { return }
        if now - lastProjects >= config.projectsEverySeconds { lastProjects = now; refreshProjects() }
        if now - lastList >= config.listEverySeconds { lastList = now; refreshThreads() }
        if now - lastWatch >= config.watchEverySeconds {
            lastWatch = now
            for id in watched { refreshThreadItems(id, force: false) }
        }
    }

    func t3call(_ tool: String, _ args: [String: Any]) -> [String: Any]? {
        guard let t3 else { return nil }
        stats.t3Calls += 1
        do {
            let r = try t3.call(tool, args)
            if link != .connected { link = .connected; notice = ""; retryPendingSends() }
            t3CheckedAt = clock()
            publishStatus()
            return r
        } catch T3Error.unauthorized {
            stats.t3Errors += 1; linkLost(.revoked); return nil
        } catch T3Error.tool(let code, let message) {
            stats.t3Errors += 1
            if code == "thread_not_found", let id = args["threadId"] as? String { forgetThread(id) }
            else { notice = message; publishStatus() }
            return nil
        } catch {
            stats.t3Errors += 1
            if link != .unreachable { link = .unreachable; notice = "T3 is not answering."; publishStatus() }
            return nil
        }
    }

    func refreshProjects() {
        guard let r = t3call("t3_project_list", ["limit": 100]), let ps = r["projects"] as? [[String: Any]] else { return }
        let live = Set(ps.compactMap { $0["id"] as? String })
        for p in ps { if let id = p["id"] as? String { store.put("p:\(id)", ["p", id, clip((p["title"] as? String) ?? "Project", 80)]) } }
        for k in store.keys(prefix: "p:") where !live.contains(String(k.dropFirst(2))) { store.remove(k) }
    }

    func refreshThreads() {
        guard let r = t3call("t3_thread_list", ["allProjects": true, "limit": config.threadLimit, "includeSubagents": false]),
              let ts = r["threads"] as? [[String: Any]] else { return }
        var order: [String] = []
        for t in ts {
            guard let id = t["threadId"] as? String else { continue }
            order.append(id)
            putThread(t)
            if let pid = t["projectId"] as? String, let inst = t["providerInstanceId"] as? String, let model = t["model"] as? String {
                let at = (t["createdAt"] as? String) ?? ""
                if (latestModel[pid]?.at ?? "") <= at { latestModel[pid] = (inst, model, at) }
            }
            if let u = t["updatedAt"] as? String, threadUpdated[id] != u {
                threadUpdated[id] = u
                if watched.contains(id) { lastWatch = -1e18 }
            }
        }
        let live = Set(order)
        for k in store.keys(prefix: "t:") where !live.contains(String(k.dropFirst(2))) && !watched.contains(String(k.dropFirst(2))) { forgetThread(String(k.dropFirst(2))) }
        store.put("tl", ["tl"] + order.prefix(60))
    }

    func putThread(_ t: [String: Any], summary: String? = nil) {
        guard let id = t["threadId"] as? String else { return }
        let status = (t["status"] as? String) ?? "unknown"
        let pending = (t["pendingRequestCount"] as? Int) ?? Int(store.get("t:\(id)")?[5] ?? "0") ?? 0
        let mode = (t["runtimeMode"] as? String) ?? "unknown"
        let access = store.get("st")?[6] ?? "none"
        var sum = summary ?? store.get("t:\(id)")?[10] ?? ""
        if pending > 0 { sum = pending == 1 ? "1 request waiting — answer it in T3" : "\(pending) requests waiting — answer them in T3" }
        else if summary == nil, status == "waiting", sum.isEmpty { sum = "Waiting" }
        store.put("t:\(id)", ["t", id, (t["projectId"] as? String) ?? "", clip((t["title"] as? String) ?? "Thread", 120), status, String(pending),
                              String(Int(Self.parseDate(t["updatedAt"] as? String) ?? 0)), ((t["settled"] as? Bool) ?? false) ? "1" : "0", mode,
                              AccessRank.canReply(linkAccess: access, threadMode: mode) ? "1" : "0", clip(sum, 160)])
    }

    /// Visible, unsettled threads this link cannot reply to (T3's ceiling, predicted conservatively).
    public var threadsAboveAccess: Int {
        store.keys(prefix: "t:").filter { k in
            guard let r = store.get(k) else { return false }
            return r[9] == "0" && r[7] == "0"
        }.count
    }

    func forgetThread(_ id: String) {
        store.remove("t:\(id)")
        for k in store.keys(prefix: "m:\(id):") { store.remove(k) }
        store.remove("h:\(id)")
        watched.removeAll { $0 == id }
    }

    func refreshThreadItems(_ id: String, force: Bool) {
        guard let head = t3call("t3_thread_read", ["threadId": id, "view": "activity", "limit": 1, "maxCharsPerItem": 1, "runLimit": 1]),
              let thread = head["thread"] as? [String: Any] else { return }
        let count = (thread["itemCount"] as? Int) ?? 0
        let start = max(0, count - config.historyPage)
        var args: [String: Any] = ["threadId": id, "view": "activity", "limit": config.historyPage, "maxCharsPerItem": config.maxMessageChars, "runLimit": 1]
        if start > 0 { args["afterPosition"] = start - 1 }
        guard let page = t3call("t3_thread_read", args) else { return }
        let items = (page["items"] as? [[String: Any]]) ?? []
        for it in items { putItem(id, it) }
        let summary = items.last { ($0["type"] as? String).map { !["user_message", "assistant_message"].contains($0) } ?? false }?["title"] as? String
        putThread(thread, summary: summary.map { clip($0, 160) })
        let oldest = store.keys(prefix: "m:\(id):").compactMap { Int(store.get($0)?[3] ?? "") }.min() ?? start
        if store.get("h:\(id)") == nil || force { store.put("h:\(id)", ["h", id, String(oldest), oldest > 0 ? "1" : "0", "0"]) }
        trimItems(id)
    }

    func olderPage(_ id: String, before: Int) {
        guard before > 0 else { return }
        let start = max(0, before - config.historyPage)
        var args: [String: Any] = ["threadId": id, "view": "activity", "limit": before - start, "maxCharsPerItem": config.maxMessageChars, "runLimit": 1]
        if start > 0 { args["afterPosition"] = start - 1 }
        guard let page = t3call("t3_thread_read", args) else { return }
        for it in (page["items"] as? [[String: Any]]) ?? [] where ((it["position"] as? Int) ?? Int.max) < before { putItem(id, it) }
        store.put("h:\(id)", ["h", id, String(start), start > 0 ? "1" : "0", "0"])
    }

    func putItem(_ threadId: String, _ it: [String: Any]) {
        guard let itemId = it["itemId"] as? String, let pos = it["position"] as? Int else { return }
        let type = (it["type"] as? String) ?? "activity"
        let kind: String
        switch type {
        case "user_message": kind = "user"
        case "assistant_message": kind = "assistant"
        case "plan": kind = "plan"
        case "error": kind = "error"
        default: kind = "activity"
        }
        let messageId = (it["messageId"] as? String) ?? ""
        let author: String
        if kind == "user" { author = messageId.contains("thread-send:wow%3A") || messageId.contains("thread-send:wow:") ? "wow" : ((it["createdBy"] as? String) == "user" ? "you" : "agent") }
        else { author = kind == "assistant" ? "t3" : "tool" }
        var text = (it["text"] as? String) ?? ""
        var truncated = (it["textTruncated"] as? Bool) ?? false
        if kind == "activity" {
            let title = (it["title"] as? String) ?? type.replacingOccurrences(of: "_", with: " ")
            let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
            text = firstLine.isEmpty || firstLine == title ? title : "\(title): \(firstLine)"
            if text.count > config.maxActivityChars { text = String(text.prefix(config.maxActivityChars)); truncated = true }
        } else if text.count > config.maxMessageChars { text = String(text.prefix(config.maxMessageChars)); truncated = true }
        store.put("m:\(threadId):\(itemId)", ["m", threadId, itemId, String(pos), kind, (it["status"] as? String) ?? "", author,
                                              String(Int(Self.parseDate(it["updatedAt"] as? String) ?? 0)), text, truncated ? "1" : "0"])
    }

    func trimItems(_ id: String) {
        let keys = store.keys(prefix: "m:\(id):").map { ($0, Int(store.get($0)?[3] ?? "") ?? 0) }.sorted { $0.1 < $1.1 }
        guard keys.count > config.maxItemsPerThread else { return }
        for (k, _) in keys.prefix(keys.count - config.maxItemsPerThread) { store.remove(k) }
        let oldest = keys[keys.count - config.maxItemsPerThread].1
        store.put("h:\(id)", ["h", id, String(oldest), oldest > 0 ? "1" : "0", "0"])
    }

    // MARK: delivery

    /// Builds the payload for `slot` from the current store; nil if nothing is known about the game.
    public func deliveryPayload(slot: Int) -> [UInt8]? {
        guard let s = gameSession else { return nil }
        let ch = store.changes(since: ackVersion, maxBytes: config.maxDeliveryBytes)
        var fields: [[UInt8]] = [Array("T3D1".utf8), Array(String(slot).utf8), Array(String(epoch).utf8), Array(String(s).utf8),
                                 Array(String(ch.version).utf8), Array((ch.more ? "1" : "0").utf8), Array(String(Int(clock())).utf8), Array(String(ch.records.count).utf8)]
        for r in ch.records { fields.append(Codec.netstrings(r)) }
        return Codec.netstringsBytes(fields)
    }

    /// Writes the slot the game will load next whenever state changed. Returns true if written.
    @discardableResult
    public func flush() -> Bool {
        guard let s = gameSession, nextSlot > 0 else { return false }
        if let w = lastWritten, w.slot == nextSlot, w.version == store.version, w.session == s { return false }
        guard let payload = deliveryPayload(slot: nextSlot) else { return false }
        do {
            try slots.write(slot: nextSlot, payload: payload)
            lastWritten = (nextSlot, store.version, s)
            stats.slotWrites += 1
            slotWriteError = nil
            return true
        } catch {
            slotWriteError = "delivery slot \(nextSlot) could not be written (\(error.localizedDescription))"
            return false
        }
    }

    // MARK: helpers

    static func parseDate(_ s: String?) -> Double? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d.timeIntervalSince1970 }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)?.timeIntervalSince1970
    }
}

func clip(_ s: String, _ n: Int) -> String {
    let flat = s.replacingOccurrences(of: "\n", with: " ")
    return flat.count <= n ? flat : String(flat.prefix(n - 1)) + "…"
}
