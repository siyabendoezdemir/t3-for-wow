-- Game-side model of the owner's T3: what the bridge last told us, plus local drafts.
-- All text is data; nothing here is ever evaluated.
local _, ns = ...
local Model = {}
Model.__index = Model
ns.Model = Model

local LABELS = {
  running = "Working", starting = "Starting", preparing = "Starting", queued = "Queued",
  waiting = "Waiting", completed = "Run finished", interrupted = "Stopped", cancelled = "Stopped",
  failed = "Failed", rolled_back = "Rolled back", idle = "Idle",
}
local WORKING = { running = true, starting = true, preparing = true, queued = true, waiting = true }
local RECENT = { completed = true, interrupted = true, cancelled = true, failed = true, rolled_back = true }
Model.RECENT_WINDOW = 12 * 3600
Model.SILENT_AFTER = 3

function Model.label(status) return LABELS[status] or "Unknown" end

function Model.new()
  local m = setmetatable({ drafts = {} }, Model)
  m:reset()
  return m
end

function Model:reset()
  self.epoch, self.version = nil, -1
  self.st, self.projects, self.threads, self.order = nil, {}, {}, {}
  self.msgs, self.history, self.requests = {}, {}, {}
  self.appliedAt, self.bridgeTime = nil, nil
end

local function num(s) return tonumber(s) or 0 end

function Model:applyRecord(r)
  local k = r[1]
  if k == "st" then
    self.st = { bridge = r[2], t3 = r[3], t3CheckedAt = num(r[4]), notice = r[5], pairExpiresAt = num(r[6]), access = r[7], hint = num(r[8]) }
  elseif k == "p" then
    self.projects[r[2]] = { id = r[2], title = r[3] }
  elseif k == "t" then
    self.threads[r[2]] = { id = r[2], projectId = r[3], title = r[4], status = r[5], pending = num(r[6]), updatedAt = num(r[7]),
      settled = r[8] == "1", runtimeMode = r[9], canReply = r[10] == "1", summary = r[11] }
  elseif k == "tl" then
    local order = {}
    for i = 2, #r do order[#order + 1] = r[i] end
    self.order = order
  elseif k == "m" then
    local list = self.msgs[r[2]] or {}
    self.msgs[r[2]] = list
    list[r[3]] = { itemId = r[3], position = num(r[4]), kind = r[5], status = r[6], author = r[7], updatedAt = num(r[8]), text = r[9], truncated = r[10] == "1" }
  elseif k == "h" then
    self.history[r[2]] = { oldest = num(r[3]), hasMore = r[4] == "1", loading = r[5] == "1" }
  elseif k == "r" then
    self.requests[r[2]] = { state = r[3], detail = r[4], threadId = r[5], messageId = r[6] }
  elseif k == "x" then
    local key = r[2]
    local tid = key:match("^t:(.+)$")
    if tid then self.threads[tid] = nil; self.msgs[tid] = nil end
    local mt, mi = key:match("^m:(.-):(.+)$")
    if mt and self.msgs[mt] then self.msgs[mt][mi] = nil end
  end
end

-- d: parsed delivery; now: game clock. Returns "applied" or "old".
function Model:apply(d, now)
  if d.epoch ~= self.epoch then self:reset(); self.epoch = d.epoch
  elseif d.version <= self.version then return "old" end
  for _, r in ipairs(d.records) do self:applyRecord(r) end
  self.version, self.bridgeTime, self.appliedAt = d.version, d.bridgeTime, now
  return "applied"
end

local function newestFirst(a, b) if a.updatedAt ~= b.updatedAt then return a.updatedAt > b.updatedAt end return a.id < b.id end

-- Needs-you is a pending runtime request (question/approval), which outranks any run state.
function Model:isNeedsYou(t) return t.pending > 0 end

