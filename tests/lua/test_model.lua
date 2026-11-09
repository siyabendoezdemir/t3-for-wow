local H = ...
local test, eq, ok = H.test, H.eq, H.ok
local function N() return H.loadAddon(H.CORE) end

local function T(id, status, pending, updatedAt, extra)
  extra = extra or {}
  return { "t", id, extra.project or "p1", extra.title or id, status, tostring(pending or 0), tostring(updatedAt or 1000),
    extra.settled or "0", extra.mode or "approval-required", extra.canReply or "1", extra.summary or "" }
end
local function D(version, records, epoch) return { epoch = epoch or 1, version = version, bridgeTime = 2000, records = records, more = false } end
local ST = { "st", "online", "connected", "1990", "", "0", "approval-required", "60" }

test("needs-you = a pending runtime request (not bare 'waiting'); then working; then recently stopped; settled hidden", function()
  local m = N().Model.new()
  eq(m:apply(D(1, { ST,
    T("a", "running", 0, 1500), T("b", "completed", 0, 1900), T("c", "waiting", 0, 1000),
    T("d", "running", 2, 1200), T("e", "completed", 0, 1950, { settled = "1" }), T("f", "failed", 0, 1800),
  }), 2000), "applied")
  local g = m:tracker(2000)
  eq(#g.needs, 1); eq(g.needs[1].id, "d") -- pending request wins over an active run
  eq(#g.working, 2); eq(g.working[1].id, "a"); eq(g.working[2].id, "c") -- waiting without a request is still working

  eq(#g.recent, 2); eq(g.recent[1].id, "b"); eq(g.recent[2].id, "f")
end)

test("labels never claim verified completion or invisible subagent work", function()
  local M = N().Model
  eq(M.label("running"), "Working")
  eq(M.label("waiting"), "Waiting")
  eq(M.label("completed"), "Run finished")
  eq(M.label("interrupted"), "Stopped")
  eq(M.label("failed"), "Failed")
  eq(M.label("something-new"), "Unknown")
  for _, s in ipairs({ "completed", "running", "waiting" }) do
    ok(not M.label(s):lower():find("done") and not M.label(s):lower():find("deploy"), s)
  end
end)

test("old versions are ignored; a new bridge epoch replaces the model", function()
  local m = N().Model.new()
  m:apply(D(5, { ST, T("a", "running") }), 0)
  eq(m:apply(D(4, { T("a", "failed") }), 0), "old")
  eq(m.threads.a.status, "running")
  eq(m:apply(D(1, { ST, T("z", "running") }, 2), 0), "applied")
  eq(m.threads.a, nil, "previous epoch state cleared")
  ok(m.threads.z)
end)

test("project filter and project titles", function()
  local m = N().Model.new()
  m:apply(D(1, { ST, { "p", "p1", "Alpha" }, { "p", "p2", "Beta" }, T("a", "running", 0, 1, { project = "p1" }), T("b", "running", 0, 2, { project = "p2" }) }), 0)
  eq(#m:tracker(0, "p2").working, 1)
  eq(m:tracker(0, "p2").working[1].id, "b")
  eq(m.projects.p1.title, "Alpha")
end)

test("messages are ordered by position, tombstones remove, text is kept as data", function()
  local m = N().Model.new()
  m:apply(D(1, { ST, T("a", "running"),
    { "m", "a", "i2", "2", "assistant", "completed", "t3", "10", "second", "0" },
    { "m", "a", "i1", "1", "user", "completed", "wow", "9", "|cffff0000red|r print('x')", "0" },
    { "h", "a", "1", "1", "0" },
  }), 0)
  local msgs = m:messages("a")
  eq(#msgs, 2); eq(msgs[1].itemId, "i1"); eq(msgs[2].text, "second")
  eq(m.history.a.hasMore, true)
  m:apply(D(2, { { "x", "m:a:i2" } }), 0)
  eq(#m:messages("a"), 1)
end)

test("health separates bridge liveness from T3 freshness", function()
  local m = N().Model.new()
  eq(m:health(100).bridge, "never")
  m:apply(D(1, { { "st", "online", "connected", "1940", "", "0", "approval-required", "60" } }), 100)
  local h = m:health(130)
  eq(h.bridge, "online"); eq(h.t3, "connected"); eq(h.t3Age, 2000 - 1940 + 30)
  h = m:health(100 + 400, 60)
  eq(h.bridge, "silent")
  m:apply(D(2, { { "st", "online", "unreachable", "1500", "T3 is not answering", "0", "approval-required", "60" } }), 600)
  eq(m:health(600).t3, "unreachable")
end)

test("drafts are per target and never move to another thread", function()
  local m = N().Model.new()
  m:setDraft("thread:a", "half typed")
  eq(m:draft("thread:b"), "")
  eq(m:draft("thread:a"), "half typed")
  m:setDraft("thread:a", "")
  eq(m:draft("thread:a"), "")
end)

test("pairing expiry warning appears in the last three days", function()
  local m = N().Model.new()
  m:apply(D(1, { { "st", "online", "connected", "2000", "", tostring(2000 + 2 * 86400), "approval-required", "60" } }), 2000)
  ok(m:health(2000).pairWarning)
  m:apply(D(2, { { "st", "online", "connected", "2000", "", tostring(2000 + 20 * 86400), "approval-required", "60" } }), 2000)
  ok(not m:health(2000).pairWarning)
end)

test("request records update request state", function()
  local m = N().Model.new()
  m:apply(D(1, { ST, { "r", "7", "queued", "T3 runs it after the current turn", "a", "msg:1" } }), 0)
  eq(m.requests["7"].state, "queued")
  eq(m.requests["7"].threadId, "a")
end)

test("work state: running thread on a live link animates, with truthful last-activity age", function()
  local m = N().Model.new()
  m:apply(D(1, { ST, T("a", "running", 0, 1990) }), 100)
  local w = m:workState(m.threads.a, 105)
  eq(w.kind, "working"); eq(w.label, "Agent working"); ok(w.animate)
  eq(w.detail, "last activity 15s ago")        -- bridgeTime 2000 − 1990 + (105 − 100)
end)

test("work state: stale bridge or T3 offline → 'Status unknown', never an animated working", function()
  local m = N().Model.new()
  m:apply(D(1, { ST, T("a", "running", 0, 1990) }), 100)
  local w = m:workState(m.threads.a, 100 + 600, 60)
  eq(w.kind, "unknown"); ok(not w.animate); ok(w.detail:find("app has been silent"))
  m:apply(D(2, { { "st", "online", "unreachable", "1500", "x", "0", "operate", "60" } }), 700)
  w = m:workState(m.threads.a, 700)
  eq(w.kind, "unknown"); ok(w.detail:find("T3 is not answering"))
end)

test("work state: needs-you outranks running; finished never claims verified; failed/stopped distinct", function()
  local m = N().Model.new()
  m:apply(D(1, { ST, T("n", "running", 2, 1990), T("f", "completed", 0, 1900), T("x", "failed", 0, 1900),
                 T("s", "interrupted", 0, 1900), T("q", "queued", 0, 1990), T("w", "waiting", 0, 1990) }), 100)
  local s = function(id) return m:workState(m.threads[id], 100) end
  eq(s("n").kind, "needs"); eq(s("n").label, "Needs you"); ok(s("n").detail:find("2 requests"))
  eq(s("f").kind, "finished"); eq(s("f").label, "Run finished"); ok(s("f").detail:find("not verified"))
  eq(s("x").kind, "failed"); eq(s("s").kind, "stopped")
  eq(s("q").label, "Queued"); ok(not s("q").animate)
  eq(s("w").label, "Waiting"); ok(not s("w").animate)
end)

test("work state: a long-quiet running thread says so instead of implying progress", function()
  local m = N().Model.new()
  m:apply(D(1, { ST, T("a", "running", 0, 1000) }), 100)
  local w = m:workState(m.threads.a, 100)
  eq(w.kind, "working"); ok(w.detail:find("no activity for 16m"), w.detail)
end)

-- Delivery with explicit bridge time and status record (parent's reproduction).
local function stAt(checkedAt) return { "st", "online", "connected", tostring(checkedAt), "", "0", "approval-required", "60" } end
test("work state: fresh app heartbeat but stale T3 confirmation → unknown, never an animated working", function()
  local m = N().Model.new()
  m:apply({ epoch = 1, version = 1, bridgeTime = 4000, more = false, records = { stAt(1), T("a", "running", 0, 1) } }, 4000)
  local h = m:health(4000, 15)
  eq(h.bridge, "online"); eq(h.t3, "connected"); eq(h.t3Age, 3999)
  local w = m:workState(m.threads.a, 4000, 15)
  eq(w.kind, "unknown"); ok(not w.animate); eq(w.label, "Status unknown")
  ok(w.detail:find("T3 last confirmed 1h ago", 1, true), w.detail)
  -- pending requests from an unconfirmed backend are not asserted either
  m:apply({ epoch = 1, version = 2, bridgeTime = 4000, more = false, records = { T("a", "running", 2, 1) } }, 4000)
  eq(m:workState(m.threads.a, 4000, 15).kind, "unknown")
end)

test("work state: a long-quiet run with a fresh T3 check still shows working (backend age, not message age)", function()
  local m = N().Model.new()
  m:apply({ epoch = 1, version = 1, bridgeTime = 4000, more = false, records = { stAt(3997), T("a", "running", 0, 1) } }, 4000)
  local w = m:workState(m.threads.a, 4010, 15)
  eq(w.kind, "working"); ok(w.animate); ok(w.detail:find("no activity for 1h", 1, true), w.detail)
end)

test("work state: T3 freshness window — limit tracks the delivery interval, boundary is inclusive", function()
  local M = N().Model
  eq(M.t3FreshLimit(nil), 90); eq(M.t3FreshLimit(15), 90); eq(M.t3FreshLimit(60), 210)
  local m = M.new()
  m:apply({ epoch = 1, version = 1, bridgeTime = 4000, more = false, records = { stAt(3910), T("a", "running", 0, 3990) } }, 4000)
  ok(m:workState(m.threads.a, 4000, 15).animate, "t3Age 90 = still fresh")
  eq(m:workState(m.threads.a, 4001, 15).kind, "unknown", "t3Age 91 = stale")
  m:apply({ epoch = 1, version = 2, bridgeTime = 4000, more = false, records = { stAt(0) } }, 4000)
  local w = m:workState(m.threads.a, 4000, 15)
  eq(w.kind, "unknown"); eq(w.detail, "T3 not confirmed yet")
end)
