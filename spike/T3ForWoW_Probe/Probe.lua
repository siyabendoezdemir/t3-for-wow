-- T3 for WoW — bounded real-client transport probe (spike only; not part of the product).
-- Answers, in the real WoW: Forever client, using only documented APIs:
--   H0  a loaded LoD addon whose file is rewritten is NOT re-run by LoadAddOn   (confirms finite slots)
--   H1  LoadAddOn on an LoD addon whose listed file is missing: retriable failure, or consumed?
--   H1b an LoD addon folder created after startup: does the client ever see it?
--   H2  FontInstance:SetFont(success) on a loose font file: does it track live create/delete?
--   H2b C_UIFileAsset.IsKnownFile on the same path: live or startup index?
--   H4  time from this addon's load to PLAYER_LOGIN, and the number of addons the client indexed
-- Output: local chat frame lines "T3PROBE ..." and SavedVariables T3ForWoWProbeDB (written by the
-- client at logout or a player-initiated /reload). No input, no network, no reload, no other addon.
local START = debugprofilestop()
local LOG = {}
T3ForWoWProbeDB = nil
local t0
local function now() return t0 and (GetTime() - t0) or 0 end
local function log(fmt, ...)
  local line = string.format("%6.1f ", now()) .. string.format(fmt, ...)
  LOG[#LOG + 1] = line
  if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("T3PROBE " .. line) end
end

local BELL = "Interface\\AddOns\\T3ForWoW_Probe\\bell.ttf"
local last = {}
local function changed(key, value)
  value = tostring(value)
  if last[key] ~= value then last[key] = value; log("%s = %s", key, value) end
end

T3ForWoWProbe_Ran = function(id, version) log("EXEC %s version=%s", tostring(id), tostring(version)) end

local fs
local function poll()
  -- H0: L1 was loaded at start; companion rewrites it at +10 s; we ask again every poll.
  local okL1, whyL1 = C_AddOns.LoadAddOn("T3ForWoW_ProbeL1")
  changed("H0 LoadAddOn(L1)", tostring(okL1) .. "/" .. tostring(whyL1))
  -- H1: L2's listed file is missing at startup; companion creates it at +30 s.
  local loaded, loadedOrLoading = C_AddOns.IsAddOnLoaded("T3ForWoW_ProbeL2")
  changed("H1 IsAddOnLoaded(L2)", tostring(loaded) .. "/" .. tostring(loadedOrLoading))
  local ok2, why2 = C_AddOns.LoadAddOn("T3ForWoW_ProbeL2")
  changed("H1 LoadAddOn(L2)", tostring(ok2) .. "/" .. tostring(why2))
  -- H1b: L3 folder does not exist at startup; companion creates it at +30 s.
  changed("H1b DoesAddOnExist(L3)", C_AddOns.DoesAddOnExist("T3ForWoW_ProbeL3"))
  -- H2/H2b: bell.ttf absent at start; created +40 s, deleted +70 s, re-created +100 s.
  changed("H2 SetFont(bell)", fs:SetFont(BELL, 12, ""))
  if C_UIFileAsset and C_UIFileAsset.IsKnownFile then changed("H2b IsKnownFile(bell)", C_UIFileAsset.IsKnownFile(BELL)) end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
  t0 = GetTime()
  log("READY addons=%d loadToLogin_ms=%.0f build=%s", C_AddOns.GetNumAddOns(), debugprofilestop() - START, tostring((select(4, GetBuildInfo()))))
  fs = f:CreateFontString(nil, "OVERLAY")
  local okL1, whyL1 = C_AddOns.LoadAddOn("T3ForWoW_ProbeL1")
  log("H0 initial LoadAddOn(L1) = %s/%s", tostring(okL1), tostring(whyL1))
  local ticks = 0
  local ticker
  ticker = C_Timer.NewTicker(2, function()
    ticks = ticks + 1
    poll()
    if ticks >= 75 then -- 150 s, then stop by itself
      ticker:Cancel()
      log("DONE")
      T3ForWoWProbeDB = { log = LOG, finishedAt = time() }
    end
  end)
end)
