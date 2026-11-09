// Exercises the REAL T3 Code server contracts the WoW bridge depends on, against a THROWAWAY
// isolated server (see start.sh). Nothing here touches the owner's real T3.
//
//   node tests/isolated-t3/contract.mjs <t3-binary> <workdir> <fixtures-out-dir>
//
// Every assertion is about observed server behaviour. Recorded fixtures are sanitized
// (tokens, cookies, codes, client ids, absolute temp paths replaced) and later replayed by the
// bridge codec tests. Exit code 0 only if every check passed.
import { spawnSync, execFileSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { readFileSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

const [T3, WORK, OUT] = process.argv.slice(2);
if (!T3 || !WORK || !OUT) { console.error("usage: contract.mjs <t3> <workdir> <fixtures-out>"); process.exit(64); }
const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, "../..");
rmSync(WORK, { recursive: true, force: true });
mkdirSync(OUT, { recursive: true });

const results = [];
let socketDrops = 0;
const secrets = new Set();
let failed = 0;
function check(name, ok, detail = "") {
  results.push({ name, ok: !!ok, detail: String(detail).slice(0, 300) });
  if (!ok) failed++;
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail && !ok ? "  -- " + String(detail).slice(0, 300) : ""}`);
}
function sanitize(value) {
  let s = JSON.stringify(value, null, 2);
  for (const secret of secrets) if (secret && secret.length >= 8) s = s.split(secret).join("<redacted>");
  s = s.split(WORK).join("<work>");
  // never record where this machine keeps the checkout or the user's home (recorded fixtures are public)
  s = s.split(REPO).join("<repo>").split(homedir()).join("<home>");
  s = s.replace(/127\.0\.0\.1:\d+/g, "127.0.0.1:<port>");
  return JSON.parse(s);
}
function record(name, value) { writeFileSync(join(OUT, `${name}.json`), JSON.stringify(sanitize(value), null, 2) + "\n"); }

function start() {
  const r = spawnSync(join(HERE, "start.sh"), [T3, WORK], { encoding: "utf8" });
  if (r.status !== 0) throw new Error("isolated server failed to start: " + r.stderr);
  return Number(readFileSync(join(WORK, "port"), "utf8"));
}
function stop() {
  try { process.kill(Number(readFileSync(join(WORK, "server.pid"), "utf8")), "SIGTERM"); } catch {}
}
function cli(args) {
  return execFileSync(T3, [...args, "--base-dir", join(WORK, "base")], {
    encoding: "utf8",
    env: { HOME: join(WORK, "home"), PATH: "/usr/bin:/bin", T3CODE_TELEMETRY_ENABLED: "false", T3CODE_OTEL_SDK_DISABLED: "true" },
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let PORT = start();
let BASE = `http://127.0.0.1:${PORT}`;
async function http(method, path, { headers = {}, body, form, redirect = "manual" } = {}) {
  const init = { method, headers: { ...headers }, redirect };
  if (body !== undefined) { init.body = JSON.stringify(body); init.headers["content-type"] = "application/json"; }
  if (form !== undefined) { init.body = new URLSearchParams(form).toString(); init.headers["content-type"] = "application/x-www-form-urlencoded"; }
  let res;
  try { res = await fetch(BASE + path, init); }
  catch (e) {
    // T3 closes the open connections of a revoked session; a pooled socket then dies. Retry once fresh.
    if (String(e?.cause?.code) !== "UND_ERR_SOCKET") throw e;
    socketDrops++;
    res = await fetch(BASE + path, { ...init, headers: { ...init.headers, connection: "close" } });
  }
  const text = await res.text();
  let json; try { json = JSON.parse(text); } catch {}
  return { status: res.status, headers: res.headers, text, json };
}

// ---------------------------------------------------------------- 1. owner browser session
// The isolated server prints a one-time owner pairing link (throwaway; never printed here).
let pairToken;
for (let i = 0; i < 150 && !pairToken; i++) { // the link is printed shortly after the server is healthy
  pairToken = (readFileSync(join(WORK, "server.log"), "utf8").match(/\/pair#token=([A-Za-z0-9_-]+)/) || [])[1];
  if (!pairToken) await sleep(100);
}
check("server prints an owner pairing link on first start", pairToken);
secrets.add(pairToken);
const bs = await http("POST", "/api/auth/browser-session", { body: { credential: pairToken } });
const cookie = (bs.headers.get("set-cookie") || "").split(";")[0];
check("owner pairing token redeems to a browser session cookie", bs.status === 200 && cookie, bs.status + " " + bs.text);
secrets.add(cookie.split("=")[1]);

// ---------------------------------------------------------------- 2. MCP OAuth (bridge pairing)
const md = await http("GET", "/.well-known/oauth-authorization-server");
record("oauth-authorization-server", md.json);
check("authorization metadata: code + S256 + public client", md.json?.grant_types_supported?.join() === "authorization_code"
  && md.json?.code_challenge_methods_supported?.includes("S256") && md.json?.token_endpoint_auth_methods_supported?.includes("none"));
const prm = await http("GET", "/.well-known/oauth-protected-resource/mcp");
record("oauth-protected-resource-mcp", prm.json);
const RESOURCE = prm.json?.resource;
check("protected resource names /mcp", RESOURCE?.endsWith("/mcp"), RESOURCE);

const REDIRECT = "http://127.0.0.1:47123/t3wow/callback";
const badReg = await http("POST", "/oauth/mcp/register", { body: { client_name: "x", redirect_uris: ["http://evil.example/cb"] } });
check("registration rejects non-loopback http redirect", badReg.status === 400, badReg.status);
const reg = await http("POST", "/oauth/mcp/register", { body: { client_name: "T3 for WoW (contract test)", redirect_uris: [REDIRECT], token_endpoint_auth_method: "none" } });
check("dynamic registration of a loopback public client", reg.status === 201 && reg.json?.client_id, reg.status + reg.text);
const clientId = reg.json.client_id; secrets.add(clientId);
record("oauth-register-response", reg.json);

function pkce() {
  const verifier = randomBytes(32).toString("base64url");
  const challenge = createHash("sha256").update(verifier).digest("base64url");
  return { verifier, challenge };
}
async function authorize(access, decisionTag = "browser-session", withCookie = true) {
  const { verifier, challenge } = pkce();
  const state = randomBytes(12).toString("base64url");
  const authorization = { response_type: "code", client_id: clientId, redirect_uri: REDIRECT, code_challenge: challenge, code_challenge_method: "S256", state, resource: RESOURCE };
  const a = await http("GET", "/oauth/mcp/authorize?" + new URLSearchParams(authorization));
  const approvalPage = a.headers.get("location");
  const ap = await http("POST", "/oauth/mcp/approval", { headers: withCookie ? { cookie } : {}, body: authorization });
  const decision = decisionTag === "deny" ? { _tag: "deny" } : { _tag: "browser-session", access, csrfToken: ap.json?.csrfToken ?? "none" };
  const d = await http("POST", "/oauth/mcp/decision", { headers: withCookie ? { cookie } : {}, body: { authorization, decision } });
  return { a, approvalPage, ap, d, verifier, state };
}

const denied = await authorize("approval-required", "deny");
const deniedUrl = denied.d.json?.redirectTo ? new URL(denied.d.json.redirectTo) : null;
check("authorize redirects to the T3 approval page", denied.a.status >= 300 && denied.a.status < 400 && /oauth|approv|mcp/i.test(denied.approvalPage ?? ""), denied.approvalPage);
check("owner Deny returns access_denied to the bridge redirect with state", deniedUrl?.searchParams.get("error") === "access_denied" && deniedUrl?.searchParams.get("state") === denied.state, denied.d.text);

const noCookie = await authorize("approval-required", "browser-session", false);
check("approval page without an owner session offers no one-click approval", noCookie.ap.status === 200 && !noCookie.ap.json?.csrfToken, noCookie.ap.text);
check("decision without an owner session is refused", noCookie.d.status === 400, noCookie.d.status + noCookie.d.text);

const ok = await authorize("approval-required");
record("oauth-approval-details", ok.ap.json);
check("approval details list one-click access levels incl. approval-required", ok.ap.json?.oneClickAccess?.includes("approval-required"), JSON.stringify(ok.ap.json?.oneClickAccess));
const okUrl = ok.d.json?.redirectTo ? new URL(ok.d.json.redirectTo) : null;
const code = okUrl?.searchParams.get("code");
check("owner Approve returns a code + state + iss", code && okUrl.searchParams.get("state") === ok.state && okUrl.searchParams.get("iss"), ok.d.text);
secrets.add(code);
const badVerifier = await http("POST", "/oauth/mcp/token", { form: { grant_type: "authorization_code", code, redirect_uri: REDIRECT, client_id: clientId, code_verifier: pkce().verifier, resource: RESOURCE } });
check("token exchange with the wrong PKCE verifier fails", badVerifier.status === 400, badVerifier.status + badVerifier.text);
// A code is single-use: after a failed exchange it is consumed; re-run the approval.
const ok2 = await authorize("approval-required");
if (!ok2.d.json?.redirectTo) { console.log("second approval answered:", ok2.d.status, ok2.d.text.slice(0, 300), "approval:", ok2.ap.status, ok2.ap.text.slice(0, 200)); }
const code2 = new URL(ok2.d.json.redirectTo).searchParams.get("code"); secrets.add(code2);
const tok = await http("POST", "/oauth/mcp/token", { form: { grant_type: "authorization_code", code: code2, redirect_uri: REDIRECT, client_id: clientId, code_verifier: ok2.verifier, resource: RESOURCE } });
check("token exchange returns a Bearer with expiry and scope", tok.status === 200 && tok.json?.token_type === "Bearer" && tok.json?.expires_in > 0, tok.status + tok.text);
const TOKEN = tok.json.access_token; secrets.add(TOKEN);
record("oauth-token-response", { ...tok.json, access_token: "<redacted>" });
check("token lifetime is 30 days and no refresh token is issued", Math.abs(tok.json.expires_in - 30 * 86400) < 120 && tok.json.refresh_token === undefined, tok.json.expires_in);
check("approval-required access maps to orchestration read+operate only", tok.json.scope.split(" ").sort().join() === "orchestration:operate,orchestration:read", tok.json.scope);
const replay = await http("POST", "/oauth/mcp/token", { form: { grant_type: "authorization_code", code: code2, redirect_uri: REDIRECT, client_id: clientId, code_verifier: ok2.verifier, resource: RESOURCE } });
check("authorization code cannot be replayed", replay.status === 400, replay.status);

// ---------------------------------------------------------------- 2b. approval WITHOUT a browser session
// Owner who uses the T3 desktop app: T3's page accepts a one-time pairing code the owner mints in T3
// (here: the owner CLI on the throwaway base dir, scoped to read+operate, 5 min). Typed into T3's page.
function pairingCode(scopes) {
  const out = cli(["auth", "pairing", "create", ...scopes.flatMap((x) => ["--scope", x]), "--ttl", "5m", "--label", "contract pairing code", "--json"]);
  const j = JSON.parse(out); const c = j.credential ?? j.token ?? j.pairingToken ?? j.code; secrets.add(c); return { c, keys: Object.keys(j) };
}
async function decideWithCode(access, code) {
  const { verifier, challenge } = pkce();
  const state = randomBytes(12).toString("base64url");
  const authorization = { response_type: "code", client_id: clientId, redirect_uri: REDIRECT, code_challenge: challenge, code_challenge_method: "S256", state, resource: RESOURCE };
  const d = await http("POST", "/oauth/mcp/decision", { body: { authorization, decision: { _tag: "pairing-code", access, code } } });
  return { d, verifier };
}
const pc = pairingCode(["orchestration:read", "orchestration:operate"]);
writeFileSync(join(OUT, "observed-pairing-create-keys.txt"), pc.keys.sort().join("\n") + "\n");
check("owner can mint a scoped one-time pairing code (read+operate only)", typeof pc.c === "string" && pc.c.length > 8, pc.keys.join(","));
const viaCode = await decideWithCode("approval-required", pc.c);
const codeUrl = viaCode.d.json?.redirectTo ? new URL(viaCode.d.json.redirectTo) : null;
check("pairing code approves without a browser session", codeUrl?.searchParams.get("code"), viaCode.d.status + " " + viaCode.d.text.slice(0, 200));
if (codeUrl?.searchParams.get("code")) {
  secrets.add(codeUrl.searchParams.get("code"));
  const t2 = await http("POST", "/oauth/mcp/token", { form: { grant_type: "authorization_code", code: codeUrl.searchParams.get("code"), redirect_uri: REDIRECT, client_id: clientId, code_verifier: viaCode.verifier, resource: RESOURCE } });
  if (t2.json?.access_token) secrets.add(t2.json.access_token);
  check("pairing-code approval yields the same read+operate bearer", t2.json?.scope?.split(" ").sort().join() === "orchestration:operate,orchestration:read", t2.text.slice(0, 120));
}
const reuse = await decideWithCode("approval-required", pc.c);
check("a pairing code is single-use", reuse.d.status === 400, reuse.d.status);
const roCodeOnly = pairingCode(["orchestration:read"]);
const tooWide = await decideWithCode("approval-required", roCodeOnly.c);
check("a read-only pairing code cannot approve operate access", tooWide.d.status === 400, tooWide.d.status + " " + tooWide.d.text.slice(0, 120));

// ---------------------------------------------------------------- 3. MCP JSON-RPC
let mcpSession = null; let rpcId = 0;
async function mcp(method, params, token = TOKEN) {
  const headers = { authorization: `Bearer ${token}`, accept: "application/json, text/event-stream", "mcp-protocol-version": "2025-06-18" };
  if (mcpSession) headers["mcp-session-id"] = mcpSession;
  const id = ++rpcId;
  const r = await http("POST", "/mcp", { headers, body: { jsonrpc: "2.0", id, method, params } });
  if (r.headers.get("mcp-session-id")) mcpSession = r.headers.get("mcp-session-id");
  let msg = r.json;
  if (!msg && r.text.includes("data:")) {
    for (const line of r.text.split("\n")) if (line.startsWith("data:")) { try { const m = JSON.parse(line.slice(5)); if (m.id === id) msg = m; } catch {} }
  }
  return { status: r.status, msg, raw: r.text, headers: r.headers };
}
async function tool(name, args, token) {
  const r = await mcp("tools/call", { name, arguments: args }, token);
  const res = r.msg?.result;
  return { status: r.status, isError: !!res?.isError || !!r.msg?.error, structured: res?.structuredContent, text: res?.content?.map((c) => c.text).join("\n") ?? JSON.stringify(r.msg?.error ?? r.raw), raw: r };
}

const unauth = await http("POST", "/mcp", { headers: { accept: "application/json, text/event-stream" }, body: { jsonrpc: "2.0", id: 0, method: "initialize", params: {} } });
check("MCP without a bearer is 401 with a resource-metadata challenge", unauth.status === 401 && /resource_metadata/i.test(unauth.headers.get("www-authenticate") ?? ""), unauth.status + " " + unauth.headers.get("www-authenticate"));

const init = await mcp("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "t3-for-wow-contract", version: "0" } });
check("MCP initialize succeeds with the OAuth bearer", init.status === 200 && init.msg?.result?.serverInfo, init.status + init.raw.slice(0, 200));
record("mcp-initialize-result", init.msg?.result);
await mcp("notifications/initialized", {});
const tl = await mcp("tools/list", {});
const toolNames = (tl.msg?.result?.tools ?? []).map((t) => t.name).sort();
record("mcp-tools-list-approval-required", (tl.msg?.result?.tools ?? []).filter((t) => /^t3_(project_list|thread_(list|read|send|launch|wait)|pending_request)$/.test(t.name)));
writeFileSync(join(OUT, "mcp-tool-names-approval-required.txt"), toolNames.join("\n") + "\n");
for (const need of ["t3_project_list", "t3_thread_list", "t3_thread_read", "t3_thread_send", "t3_thread_launch", "t3_thread_wait", "t3_pending_request"])
  check(`tool available to an approval-required client: ${need}`, toolNames.includes(need), toolNames.join(","));

// project in the isolated server (created by the owner CLI on the throwaway base dir)
cli(["project", "add", join(WORK, "project"), "--title", "Contract Fixture"]);
const pl = await tool("t3_project_list", { limit: 100 });
record("t3_project_list", pl.structured);
const project = pl.structured?.projects?.find((p) => p.title === "Contract Fixture");
check("t3_project_list returns the fixture project with id/title/workspaceRoot", project?.id && project?.workspaceRoot, pl.text);

// thread launch with idempotency key
const caps = await tool("orchestrator_capabilities", {});
record("orchestrator_capabilities", caps.structured ?? { error: caps.text });
// Pick the Claude driver: its executable is NOT on the isolated PATH (/usr/bin:/bin) and HOME is
// empty, so any turn must fail to start instead of spending a subscription.
const prov = (caps.structured?.providers ?? []).find((p) => p.providerInstanceId === "claudeAgent");
const modelSelection = prov?.models?.length ? { instanceId: prov.providerInstanceId, model: prov.models.at(-1).id } : undefined;
writeFileSync(join(OUT, "observed-model-selection.json"), JSON.stringify(modelSelection ?? null) + "\n");
const launchKey = "t3wow-launch-" + randomBytes(6).toString("hex");
const launchArgs = { projectId: project.id, title: "Fixture thread", message: "fixture: hello from the contract test", clientRequestId: launchKey, ...(modelSelection ? { modelSelection } : {}) };
const l1 = await tool("t3_thread_launch", launchArgs);
record("t3_thread_launch", l1.structured ?? { error: l1.text });
check("t3_thread_launch creates a thread", !l1.isError && l1.structured?.threadId, l1.text);
const l2 = await tool("t3_thread_launch", launchArgs);
check("t3_thread_launch replay with same clientRequestId returns the same thread", l1.structured?.threadId && l2.structured?.threadId === l1.structured?.threadId, l2.text);
if (!l1.structured?.threadId) { stop(); process.exit(1); }
const threadId = l1.structured.threadId;

await sleep(1500);
const tlist = await tool("t3_thread_list", { projectId: project.id, limit: 50 });
record("t3_thread_list", tlist.structured);
const launchedThreads = (tlist.structured?.threads ?? []).filter((t) => t.title === "Fixture thread");
check("replayed launch produced exactly one thread", launchedThreads.length === 1, JSON.stringify(tlist.structured?.threads?.map((t) => t.title)));
const allp = await tool("t3_thread_list", { allProjects: true, limit: 50 });
check("t3_thread_list allProjects works", !allp.isError && Array.isArray(allp.structured?.threads), allp.text);

// wait for the run to settle (no provider CLI in the isolated PATH: it must FAIL, not complete)
const w = await tool("t3_thread_wait", { threadId, timeoutMs: 20000 });
record("t3_thread_wait-after-launch", w.structured ?? { error: w.text });
check("t3_thread_wait reports an ended status", !w.isError && typeof w.structured?.status === "string", w.text);
writeFileSync(join(OUT, "observed-run-status-without-provider.txt"), (w.structured?.status ?? "?") + "\n");

// idempotent send
const sendKey = "t3wow-send-" + randomBytes(6).toString("hex");
const s1 = await tool("t3_thread_send", { threadId, message: "fixture: exactly-once reply", mode: "queue", clientRequestId: sendKey });
record("t3_thread_send", s1.structured ?? { error: s1.text });
check("t3_thread_send accepted", !s1.isError && s1.structured?.messageId, s1.text);
const s2 = await tool("t3_thread_send", { threadId, message: "fixture: exactly-once reply", mode: "queue", clientRequestId: sendKey });
record("t3_thread_send-replay", s2.structured ?? { error: s2.text });
check("t3_thread_send replay returns same messageId", s2.structured?.messageId === s1.structured?.messageId, s2.text);
await tool("t3_thread_wait", { threadId, timeoutMs: 15000 });
const r1 = await tool("t3_thread_read", { threadId, view: "messages", limit: 100, maxCharsPerItem: 2000 });
record("t3_thread_read-messages", r1.structured);
const userMsgs = (r1.structured?.items ?? []).filter((i) => i.type === "user_message");
const exact = userMsgs.filter((i) => (i.text ?? "").includes("exactly-once reply"));
check("thread history contains the replayed reply exactly once", exact.length === 1, JSON.stringify(userMsgs.map((i) => i.text)));
check("thread read exposes status, itemCount, pendingRequestCount", r1.structured?.thread && "itemCount" in r1.structured.thread && "pendingRequestCount" in r1.structured.thread && "status" in r1.structured.thread, JSON.stringify(r1.structured?.thread));
const r2 = await tool("t3_thread_read", { threadId, view: "activity", limit: 100, maxCharsPerItem: 500 });
record("t3_thread_read-activity", r2.structured);
writeFileSync(join(OUT, "observed-activity-item-types.txt"), [...new Set((r2.structured?.items ?? []).map((i) => i.type))].sort().join("\n") + "\n");
check("activity view returns timeline items with positions", (r2.structured?.items ?? []).every((i) => typeof i.position === "number"), r2.text.slice(0, 200));
const page = await tool("t3_thread_read", { threadId, view: "messages", limit: 1, maxCharsPerItem: 50 });
check("history is pageable (limit + nextPosition/hasMore)", page.structured && "hasMore" in page.structured, page.text.slice(0, 200));

const s3 = await tool("t3_thread_send", { threadId, message: "fixture: a second distinct reply", mode: "queue", clientRequestId: sendKey + "-b" });
check("a new clientRequestId sends a distinct message", s3.structured?.messageId && s3.structured.messageId !== s1.structured.messageId, s3.text);
const missing = await tool("t3_thread_send", { threadId: "thread-does-not-exist", message: "x", clientRequestId: "k" });
check("send to an unknown thread is an error, not a silent success", missing.isError, missing.text);
writeFileSync(join(OUT, "observed-unknown-thread-error.txt"), missing.text + "\n");

const pend = await tool("t3_pending_request", { action: "list", threadId });
record("t3_pending_request-list", pend.structured ?? { error: pend.text });
check("t3_pending_request list callable by an outside client", !pend.isError, pend.text);

// read-only client cannot send
const ro = await authorize("read-only");
const roCode = new URL(ro.d.json.redirectTo).searchParams.get("code"); secrets.add(roCode);
const roTok = await http("POST", "/oauth/mcp/token", { form: { grant_type: "authorization_code", code: roCode, redirect_uri: REDIRECT, client_id: clientId, code_verifier: ro.verifier, resource: RESOURCE } });
const RO = roTok.json?.access_token; secrets.add(RO);
check("read-only access maps to orchestration:read", roTok.json?.scope === "orchestration:read", roTok.json?.scope);
const savedSession = mcpSession; mcpSession = null;
await mcp("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "ro", version: "0" } }, RO);
const roSend = await tool("t3_thread_send", { threadId, message: "fixture: must be refused", clientRequestId: "ro-1" }, RO);
check("read-only client cannot send", roSend.isError || roSend.status >= 400, roSend.text);
mcpSession = savedSession;

// permission ceiling: approval-required client vs a full-access thread
const fullThread = cli(["thread", "start", project.id, "fixture: full-access thread", "--json", ...(modelSelection ? ["--provider", modelSelection.instanceId, "--model", modelSelection.model] : [])]);
const fullId = JSON.parse(fullThread).threadId;
const ceilingRead = await tool("t3_thread_read", { threadId: fullId, limit: 1 });
const ceilingSend = await tool("t3_thread_send", { threadId: fullId, message: "fixture: ceiling probe", clientRequestId: "ceiling-1" });
writeFileSync(join(OUT, "observed-ceiling.txt"), `threadRuntimeMode=${ceilingRead.structured?.thread?.runtimeMode}\nsendError=${ceilingSend.isError}\n${ceilingSend.text}\n`);
check("permission ceiling is enforced or explicitly reported for broader threads",
  ceilingRead.structured?.thread?.runtimeMode !== "full-access" || ceilingSend.isError, `${ceilingRead.structured?.thread?.runtimeMode} / ${ceilingSend.text}`);

// Owner explicitly chooses "full-access" on T3's page: the only owner-approved MCP path that matches a
// full-access thread. It also grants settings:write + source-control:write (disclosed, never silent).
const fa = await authorize("full-access");
const faCode = fa.d.json?.redirectTo ? new URL(fa.d.json.redirectTo).searchParams.get("code") : null; secrets.add(faCode);
const faTok = await http("POST", "/oauth/mcp/token", { form: { grant_type: "authorization_code", code: faCode, redirect_uri: REDIRECT, client_id: clientId, code_verifier: fa.verifier, resource: RESOURCE } });
const FA = faTok.json?.access_token; secrets.add(FA);
writeFileSync(join(OUT, "observed-full-access-scope.txt"), (faTok.json?.scope ?? "?") + "\n");
check("full-access approval scope = read+operate+settings:write+source-control:write (disclosed breadth)",
  faTok.json?.scope?.split(" ").sort().join() === "orchestration:operate,orchestration:read,settings:write,source-control:write", faTok.json?.scope);
const keepSession = mcpSession; mcpSession = null;
await mcp("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "fa", version: "0" } }, FA);
const faSend = await tool("t3_thread_send", { threadId: fullId, message: "fixture: full-access link reply", mode: "queue", clientRequestId: "fa-1" }, FA);
writeFileSync(join(OUT, "observed-full-access-send.txt"), `sendError=${faSend.isError}\n${faSend.isError ? faSend.text : faSend.structured?.delivery}\n`);
check("a full-access link CAN reply to a full-access thread (no runtime mode changed)", !faSend.isError && faSend.structured?.messageId, faSend.text.slice(0, 200));
const modeAfter = await tool("t3_thread_read", { threadId: fullId, limit: 1 }, FA);
check("the thread's runtime mode is unchanged by the reply", modeAfter.structured?.thread?.runtimeMode === "full-access", modeAfter.structured?.thread?.runtimeMode);
mcpSession = keepSession;

// ---------------------------------------------------------------- 4. restart persistence
stop(); await sleep(1500);
PORT = start(); BASE = `http://127.0.0.1:${PORT}`;
// Resource URL depends on the port; a real owner keeps a stable port. Here the token is
// presented to the new port's resource.
mcpSession = null;
const reinit = await mcp("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "after-restart", version: "0" } });
check("bearer survives a T3 server restart", reinit.status === 200 && reinit.msg?.result, reinit.status + reinit.raw.slice(0, 200));
const s4 = await tool("t3_thread_send", { threadId, message: "fixture: exactly-once reply", mode: "queue", clientRequestId: sendKey });
check("send idempotency survives a T3 server restart (same messageId)", s4.structured?.messageId === s1.structured.messageId, s4.text);
await sleep(1000);
const r3 = await tool("t3_thread_read", { threadId, view: "messages", limit: 100, maxCharsPerItem: 2000 });
check("still exactly one copy of the replayed reply after restart", (r3.structured?.items ?? []).filter((i) => i.type === "user_message" && (i.text ?? "").includes("exactly-once reply")).length === 1);

// ---------------------------------------------------------------- 5. revocation
const sessions = JSON.parse(cli(["auth", "session", "list", "--json"]));
writeFileSync(join(OUT, "observed-session-list-shape.json"), JSON.stringify(sanitize(Array.isArray(sessions) ? sessions.slice(0, 1).map((x) => Object.fromEntries(Object.keys(x).map((k) => [k, typeof x[k]]))) : Object.keys(sessions)), null, 2) + "\n");
const list = Array.isArray(sessions) ? sessions : sessions.sessions ?? [];
const mine = list.filter((x) => JSON.stringify(x).includes("contract test"));
check("owner can see the bridge session labelled with its client name", mine.length >= 1, JSON.stringify(list.map((x) => x.label ?? x.client?.label)));
for (const x of mine) cli(["auth", "session", "revoke", x.sessionId ?? x.id]);
mcpSession = null;
const afterRevoke = await mcp("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "revoked", version: "0" } });
check("revoked bearer is refused with 401", afterRevoke.status === 401, afterRevoke.status);
writeFileSync(join(OUT, "observed-revocation-drops-connections.txt"), `pooled connections dropped by the server after revocation: ${socketDrops}\n`);

stop();
writeFileSync(join(OUT, "contract-results.json"), JSON.stringify(sanitize({ t3Version: execFileSync(T3, ["--version"], { encoding: "utf8" }).trim(), results }), null, 2) + "\n");
console.log(`\n${results.length - failed}/${results.length} contract checks passed`);
process.exit(failed ? 1 : 0);