-- Groups for the compact tracker and the expanded list.
function Model:tracker(now, projectId)
  local g = { needs = {}, working = {}, recent = {}, other = {} }
  local ref = self.bridgeTime or now
  for _, t in pairs(self.threads) do
    if not t.settled and (not projectId or t.projectId == projectId) then
      if self:isNeedsYou(t) then g.needs[#g.needs + 1] = t
      elseif WORKING[t.status] then g.working[#g.working + 1] = t
      elseif RECENT[t.status] and ref - t.updatedAt <= Model.RECENT_WINDOW then g.recent[#g.recent + 1] = t
      else g.other[#g.other + 1] = t end
    end
  end
  for _, list in pairs(g) do table.sort(list, newestFirst) end
  return g
end

function Model:messages(threadId)
  local out = {}
  for _, m in pairs(self.msgs[threadId] or {}) do out[#out + 1] = m end
  table.sort(out, function(a, b) return a.position < b.position end)
  return out
end

-- expectedInterval: seconds until the next slot was due. Bridge is "silent" when no fresh
-- delivery arrived for SILENT_AFTER intervals.
function Model:health(now, expectedInterval)
  if not self.appliedAt then return { bridge = "never", t3 = "unknown" } end
  local h = { bridge = "online", t3 = self.st and self.st.t3 or "unknown", notice = self.st and self.st.notice or "" }
  local since = now - self.appliedAt
  if expectedInterval and since > expectedInterval * Model.SILENT_AFTER then h.bridge = "silent" end
  if self.st then
    h.t3Age = (self.bridgeTime - self.st.t3CheckedAt) + since
    local exp = self.st.pairExpiresAt
    if exp > 0 and exp - now < 3 * 86400 then h.pairWarning = math.max(0, math.floor((exp - now) / 86400)) end
  end
  h.age = since
  return h
end

-- Seconds since a bridge timestamp, counting game time elapsed since the last delivery (so a silent
-- link never makes old activity look recent).
function Model:ageOf(ts, now)
  return (self.bridgeTime or now) - (ts or 0) + (self.appliedAt and (now - self.appliedAt) or 0)
end

function Model:draft(key) return self.drafts[key] or "" end
function Model:setDraft(key, text) if text == "" then self.drafts[key] = nil else self.drafts[key] = text end end

-- Truthful work state for one thread: what the journal and tracker show, and whether the "working"
-- spinner may animate. Animation needs a live bridge, a connected T3 and a running/starting run.
-- kinds: needs · working · finished · failed · stopped · idle · unknown
Model.QUIET_AFTER = 10 * 60
-- A fresh app heartbeat is not fresh backend confirmation. While the game is active the bridge talks to
-- T3 every few seconds and stamps each success (st.t3CheckedAt), so a live link carries a check only
-- seconds old. Allow the normal spacing between deliveries (the same SILENT_AFTER intervals that mark
-- the app itself silent) plus margin, and never less than T3_FRESH_MIN.
Model.T3_FRESH_MIN = 90
function Model.t3FreshLimit(expectedInterval)
  return math.max(Model.T3_FRESH_MIN, (expectedInterval or 0) * Model.SILENT_AFTER + 30)
end
function Model:workState(t, now, expectedInterval)
  local h = self:health(now, expectedInterval)
  local age = self:ageOf(t.updatedAt, now)
  local ago = ns.Text.age(age)
  local last = age < 5 and "last activity just now" or ("last activity " .. (age < 60 and (math.floor(age) .. "s") or ago) .. " ago")
  if h.bridge ~= "online" then
    return { kind = "unknown", label = "Status unknown", detail = h.bridge == "never" and "no update from the app yet"
             or ("the T3 for WoW app has been silent for " .. ns.Text.age(h.age)), animate = false }
  end
  if h.t3 ~= "connected" then return { kind = "unknown", label = "Status unknown", detail = "T3 is not answering", animate = false } end
  if not h.t3Age or h.t3Age > Model.t3FreshLimit(expectedInterval) then
    return { kind = "unknown", label = "Status unknown", animate = false,
             detail = (h.t3Age and self.st.t3CheckedAt > 0) and ("T3 last confirmed " .. ns.Text.age(h.t3Age) .. " ago") or "T3 not confirmed yet" }
  end
  if t.pending > 0 then
    return { kind = "needs", label = "Needs you", detail = (t.pending == 1 and "1 request" or (t.pending .. " requests")) .. " waiting — answer in T3", animate = false }
  end
  local s = t.status
  if s == "running" or s == "starting" or s == "preparing" then
    local quiet = age >= Model.QUIET_AFTER
    return { kind = "working", label = s == "running" and "Agent working" or "Starting",
             detail = quiet and ("no activity for " .. ago) or last, animate = true }
  end
  if s == "queued" then return { kind = "working", label = "Queued", detail = last, animate = false } end
  if s == "waiting" then return { kind = "working", label = "Waiting", detail = last, animate = false } end
  if s == "completed" then return { kind = "finished", label = "Run finished", detail = "results not verified · " .. ago .. " ago", animate = false } end
  if s == "failed" then return { kind = "failed", label = "Run failed", detail = ago .. " ago", animate = false } end
  if s == "interrupted" or s == "cancelled" then return { kind = "stopped", label = "Stopped", detail = ago .. " ago", animate = false } end
  return { kind = "idle", label = Model.label(s), detail = ago ~= "" and (ago .. " ago") or "", animate = false }
end
