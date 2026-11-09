-- The T3 Journal: an in-game window in the grammar of WoW's Map & Quest Log.
--   PortraitFrameTemplate shell (book portrait, title, close)
--   breadcrumb bar  T3 › project ▾ › thread                      [status for the open thread]
--   parchment page: the open thread like quest text (QuestTitleFont / QuestFont), Markdown rendered
--   composer bar (inset): reply / new-thread box, Send, request state
--   dark quest-log column: search, "Threads: N", collapsible project headers, thread entries with
--   status icons (spinner while the agent works), gold titles and objective-style detail lines.
-- Hidden until needed. All agent text is data (Markdown/Text escape it); nothing is evaluated.
local _, ns = ...
local Window = { W = 960, H = 620, LOG_W = 336, ENTRY_W = 296 }
ns.Window = Window
local T, MD, W = ns.Text, ns.Markdown, ns.Widgets

local AUTHOR = { wow = "You · from WoW", you = "You", agent = "Agent", t3 = "T3", tool = "" }
local ORDER = { needs = 1, working = 2, unknown = 3, finished = 4, failed = 4, stopped = 5, idle = 6 }
local TAG = { needs = "Needs you", working = "Working", finished = "Finished", failed = "Failed", stopped = "Stopped", idle = "Idle", unknown = "Unknown" }

-- MARK: construction

local function inset(parent)
  local f = CreateFrame("Frame", nil, parent, "InsetFrameTemplate")
  return f
end

