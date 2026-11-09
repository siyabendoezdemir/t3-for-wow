-- Slot budget governor (docs/PROTOCOL.md section 3). The slot pool is finite per UI session;
-- this module decides how long to wait before loading the next one. It never reloads anything.
local _, ns = ...
local Budget = {}
Budget.__index = Budget
ns.Budget = Budget

Budget.POLICY = { reply = 15, open = 30, active = 60, idle = 120 }
Budget.SILENCE = { 60, 120, 300 }
Budget.DEFAULT_HORIZON = 8 * 3600

function Budget.new(o)
  return setmetatable({ slotCount = o.slotCount, startedAt = o.startedAt or 0, horizon = o.horizon or Budget.DEFAULT_HORIZON }, Budget)
end

function Budget:status(used)
  local remaining = math.max(0, self.slotCount - used)
  return { remaining = remaining, used = used, low = remaining <= math.floor(self.slotCount * 0.1), exhausted = remaining == 0 }
end

-- mode: reply|open|active|idle; silentStreak: consecutive deliveries with nothing new from the bridge.
-- Returns seconds until the next slot load, or nil when the pool is exhausted.
function Budget:interval(mode, now, used, silentStreak)
  local remaining = self.slotCount - used
  if remaining <= 0 then return nil end
  local want = Budget.POLICY[mode] or Budget.POLICY.idle
  if silentStreak and silentStreak > 0 then
    want = math.max(want, Budget.SILENCE[math.min(silentStreak, #Budget.SILENCE)])
  end
  local horizonLeft = math.max(0, self.horizon - (now - self.startedAt))
  -- Bursts may run up to 4x the average rate while the pool is healthy; the allowance tightens as
  -- it drains, and in the last quarter the pace is exactly "what is left, spread over the time left".
  local k = remaining > self.slotCount * 0.5 and 0.25 or (remaining > self.slotCount * 0.25 and 0.5 or 1.0)
  local floor = math.ceil(k * horizonLeft / remaining)
  return math.max(want, floor)
end
