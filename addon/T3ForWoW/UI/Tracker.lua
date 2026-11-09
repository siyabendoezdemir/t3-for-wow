-- Compact, quest-objective-like tracker: needs-you first, then working, then recently stopped.
-- Its own frame (never touches the quest tracker); shift-drag to move; click a line to open it.
local _, ns = ...
local Tracker = { MAX_LINES = 6 }
ns.Tracker = Tracker
local T = ns.Text

local COLORS = {
  needs = { 1.0, 0.55, 0.1 }, working = { 0.4, 0.78, 1.0 }, recent = { 0.62, 0.62, 0.62 },
}

function Tracker.create(app)
  local f = CreateFrame("Frame", "T3ForWoWTracker", UIParent)
  Tracker.frame, Tracker.app = f, app
  f:SetSize(230, 24)
  f:SetMovable(true)
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) if IsShiftKeyDown() then self:StartMoving() end end)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, rp, x, y = self:GetPoint(1)
    app.db.tracker = { point = p, relPoint = rp, x = x, y = y, collapsed = app.db.tracker and app.db.tracker.collapsed }
  end)
  local pos = app.db.tracker
  if pos and pos.point then f:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
  else f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 24, -190) end

  local header = CreateFrame("Button", nil, f)
  header:SetPoint("TOPLEFT"); header:SetSize(230, 18)
  header:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  header.text = header:CreateFontString(nil, "OVERLAY", "ObjectiveTrackerHeaderFont")
  header.text:SetPoint("LEFT", 16, 0)
  header.text:SetJustifyH("LEFT")
  header.dot = header:CreateTexture(nil, "OVERLAY")
  header.dot:SetSize(12, 12); header.dot:SetPoint("LEFT", 0, 0)
  header.state = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  header.state:SetPoint("LEFT", header.text, "RIGHT", 6, 0)
  header:SetScript("OnClick", function(_, button)
    if button == "RightButton" then
      app.db.tracker = app.db.tracker or {}
      app.db.tracker.collapsed = not app.db.tracker.collapsed
      Tracker.refresh()
    else app:toggleWindow() end
  end)
  header:SetScript("OnEnter", function(self) Tracker.tooltip(self) end)
  header:SetScript("OnLeave", function() GameTooltip:Hide() end)
  f.header = header

  local pulse = header:CreateAnimationGroup()
  local a = pulse:CreateAnimation("Alpha")
  a:SetFromAlpha(1); a:SetToAlpha(0.35); a:SetDuration(0.6); a:SetSmoothing("IN_OUT")
  pulse:SetLooping("BOUNCE")
  f.pulse = pulse

  f.lines = {}
  for i = 1, Tracker.MAX_LINES do
    local b = CreateFrame("Button", nil, f)
    b:SetSize(222, 28)
    b:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -20 - (i - 1) * 28)
    b.title = b:CreateFontString(nil, "OVERLAY", "ObjectiveFont")
    b.title:SetPoint("TOPLEFT", 8, 0); b.title:SetPoint("RIGHT", b, "RIGHT", 0, 0)
    b.title:SetJustifyH("LEFT"); b.title:SetWordWrap(false)
    b.sub = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.sub:SetPoint("TOPLEFT", b.title, "BOTTOMLEFT", 0, -1); b.sub:SetPoint("RIGHT", b, "RIGHT", 0, 0)
    b.sub:SetJustifyH("LEFT"); b.sub:SetWordWrap(false)
    b.bullet = b:CreateTexture(nil, "OVERLAY")
    b.bullet:SetSize(6, 6); b.bullet:SetPoint("TOPLEFT", 0, -4)
    -- the agent is working right now (live link, running run): a turning spinner replaces the bullet
    b.spin = ns.Widgets.spinner(b, 10); b.spin:SetPoint("TOPLEFT", -4, -1); b.spin:Hide()
    b:SetScript("OnClick", function(self) if self.threadId then app:openThread(self.threadId) end end)
    b:Hide()
    f.lines[i] = b
  end
  Tracker.refresh()
  return f
end

local DOT = {
  ok = "Interface\\FriendsFrame\\StatusIcon-Online", warn = "Interface\\FriendsFrame\\StatusIcon-Away",
  bad = "Interface\\FriendsFrame\\StatusIcon-DnD", off = "Interface\\FriendsFrame\\StatusIcon-Offline",
}

