local H = ...
local test, eq, ok = H.test, H.eq, H.ok
local function Budget() return H.loadAddon(H.CORE).Budget end

test("policy intervals by mode (large pool: governor inactive)", function()
  local b = Budget().new({ slotCount = 100000, startedAt = 0 })
  eq(b:interval("reply", 0, 0), 15)
  eq(b:interval("open", 0, 0), 30)
  eq(b:interval("active", 0, 0), 60)
  eq(b:interval("idle", 0, 0), 120)
end)

test("governor: bursts cannot drain the pool early", function()
  local b = Budget().new({ slotCount = 100, startedAt = 0, horizon = 8 * 3600 })
  -- 100 slots over 8 h = 288 s average; the floor is a quarter of the remaining average.
  eq(b:interval("reply", 0, 0), 72)
  -- after 90 slots used in the first hour, 10 remain (< 25 %): exactly 7 h / 10 = 2520 s
  eq(b:interval("idle", 3600, 90), 2520)
  -- 60 remaining (> 50 %) at t=0: a quarter of the average
  eq(b:interval("reply", 0, 40), math.ceil(0.25 * 28800 / 60))
end)

test("default pool keeps the 15 s reply cadence at the start of a session", function()
  local b = Budget().new({ slotCount = 480, startedAt = 0 })
  eq(b:interval("reply", 0, 0), 15)
end)

test("governor never exhausts the pool before the horizon even when always replying", function()
  local b = Budget().new({ slotCount = 480, startedAt = 0 })
  local t, used = 0, 0
  while t < 8 * 3600 do local i = b:interval("reply", t, used); assert(i, "exhausted at " .. t); t = t + i; used = used + 1 end
  ok(used <= 480, "used " .. used) -- the loop's assert proves it was never exhausted before 8 h
end)

test("bridge silence backs off 60 -> 120 -> 300", function()
  local b = Budget().new({ slotCount = 480, startedAt = 0 })
  eq(b:interval("reply", 0, 0, 1), 60)
  eq(b:interval("reply", 0, 0, 2), 120)
  eq(b:interval("reply", 0, 0, 3), 300)
  eq(b:interval("reply", 0, 0, 9), 300)
end)

test("low and exhausted states are explicit", function()
  local b = Budget().new({ slotCount = 480, startedAt = 0 })
  ok(not b:status(431).low); ok(b:status(432).low)
  eq(b:status(479).remaining, 1)
  ok(b:status(480).exhausted)
  ok(b:interval("idle", 0, 480) == nil, "no interval once exhausted")
end)

-- A representative 4-hour evening, simulated against the governor with 480 slots.
-- Summarised in docs/LIMITS.md; this is arithmetic over the policy, not a game measurement.
test("representative 4 h session fits the default pool with margin", function()
  local b = Budget().new({ slotCount = 480, startedAt = 0 })
  local t, used = 0, 0
  local function phase(mode, seconds)
    local stop = t + seconds
    while t < stop do
      local i = b:interval(mode, t, used); assert(i, "exhausted at t=" .. t)
      t = t + i; used = used + 1
    end
  end
  phase("idle", 30 * 60)      -- playing, nothing running
  phase("active", 60 * 60)    -- agents working, tracker only
  phase("open", 10 * 60)      -- browsing a conversation
  phase("reply", 15 * 60)     -- replying and waiting for an answer
  phase("active", 45 * 60)
  phase("reply", 10 * 60)
  phase("idle", 70 * 60)
  H.SESSION_4H_USED = used
  ok(used <= 288, "4 h must leave at least 40% of the pool: used " .. used)
  ok(not b:status(used).low, "not even low after 4 h")
end)

test("tracker-only working all evening: 8 h at the active cadence fits", function()
  local b = Budget().new({ slotCount = 480, startedAt = 0 })
  local t, used = 0, 0
  while t < 8 * 3600 - 60 do local i = b:interval("active", t, used); assert(i, "exhausted at " .. t); t = t + i; used = used + 1 end
  H.SESSION_8H_ACTIVE_USED = used
  ok(used <= 480)
end)
