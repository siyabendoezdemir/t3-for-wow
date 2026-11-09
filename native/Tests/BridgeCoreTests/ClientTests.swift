import Foundation
@testable import BridgeCore

final class ScriptedHTTP: HTTPTransport {
    var handler: (HTTPRequest) -> HTTPResponse
    var requests: [HTTPRequest] = []
    init(_ h: @escaping (HTTPRequest) -> HTTPResponse) { handler = h }
    func send(_ r: HTTPRequest) throws -> HTTPResponse { requests.append(r); return handler(r) }
}
func json(_ status: Int, _ o: Any, headers: [String: String] = ["content-type": "application/json"]) -> HTTPResponse {
    HTTPResponse(status: status, headers: headers, body: try! JSONSerialization.data(withJSONObject: o))
}

func runClientTests() {
    test("MCP client: initialize once, SSE-framed tool result, bearer header, tool error mapping") {
        var inits = 0
        let http = ScriptedHTTP { r in
            let body = try! JSONSerialization.jsonObject(with: r.body!) as! [String: Any]
            let id = body["id"] as? Int ?? 0
            switch body["method"] as! String {
            case "initialize": inits += 1; return json(200, ["jsonrpc": "2.0", "id": id, "result": ["serverInfo": ["name": "t3"]]], headers: ["mcp-session-id": "s1", "content-type": "application/json"])
            case "notifications/initialized": return HTTPResponse(status: 202, headers: [:], body: Data())
            default:
                let name = (body["params"] as! [String: Any])["name"] as! String
                if name == "bad" {
                    return json(200, ["jsonrpc": "2.0", "id": id, "result": ["isError": true, "content": [["type": "text", "text": "{\"code\":\"thread_not_found\",\"message\":\"nope\"}"]]]])
                }
                let payload = String(data: try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": ["structuredContent": ["ok": 1]]]), encoding: .utf8)!
                return HTTPResponse(status: 200, headers: ["content-type": "text/event-stream"], body: Data("event: message\ndata: \(payload)\n\n".utf8))
            }
        }
        let c = MCPClient(endpoint: URL(string: "http://127.0.0.1:9/mcp")!, transport: http, token: { "tok" })
        try eq(try c.call("good", [:])["ok"] as? Int, 1)
        _ = try c.call("good", [:])
        try eq(inits, 1)
        try eq(http.requests.last!.headers["authorization"], "Bearer tok")
        try eq(http.requests.last!.headers["mcp-session-id"], "s1")
        do { _ = try c.call("bad", [:]); throw Failure(description: "no error") } catch T3Error.tool(let code, _) { try eq(code, "thread_not_found") }
    }
    test("MCP client: 401 → unauthorized") {
        let c = MCPClient(endpoint: URL(string: "http://127.0.0.1:9/mcp")!, transport: ScriptedHTTP { _ in HTTPResponse(status: 401, headers: [:], body: Data()) }, token: { "tok" })
        do { _ = try c.call("x", [:]); throw Failure(description: "no error") } catch T3Error.unauthorized {}
    }
    test("OAuth begin: discovery from recorded metadata, loopback redirect, S256 challenge, state, resource") {
        let prm = fixture("oauth-protected-resource-mcp"), asm = fixture("oauth-authorization-server")
        func fix(_ o: [String: Any]) -> [String: Any] {
            let s = String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!.replacingOccurrences(of: "<port>", with: "4567")
            return try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
        }
        var registered: [String: Any] = [:]
        let http = ScriptedHTTP { r in
            if r.url.path.hasSuffix("oauth-protected-resource/mcp") { return json(200, fix(prm)) }
            if r.url.path.hasSuffix("oauth-authorization-server") { return json(200, fix(asm)) }
            if r.url.path.hasSuffix("/register") { registered = try! JSONSerialization.jsonObject(with: r.body!) as! [String: Any]; return json(201, ["client_id": "cid"]) }
            return json(404, [:])
        }
        let p = try OAuthPairing.begin(origin: URL(string: "http://127.0.0.1:4567")!, redirectPort: 50123, transport: http)
        try eq(registered["redirect_uris"] as! [String], ["http://127.0.0.1:50123/t3wow/callback"])
        try eq(registered["client_name"] as? String, "T3 for WoW")
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: p.authorizeURL, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        try eq(q["code_challenge_method"], "S256"); try eq(q["resource"], "http://127.0.0.1:4567/mcp")
        try eq(q["code_challenge"], Hashing.base64URL(Hashing.sha256(Array(p.verifier.utf8))))
        try eq(p.authorizeURL.path, "/oauth/mcp/authorize")
    }
    test("OAuth complete: denial, state mismatch and exchange") {
        let p = PendingPairing(authorizeURL: URL(string: "http://x/a")!, clientId: "cid", redirectURI: "http://127.0.0.1:1/t3wow/callback", verifier: "v",
                               state: "s", tokenEndpoint: URL(string: "http://x/oauth/mcp/token")!, resource: "http://x/mcp", environmentOrigin: URL(string: "http://x")!)
        let http = ScriptedHTTP { r in
            let form = String(data: r.body!, encoding: .utf8)!
            return form.contains("code=good") ? json(200, ["access_token": "AT", "token_type": "Bearer", "expires_in": 2_592_000, "scope": "orchestration:operate orchestration:read"])
                                              : json(400, ["error": "invalid_grant", "error_description": "The code is unknown."])
        }
        do { _ = try OAuthPairing.complete(p, callbackQuery: ["state": "s", "error": "access_denied"], transport: http, now: 0); throw Failure(description: "x") } catch PairingError.denied {}
        do { _ = try OAuthPairing.complete(p, callbackQuery: ["state": "evil", "code": "good"], transport: http, now: 0); throw Failure(description: "x") } catch PairingError.stateMismatch {}
        let g = try OAuthPairing.complete(p, callbackQuery: ["state": "s", "code": "good"], transport: http, now: 100)
        try eq(g.expiresAt, 100 + 2_592_000); try eq(g.access, "operate")
        do { _ = try OAuthPairing.complete(p, callbackQuery: ["state": "s", "code": "bad"], transport: http, now: 0); throw Failure(description: "x") } catch PairingError.exchange(let m) { try eq(m, "The code is unknown.") }
    }
}
