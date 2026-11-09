-- T3 for WoW: bootstrap. Globals created: T3ForWoW_Deliver (called by slot files), T3ForWoWDB
-- (SavedVariables: window/tracker positions only; no messages, drafts or credentials).
local ADDON, ns = ...
local App = {}
ns.App = App

local timeBase
function App.clock()
  if not timeBase then timeBase = time() - GetTime() end
  return timeBase + GetTime()
end

local function countSlots()
  local n = 0
  while n < 4000 and C_AddOns.DoesAddOnExist(string.format("T3ForWoW_Slot%04d", n + 1)) do n = n + 1 end
  return n
end

function App:toggleWindow() if ns.Window.frame:IsShown() then ns.Window.frame:Hide() else ns.Window.frame:Show() end end
function App:openThread(id) ns.Window.frame:Show(); ns.Window.select(id) end

function App:refresh()
  ns.Tracker.refresh()
  ns.Window.refresh()
end

function App:start()
  self.db = T3ForWoWDB
  self.transport = ns.Transport.new({
    clock = App.clock,
    random = function() return math.random(1, 2147483646) end,
    slotCount = countSlots(),
    loadSlot = function(k)
      local loaded, reason = C_AddOns.LoadAddOn(string.format("T3ForWoW_Slot%04d", k))
      if loaded then return true end
      return false, reason
    end,
  })
  T3ForWoW_Deliver = function(slot, payload) App.transport:onDeliver(slot, payload) end
  ns.Strip.create()
  ns.Tracker.create(self)
  ns.Window.create(self)
  if self.transport.slotCount == 0 then
    self.transport.loadError = "no delivery slots installed — run the T3 for WoW app's installer"
  end
  local tick = 0
  C_Timer.NewTicker(0.25, function()
    tick = tick + 1
    local now = App.clock()
    local loaded = self.transport:step(now)
    if tick % 2 == 0 then ns.Strip.paint(self.transport:frame()) end
    if loaded or tick % 8 == 0 then self:refresh() end
  end)
  ns.Strip.paint(self.transport:frame())
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("UI_SCALE_CHANGED")
ev:RegisterEvent("DISPLAY_SIZE_CHANGED")
ev:SetScript("OnEvent", function(_, event, name)
  if event == "ADDON_LOADED" and name == ADDON then
    T3ForWoWDB = type(T3ForWoWDB) == "table" and T3ForWoWDB or {}
  elseif event == "PLAYER_LOGIN" then
    App:start()
  elseif ns.Strip.frame then
    ns.Strip.layout()
  end
end)

-- /t3wow always; /t3 only if no other addon already registered it (checked once at load).
local function slashTaken(cmd)
  for k, v in pairs(_G) do
    if type(k) == "string" and k:sub(1, 6) == "SLASH_" and type(v) == "string" and v:lower() == cmd and not k:find("^SLASH_T3FORWOW") then return true end
  end
  return false
end
SLASH_T3FORWOW1 = "/t3wow"
if not slashTaken("/t3") then SLASH_T3FORWOW2 = "/t3" end
local function say(s) DEFAULT_CHAT_FRAME:AddMessage("|cffffd100T3 for WoW:|r " .. s) end
SlashCmdList.T3FORWOW = function(msg)
  msg = ((msg or ""):lower():match("^%s*(.-)%s*$")) or ""
  if not App.transport then say("still loading; try again in a moment."); return end
  if msg == "" then
    App:toggleWindow()
  elseif msg == "tracker" then
    local f = ns.Tracker.frame
    if f:IsShown() then f:Hide() else f:Show() end
    App.transport.trackerVisible = f:IsShown()
  elseif msg == "reset" then
    App.db.tracker = nil
    local f = ns.Tracker.frame
    f:ClearAllPoints(); f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 24, -190); f:Show()
    App.transport.trackerVisible = true
    ns.Window.frame:ClearAllPoints(); ns.Window.frame:SetPoint("CENTER")
    ns.Tracker.refresh()
    say("tracker and journal moved back to their default places.")
  elseif msg == "help" or msg == "?" then
    local c = SLASH_T3FORWOW2 or SLASH_T3FORWOW1
    say(c .. " — open or close the T3 Journal")
    say(c .. " tracker — show or hide the tracker (shift-drag moves it, right-click collapses it)")
    say(c .. " reset — move the tracker and journal back to their default places")
    say("Needs the T3 for WoW app running on this Mac. Each update uses one delivery slot; when they run out, the journal offers Reload UI.")
  else
    say("unknown command \"" .. msg:sub(1, 20):gsub("|", "||") .. "\". Type " .. (SLASH_T3FORWOW2 or SLASH_T3FORWOW1) .. " help.")
  end
end
