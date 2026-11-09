-- Whole-session slot budget with the REAL governor (addon Core/Budget.lua). Arithmetic over the
-- policy, not a game measurement. Prints JSON lines.
local root, pool = arg[1], tonumber(arg[2])
local H = dofile(root .. "/tests/lua/harness.lua"); H.ROOT = root
local ns = H.loadAddon(H.CORE)
local function run(phases, horizon)
  local b = ns.Budget.new({ slotCount = pool, startedAt = 0, horizon = horizon })
  local t, used, worst = 0, 0, 0
  for _, ph in ipairs(phases) do
    local stop = t + ph[2]
    while t < stop do
      local i = b:interval(ph[1], t, used)
      if not i then return { exhaustedAtHours = t / 3600, used = used, worstIntervalS = worst } end
      worst = math.max(worst, i); t = t + i; used = used + 1
    end
  end
  return { used = used, worstIntervalS = worst }
end
local evening = { { "idle", 1800 }, { "active", 3600 }, { "open", 600 }, { "reply", 900 }, { "active", 2700 }, { "reply", 600 }, { "idle", 4200 } }
local function rep(p, n) local o = {} for _ = 1, n do for _, x in ipairs(p) do o[#o + 1] = x end end return o end
local r4 = run(evening, 8 * 3600)
local r8 = run(rep(evening, 2), 8 * 3600)
local r12 = run(rep(evening, 3), 12 * 3600)
local act = run({ { "active", 24 * 3600 } }, 8 * 3600)
print(string.format('{"pool":%d,"typical4h":{"used":%d,"worstIntervalS":%d},"typical8h":{"used":%d,"worstIntervalS":%d},"typical12hWithHorizon12h":%s,"continuousActiveHoursUntilExhausted":%.1f}',
  pool, r4.used, r4.worstIntervalS, r8.used, r8.worstIntervalS,
  r12.exhaustedAtHours and string.format('{"exhaustedAtHours":%.1f}', r12.exhaustedAtHours) or string.format('{"used":%d,"worstIntervalS":%d}', r12.used, r12.worstIntervalS),
  act.exhaustedAtHours or 24))