-- Truthful one-word state for the header (and why, in the tooltip).
function Tracker.state(app, now)
  local tr = app.transport
  local h = tr.model:health(now, tr.expected)
  local b = tr:budgetStatus()
  if tr.loadError then return "bad", "Slots blocked", "The T3 for WoW delivery slots could not load (" .. tostring(tr.loadError) .. "). Enable them in the AddOns list." end
  if b.exhausted then return "bad", "Paused", "This UI session used all " .. tr.slotCount .. " update slots. Click Reload in the T3 window to continue; nothing reloads by itself." end
  if h.bridge == "never" then return "off", "Waiting for app", "No update from the T3 for WoW app on this Mac yet." end
  if h.bridge == "silent" then return "warn", "App silent", "The T3 for WoW app has not answered for " .. T.age(h.age) .. ". Showing what it last said." end
  if h.t3 == "unpaired" then return "off", "Not connected", "Open the T3 for WoW app on this Mac to connect your T3." end
  if h.t3 == "revoked" or h.t3 == "expired" then return "bad", "Reconnect", h.notice ~= "" and h.notice or "Open the T3 for WoW app to reconnect." end
  if h.t3 == "verifying" then return "warn", "Checking T3", "The app has a saved approval and is checking that T3 still accepts it." end
  if h.t3 == "originChanged" then return "bad", "Reconnect", h.notice ~= "" and h.notice or "Your T3's address changed. Approve this T3 in the T3 for WoW app." end
  if h.t3 == "unreachable" then return "warn", "T3 offline", "T3 is not answering (last good contact " .. T.age(h.t3Age) .. " ago)." end
  if h.pairWarning then return "warn", "", "Your WoW link to T3 expires in " .. h.pairWarning .. " day(s). Re-approve it in the T3 for WoW app." end
  if b.low then return "warn", "", b.remaining .. " update slots left this session." end
  return "ok", "", "Connected. T3 checked " .. T.age(h.t3Age) .. " ago."
end

function Tracker.tooltip(owner)
  local app = Tracker.app
  local now = app.clock()
  local _, _, why = Tracker.state(app, now)
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  GameTooltip:SetText("T3", 1, 0.82, 0)
  GameTooltip:AddLine(T.safe(why), 1, 1, 1, true)
  local b = app.transport:budgetStatus()
  GameTooltip:AddLine(string.format("Updates this session: %d of %d", b.used, app.transport.slotCount), 0.7, 0.7, 0.7)
  GameTooltip:AddLine("Click: open  ·  Right-click: collapse  ·  Shift-drag: move", 0.5, 0.5, 0.5)
  GameTooltip:Show()
end

function Tracker.rows(app, now)
  local g = app.transport.model:tracker(now)
  local rows = {}
  local function add(list, group)
    for _, t in ipairs(list) do
      if #rows >= Tracker.MAX_LINES then return end
      rows[#rows + 1] = { thread = t, group = group }
    end
  end
  add(g.needs, "needs"); add(g.working, "working"); add(g.recent, "recent")
  return rows, g
end

function Tracker.refresh()
  local f, app = Tracker.frame, Tracker.app
  if not f then return end
  local now = app.clock()
  local kind, word = Tracker.state(app, now)
  local rows, g = Tracker.rows(app, now)
  local collapsed = app.db.tracker and app.db.tracker.collapsed
  f.header.dot:SetTexture(DOT[kind])
  local counts = {}
  if #g.needs > 0 then counts[#counts + 1] = "|cffff8c1a" .. #g.needs .. " need you|r" end
  if #g.working > 0 then counts[#counts + 1] = #g.working .. " working" end
  f.header.text:SetText("T3")
  f.header.state:SetText((word ~= "" and word or table.concat(counts, ", ")))
  if #g.needs > 0 then if not f.pulse:IsPlaying() then f.pulse:Play() end elseif f.pulse:IsPlaying() then f.pulse:Stop() end
  local shown = 0
  for i, b in ipairs(f.lines) do
    local r = not collapsed and rows[i]
    if r then
      local t = r.thread
      local c = COLORS[r.group]
      b.threadId = t.id
      b.title:SetText(T.line(t.title, 60))
      local ws = app.transport.model:workState(t, now, app.transport.expected)
      local sub = T.safe(ws.label)
      if t.summary and t.summary ~= "" then sub = sub .. " · " .. T.line(t.summary, 60) end
      local age = T.age(app.transport.model:ageOf(t.updatedAt, now))
      b.sub:SetText(sub .. (age ~= "" and (" · " .. age) or ""))
      if ws.kind == "unknown" then c = COLORS.recent end   -- never colour a stale state as live
      b.bullet:SetColorTexture(c[1], c[2], c[3], 1)
      b.bullet:SetShown(not ws.animate)
      if ws.animate then b.spin:Show(); b.spin:SetSpinning(true) else b.spin:SetSpinning(false); b.spin:Hide() end
      b.title:SetTextColor(r.group == "needs" and 1 or 0.9, r.group == "needs" and 0.82 or 0.9, r.group == "needs" and 0 or 0.9)
      b:Show(); shown = shown + 1
    else b:Hide(); b.threadId = nil; b.spin:SetSpinning(false) end
  end
  f:SetHeight(20 + shown * 28)
end
