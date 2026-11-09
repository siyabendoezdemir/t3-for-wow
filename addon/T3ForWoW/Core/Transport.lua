-- Ties outbox, frame, slots, budget and model together. WoW specifics are injected:
--   env.clock()        -> seconds (WoW: GetTime-based wall clock, see T3ForWoW.lua)
--   env.loadSlot(k)    -> true | false, reason  (WoW: C_AddOns.LoadAddOn("T3ForWoW_Slot%04d"))
--   env.random()       -> 32-bit session id
local _, ns = ...
local Transport = { DWELL = 3, REPLY_WINDOW = 600 }
Transport.__index = Transport
ns.Transport = Transport

function Transport.new(env)
  local now = env.clock()
  local t = setmetatable({
    env = env, gameSession = env.random(), slotCount = env.slotCount, nextSlot = env.slotCount > 0 and 1 or 0,
    used = 0, frameSeq = 0, epochAck = 0, deliveryAck = 0, silent = 0, announcedAt = now, nextLoadAt = now + Transport.DWELL,
    windowOpen = false, trackerVisible = true, lastReason = nil, loadError = nil,
  }, Transport)
  t.model = ns.Model.new()
  t.outbox = ns.Outbox.new(env.clock)
  t.budget = ns.Budget.new({ slotCount = env.slotCount, startedAt = now, horizon = env.horizon })
  return t
end

function Transport:flags()
  local f = 0
  if self.windowOpen then f = f + 1 end
  if self.nextSlot == 0 then f = f + 2 end
  if self.trackerVisible then f = f + 4 end
  return f
end

-- Bytes for the pixel strip right now.
function Transport:frame()
  self.frameSeq = (self.frameSeq + 1) % 65536
  return ns.Frame.encode({ gameSession = self.gameSession, frameSeq = self.frameSeq, epochAck = self.epochAck, deliveryAck = self.deliveryAck,
    nextSlot = self.nextSlot, slotCount = self.slotCount, flags = self:flags(), chunks = self.outbox:nextChunks(ns.Frame.MAX_PAYLOAD) })
end

function Transport:mode(now)
  local m = self.model
  for _, id in ipairs(self.outbox.order) do
    local it = self.outbox.items[id]
    if (it.kind == "S" or it.kind == "N") and now - it.sentAt < Transport.REPLY_WINDOW then
      local th = it.threadId and m.threads[it.threadId]
      if not it.acked or (th and (th.status == "running" or th.status == "starting" or th.status == "queued" or th.status == "preparing")) then return "reply" end
    end
  end
  if self.windowOpen then
    local w = self.watching and m.threads[self.watching]
    if w and w.status == "running" then return "reply" end
    return "open"
  end
  local g = m:tracker(now)
  if #g.needs > 0 or #g.working > 0 then return "active" end
  return "idle"
end

-- Called by the slot's code (via the T3ForWoW_Deliver global) during loadSlot.
function Transport:onDeliver(slot, payload)
  local now = self.env.clock()
  local d, reason = ns.Delivery.parse(payload, { slot = slot, gameSession = self.gameSession })
  self.lastReason = reason
  if not d then return false end
  local result = self.model:apply(d, now)
  if result == "applied" then
    self.epochAck, self.deliveryAck = d.epoch, d.version
    for _, r in ipairs(d.records) do
      if r[1] == "r" then self.outbox:ack(tonumber(r[2]), r[3]) end
    end
    self.outbox:compact()
    self.gotFresh = true
  end
  return true
end

function Transport:due(now) return self.nextSlot > 0 and now >= self.nextLoadAt end

-- Loads the next slot if it is due. Returns the slot loaded or nil.
function Transport:step(now)
  self.outbox:expire()
  if not self:due(now) then return nil end
  local slot = self.nextSlot
  self.gotFresh = false
  local ok, why = self.env.loadSlot(slot)
  if not ok then
    -- e.g. slot addons disabled in the AddOns list: say so, don't burn the pool.
    self.loadError = why or "could not load"
    self.nextLoadAt = now + 60
    return nil
  end
  self.loadError = nil
  self.used = self.used + 1
  self.silent = self.gotFresh and 0 or self.silent + 1
  self.nextSlot = slot < self.slotCount and slot + 1 or 0
  self.announcedAt = now
  local interval = self.budget:interval(self:mode(now), now, self.used, self.silent)
  if self.env.intervalOverride then interval = interval and self.env.intervalOverride end
  self.expected = interval
  self.nextLoadAt = interval and now + math.max(Transport.DWELL, interval) or math.huge
  return slot
end

-- Something the player did needs fresh data soon (opened the window, sent a reply).
function Transport:expedite(now)
  if self.nextSlot == 0 then return end
  local i = self.budget:interval("reply", now, self.used, 0) or 0
  local soonest = math.max(self.announcedAt + Transport.DWELL, now + Transport.DWELL)
  self.nextLoadAt = math.min(self.nextLoadAt, math.max(soonest, self.announcedAt + i))
end

function Transport:budgetStatus() return self.budget:status(self.used) end
