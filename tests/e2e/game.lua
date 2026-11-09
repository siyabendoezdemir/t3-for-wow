-- SYNTHETIC game process for the cross-process end-to-end harness. Runs the real addon core
-- (Transport/Outbox/Model/Frame/Delivery) outside WoW: draws the strip into a PPM "screen" the
-- bridge captures, and loads slot files exactly as the client executes them (only the
-- T3ForWoW_Deliver global exists). NOT a WoW client, NOT in-game evidence.
--   lua game.lua <root> <addonsDir> <screen.ppm> <session> <script> [args...]
local root, addons, screen, session, script = arg[1], arg[2], arg[3], tonumber(arg[4]), arg[5]
local H = dofile(root .. "/tests/lua/harness.lua"); H.ROOT = root
local ns = H.loadAddon(H.CORE)
ns.Transport.DWELL = 1

local function now() local p = io.popen("date +%s.%N"); local s = p:read("*l"); p:close(); return tonumber(s) end
local function sleep(s) os.execute("sleep " .. s) end
local function out(k, v) print(k .. "=" .. tostring(v)); io.stdout:flush() end

local tr
local env = { clock = now, random = function() return session end, slotCount = tonumber(os.getenv("E2E_SLOTS") or "40"), intervalOverride = 1 }
env.loadSlot = function(k)
  local path = string.format("%s/T3ForWoW_Slot%04d/Slot.lua", addons, k)
  local f = io.open(path, "rb"); if not f then return false, "MISSING" end
  local src = f:read("*a"); f:close()
  local chunk = loadstring(src, "slot")
  if not chunk then return false, "CORRUPT" end
  setfenv(chunk, { T3ForWoW_Deliver = function(slot, payload) tr:onDeliver(slot, payload) end })
  local ok = pcall(chunk)
  return true, ok and nil or "error"
end
tr = ns.Transport.new(env)
if os.getenv("E2E_NEXT_REQ") then tr.outbox.nextId = tonumber(os.getenv("E2E_NEXT_REQ")) end
tr.windowOpen = true

local function draw()
  local g = ns.Frame.grid(tr:frame())
  local cell, W, Hh = 3, 80 * 3 + 40, 16 * 3 + 20
  local px = {}
  for i = 1, W * Hh do px[i] = "\30\20\15" end
  for i, c in ipairs(g.cells) do
    local cx, cy = 20 + ((i - 1) % 80) * cell, 10 + math.floor((i - 1) / 80) * cell
    local s = string.char(c[1], c[2], c[3])
    for dy = 0, cell - 1 do for dx = 0, cell - 1 do px[(cy + dy) * W + cx + dx + 1] = s end end
  end
  local tmp = screen .. ".tmp"
  local f = assert(io.open(tmp, "wb")); f:write("P6\n" .. W .. " " .. Hh .. "\n255\n" .. table.concat(px)); f:close()
  os.rename(tmp, screen)
end

local function pump(seconds, until_)
  local stop = now() + seconds
  while now() < stop do
    draw()
    tr:step(now())
    if until_ and until_() then return true end
    sleep(0.25)
  end
  return false
end

local function threadByTitle(title)
  for _, t in pairs(tr.model.threads) do if t.title == title then return t end end
end
local function reqState(id) local it = tr.outbox:get(id); return it and it.state end
local function settledReq(id) local s = reqState(id); return s and s ~= "waiting" and s ~= "sending" and s ~= "unconfirmed" end

out("SESSION", session)
local t0 = now()
if not pump(60, function() return tr.model.st and tr.model.st.t3 == "connected" and threadByTitle("Owner thread") end) then out("FAIL", "no tracker data"); os.exit(1) end
out("TRACKER_READY_S", string.format("%.1f", now() - t0))
local h = tr.model:health(now(), 5)
out("HEALTH", h.bridge .. "/" .. h.t3)

if script == "main" then
  local owner = threadByTitle("Owner thread")
  out("OWNER_THREAD_MODE", owner.runtimeMode); out("OWNER_THREAD_CANREPLY", owner.canReply)
  local r1 = tr.outbox:send(owner.id, "e2e: should be refused by the permission ceiling")
  pump(30, function() return settledReq(r1) end)
  out("CEILING_REQ", reqState(r1))
  out("CEILING_DETAIL", (tr.model.requests[tostring(r1)] or {}).detail)

  local r2 = tr.outbox:newThread(owner.projectId, "WoW thread", "e2e: new thread from the game")
  pump(40, function() return settledReq(r2) and threadByTitle("WoW thread") end)
  out("NEWTHREAD_REQ", reqState(r2))
  out("NEWTHREAD_DETAIL", (tr.model.requests[tostring(r2)] or {}).detail)
  local wt = threadByTitle("WoW thread")
  out("NEWTHREAD_SEEN", wt ~= nil)
  pump(30, function() local t = threadByTitle("WoW thread"); return t and t.status == "failed" end)
  wt = threadByTitle("WoW thread")
  out("NEWTHREAD_STATUS", wt and ns.Model.label(wt.status))
  if not wt then os.exit(1) end

  tr.watching = wt.id
  tr.outbox:watch(wt.id)
  local text = "e2e: exactly once from WoW " .. session
  local t1 = now()
  local r3 = tr.outbox:send(wt.id, text)
  out("REPLY_REQ_ID", r3)
  pump(40, function() return settledReq(r3) end)
  out("REPLY_REQ", reqState(r3))
  out("REPLY_ACK_S", string.format("%.1f", now() - t1))
  local seen = pump(40, function()
    for _, m in ipairs(tr.model:messages(wt.id)) do if m.text == text and m.author == "wow" then return true end end
  end)
  out("REPLY_IN_HISTORY", seen)
  out("REPLY_VISIBLE_S", string.format("%.1f", now() - t1))
  out("THREAD_ID", wt.id)
  out("SLOTS_USED", tr.used)
elseif script == "reshow" then
  -- Same game session, same reqId and text as before a bridge crash: must not duplicate.
  local wt = threadByTitle("WoW thread")
  local id = tr.outbox:send(wt.id, "e2e: exactly once from WoW " .. arg[6])
  out("RESHOW_REQ_ID", id)
  pump(40, function() return settledReq(id) end)
  out("RESHOW_REQ", reqState(id))
  out("EPOCH", tr.epochAck)
  out("SLOTS_USED", tr.used)
end
