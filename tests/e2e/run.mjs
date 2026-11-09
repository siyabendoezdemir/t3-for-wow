// Cross-process end-to-end loop against a REAL isolated T3 v0.1.7 server:
//   synthetic game (tests/e2e/game.lua, real addon core) --pixels--> t3wow-bridge --MCP--> T3
//   T3 --> t3wow-bridge --slot files--> synthetic game
// Owner approval is simulated with the isolated server's own owner browser session (the step a
// person performs by clicking Approve on T3's page). SYNTHETIC game; not a WoW client.
//   node tests/e2e/run.mjs <t3> <bridge-binary> <lua> <workdir> <evidence-out.json>
import { spawn, spawnSync, execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync, rmSync, existsSync, readdirSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const [T3, BRIDGE, LUA, WORK, EVIDENCE] = process.argv.slice(2).map((p) => resolve(p));
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
rmSync(WORK, { recursive: true, force: true }); mkdirSync(WORK, { recursive: true });
const checks = []; let failed = 0;
const check = (name, ok, detail = "") => { checks.push({ name, ok: !!ok, detail: String(detail).slice(0, 300) }); if (!ok) failed++; console.log(`${ok ? "PASS" : "FAIL"}  ${name}${ok ? "" : "  -- " + detail}`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const iso = join(WORK, "t3");
const st = spawnSync(join(ROOT, "tests/isolated-t3/start.sh"), [T3, iso], { encoding: "utf8" });
if (st.status !== 0) { console.error(st.stderr); process.exit(1); }
const PORT = Number(readFileSync(join(iso, "port"), "utf8")); const BASE = `http://127.0.0.1:${PORT}`;
const cliEnv = { HOME: join(iso, "home"), PATH: "/usr/bin:/bin", T3CODE_TELEMETRY_ENABLED: "false", T3CODE_OTEL_SDK_DISABLED: "true" };
const cli = (a) => execFileSync(T3, [...a, "--base-dir", join(iso, "base")], { encoding: "utf8", env: cliEnv });
const stopServer = () => { try { process.kill(Number(readFileSync(join(iso, "server.pid"), "utf8"))); } catch {} };

try {
  // ---- owner-side fixture: a project and one ordinary (full-access) thread
  cli(["project", "add", join(iso, "project"), "--title", "E2E Project"]);
  const projectId = JSON.parse(cli(["thread", "list", "--project", join(iso, "project"), "--json"]) || "[]") && null;
  cli(["thread", "start", join(iso, "project"), "Owner fixture thread", "--title", "Owner thread", "--provider", "claudeAgent", "--model", "claude-haiku-5-5", "--json"]);

  // ---- pairing through the real headless bridge
  const grantFile = join(WORK, "grant.json");
  const refused = spawnSync(BRIDGE, ["pair", "--origin", BASE, "--grant-file", grantFile, "--timeout", "1"], { encoding: "utf8", env: { PATH: process.env.PATH } });
  check("headless grant-file pairing refuses outside isolated-test mode", refused.status === 77 && /only for isolated test servers/.test(refused.stderr), refused.status);
  const refusedPath = spawnSync(BRIDGE, ["pair", "--origin", BASE, "--grant-file", join(process.env.HOME || "/root", "grant.json"), "--timeout", "1"], { encoding: "utf8", env: { PATH: process.env.PATH, T3WOW_ISOLATED_TEST: "1" } });
  check("headless grant file refused outside a temp/.build directory", refusedPath.status === 77, refusedPath.status);
  const isoEnv = { ...process.env, T3WOW_ISOLATED_TEST: "1" };
  const pair = spawn(BRIDGE, ["pair", "--origin", BASE, "--grant-file", grantFile, "--timeout", "60"], { stdio: ["ignore", "pipe", "pipe"], env: isoEnv });
  let pairOut = ""; pair.stdout.on("data", (d) => (pairOut += d)); pair.stderr.on("data", (d) => (pairOut += d));
  const pairDone = new Promise((r) => pair.on("exit", (c) => r(c)));
  for (let i = 0; i < 100 && !pairOut.includes("APPROVE_URL="); i++) await sleep(100);
  const approveUrl = new URL(pairOut.match(/APPROVE_URL=(\S+)/)[1]);
  check("bridge registers with T3 and produces T3's own approval URL", approveUrl.pathname === "/oauth/mcp/authorize" && approveUrl.searchParams.get("code_challenge_method") === "S256", approveUrl.pathname);
  // The owner: signed in to their T3 in the browser, opens the URL and clicks Approve.
  let pairToken;
  for (let i = 0; i < 150 && !pairToken; i++) { pairToken = (readFileSync(join(iso, "server.log"), "utf8").match(/\/pair#token=([A-Za-z0-9_-]+)/) || [])[1]; if (!pairToken) await sleep(100); }
  const bs = await fetch(BASE + "/api/auth/browser-session", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ credential: pairToken }) });
  const cookie = bs.headers.get("set-cookie").split(";")[0];
  const authorization = Object.fromEntries(approveUrl.searchParams);
  const ap = await (await fetch(BASE + "/oauth/mcp/approval", { method: "POST", headers: { "content-type": "application/json", cookie }, body: JSON.stringify(authorization) })).json();
  check("approval page shows the bridge's self-declared name and loopback redirect host", ap.clientName === "T3 for WoW" && /^127\.0\.0\.1:\d+$/.test(ap.redirectHost), JSON.stringify({ n: ap.clientName, h: ap.redirectHost }));
  const dec = await (await fetch(BASE + "/oauth/mcp/decision", { method: "POST", headers: { "content-type": "application/json", cookie },
    body: JSON.stringify({ authorization, decision: { _tag: "browser-session", access: "approval-required", csrfToken: ap.csrfToken } }) })).json();
  await fetch(dec.redirectTo); // the browser follows T3's redirect to the bridge's loopback callback
  const pairCode = await pairDone;
  check("bridge completes pairing from the loopback callback", pairCode === 0 && /PAIR_RESULT=approved scope=(orchestration:read orchestration:operate|orchestration:operate orchestration:read) /.test(pairOut), pairOut.replace(/APPROVE_URL=\S+/, "APPROVE_URL=<url>"));
  const grant = JSON.parse(readFileSync(grantFile, "utf8"));
  check("grant expires in ~30 days (re-approval needed monthly; no refresh token in T3 0.1.7)", Math.abs(grant.expiresAt - Date.now() / 1000 - 30 * 86400) < 300);

  // ---- install from the built artifact into a fake AddOns folder
  const addons = join(WORK, "Interface/AddOns");
  const inst = execFileSync(BRIDGE, ["install", "--addon", join(ROOT, "addon/T3ForWoW"), "--addons", addons, "--slots", "40"], { encoding: "utf8" });
  check("installer creates addon + 40 slots", /INSTALLED slotsCreated=40 restartNeeded=true change=restart folders=41/.test(inst), inst);

  // ---- run
  const screen = join(WORK, "screen.ppm"), ledger = join(WORK, "ledger.json"), stats = join(WORK, "stats.json");
  const startBridge = () => spawn(BRIDGE, ["run", "--frame-file", screen, "--addons", addons, "--ledger", ledger, "--grant-file", grantFile, "--stats", stats, "--seconds", "300"], { stdio: ["ignore", "pipe", "inherit"], env: isoEnv });
  let bridge = startBridge();
  const session = 0x51a7e000 + Math.floor(Math.random() * 4096);
  const game = spawnSync(LUA, [join(ROOT, "tests/e2e/game.lua"), ROOT, addons, screen, String(session), "main"], { encoding: "utf8", timeout: 240000 });
  const g = Object.fromEntries(game.stdout.split("\n").filter((l) => l.includes("=")).map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]));
  if (game.status !== 0) console.log(game.stdout, game.stderr);
  check("game sees T3 connected through the bridge with tracker data", g.HEALTH === "online/connected" && g.TRACKER_READY_S, JSON.stringify(g));
  check("owner's full-access thread is shown as not repliable from an approval-required link", g.OWNER_THREAD_MODE === "full-access" && g.OWNER_THREAD_CANREPLY === "false", `${g.OWNER_THREAD_MODE}/${g.OWNER_THREAD_CANREPLY}`);
  check("reply to it is refused by T3's permission ceiling and explained", g.CEILING_REQ === "rejected" && /runs with Full access/.test(g.CEILING_DETAIL ?? ""), `${g.CEILING_REQ}: ${g.CEILING_DETAIL}`);
  check("new thread from the game is created in the project", g.NEWTHREAD_REQ === "accepted" && g.NEWTHREAD_SEEN === "true", `${g.NEWTHREAD_REQ}/${g.NEWTHREAD_SEEN}: ${g.NEWTHREAD_DETAIL}`);
  check("no silent model choice: the new thread names the model it copied from the owner's latest thread", /Using claude-haiku-5-5, like your latest thread/.test(g.NEWTHREAD_DETAIL ?? ""), g.NEWTHREAD_DETAIL);
  check("its failed run (no provider in the isolated server) is shown as Failed, not done", g.NEWTHREAD_STATUS === "Failed", g.NEWTHREAD_STATUS);
  check("typed reply to the selected thread is accepted by T3", ["accepted", "queued"].includes(g.REPLY_REQ), g.REPLY_REQ);
  check("the reply appears in the game's history, attributed to WoW", g.REPLY_IN_HISTORY === "true", g.REPLY_IN_HISTORY);

  // ---- crash the bridge, restart it (new epoch), game re-shows the same request
  bridge.kill("SIGKILL"); await sleep(300);
  bridge = startBridge();
  const again = spawnSync(LUA, [join(ROOT, "tests/e2e/game.lua"), ROOT, addons, screen, String(session), "reshow", String(session)], { encoding: "utf8", timeout: 120000, env: { ...process.env, E2E_NEXT_REQ: g.REPLY_REQ_ID } });
  const a = Object.fromEntries(again.stdout.split("\n").filter((l) => l.includes("=")).map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]));
  check("after a bridge crash the re-shown request is answered from the ledger", a.RESHOW_REQ_ID === g.REPLY_REQ_ID && ["accepted", "queued"].includes(a.RESHOW_REQ), JSON.stringify(a));
  bridge.kill("SIGTERM");

  // ---- owner-side truth: exactly one copy in T3
  const shown = JSON.parse(cli(["thread", "show", g.THREAD_ID, "--messages", "50", "--json"]));
  const copies = shown.messages.filter((m) => m.role === "user" && m.text === `e2e: exactly once from WoW ${session}`).length;
  check("T3 holds exactly one copy of the WoW reply (owner view)", copies === 1, `copies=${copies}`);
  const owner = JSON.parse(cli(["thread", "list", "--project", join(iso, "project"), "--json"])).find((t) => t.title === "Owner thread");
  const ownerShown = JSON.parse(cli(["thread", "show", owner.threadId, "--messages", "50", "--json"]));
  check("nothing reached the refused full-access thread", !ownerShown.messages.some((m) => m.text.includes("permission ceiling")));

  const st2 = JSON.parse(readFileSync(stats, "utf8"));
  const evidence = {
    kind: "SYNTHETIC game process + REAL isolated T3 v0.1.7 + real headless bridge build",
    t3Version: execFileSync(T3, ["--version"], { encoding: "utf8" }).trim(),
    gameIntervalOverrideSeconds: 1,
    trackerReadySeconds: Number(g.TRACKER_READY_S), replyAckSeconds: Number(g.REPLY_ACK_S), replyVisibleSeconds: Number(g.REPLY_VISIBLE_S),
    slotsUsedMainPhase: Number(g.SLOTS_USED), slotsUsedReshowPhase: Number(a.SLOTS_USED), bridgeStatsAfterRestart: st2,
    footprint: inst.trim(), checks,
  };
  mkdirSync(dirname(EVIDENCE), { recursive: true });
  writeFileSync(EVIDENCE, JSON.stringify(evidence, null, 2) + "\n");
} finally {
  stopServer();
}
console.log(`\n${checks.length - failed}/${checks.length} end-to-end checks passed`);
process.exit(failed ? 1 : 0);
