import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest {
    public var method: String, url: URL, headers: [String: String], body: Data?
    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method; self.url = url; self.headers = headers; self.body = body
    }
}
public struct HTTPResponse {
    public var status: Int, headers: [String: String], body: Data
    public init(status: Int, headers: [String: String], body: Data) { self.status = status; self.headers = headers; self.body = body }
    public func header(_ name: String) -> String? { headers.first { $0.key.lowercased() == name.lowercased() }?.value }
}
public protocol HTTPTransport { func send(_ r: HTTPRequest) throws -> HTTPResponse }

public enum T3Error: Error, Equatable {
    case unreachable(String)        // network/timeout: outcome of a mutation is unknown, idempotent retry is safe
    case unauthorized               // bearer missing, expired or revoked
    case tool(code: String, message: String) // definitive refusal from T3
    case protocolError(String)
}

/// Blocking HTTP over URLSession, no redirects followed, no cookies, short timeouts.
public final class URLSessionTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.httpCookieStorage = nil
        c.urlCache = nil
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()
    public override init() {}
    public func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse, newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    public func send(_ r: HTTPRequest) throws -> HTTPResponse {
        var req = URLRequest(url: r.url)
        req.httpMethod = r.method
        req.httpBody = r.body
        for (k, v) in r.headers { req.setValue(v, forHTTPHeaderField: k) }
        let sem = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var out: Result<HTTPResponse, Error> = .failure(T3Error.unreachable("no response")) }
        let box = Box()
        session.dataTask(with: req) { data, resp, err in
            if let err { box.out = .failure(T3Error.unreachable(err.localizedDescription)) }
            else if let h = resp as? HTTPURLResponse {
                var headers: [String: String] = [:]
                for (k, v) in h.allHeaderFields { headers["\(k)"] = "\(v)" }
                box.out = .success(HTTPResponse(status: h.statusCode, headers: headers, body: data ?? Data()))
            }
            sem.signal()
        }.resume()
        sem.wait()
        return try box.out.get()
    }
}

/// Minimal MCP (streamable HTTP, JSON-RPC 2.0) client for T3's `/mcp` endpoint.
public final class MCPClient {
    public let endpoint: URL
    private let transport: HTTPTransport
    private let token: () -> String?
    private var sessionId: String?
    private var initialized = false
    private var nextId = 1

    public init(endpoint: URL, transport: HTTPTransport, token: @escaping () -> String?) {
        self.endpoint = endpoint; self.transport = transport; self.token = token
    }

    func rpc(_ method: String, _ params: [String: Any], notification: Bool = false) throws -> [String: Any]? {
        guard let bearer = token() else { throw T3Error.unauthorized }
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        let id = nextId
        if !notification { body["id"] = id; nextId += 1 }
        var headers = ["authorization": "Bearer \(bearer)", "content-type": "application/json",
                       "accept": "application/json, text/event-stream", "mcp-protocol-version": "2025-06-18"]
        if let sessionId { headers["mcp-session-id"] = sessionId }
        let resp = try transport.send(HTTPRequest(method: "POST", url: endpoint, headers: headers, body: try JSONSerialization.data(withJSONObject: body)))
        if resp.status == 401 || resp.status == 403 { initialized = false; sessionId = nil; throw T3Error.unauthorized }
        if resp.status == 404 && sessionId != nil { initialized = false; sessionId = nil; throw T3Error.unreachable("MCP session expired") }
        if let sid = resp.header("mcp-session-id") { sessionId = sid }
        if notification { return nil }
        guard (200..<300).contains(resp.status) else { throw T3Error.unreachable("HTTP \(resp.status)") }
        return try Self.decodeMessage(resp, id: id)
    }

    static func decodeMessage(_ resp: HTTPResponse, id: Int) throws -> [String: Any] {
        let text = String(decoding: resp.body, as: UTF8.self)
        var candidates: [String] = []
        if (resp.header("content-type") ?? "").contains("text/event-stream") || text.hasPrefix("event:") || text.hasPrefix("data:") {
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) where line.hasPrefix("data:") {
                candidates.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        } else { candidates = [text] }
        for c in candidates {
            if let obj = try? JSONSerialization.jsonObject(with: Data(c.utf8)) as? [String: Any], (obj["id"] as? Int) == id { return obj }
        }
        throw T3Error.protocolError("no JSON-RPC response")
    }

    func ensureInitialized() throws {
        if initialized { return }
        let r = try rpc("initialize", ["protocolVersion": "2025-06-18", "capabilities": [String: Any](),
                                       "clientInfo": ["name": "t3-for-wow", "version": BridgeVersion.string]])
        guard r?["result"] != nil else { throw T3Error.protocolError("initialize failed") }
        _ = try rpc("notifications/initialized", [:], notification: true)
        initialized = true
    }

    /// Calls an MCP tool and returns its structured content. Tool-level errors become `.tool`.
    public func call(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
        try ensureInitialized()
        guard let msg = try rpc("tools/call", ["name": name, "arguments": args]) else { throw T3Error.protocolError("empty") }
        if let err = msg["error"] as? [String: Any] {
            throw T3Error.tool(code: "rpc_\(err["code"] ?? "")", message: (err["message"] as? String) ?? "MCP error")
        }
        guard let result = msg["result"] as? [String: Any] else { throw T3Error.protocolError("no result") }
        let text = ((result["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        if (result["isError"] as? Bool) == true {
            if let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                throw T3Error.tool(code: (obj["code"] as? String) ?? "error", message: (obj["message"] as? String) ?? text)
            }
            throw T3Error.tool(code: "error", message: text)
        }
        if let s = result["structuredContent"] as? [String: Any] { return s }
        if let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] { return obj }
        throw T3Error.protocolError("no structured content")
    }
}

public enum BridgeVersion { public static let string = "0.9.1" }
