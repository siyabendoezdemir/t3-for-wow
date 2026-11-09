local H = ...
local test, eq, ok = H.test, H.eq, H.ok
-- SYNTHETIC: proves the spike probe runs, records transitions and stops itself. Not a client result.
test("spike probe: records each observable transition once and finishes in 150 s", function()
  local S = assert(loadfile(H.ROOT .. "/tests/lua/wowstub.lua"))(H.ROOT)
  local env = setmetatable({}, { __index = _G }); env._G = env; S.install(env); S.slotCount = 0
  local lines = {}
  env.debugprofilestop = function() return 0 end
  env.GetBuildInfo = function() return "1.60.1", "70862", "x", 16001 end
  env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) lines[#lines + 1] = m end }
  env.C_AddOns.GetNumAddOns = function() return 3 end
  env.C_AddOns.IsAddOnLoaded = function() return false, false end
  local bell = false
  S.fontExists = function() return bell end
  local c = assert(loadfile(H.ROOT .. "/spike/T3ForWoW_Probe/Probe.lua")); setfenv(c, env); c("T3ForWoW_Probe", {})
  S.fire("PLAYER_LOGIN")
  S.advance(40); bell = true; S.advance(40); bell = false; S.advance(80)
  local text = table.concat(lines, "\n")
  ok(text:find("READY addons=3"), text)
  local n = 0
  for _ in text:gmatch("H2 SetFont%(bell%) = ") do n = n + 1 end
  eq(n, 3, "false -> true -> false transitions logged once each")
  ok(text:find("DONE")); ok(env.T3ForWoWProbeDB and #env.T3ForWoWProbeDB.log > 0)
end)