function Window.create(app)
  local f = CreateFrame("Frame", "T3ForWoWWindow", UIParent, "PortraitFrameTemplate")
  Window.frame, Window.app = f, app
  f:SetSize(Window.W, Window.H)
  f:SetPoint("CENTER")
  f:SetFrameStrata("HIGH")
  f:SetMovable(true); f:EnableMouse(true); f:SetClampedToScreen(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetPortraitToAsset("Interface\\QuestFrame\\UI-QuestLog-BookIcon")
  f:SetTitle("T3 Journal")
  f:Hide()
  f:SetScript("OnShow", function() app.transport.windowOpen = true; app.transport:expedite(app.clock()); Window.refresh() end)
  f:SetScript("OnHide", function() app.transport.windowOpen = false; Window.saveDraft() end)
  tinsert(UISpecialFrames, "T3ForWoWWindow")
  local leftW = Window.W - Window.LOG_W - 24

  -- Breadcrumb bar ---------------------------------------------------------------------------
  local nav = inset(f)
  nav:SetPoint("TOPLEFT", f, "TOPLEFT", 60, -28); nav:SetSize(leftW - 50, 30)
  f.nav = nav
  local function crumb(text)
    local b = CreateFrame("Button", nil, nav)
    b:SetSize(10, 22)
    b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    b.label:SetPoint("LEFT", 6, 0); b.label:SetText(text)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    return b
  end
  f.home = crumb("T3"); f.home:SetPoint("LEFT", nav, "LEFT", 6, 0); f.home:SetSize(34, 22)
  f.home:SetScript("OnClick", function() app.filter = nil; Window.refresh() end)
  f.sep1 = nav:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"); f.sep1:SetPoint("LEFT", f.home, "RIGHT", 2, 0); f.sep1:SetText("›")
  f.filter = crumb("All projects"); f.filter:SetPoint("LEFT", f.sep1, "RIGHT", 2, 0); f.filter:SetSize(170, 22)
  f.filter:SetScript("OnClick", function(self) Window.projectMenu(self) end)
  f.sep2 = nav:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"); f.sep2:SetPoint("LEFT", f.filter, "RIGHT", 2, 0); f.sep2:SetText("›")
  f.crumbThread = nav:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.crumbThread:SetPoint("LEFT", f.sep2, "RIGHT", 8, 0); f.crumbThread:SetWidth(leftW - 360)
  f.crumbThread:SetJustifyH("LEFT"); f.crumbThread:SetWordWrap(false)
  -- link health, right end of the bar (bridge / T3 / update budget)
  f.status = nav:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.status:SetPoint("RIGHT", nav, "RIGHT", -10, 0); f.status:SetJustifyH("RIGHT"); f.status:SetWordWrap(false)

  -- Parchment page -----------------------------------------------------------------------------
  local pageInset = inset(f)
  pageInset:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -64); pageInset:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -(Window.LOG_W + 14), 112)
  local page = CreateFrame("Frame", nil, pageInset)
  page:SetPoint("TOPLEFT", pageInset, "TOPLEFT", 3, -3); page:SetPoint("BOTTOMRIGHT", pageInset, "BOTTOMRIGHT", -3, 3)
  f.page = page
  page.bg = page:CreateTexture(nil, "BACKGROUND"); page.bg:SetAllPoints(); page.bg:SetAtlas("QuestDetailsBackgrounds")
  local pageW = leftW - 6

  f.convTitle = page:CreateFontString(nil, "OVERLAY", "QuestTitleFont")
  f.convTitle:SetPoint("TOPLEFT", page, "TOPLEFT", 22, -16); f.convTitle:SetWidth(pageW - 170)
  f.convTitle:SetJustifyH("LEFT"); f.convTitle:SetWordWrap(false)
  f.workIcon = W.statusIcon(page, 18); f.workIcon:SetPoint("TOPLEFT", f.convTitle, "BOTTOMLEFT", 0, -7)
  f.workLabel = page:CreateFontString(nil, "OVERLAY", "QuestFontNormalSmall")
  f.workLabel:SetPoint("LEFT", f.workIcon, "RIGHT", 6, 0); f.workLabel:SetJustifyH("LEFT")
  f.convSub = page:CreateFontString(nil, "OVERLAY", "QuestFontNormalSmall")   -- truthful detail line
  f.convSub:SetPoint("LEFT", f.workLabel, "RIGHT", 8, 0); f.convSub:SetWidth(pageW - 220)
  f.convSub:SetJustifyH("LEFT"); f.convSub:SetWordWrap(false)
  f.older = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
  f.older:SetSize(110, 22); f.older:SetPoint("TOPRIGHT", page, "TOPRIGHT", -16, -16); f.older:SetText("Older…")
  f.older:SetScript("OnClick", function() Window.loadOlder() end)
  f.rule = page:CreateTexture(nil, "ARTWORK"); f.rule:SetAtlas("QuestLog-frame-devider")
  f.rule:SetPoint("TOPLEFT", page, "TOPLEFT", 16, -64); f.rule:SetSize(pageW - 32, 8)

  f.hist = CreateFrame("ScrollFrame", "T3ForWoWHistory", page, "UIPanelScrollFrameTemplate")
  f.hist:SetPoint("TOPLEFT", page, "TOPLEFT", 22, -76); f.hist:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -30, 10)
  f.histChild = CreateFrame("Frame", nil, f.hist); f.histChild:SetSize(pageW - 60, 10)
  f.hist:SetScrollChild(f.histChild)
  f.blocks = {}
  f.empty = f.histChild:CreateFontString(nil, "OVERLAY", "QuestFont")
  f.empty:SetPoint("TOPLEFT"); f.empty:SetWidth(pageW - 64); f.empty:SetJustifyH("LEFT")

  -- Composer bar -----------------------------------------------------------------------------------
  local bar = inset(f)
  bar:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 10); bar:SetSize(leftW, 96)
  f.bar = bar
  f.titleBox = CreateFrame("EditBox", nil, bar, "InputBoxTemplate")
  f.titleBox:SetSize(leftW - 140, 20); f.titleBox:SetPoint("TOPLEFT", bar, "TOPLEFT", 16, -8)
  f.titleBox:SetAutoFocus(false); f.titleBox:SetMaxLetters(80)
  f.titleBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  f.titleBox:Hide()
  f.composer = CreateFrame("ScrollFrame", "T3ForWoWComposer", bar, "InputScrollFrameTemplate")
  f.composer:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 12, 28); f.composer:SetSize(leftW - 130, 44)
  local eb = f.composer.EditBox
  eb:SetFontObject("ChatFontNormal"); eb:SetWidth(leftW - 140); eb:SetMaxBytes(4000)
  f.composer.CharCount:Hide()
  eb:SetScript("OnEnterPressed", function(self) if IsShiftKeyDown() then self:Insert("\n") else Window.send() end end)
  eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  eb:HookScript("OnTextChanged", function() Window.saveDraft() end)
  f.sendBtn = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
  f.sendBtn:SetSize(96, 26); f.sendBtn:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -12, 40); f.sendBtn:SetText("Send")
  f.sendBtn:SetScript("OnClick", function() Window.send() end)
  f.note = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.note:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 16, 9); f.note:SetWidth(leftW - 140)
  f.note:SetJustifyH("LEFT"); f.note:SetWordWrap(false)
  f.reload = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
  f.reload:SetSize(96, 22); f.reload:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -12, 8); f.reload:SetText("Reload UI")
  f.reload:SetScript("OnClick", function() ReloadUI() end) -- only ever on the player's click
  f.reload:Hide()

  -- Quest-log column ----------------------------------------------------------------------------------
  local log = CreateFrame("Frame", nil, f)
  log:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -28); log:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 10); log:SetWidth(Window.LOG_W)
  f.log = log
  log.bg = log:CreateTexture(nil, "BACKGROUND"); log.bg:SetAllPoints(); log.bg:SetAtlas("QuestLog-main-background")
  log.frame = log:CreateTexture(nil, "BORDER"); log.frame:SetAllPoints(); log.frame:SetAtlas("questlog-frame")
  log.filigree = log:CreateTexture(nil, "ARTWORK"); log.filigree:SetAtlas("questlog-frame-filigree", true)
  log.filigree:SetPoint("TOP", log, "TOP", 0, -34)
  f.search = CreateFrame("EditBox", "T3ForWoWSearch", log, "SearchBoxTemplate")
  f.search:SetSize(Window.LOG_W - 120, 20); f.search:SetPoint("TOPLEFT", log, "TOPLEFT", 14, -6)
  f.search:SetAutoFocus(false)
  f.search.Instructions:SetText("Search threads")
  f.search:HookScript("OnTextChanged", function(self) app.search = (self:GetText() or ""):lower(); Window.refresh() end)
  f.count = log:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.count:SetPoint("TOPRIGHT", log, "TOPRIGHT", -14, -10); f.count:SetJustifyH("RIGHT")
  f.list = CreateFrame("ScrollFrame", "T3ForWoWThreadList", log, "UIPanelScrollFrameTemplate")
  f.list:SetPoint("TOPLEFT", log, "TOPLEFT", 8, -44); f.list:SetPoint("BOTTOMRIGHT", log, "BOTTOMRIGHT", -28, 42)
  f.listChild = CreateFrame("Frame", nil, f.list); f.listChild:SetSize(Window.ENTRY_W, 10)
  f.list:SetScrollChild(f.listChild)
  f.headers, f.rows = {}, {}
  f.newBtn = CreateFrame("Button", nil, log, "UIPanelButtonTemplate")
  f.newBtn:SetSize(140, 24); f.newBtn:SetPoint("BOTTOMLEFT", log, "BOTTOMLEFT", 12, 10); f.newBtn:SetText("New Thread")
  f.newBtn:SetScript("OnClick", function() Window.startNewThread() end)
  return f
