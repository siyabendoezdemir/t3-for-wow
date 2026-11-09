local H = ...
local test, eq, ok = H.test, H.eq, H.ok

-- Boot the whole addon from its .toc into a stub WoW environment. SYNTHETIC.
local function boot(opts)
  opts = opts or {}
  local Stub = assert(loadfile(H.ROOT .. "/tests/lua/wowstub.lua"))(H.ROOT)
  local env = setmetatable({}, { __index = _G })
  env._G = env
  Stub.install(env)
  Stub.slotCount = opts.slots or 50
  env.T3ForWoWDB = opts.db
  local toc = H.readFile(H.ROOT .. "/addon/T3ForWoW/T3ForWoW.toc")
  local ns = {}
  for line in toc:gmatch("[^\n]+") do
    if not line:match("^#") and line:match("%S") then
      local chunk = assert(loadfile(H.ROOT .. "/addon/T3ForWoW/" .. line:gsub("\\", "/")))
      setfenv(chunk, env)
      chunk("T3ForWoW", ns)
    end
  end
  Stub.fire("ADDON_LOADED", "T3ForWoW")
  Stub.fire("PLAYER_LOGIN")
  return Stub, env, ns
end

local function rec(...) return { ... } end
local function deliveryFor(ns, Stub, version, records)
  return function(k)
    local B = ns.Bytes
    local list = { "T3D1", tostring(k), "9", tostring(ns.App.transport.gameSession), tostring(version), "0", tostring(Stub.now), tostring(#records) }
    for _, r in ipairs(records) do list[#list + 1] = B.netstrings(r) end
    return B.netstrings(list)
  end
end
local ST = rec("st", "online", "connected", "1794160000", "", "1796700000", "approval-required", "60")
local function threads()
  return {
    ST, rec("p", "p1", "Alpha"), rec("p", "p2", "Beta"),
    rec("t", "t-work", "p1", "Refactor the parser", "running", "0", "1794159990", "0", "approval-required", "1", "Edited files"),
    rec("t", "t-need", "p2", "Ship |cffff0000release|r", "waiting", "1", "1794159900", "0", "approval-required", "1", ""),
    rec("t", "t-full", "p1", "Full access job", "completed", "0", "1794159000", "0", "full-access", "0", ""),
    rec("m", "t-work", "i1", "1", "user", "completed", "you", "1794159980", "Please refactor", "0"),
    rec("m", "t-work", "i2", "2", "assistant", "completed", "t3", "1794159985", "Sure |TInterface\\Icons\\INV_Misc_QuestionMark:0|t |Hitem:1|h[x]|h done", "0"),
    rec("m", "t-work", "i3", "3", "activity", "completed", "tool", "1794159986", "Edited files: src/a.lua", "0"),
    rec("h", "t-work", "1", "1", "0"),
  }
end

local function loaded(opts)
  local Stub, env, ns = boot(opts)
  Stub.onLoadSlot = deliveryFor(ns, Stub, 1, threads())
  Stub.advance(4)
  return Stub, env, ns
end

test("ui: boots from the .toc with only verified templates, fonts and textures", function()
  local Stub, env, ns = loaded()
  ok(env.T3ForWoWWindow and env.T3ForWoWTracker and env.T3ForWoWStrip, "frames created")
  eq(#Stub.violations, 0, table.concat(Stub.violations, "; "))
  eq(ns.App.transport.slotCount, 50, "slot count detected from installed slot addons")
  ok(not env.T3ForWoWWindow:IsShown(), "main window hidden until needed")
end)

test("ui: tracker puts needs-you first, escapes agent text, pulses only when someone needs you", function()
  local Stub, env, ns = loaded()
  local lines = env.T3ForWoWTracker.lines
  eq(lines[1].threadId, "t-need")
  eq(lines[2].threadId, "t-work")
  eq(lines[3].threadId, "t-full")
  eq(lines[1].title:GetText(), "Ship ||cffff0000release||r", "colour codes from T3 are shown literally")
  ok(env.T3ForWoWTracker.header.state:GetText():find("1 need you"))
  ok(env.T3ForWoWTracker.pulse:IsPlaying())
  ok(lines[3].sub:GetText():find("Run finished"), "completed = latest run finished, not task done")
end)

test("ui: clicking a tracker line opens that exact thread and asks the bridge to watch it", function()
  local Stub, env, ns = loaded()
  env.T3ForWoWTracker.lines[2]:Click()
  ok(env.T3ForWoWWindow:IsShown())
  eq(ns.App.selected, "t-work")
  local w
  for _, id in ipairs(ns.App.transport.outbox.order) do local it = ns.App.transport.outbox.items[id]; if it.kind == "W" then w = it end end
  eq(w.threadId, "t-work")
  local hist = ns.Window.pageText()
  ok(hist:find("||TInterface"), "texture escape neutralised")
  ok(hist:find("||Hitem"), "hyperlink escape neutralised")
  ok(not hist:find("[^|]|T"), "no live texture escape")
  ok(hist:find("Edited files"), "compact activity line")
end)

test("ui: Enter sends to the selected thread only; drafts stay with their own thread", function()
  local Stub, env, ns = loaded()
  local win = env.T3ForWoWWindow
  ns.App:openThread("t-work")
  local eb = win.composer.EditBox
  eb:SetText("draft for work")
  ns.Window.select("t-need")
  eq(eb:GetText(), "", "other thread starts with its own (empty) draft")
  eb:SetText("answer for need")
  ns.Window.select("t-work")
  eq(eb:GetText(), "draft for work")
  eb._scripts.OnEnterPressed(eb)
  local sends = {}
  for _, id in ipairs(ns.App.transport.outbox.order) do local it = ns.App.transport.outbox.items[id]; if it.kind == "S" then sends[#sends + 1] = it end end
  eq(#sends, 1); eq(sends[1].threadId, "t-work"); eq(sends[1].text, "draft for work")
  eq(eb:GetText(), "", "composer cleared after send")
  ns.Window.select("t-need")
  eq(eb:GetText(), "answer for need", "unsent draft of the other thread kept")
end)

test("ui: Shift+Enter inserts a newline instead of sending", function()
  local Stub, env, ns = loaded()
  ns.App:openThread("t-work")
  local eb = env.T3ForWoWWindow.composer.EditBox
  eb:SetText("line one"); Stub.shift = true
  eb._scripts.OnEnterPressed(eb); Stub.shift = false
  eq(eb:GetText(), "line one\n")
end)

test("ui: a thread beyond the link's permission ceiling cannot be replied to from WoW", function()
  local Stub, env, ns = loaded()
  ns.App:openThread("t-full")
  local win = env.T3ForWoWWindow
  ok(not win.sendBtn:IsEnabled())
  ok(win.convSub:GetText():find("read%-only from WoW"))
  ok(win.note:GetText():find("Read-only here: this thread runs with full-access", 1, true), "composer says why")
  win.composer.EditBox:SetText("try anyway")
  ns.Window.send()
  for _, id in ipairs(ns.App.transport.outbox.order) do ok(ns.App.transport.outbox.items[id].kind ~= "S") end
  ok(win.note:GetText():find("Reconnect with Full access"))
end)

test("ui: not connected → nothing is sent and the draft is kept", function()
  local Stub, env, ns = boot()
  Stub.onLoadSlot = deliveryFor(ns, Stub, 1, { rec("st", "online", "unreachable", "1794150000", "T3 is not answering.", "0", "approval-required", "60"),
    rec("t", "t-work", "p1", "Refactor", "running", "0", "1794159990", "0", "approval-required", "1", "") })
  Stub.advance(4)
  ns.App:openThread("t-work")
  local eb = env.T3ForWoWWindow.composer.EditBox
  eb:SetText("keep me")
  ns.Window.send()
  eq(eb:GetText(), "keep me")
  ok(env.T3ForWoWWindow.note:GetText():find("nothing was sent"))
  ok(env.T3ForWoWTracker.header.state:GetText():find("T3 offline"))
end)

test("ui: new thread goes to the chosen project with the typed title", function()
  local Stub, env, ns = loaded()
  ns.App:toggleWindow()
  ns.Window.projectMenu(env.T3ForWoWWindow.filter)
  local menu = Stub.menus[#Stub.menus]
  menu.items[2].select() -- "Alpha" (sorted)
  eq(ns.App.filter, "p1")
  env.T3ForWoWWindow.newBtn:Click()
  env.T3ForWoWWindow.titleBox:SetText("Fix login")
  env.T3ForWoWWindow.composer.EditBox:SetText("Please fix the login bug")
  ns.Window.send()
  local n
  for _, id in ipairs(ns.App.transport.outbox.order) do local it = ns.App.transport.outbox.items[id]; if it.kind == "N" then n = it end end
  eq(n.projectId, "p1")
  local f = ns.Bytes.parseNetstrings(n.body)
  eq(f[3], "Fix login"); eq(f[4], "Please fix the login bug")
end)

test("ui: exhausted pool shows a Reload button but never reloads on its own", function()
  local Stub, env, ns = boot({ slots = 2 })
  Stub.onLoadSlot = deliveryFor(ns, Stub, 1, threads())
  Stub.advance(4)
  Stub.onLoadSlot = deliveryFor(ns, Stub, 2, threads())
  Stub.jump(9 * 3600)
  ok(ns.App.transport:budgetStatus().exhausted)
  ns.App:toggleWindow()
  ok(env.T3ForWoWWindow.reload:IsShown())
  eq(Stub.reloads, 0)
  ok(env.T3ForWoWTracker.header.state:GetText():find("Paused"))
  env.T3ForWoWWindow.reload:Click()
  eq(Stub.reloads, 1)
end)

test("ui: disabled slot addons are reported, not silently retried every tick", function()
  local Stub, env, ns = boot()
  Stub.slotsDisabled = true
  Stub.advance(10)
  ok(env.T3ForWoWTracker.header.state:GetText():find("Slots blocked"))
  eq(ns.App.transport.used, 0)
end)

test("ui: strip paints exactly the frame grid in whole cells", function()
  local Stub, env, ns = loaded()
  local strip = env.T3ForWoWStrip
  local bytes = ns.App.transport:frame()
  ns.Strip.paint(bytes)
  local grid = ns.Frame.grid(bytes)
  local shown = 0
  for i, t in ipairs(strip.cells) do if t:IsShown() then shown = shown + 1 end end
  eq(shown, grid.rows * 80)
  local c = strip.cells[1]._color
  eq(c[1], 0); eq(c[2], 1); eq(c[3], 1)
  -- 3 physical pixels per cell on a 1800 px tall screen at UI scale 1
  ok(math.abs(strip.cellSize - 3 * 768 / 1800) < 1e-9)
end)

test("ui: positions only are saved; no messages or drafts in SavedVariables", function()
  local Stub, env, ns = loaded({ db = {} })
  ns.App:openThread("t-work")
  env.T3ForWoWWindow.composer.EditBox:SetText("secret draft")
  local function scan(t, seen)
    seen = seen or {}
    if seen[t] then return end; seen[t] = true
    for k, v in pairs(t) do
      ok(type(v) ~= "string" or not v:find("secret draft"), "draft leaked into SavedVariables at " .. tostring(k))
      if type(v) == "table" then scan(v, seen) end
    end
  end
  scan(env.T3ForWoWDB)
end)

test("ui: approval expiring within 3 days is surfaced in the tracker tooltip", function()
  local Stub, env, ns = boot()
  Stub.onLoadSlot = deliveryFor(ns, Stub, 1, { rec("st", "online", "connected", tostring(Stub.now), "", tostring(Stub.now + 2 * 86400), "operate", "60") })
  Stub.advance(4)
  local kind, word, why = ns.Tracker.state(ns.App, ns.App.clock())
  eq(kind, "warn"); ok(why:find("expires in 1 day") or why:find("expires in 2 day"), why)
end)

test("ui: 'verifying' and 'originChanged' are never shown as connected; sends are refused", function()
  for _, case in ipairs({ { "verifying", "Checking T3" }, { "originChanged", "Reconnect" } }) do
    local Stub, env, ns = boot()
    Stub.onLoadSlot = deliveryFor(ns, Stub, 1, { rec("st", "online", case[1], "0", "", "0", "operate", "60"),
      rec("t", "t-work", "p1", "Refactor", "running", "0", "1794159990", "0", "approval-required", "1", "") })
    Stub.advance(4)
    local kind, word = ns.Tracker.state(ns.App, ns.App.clock())
    ok(kind ~= "ok", case[1]); eq(word, case[2])
    ns.App:openThread("t-work")
    env.T3ForWoWWindow.composer.EditBox:SetText("x"); ns.Window.send()
    for _, id in ipairs(ns.App.transport.outbox.order) do ok(ns.App.transport.outbox.items[id].kind ~= "S") end
  end
end)

-- MARK: T3 Journal (Map & Quest Log composition)

local function entryFor(win, id) for _, b in ipairs(win.rows) do if b:IsShown() and b.threadId == id then return b end end end
local function headerFor(win, pid) for _, h in ipairs(win.headers) do if h:IsShown() and h.projectId == pid then return h end end end

test("journal: native quest-log shell — portrait frame, book portrait, parchment page, quest-log column", function()
  local Stub, env, ns = loaded()
  ns.App:openThread("t-work")
  local win = env.T3ForWoWWindow
  eq(win._template, "PortraitFrameTemplate")
  eq(win.PortraitContainer.portrait:GetTexture(), "Interface\\QuestFrame\\UI-QuestLog-BookIcon")
  eq(win.TitleContainer.TitleText:GetText(), "T3 Journal")
  eq(win.page.bg:GetAtlas(), "QuestDetailsBackgrounds")
  eq(win.log.bg:GetAtlas(), "QuestLog-main-background")
  eq(win.log.frame:GetAtlas(), "questlog-frame")
  eq(win.rule:GetAtlas(), "QuestLog-frame-devider")
  eq(win.convTitle._font, "QuestTitleFont")
  eq(#Stub.violations, 0, table.concat(Stub.violations, "; "))
end)

test("journal: the spinner turns only for a running thread on a live link; stale link stops it", function()
  local Stub, env, ns = loaded()
  ns.App:openThread("t-work")
  local win = env.T3ForWoWWindow
  local work, need, full = entryFor(win, "t-work"), entryFor(win, "t-need"), entryFor(win, "t-full")
  ok(work and need and full, "all three threads listed")
  ok(work.icon.spin:IsShown() and work.icon.spin.anim:IsPlaying(), "working thread spins")
  ok(work.tag:GetText():find("(Working)", 1, true))
  ok(not need.icon.spin.anim:IsPlaying() and need.icon.mark:GetAtlas() == "QuestNormal", "needs-you uses the ! mark")
  ok(not full.icon.spin.anim:IsPlaying() and full.icon.mark:GetAtlas() == "QuestTurnin")
  ok(win.workIcon.spin.anim:IsPlaying(), "page header spinner for the open working thread")
  ok(win.workLabel:GetText():find("Agent working"))
  -- the tracker spins too, for that line only
  local lines = env.T3ForWoWTracker.lines
  ok(lines[2].spin.anim:IsPlaying() and not lines[1].spin.anim:IsPlaying() and not lines[3].spin.anim:IsPlaying())
  -- bridge goes silent: nothing may keep claiming live work
  Stub.onLoadSlot = function() return nil end
  Stub.jump(3600)
  ns.Window.refresh(); ns.Tracker.refresh()
  work = entryFor(win, "t-work")
  ok(not work.icon.spin.anim:IsPlaying(), "no spinning on a stale link")
  ok(work.tag:GetText():find("(Unknown)", 1, true))
  ok(not win.workIcon.spin.anim:IsPlaying() and win.workLabel:GetText():find("Status unknown"))
  ok(not env.T3ForWoWTracker.lines[2].spin.anim:IsPlaying())
end)

test("journal: agent Markdown renders as clean WoW text on the page, still escape-safe", function()
  local Stub, env, ns = boot()
  local recs = threads()
  recs[#recs + 1] = rec("m", "t-work", "i4", "4", "assistant", "completed", "t3", "1794159989",
    "## Result\n- **parser** split into `lexer.lua`\n- [x] tests pass\n```\nlocal a = 1\n```", "0")
  Stub.onLoadSlot = deliveryFor(ns, Stub, 1, recs)
  Stub.advance(4)
  ns.App:openThread("t-work")
  local page = ns.Window.pageText()
  ok(page:find("Result") and not page:find("## Result", 1, true), "heading marks removed")
  ok(page:find("• ", 1, true) and page:find("parser") and not page:find("**parser**", 1, true))
  local plain = page:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  ok(plain:find("    local a = 1", 1, true), "code kept verbatim: " .. page)
  ok(not page:find("```", 1, true))
  ok(page:find("Agent") and page:find("You"), "author headings")
  ok(not page:gsub("||", ""):find("|[^cr]"), "only our own colour codes are live")
end)

test("journal: project headers collapse and expand like quest-log zones", function()
  local Stub, env, ns = loaded()
  ns.App:toggleWindow()
  local win = env.T3ForWoWWindow
  local h = headerFor(win, "p1")
  ok(h and h.right:GetAtlas() == "Options_ListExpand_Right_Expanded")
  ok(entryFor(win, "t-work"))
  h:Click()
  ok(not entryFor(win, "t-work") and not entryFor(win, "t-full"), "p1 threads hidden")
  ok(entryFor(win, "t-need"), "other project unaffected")
  eq(headerFor(win, "p1").right:GetAtlas(), "Options_ListExpand_Right")
  headerFor(win, "p1"):Click()
  ok(entryFor(win, "t-work"))
  -- needs-you project is listed first
  eq(win.headers[1].projectId, "p2")
end)

test("journal: search filters thread titles; count shows shown/total", function()
  local Stub, env, ns = loaded()
  ns.App:toggleWindow()
  local win = env.T3ForWoWWindow
  eq(win.count:GetText(), "Threads: 3")
  win.search:SetText("PARSER")
  win.search._scripts.OnTextChanged(win.search)
  ok(entryFor(win, "t-work") and not entryFor(win, "t-need"))
  eq(win.count:GetText(), "Threads: 1/3")
end)

test("journal: breadcrumb shows T3 › project › thread; home clears the project filter", function()
  local Stub, env, ns = loaded()
  ns.App:openThread("t-work")
  local win = env.T3ForWoWWindow
  eq(win.crumbThread:GetText(), "Refactor the parser")
  ns.App.filter = "p1"; ns.Window.refresh()
  eq(win.filter.label:GetText(), "Alpha")
  ok(not entryFor(win, "t-need"))
  win.home:Click()
  eq(ns.App.filter, nil); eq(win.filter.label:GetText(), "All projects")
end)

test("tracker/journal ages keep counting while the link is silent (old activity never looks recent)", function()
  local Stub, env, ns = loaded()
  ok(env.T3ForWoWTracker.lines[2].sub:GetText():find("· now", 1, true))
  Stub.onLoadSlot = function() return nil end
  Stub.jump(3600)
  ns.Tracker.refresh()
  local sub = env.T3ForWoWTracker.lines[2].sub:GetText()
  ok(sub:find("Status unknown") and sub:find("1h") and not sub:find("· now", 1, true), sub)
end)

test("slash: /t3 toggles the journal; help lists commands; reset restores default places; unknown is safe", function()
  local Stub, env, ns = loaded()
  local run = env.SlashCmdList.T3FORWOW
  run(""); ok(env.T3ForWoWWindow:IsShown()); run(""); ok(not env.T3ForWoWWindow:IsShown())
  run("  HELP "); ok(#Stub.chat >= 4, "help lines"); ok(Stub.chat[1]:find("/t3", 1, true))
  run("tracker"); ok(not env.T3ForWoWTracker:IsShown()); run("tracker"); ok(env.T3ForWoWTracker:IsShown())
  ns.App.db.tracker = { point = "CENTER", relPoint = "CENTER", x = 5, y = 5 }
  run("reset"); eq(ns.App.db.tracker, nil); ok(env.T3ForWoWTracker:IsShown())
  run("bogus|cff"); ok(Stub.chat[#Stub.chat]:find("bogus||cff", 1, true), "echo is escaped")
end)

test("sustained session (SYNTHETIC soak): hours of deliveries until the pool is spent — bounded page and memory, truthful states, Reload only on click", function()
  local Stub, env, ns = boot({ slots = 60 })
  local version, items = 0, {}
  local function deliverNext(silent)
    if silent then Stub.onLoadSlot = function() return nil end; return end
    version = version + 1
    items[#items + 1] = rec("m", "t-work", "s" .. version, tostring(10 + version), version % 3 == 0 and "activity" or "assistant", "completed", "t3",
      tostring(Stub.now), "## Step " .. version .. "\n- **progress** " .. string.rep("long agent text ", 40) .. "\n```\ncode " .. version .. "\n```", "0")
    local recs = threads()
    for _, r in ipairs(items) do recs[#recs + 1] = r end
    recs[#recs + 1] = rec("st", "online", "connected", tostring(Stub.now), "", "1796700000", "approval-required", "60")
    Stub.onLoadSlot = deliveryFor(ns, Stub, version, recs)
  end
  deliverNext(); Stub.advance(4)
  ns.App:openThread("t-work")
  collectgarbage("collect"); local mem0 = collectgarbage("count")
  local peakPage, sawSpinWhileSilent, loadsAfterExhaustion, hours = 0, false, nil, 0
  for step = 1, 400 do
    local silent = step % 25 >= 20                     -- recurring quiet spells (app silent for minutes)
    deliverNext(silent)
    Stub.jump(90)                                      -- 90 s of game time per step → 10 h total
    ns.Window.refresh(); ns.Tracker.refresh()
    local page = ns.Window.pageText()
    peakPage = math.max(peakPage, #page)
    local spin = env.T3ForWoWWindow.workIcon.spin.anim:IsPlaying()
    local h = ns.App.transport.model:health(ns.App.clock(), ns.App.transport.expected)
    if spin and h.bridge ~= "online" then sawSpinWhileSilent = true end
    if ns.App.transport:budgetStatus().exhausted then
      local n = 0; for _ in pairs(Stub.slots) do n = n + 1 end
      if not loadsAfterExhaustion then loadsAfterExhaustion = n; hours = step * 90 / 3600
      else eq(n, loadsAfterExhaustion, "no slot loads after exhaustion") end
    end
  end
  ok(loadsAfterExhaustion, "the pool of 60 was spent during the soak")
  ok(hours > 1, "60 slots lasted more than an hour of mixed activity: " .. hours)
  ok(not sawSpinWhileSilent, "spinner never turns while the app is silent")
  ok(peakPage <= ns.Window.MAX_RENDER_CHARS * 1.6, "page text stays bounded: " .. peakPage)
  ok(env.T3ForWoWWindow.reload:IsShown(), "Reload UI offered"); eq(Stub.reloads, 0, "never reloads by itself")
  ok(env.T3ForWoWTracker.header.state:GetText():find("Paused"))
  collectgarbage("collect"); local grew = collectgarbage("count") - mem0
  ok(grew < 4096, "Lua memory growth bounded (KiB): " .. math.floor(grew))
  if os.getenv("T3WOW_SOAK_REPORT") then
    print(string.format("  soak: deliveries=%d slots=60 exhaustedAfter=%.2fh peakPageChars=%d luaMemGrowthKiB=%d", version, hours, peakPage, math.floor(grew)))
  end
  eq(#Stub.violations, 0, table.concat(Stub.violations, "; "))
end)