end

-- MARK: state helpers (unchanged behaviour)

function Window.target()
  local app = Window.app
  if app.newThreadProject then return "new:" .. app.newThreadProject end
  return app.selected
end

function Window.saveDraft()
  local f, key = Window.frame, Window.target()
  if not f or not key or Window.loading then return end
  Window.app.transport.model:setDraft(key, f.composer.EditBox:GetText())
end

function Window.loadDraft()
  local f, key = Window.frame, Window.target()
  Window.loading = true
  f.composer.EditBox:SetText(key and Window.app.transport.model:draft(key) or "")
  Window.loading = false
end

function Window.projectMenu(owner)
  local app = Window.app
  MenuUtil.CreateContextMenu(owner, function(_, root)
    root:CreateRadio("All projects", function() return app.filter == nil end, function() app.filter = nil; Window.refresh() end)
    local list = {}
    for _, p in pairs(app.transport.model.projects) do list[#list + 1] = p end
    table.sort(list, function(a, b) return a.title:lower() < b.title:lower() end)
    for _, p in ipairs(list) do
      root:CreateRadio(T.line(p.title, 40), function() return app.filter == p.id end, function() app.filter = p.id; Window.refresh() end)
    end
  end)
end

function Window.startNewThread()
  local app = Window.app
  local pid = app.filter
  if not pid then
    local t = app.selected and app.transport.model.threads[app.selected]
    pid = t and t.projectId
  end
  if not pid then Window.frame.note:SetText("Choose a project first (T3 › project)."); return end
  Window.saveDraft()
  app.newThreadProject, app.selected = pid, nil
  Window.loadDraft()
  Window.frame.titleBox:SetText("")
  Window.refresh()
  Window.frame.composer.EditBox:SetFocus()
end

function Window.select(threadId)
  local app = Window.app
  Window.saveDraft()
  app.newThreadProject = nil
  app.selected = threadId
  app.transport.watching = threadId
  app.transport.outbox:watch(threadId)
  app.transport:expedite(app.clock())
  Window.loadDraft()
  Window.refresh()
end

function Window.toggleProject(pid)
  local app = Window.app
  app.collapsed = app.collapsed or {}
  app.collapsed[pid] = not app.collapsed[pid]
  Window.refresh()
end

function Window.loadOlder()
  local app = Window.app
  local h = app.selected and app.transport.model.history[app.selected]
  if h and h.hasMore then
    app.transport.outbox:older(app.selected, h.oldest)
    app.transport:expedite(app.clock())
    Window.frame.note:SetText("Loading older messages…")
  end
end

-- The one place a message leaves the game. The target is captured now; switching threads later
-- cannot redirect it.
function Window.send()
  local app, f = Window.app, Window.frame
  local text = f.composer.EditBox:GetText()
  local id, err
  local model = app.transport.model
  if model:health(app.clock()).t3 ~= "connected" then f.note:SetText("Not connected to T3 — nothing was sent. Your draft is kept."); return end
  if app.newThreadProject then
    id, err = app.transport.outbox:newThread(app.newThreadProject, f.titleBox:GetText(), text)
  elseif app.selected then
    local t = model.threads[app.selected]
    if t and not t.canReply then f.note:SetText("This thread runs with Full access and your WoW link does not. Reply in T3, or use \"Reconnect with Full access…\" in the T3 for WoW app."); return end
    id, err = app.transport.outbox:send(app.selected, text)
  else
    f.note:SetText("Pick a thread first."); return
  end
  if not id then
    f.note:SetText(err == "empty" and "Type a message first." or err == "too long" and "Too long (4,000 characters max)." or "Too many messages waiting; try again shortly.")
    return
  end
  model:setDraft(Window.target(), "")
  Window.loading = true; f.composer.EditBox:SetText(""); Window.loading = false
  app.transport:expedite(app.clock())
  Window.refresh()
end

-- MARK: quest-log column

local function headerButton(f, i)
  local h = f.headers[i]
  if h then return h end
  h = CreateFrame("Button", nil, f.listChild)
  h:SetSize(Window.ENTRY_W, 22)
  h.left = h:CreateTexture(nil, "BACKGROUND"); h.left:SetAtlas("Options_ListExpand_Left", true); h.left:SetPoint("LEFT")
  h.right = h:CreateTexture(nil, "BACKGROUND"); h.right:SetAtlas("Options_ListExpand_Right", true); h.right:SetPoint("RIGHT")
  h.mid = h:CreateTexture(nil, "BACKGROUND"); h.mid:SetAtlas("_Options_ListExpand_Middle")
  h.mid:SetPoint("LEFT", h.left, "RIGHT"); h.mid:SetPoint("RIGHT", h.right, "LEFT"); h.mid:SetHeight(22)
  h.name = h:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  h.name:SetPoint("LEFT", 10, 0); h.name:SetWidth(Window.ENTRY_W - 70); h.name:SetWordWrap(false)
  h.count = h:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  h.count:SetPoint("RIGHT", -30, 0)
  h:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  h:SetScript("OnClick", function(self) Window.toggleProject(self.projectId) end)
  f.headers[i] = h
  return h
end

local function entryButton(f, i)
  local b = f.rows[i]
  if b then return b end
  b = CreateFrame("Button", nil, f.listChild)
  b:SetSize(Window.ENTRY_W, 44)
  b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  b.sel = b:CreateTexture(nil, "BACKGROUND"); b.sel:SetAllPoints()
  b.sel:SetTexture("Interface\\QuestFrame\\UI-QuestLogTitleHighlight"); b.sel:SetBlendMode("ADD"); b.sel:SetVertexColor(1, 0.82, 0.25); b.sel:Hide()
  b.icon = W.statusIcon(b, 16); b.icon:SetPoint("TOPLEFT", b, "TOPLEFT", 4, -2)
  b.title = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  b.title:SetPoint("TOPLEFT", b, "TOPLEFT", 26, -3); b.title:SetWidth(Window.ENTRY_W - 120)
  b.title:SetJustifyH("LEFT"); b.title:SetWordWrap(false)
  b.tag = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  b.tag:SetPoint("TOPRIGHT", b, "TOPRIGHT", -4, -4); b.tag:SetJustifyH("RIGHT")
  b.sub = b:CreateFontString(nil, "OVERLAY", "ObjectiveFont")
  b.sub:SetPoint("TOPLEFT", b.title, "BOTTOMLEFT", 6, -3); b.sub:SetWidth(Window.ENTRY_W - 40)
  b.sub:SetJustifyH("LEFT"); b.sub:SetWordWrap(true); b.sub:SetMaxLines(2)
  b:SetScript("OnClick", function(self) Window.select(self.threadId) end)
  f.rows[i] = b
  return b
end

-- Threads grouped by project (projects with something that needs you or is working first).
function Window.groups(now)
  local app = Window.app
  local m = app.transport.model
  local q = app.search ~= "" and app.search or nil
  local byProject, total = {}, 0
  for _, t in pairs(m.threads) do
    if not t.settled then
      total = total + 1
      if (not app.filter or t.projectId == app.filter) and (not q or t.title:lower():find(q, 1, true)) then
        local ws = m:workState(t, now, app.transport.expected)
        local list = byProject[t.projectId] or {}
        byProject[t.projectId] = list
        list[#list + 1] = { thread = t, ws = ws }
      end
    end
  end
  local out, shown = {}, 0
  for pid, list in pairs(byProject) do
    table.sort(list, function(a, b)
      local oa, ob = ORDER[a.ws.kind] or 9, ORDER[b.ws.kind] or 9
      if oa ~= ob then return oa < ob end
      if a.thread.updatedAt ~= b.thread.updatedAt then return a.thread.updatedAt > b.thread.updatedAt end
      return a.thread.id < b.thread.id
    end)
    local p = m.projects[pid]
    out[#out + 1] = { id = pid, title = p and p.title or "Project", items = list, best = ORDER[list[1].ws.kind] or 9 }
    shown = shown + #list
  end
  table.sort(out, function(a, b) if a.best ~= b.best then return a.best < b.best end return a.title:lower() < b.title:lower() end)
  return out, shown, total
end

function Window.renderList(now)
  local f, app = Window.frame, Window.app
  local groups, shown, total = Window.groups(now)
  local m = app.transport.model
  app.collapsed = app.collapsed or {}
  local y, hi, r = 0, 0, 0
  for _, g in ipairs(groups) do
    hi = hi + 1
    local h = headerButton(f, hi)
    h.projectId = g.id
    h:ClearAllPoints(); h:SetPoint("TOPLEFT", f.listChild, "TOPLEFT", 0, -y)
    h.name:SetText(T.line(g.title, 40)); h.count:SetText(tostring(#g.items))
    h.right:SetAtlas(app.collapsed[g.id] and "Options_ListExpand_Right" or "Options_ListExpand_Right_Expanded", true)
    h:Show()
    y = y + 26
    if not app.collapsed[g.id] then
      for _, it in ipairs(g.items) do
        r = r + 1
        local t, ws = it.thread, it.ws
        local b = entryButton(f, r)
        b.threadId = t.id
        b:ClearAllPoints(); b:SetPoint("TOPLEFT", f.listChild, "TOPLEFT", 4, -y)
        b.icon:SetState(ws)
        b.title:SetText(T.line(t.title, 60))
        local hex = W.KIND_HEX[ws.kind] or "9a9a9a"
        -- the tag names the state (quest-log "(Dungeon)" position); queued/waiting never say "Working"
        local tag = (ws.kind == "working" and not ws.animate) and ws.label or TAG[ws.kind]
        b.tag:SetText("|cff" .. hex .. "(" .. tag .. ")|r")
        -- objective-style lines: the truthful detail, then what T3 last summarised
        local lines = {}
        local detail = ws.detail
        if ws.kind == "unknown" then  -- the link itself is reported once, in the breadcrumb bar
          local ago = T.age(m:ageOf(t.updatedAt, now))
          detail = "last known: " .. ns.Model.label(t.status) .. (ago ~= "" and ago ~= "now" and (" · " .. ago .. " ago") or "")
        end
        if detail ~= "" then lines[1] = "- " .. T.safe(detail) end
        if t.summary and t.summary ~= "" and ws.kind ~= "needs" then lines[#lines + 1] = "- " .. T.line(t.summary, 70) end
        b.sub:SetText(table.concat(lines, "\n"))
        if t.id == app.selected then b.sel:Show() else b.sel:Hide() end
        local hgt = 22 + b.sub:GetStringHeight()
        b:SetHeight(hgt)
        b:Show()
        y = y + hgt + 4
      end
    end
  end
  for i = r + 1, #f.rows do f.rows[i]:Hide() end
  for i = hi + 1, #f.headers do f.headers[i]:Hide() end
  f.listChild:SetHeight(math.max(10, y))
  f.count:SetText(string.format("Threads: %d%s", shown, shown ~= total and ("/" .. total) or ""))
  local label = "All projects"
  if app.filter and m.projects[app.filter] then label = T.line(m.projects[app.filter].title, 22) end
  f.filter.label:SetText(label)
  f.filter:SetWidth(f.filter.label:GetStringWidth() + 14)
end

-- MARK: parchment page

Window.MAX_RENDER_CHARS = 16000

-- Visible text of the page (tests / previews).
function Window.pageText()
  local f, parts = Window.frame, {}
  if f.empty:IsShown() then parts[#parts + 1] = f.empty:GetText() end
  for _, b in ipairs(f.blocks) do
    if b:IsShown() then parts[#parts + 1] = b.head:GetText(); parts[#parts + 1] = b.body:GetText() end
  end
  return table.concat(parts, "\n")
end

local function block(f, i)
  local b = f.blocks[i]
  if b then return b end
  b = CreateFrame("Frame", nil, f.histChild)
  b:SetWidth(f.histChild:GetWidth())
  b.rule = b:CreateTexture(nil, "BACKGROUND"); b.rule:SetPoint("TOPLEFT", b, "TOPLEFT", 0, -2); b.rule:SetWidth(2)
  b.head = b:CreateFontString(nil, "OVERLAY", "QuestFontNormalSmall")
  b.head:SetPoint("TOPLEFT", b, "TOPLEFT", 10, 0); b.head:SetJustifyH("LEFT")
  b.head:SetWidth(f.histChild:GetWidth() - 16); b.head:SetWordWrap(false)   -- one line, clipped with …
  b.body = b:CreateFontString(nil, "OVERLAY", "QuestFont")
  b.body:SetPoint("TOPLEFT", b.head, "BOTTOMLEFT", 0, -4); b.body:SetWidth(f.histChild:GetWidth() - 16)
  b.body:SetJustifyH("LEFT"); b.body:SetSpacing(2)
  f.blocks[i] = b
  return b
end

function Window.renderMessages(t, now)
  local f, m = Window.frame, Window.app.transport.model
  local msgs = m:messages(t.id)
  local first, used = 1, 0
  for i = #msgs, 1, -1 do
    used = used + #(msgs[i].text or "") + 40
    if used > Window.MAX_RENDER_CHARS then first = i + 1; break end
  end
  local y, n = 0, 0
  if first > 1 then
    n = n + 1
    local b = block(f, n)
    b.head:SetText(string.format("%d earlier items not shown — use Older… for more", first - 1)); b.body:SetText("")
    b.rule:Hide(); b:ClearAllPoints(); b:SetPoint("TOPLEFT", f.histChild, "TOPLEFT", 0, -y); b:Show()
    y = y + 22
  end
  for i = first, #msgs do
    local msg = msgs[i]
    n = n + 1
    local b = block(f, n)
    b:ClearAllPoints(); b:SetPoint("TOPLEFT", f.histChild, "TOPLEFT", 0, -y)
    if msg.kind == "activity" then
      b.head:SetText("|cff6e5a40· " .. T.line(msg.text, 160) .. "|r"); b.body:SetText("")
      b.rule:Hide()
      y = y + 18
    else
      local who = AUTHOR[msg.author] or ""
      if msg.kind == "assistant" then who = "Agent" elseif msg.kind == "plan" then who = "Plan" elseif msg.kind == "error" then who = "Error" end
      local age = T.age(m:ageOf(msg.updatedAt, now))
      b.head:SetText(who .. (age ~= "" and age ~= "now" and ("  ·  " .. age .. " ago") or ""))
      local body = MD.render(msg.text or "", "parchment")
      if msg.truncated then body = body .. "\n|cff6e5a40(shortened — full text in T3)|r" end
      if msg.kind == "error" then body = "|cff8b0000" .. body .. "|r" end
      b.body:SetText(body)
      -- a quiet margin rule marks who spoke: your words vs. the agent's
      local mine = msg.author == "wow" or msg.author == "you"
      b.rule:SetColorTexture(mine and 0.55 or 0.25, mine and 0.38 or 0.17, mine and 0.12 or 0.08, 0.55)
      b.rule:Show()
      local hgt = 18 + b.body:GetStringHeight()
      b.rule:SetHeight(hgt - 4); b:SetHeight(hgt)
      y = y + hgt + 14
    end
    b:Show()
  end
  for i = n + 1, #f.blocks do f.blocks[i]:Hide() end
  f.histChild:SetHeight(math.max(10, y + 8))
  f.empty:SetShown(#msgs == 0)
  if #msgs == 0 then f.empty:SetText(m.history[t.id] and "No messages yet." or "Loading recent history…") end
  if Window.lastThread ~= t.id or Window.lastCount ~= #msgs then
    f.hist:SetVerticalScroll(f.hist:GetVerticalScrollRange())
    Window.lastThread, Window.lastCount = t.id, #msgs
  end
end

function Window.renderPage(now)
  local f, app = Window.frame, Window.app
  local m = app.transport.model
  f.titleBox:SetShown(app.newThreadProject ~= nil)
  if app.newThreadProject then
    local p = m.projects[app.newThreadProject]
    f.convTitle:SetText("New thread")
    f.crumbThread:SetText("New thread")
    f.workIcon:SetState({ kind = "idle", animate = false })
    f.workLabel:SetText("in " .. (p and T.line(p.title, 40) or "project"))
    f.convSub:SetText("title (optional) and task below")
    for _, b in ipairs(f.blocks) do b:Hide() end
    f.empty:Show(); f.empty:SetText("Write the task below and press Start. It goes to this project in your own T3.")
    f.older:Hide(); f.sendBtn:SetText("Start")
    return
  end
  f.sendBtn:SetText("Send")
  local t = app.selected and m.threads[app.selected]
  if not t then
    f.convTitle:SetText(app.selected and "Thread not available" or "Choose a thread")
    f.crumbThread:SetText("")
    f.workIcon:SetState({ kind = "idle", animate = false })
    f.workLabel:SetText(""); f.convSub:SetText("")
    for _, b in ipairs(f.blocks) do b:Hide() end
    f.empty:Show(); f.empty:SetText(m.appliedAt and "Pick a thread from the log on the right." or "Waiting for the T3 for WoW app…")
    f.older:Hide()
    return
  end
  f.convTitle:SetText(T.line(t.title, 70))
  f.crumbThread:SetText(T.line(t.title, 60))
  local ws = m:workState(t, now, app.transport.expected)
  f.workIcon:SetState(ws)
  f.workLabel:SetText("|cff" .. (ws.kind == "working" and "1f4f7a" or ws.kind == "needs" and "8a4b00" or ws.kind == "failed" and "8b0000" or "4d2e00") .. ws.label .. "|r")
  local detail = T.safe(ws.detail)
  if not t.canReply then detail = (detail ~= "" and (detail .. " · ") or "") .. "read-only from WoW" end
  f.convSub:SetText(detail)
  local h = m.history[t.id]
  f.older:SetShown(h and h.hasMore or false)
  Window.renderMessages(t, now)
end

function Window.renderNote(now)
  local f, app = Window.frame, Window.app
  local tr = app.transport
  local latest
  for i = #tr.outbox.order, 1, -1 do
    local it = tr.outbox.items[tr.outbox.order[i]]
    if (it.kind == "S" and it.threadId == app.selected) or (it.kind == "N" and app.newThreadProject and it.projectId == app.newThreadProject) then latest = it; break end
  end
  local text = ""
  if latest then
    local r = tr.model.requests[tostring(latest.id)]
    text = T.request(latest.state)
    if r and r.detail ~= "" and (latest.state == "failed" or latest.state == "rejected" or latest.state == "unknown" or latest.state == "queued") then text = T.line(r.detail, 120) end
  end
  local sel = not app.newThreadProject and app.selected and tr.model.threads[app.selected]
  if text == "" and sel and not sel.canReply then
    text = "Read-only here: this thread runs with " .. T.line(sel.runtimeMode, 20) .. ". Reply in T3."
  end
  f.note:SetText(text)
  f.reload:SetShown(tr:budgetStatus().exhausted)
end

function Window.refresh()
  local f = Window.frame
  if not f or not f:IsShown() then return end
  local app = Window.app
  app.search = app.search or ""
  local now = app.clock()
  local kind, word = ns.Tracker.state(app, now)
  local b = app.transport:budgetStatus()
  local link = kind == "ok" and "|cff40c040Connected|r" or ("|cffff8c1a" .. (word ~= "" and word or "Attention") .. "|r")
  f.status:SetText(link .. string.format("  |cff909090· updates %d/%d|r", b.used, app.transport.slotCount))
  Window.renderList(now)
  Window.renderPage(now)
  Window.renderNote(now)
  local h = app.transport.model:health(now)
  local canSend = h.t3 == "connected" and (app.newThreadProject or (app.selected and app.transport.model.threads[app.selected] and app.transport.model.threads[app.selected].canReply))
  if canSend then f.sendBtn:Enable() else f.sendBtn:Disable() end
end
