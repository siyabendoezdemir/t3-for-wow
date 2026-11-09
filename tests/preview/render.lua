-- SYNTHETIC LAYOUT PREVIEW renderer.
-- Boots the real addon (from its .toc) inside the strict WoW stub with synthetic threads, then draws
-- the frame tree the addon actually built — positions from its own SetPoint/SetSize/SetAllPoints
-- anchors, text through its own Markdown/escaping, icons from the work state it computed — as SVG.
-- The client's art is NOT available here: every atlas/texture is drawn as a flat approximation.
-- Output is a layout preview, never an in-game capture.
--
--   .deps/lua-5.1.5/src/lua tests/preview/render.lua <repo-root> <out-dir>
local ROOT, OUT = arg[1] or ".", arg[2] or "docs/previews"
local function readFile(p) local f = assert(io.open(p, "rb")); local s = f:read("*a"); f:close(); return s end
local WATERMARK = "SYNTHETIC LAYOUT PREVIEW — real addon frame tree in a test stub; art approximated; NOT an in-game capture"

-- MARK: fonts (sizes/colours from the pinned client FrameXML; faces approximated)
local SERIF = "'Friz Quadrata TT','Palatino Linotype',Georgia,serif"
local TITLE = "'Morpheus','Trajan Pro','Palatino Linotype',Georgia,serif"
local FONTS = {
  QuestFont = { 13, "000000", SERIF }, QuestTitleFont = { 18, "000000", TITLE, bold = true },
  QuestFontNormalSmall = { 12, "4d2e00", SERIF, bold = true },
  GameFontNormal = { 12, "ffd100", SERIF, shadow = true }, GameFontNormalLeft = { 12, "ffd100", SERIF, shadow = true },
  GameFontHighlight = { 12, "ffffff", SERIF, shadow = true }, GameFontNormalSmall = { 10, "ffd100", SERIF, shadow = true },
  GameFontHighlightSmall = { 10, "ffffff", SERIF, shadow = true }, GameFontDisableSmall = { 10, "808080", SERIF, shadow = true },
  ObjectiveFont = { 12, "cccccc", SERIF, shadow = true }, ChatFontNormal = { 13, "ffffff", "Arial,Helvetica,sans-serif", shadow = true },
  ObjectiveTrackerHeaderFont = { 14, "ffd100", SERIF, shadow = true },
}
local function font(fs) return FONTS[fs._font or ""] or FONTS.GameFontNormal end
local function charW(size, bold) return size * (bold and 0.62 or 0.53) end
local function lineH(fs) local f = font(fs); return f[1] + 3 + (fs._spacing or 0) end
local function ulen(s) local n = 0; for _ in s:gmatch("[^\128-\191]") do n = n + 1 end; return n end

-- WoW text → runs of { text, colour }. "||" is a literal bar; |cAARRGGBB … |r colours.
local function runs(text, base)
  local out, col, i, buf = {}, base, 1, {}
  local stack = {}
  local function flush() if #buf > 0 then out[#out + 1] = { table.concat(buf), col }; buf = {} end end
  while i <= #text do
    local c = text:sub(i, i)
    if c == "|" then
      local n = text:sub(i + 1, i + 1)
      if n == "|" then buf[#buf + 1] = "|"; i = i + 2
      elseif n == "c" and text:sub(i + 2, i + 9):match("^%x%x%x%x%x%x%x%x$") then
        flush(); stack[#stack + 1] = col; col = text:sub(i + 4, i + 9); i = i + 10
      elseif n == "r" then flush(); col = table.remove(stack) or base; i = i + 2
      else buf[#buf + 1] = "|"; i = i + 1 end
    elseif c == "\n" then flush(); out[#out + 1] = { "\n", col }; i = i + 1
    else buf[#buf + 1] = c; i = i + 1 end
  end
  flush()
  return out
end

-- Word-wrap runs to a pixel width. Returns lines (lists of runs).
local function wrap(fs, width)
  local f = font(fs)
  local cw = charW(f[1], f.bold)
  local lines, cur, curW = {}, {}, 0
  local function push() lines[#lines + 1] = cur; cur, curW = {}, 0 end
  for _, r in ipairs(runs(fs._text or "", f[2])) do
    if r[1] == "\n" then push()
    else
      for tok in r[1]:gmatch("%S*%s*") do
        if tok ~= "" then
          local w = ulen(tok) * cw
          local stripped = tok:gsub("%s+$", "")
          if width and width > 0 and not fs._nowrap and curW > 0 and curW + ulen(stripped) * cw > width + 2 then
            push(); tok = tok:gsub("^%s+", ""); w = ulen(tok) * cw
          end
          cur[#cur + 1] = { tok, r[2] }; curW = curW + w
        end
      end
    end
  end
  push()
  if fs._maxLines and #lines > fs._maxLines then for i = #lines, fs._maxLines + 1, -1 do lines[i] = nil end end
  return lines
end

local function textWidth(fs)
  local best = 0
  for _, l in ipairs(wrap(fs, nil)) do local n = 0; for _, r in ipairs(l) do n = n + ulen(r[1]) end; best = math.max(best, n) end
  return best * charW(font(fs)[1], font(fs).bold)
end

-- MARK: boot the real addon

local function boot()
  local Stub = assert(loadfile(ROOT .. "/tests/lua/wowstub.lua"))(ROOT)
  local env = setmetatable({}, { __index = _G }); env._G = env
  Stub.install(env)
  Stub.slotCount = 50
  Stub.measure = function(fs)
    if (fs._text or "") == "" then return 0 end
    return #wrap(fs, fs._w) * lineH(fs)
  end
  local ns = {}
  for line in readFile(ROOT .. "/addon/T3ForWoW/T3ForWoW.toc"):gmatch("[^\n]+") do
    if not line:match("^#") and line:match("%S") then
      local chunk = assert(loadfile(ROOT .. "/addon/T3ForWoW/" .. line:gsub("\\", "/")))
      setfenv(chunk, env); chunk("T3ForWoW", ns)
    end
  end
  Stub.fire("ADDON_LOADED", "T3ForWoW"); Stub.fire("PLAYER_LOGIN")
  env.UIParent:SetSize(1280, 800)
  return Stub, env, ns
end

local function deliver(ns, Stub, version, records)
  Stub.onLoadSlot = function(k)
    local B = ns.Bytes
    local list = { "T3D1", tostring(k), "9", tostring(ns.App.transport.gameSession), tostring(version), "0", tostring(Stub.now), tostring(#records) }
    for _, r in ipairs(records) do list[#list + 1] = B.netstrings(r) end
    return B.netstrings(list)
  end
end

-- MARK: geometry

local cache
local SCREEN = { l = 0, t = 0, w = 1280, h = 800 }
local rect
local function anchorXY(r, point)
  local x = point:find("LEFT") and r.l or point:find("RIGHT") and (r.l + r.w) or (r.l + r.w / 2)
  local y = point:find("TOP") and r.t or point:find("BOTTOM") and (r.t + r.h) or (r.t + r.h / 2)
  return x, y
end
local ATLAS_SIZE = { ["questlog-frame-filigree"] = { 230, 12 }, ["Options_ListExpand_Left"] = { 10, 22 },
  ["Options_ListExpand_Right"] = { 24, 22 }, ["Options_ListExpand_Right_Expanded"] = { 24, 22 } }

function rect(w)
  if cache[w] then return cache[w] end
  local parent = w._parent
  local r
  if w._scrollOwner then
    local o = rect(w._scrollOwner)
    local off = 0
    if w._scrollOwner._name == "T3ForWoWHistory" then off = math.max(0, (w._h or 0) - o.h) end   -- the journal scrolls to the newest
    r = { l = o.l, t = o.t - off, w = w._w, h = w._h }
  elseif #w._points == 0 then
    if w._allPoints then r = rect(w._allPoints == true and parent or w._allPoints)
    elseif parent then local p = rect(parent); r = { l = p.l, t = p.t, w = (w._w > 0 and w._w or p.w), h = (w._h > 0 and w._h or p.h) }
    else r = SCREEN end
  else
    local W, Hh = w._w or 0, w._h or 0
    if w._kind == "FontString" then
      if W == 0 then W = textWidth(w) end
      if Hh == 0 then Hh = math.max(lineH(w), Stub_measure(w)) end
    elseif w._kind == "Texture" and w._atlas and ATLAS_SIZE[w._atlas] and W == 0 then W, Hh = ATLAS_SIZE[w._atlas][1], ATLAS_SIZE[w._atlas][2] end
    local L, R, CX, T, B, CY
    for _, p in ipairs(w._points) do
      local point, rel, relPoint, x, y = p[1], p[2], p[3], p[4], p[5]
      if type(rel) == "number" then rel, relPoint, x, y = nil, point, p[2], p[3]
      elseif type(relPoint) == "number" then relPoint, x, y = point, p[3], p[4] end
      if type(rel) == "string" then rel = nil end
      rel = rel or parent
      relPoint = relPoint or point
      local ax, ay = anchorXY(rect(rel), relPoint)
      ax, ay = ax + (x or 0), ay - (y or 0)
      if point:find("LEFT") then L = ax elseif point:find("RIGHT") then R = ax else CX = ax end
      if point:find("TOP") then T = ay elseif point:find("BOTTOM") then B = ay else CY = ay end
    end
    -- a font string anchored on both sides wraps to that width; re-measure its height
    if w._kind == "FontString" and L and R and (w._h or 0) == 0 then
      local save = w._w; w._w = R - L; Hh = math.max(lineH(w), Stub_measure(w)); w._w = save
    end
    local l = L or (R and R - W) or (CX and CX - W / 2) or 0
    local wd = (L and R) and (R - L) or W
    local t = T or (B and B - Hh) or (CY and CY - Hh / 2) or 0
    local ht = (T and B) and (B - T) or Hh
    r = { l = l, t = t, w = wd, h = ht }
  end
  cache[w] = r
  return r
end
function Stub_measure(fs) if (fs._text or "") == "" then return 0 end; return #wrap(fs, fs._w) * lineH(fs) end

-- MARK: SVG drawing

local out
local function esc(s) return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")) end
local function emit(s) out[#out + 1] = s end
local function f1(n) return string.format("%.1f", n) end
local function box(r, attrs) emit(string.format('<rect x="%s" y="%s" width="%s" height="%s" %s/>', f1(r.l), f1(r.t), f1(math.max(0, r.w)), f1(math.max(0, r.h)), attrs)) end

local function shown(w) while w do if not w._shown then return false end; w = w._parent end; return true end
local function alphaOf(w) local a = 1; while w do a = a * (w._alpha or 1); w = w._parent end; return a end
local function hex(c) return string.format("%02x%02x%02x", math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5)) end

local function drawText(fs, r, opts)
  opts = opts or {}
  local f = font(fs)
  local base = fs._textColor and hex(fs._textColor) or f[2]
  local save = fs._text
  local lines = wrap(fs, r.w > 0 and r.w or nil)
  local lh = lineH(fs)
  local justify = opts.justify or fs._justify or "LEFT"
  local y = r.t + f[1]
  if opts.middle then y = r.t + (r.h - #lines * lh) / 2 + f[1] end
  for _, line in ipairs(lines) do
    local n = 0; for _, run in ipairs(line) do n = n + ulen(run[1]) end
    local lw = n * charW(f[1], f.bold)
    if fs._nowrap and r.w > 0 and lw > r.w + 2 then
      -- clipped with an ellipsis, as the client does for non-wrapping strings
      local keep, acc = {}, 0
      local budget = math.floor(r.w / charW(f[1], f.bold)) - 1
      for _, run in ipairs(line) do
        local len = ulen(run[1])
        if acc + len <= budget then keep[#keep + 1] = run; acc = acc + len
        else keep[#keep + 1] = { run[1]:sub(1, math.max(0, budget - acc)) .. "…", run[2] }; break end
      end
      line, lw = keep, r.w
    end
    local x, anchor = r.l, "start"
    if justify == "RIGHT" then x, anchor = r.l + r.w, "end" elseif justify == "CENTER" then x, anchor = r.l + r.w / 2, "middle" end
    local spans = {}
    for _, run in ipairs(line) do spans[#spans + 1] = string.format('<tspan fill="#%s">%s</tspan>', base == run[2] and base or run[2], esc(run[1])) end
    if #spans > 0 then
      local attrs = string.format('x="%s" y="%s" font-family="%s" font-size="%d" text-anchor="%s" xml:space="preserve"%s',
        f1(x), f1(y), f[3], f[1], anchor, f.bold and ' font-weight="bold"' or "")
      if f.shadow then emit(string.format('<text %s fill="#000" opacity="0.85" transform="translate(1,1)">%s</text>', attrs, (table.concat(spans):gsub('fill="#%x+"', 'fill="#000"')))) end
      emit(string.format('<text %s>%s</text>', attrs, table.concat(spans)))
    end
    y = y + lh
  end
  fs._text = save
end

local function playing(tex) for _, c in ipairs(tex._children) do if c._kind == "AnimationGroup" and c._playing then return true end end end

local function drawAtlas(w, r)
  local a = w._atlas
  if a == "QuestDetailsBackgrounds" then
    box(r, 'fill="url(#parchment)"'); box(r, 'fill="url(#vignette)"')
  elseif a == "QuestLog-main-background" then
    box(r, 'fill="url(#questlog)"')
  elseif a == "questlog-frame" then
    box({ l = r.l + 1, t = r.t + 1, w = r.w - 2, h = r.h - 2 }, 'fill="none" stroke="#6b5530" stroke-width="2"')
    box({ l = r.l + 4, t = r.t + 4, w = r.w - 8, h = r.h - 8 }, 'fill="none" stroke="#000" stroke-opacity="0.6" stroke-width="2"')
  elseif a == "questlog-frame-filigree" then
    local cx, cy = r.l + r.w / 2, r.t + r.h / 2
    emit(string.format('<path d="M%s %s Q%s %s %s %s Q%s %s %s %s" stroke="#a8843c" stroke-width="1.2" fill="none" opacity="0.8"/>',
      f1(r.l), f1(cy), f1(cx - 40), f1(cy - 6), f1(cx), f1(cy), f1(cx + 40), f1(cy + 6), f1(r.l + r.w), f1(cy)))
    emit(string.format('<path d="M%s %s l6 -5 l6 5 l-6 5 z" fill="#c9a24e"/>', f1(cx - 6), f1(cy)))
  elseif a == "QuestLog-frame-devider" then
    emit(string.format('<rect x="%s" y="%s" width="%s" height="3" fill="url(#divider)"/>', f1(r.l), f1(r.t + r.h / 2 - 1), f1(r.w)))
  elseif a == "_Options_ListExpand_Middle" or a == "Options_ListExpand_Left" then
    box(r, 'fill="url(#header)"')
    emit(string.format('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="#8a6d34" stroke-width="1"/>', f1(r.l), f1(r.t + 0.5), f1(r.l + r.w), f1(r.t + 0.5)))
    emit(string.format('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="#000" stroke-width="1"/>', f1(r.l), f1(r.t + r.h - 0.5), f1(r.l + r.w), f1(r.t + r.h - 0.5)))
  elseif a == "Options_ListExpand_Right" or a == "Options_ListExpand_Right_Expanded" then
    box(r, 'fill="url(#header)"')
    local cx, cy = r.l + r.w - 12, r.t + r.h / 2
    box({ l = cx - 6, t = cy - 6, w = 12, h = 12 }, 'rx="2" fill="#2a1e10" stroke="#c9a24e" stroke-width="1"')
    emit(string.format('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="#ffd100" stroke-width="2"/>', f1(cx - 3.5), f1(cy), f1(cx + 3.5), f1(cy)))
    if a == "Options_ListExpand_Right" then emit(string.format('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="#ffd100" stroke-width="2"/>', f1(cx), f1(cy - 3.5), f1(cx), f1(cy + 3.5))) end
  elseif a == "QuestNormal" or a == "QuestTurnin" then
    local glyph = a == "QuestNormal" and "!" or "?"
    emit(string.format('<text x="%s" y="%s" font-family="Georgia,serif" font-weight="bold" font-size="%d" text-anchor="middle" fill="#ffd100" stroke="#3a2600" stroke-width="1">%s</text>',
      f1(r.l + r.w / 2), f1(r.t + r.h - 1), math.floor(r.h * 1.05), glyph))
  elseif a == "common-icon-redx" then
    local p = 3
    emit(string.format('<path d="M%s %s L%s %s M%s %s L%s %s" stroke="#e02020" stroke-width="3" stroke-linecap="round"/>',
      f1(r.l + p), f1(r.t + p), f1(r.l + r.w - p), f1(r.t + r.h - p), f1(r.l + r.w - p), f1(r.t + p), f1(r.l + p), f1(r.t + r.h - p)))
  else
    box(r, 'fill="#ff00ff" opacity="0.3"')
  end
end

local function drawTexture(w)
  local r = rect(w)
  local op = alphaOf(w)
  if op <= 0 then return end
  emit(string.format('<g opacity="%s">', f1(op)))
  if w._atlas then drawAtlas(w, r)
  elseif w._color then
    local c = w._color
    box(r, string.format('fill="#%s" fill-opacity="%s"', hex(c), f1(c[4] or 1)))
  elseif w._texture == "Interface\\COMMON\\StreamCircle" then
    emit(string.format('<circle cx="%s" cy="%s" r="%s" fill="none" stroke="#2c4660" stroke-width="%s"/>', f1(r.l + r.w / 2), f1(r.t + r.h / 2), f1(r.w / 2 - 2), f1(math.max(2, r.w / 7))))
  elseif w._texture == "Interface\\COMMON\\StreamSpark" then
    local cx, cy, rr = r.l + r.w / 2, r.t + r.h / 2, r.w / 2 - 2
    emit('<g>')
    emit(string.format('<path d="M%s %s A%s %s 0 0 1 %s %s" fill="none" stroke="#7fd0ff" stroke-width="%s" stroke-linecap="round"/>',
      f1(cx), f1(cy - rr), f1(rr), f1(rr), f1(cx + rr), f1(cy), f1(math.max(2, r.w / 7))))
    emit(string.format('<circle cx="%s" cy="%s" r="%s" fill="#e8f7ff"/>', f1(cx + rr), f1(cy), f1(math.max(1.2, r.w / 9))))
    if playing(w) then emit(string.format('<animateTransform attributeName="transform" type="rotate" from="0 %s %s" to="360 %s %s" dur="1.2s" repeatCount="indefinite"/>', f1(cx), f1(cy), f1(cx), f1(cy))) end
    emit('</g>')
  elseif w._texture == "Interface\\QuestFrame\\UI-QuestLogTitleHighlight" then
    local c = w._vertex or { 1, 1, 1 }
    box(r, string.format('fill="url(#selglow)" style="color:#%s"', hex(c)))
    box(r, string.format('fill="none" stroke="#%s" stroke-opacity="0.35"', hex(c)))
  elseif w._texture and w._texture:find("StatusIcon%-") then
    local col = w._texture:find("Online") and "#2ecc40" or w._texture:find("Away") and "#ffb000" or w._texture:find("DnD") and "#e02020" or "#777"
    emit(string.format('<circle cx="%s" cy="%s" r="%s" fill="%s" stroke="#000"/>', f1(r.l + r.w / 2), f1(r.t + r.h / 2), f1(r.w / 2 - 1), col))
  end
  emit('</g>')
end

local LAYER = { BACKGROUND = 1, BORDER = 2, ARTWORK = 3, OVERLAY = 4, HIGHLIGHT = 5 }
local skip = {}

local function button(r, label, enabled)
  emit(string.format('<rect x="%s" y="%s" width="%s" height="%s" rx="3" fill="url(#%s)" stroke="#1a0a00" stroke-width="1.5"/>',
    f1(r.l), f1(r.t), f1(r.w), f1(r.h), enabled and "redbtn" or "greybtn"))
  emit(string.format('<rect x="%s" y="%s" width="%s" height="%s" rx="2" fill="none" stroke="#c9a24e" stroke-opacity="%s"/>',
    f1(r.l + 1.5), f1(r.t + 1.5), f1(r.w - 3), f1(r.h - 3), enabled and "0.75" or "0.35"))
  local fs = { _text = label, _font = enabled and "GameFontNormal" or "GameFontDisableSmall", _justify = "CENTER" }
  if not enabled then fs._font = "GameFontDisableSmall" end
  drawText(fs, r, { justify = "CENTER", middle = true })
end

local function decorate(w)
  local r = rect(w)
  local t = w._template
  if t == "PortraitFrameTemplate" then
    for _, k in ipairs({ "PortraitContainer", "TitleContainer", "CloseButton", "Bg" }) do skip[w[k]] = true end
    emit(string.format('<rect x="%s" y="%s" width="%s" height="%s" rx="4" fill="url(#marble)" stroke="#000" stroke-width="2"/>', f1(r.l), f1(r.t), f1(r.w), f1(r.h)))
    emit(string.format('<rect x="%s" y="%s" width="%s" height="%s" rx="3" fill="none" stroke="url(#metal)" stroke-width="5"/>', f1(r.l + 2.5), f1(r.t + 2.5), f1(r.w - 5), f1(r.h - 5)))
    emit(string.format('<rect x="%s" y="%s" width="%s" height="20" fill="url(#titlebar)"/>', f1(r.l + 5), f1(r.t + 4), f1(r.w - 10)))
    drawText({ _text = w.TitleContainer.TitleText._text, _font = "GameFontNormal" }, { l = r.l + 60, t = r.t + 4, w = r.w - 120, h = 20 }, { justify = "CENTER", middle = true })
    -- portrait: round book icon breaking the frame at the top-left, like the client's journals
    local cx, cy = r.l + 24, r.t + 20
    emit(string.format('<circle cx="%s" cy="%s" r="30" fill="#000"/><circle cx="%s" cy="%s" r="27" fill="url(#portrait)"/>', f1(cx), f1(cy), f1(cx), f1(cy)))
    emit(string.format('<circle cx="%s" cy="%s" r="29" fill="none" stroke="url(#metal)" stroke-width="4"/>', f1(cx), f1(cy)))
    emit(string.format('<g transform="translate(%s,%s)"><path d="M-14 -11 L0 -7 L14 -11 L14 11 L0 15 L-14 11 Z" fill="#6b2a14" stroke="#2a0e04" stroke-width="1.5"/>' ..
      '<path d="M-11 -8 L0 -4.5 L11 -8 L11 9 L0 12 L-11 9 Z" fill="#efe0b8"/><line x1="0" y1="-4.5" x2="0" y2="12" stroke="#7a5a2a"/>' ..
      '<path d="M-8 -3 L-3 -1.5 M-8 1 L-3 2.5 M-8 5 L-3 6.5 M3 -1.5 L8 -3 M3 2.5 L8 1 M3 6.5 L8 5" stroke="#9a7a4a" stroke-width="0.8"/></g>', f1(cx), f1(cy)))
    -- close button
    local bx, by = r.l + r.w - 26, r.t + 5
    emit(string.format('<rect x="%s" y="%s" width="18" height="18" rx="3" fill="url(#redbtn)" stroke="#c9a24e" stroke-width="1"/>' ..
      '<path d="M%s %s l8 8 M%s %s l-8 8" stroke="#ffd100" stroke-width="2.2" stroke-linecap="round"/>', f1(bx), f1(by), f1(bx + 5), f1(by + 5), f1(bx + 13), f1(by + 5)))
  elseif t == "InsetFrameTemplate" then
    skip[w.Bg] = true
    emit(string.format('<rect x="%s" y="%s" width="%s" height="%s" fill="#050403" fill-opacity="0.72" stroke="#000" stroke-width="2"/>', f1(r.l), f1(r.t), f1(r.w), f1(r.h)))
    emit(string.format('<rect x="%s" y="%s" width="%s" height="%s" fill="none" stroke="#5a4a30" stroke-opacity="0.55"/>', f1(r.l + 1.5), f1(r.t + 1.5), f1(r.w - 3), f1(r.h - 3)))
  elseif t == "UIPanelButtonTemplate" then
    button(r, w._text or "", w._enabled ~= false)
  elseif t == "InputBoxTemplate" then
    emit(string.format('<rect x="%s" y="%s" width="%s" height="%s" rx="2" fill="#000" fill-opacity="0.7" stroke="#6e6e6e"/>', f1(r.l - 5), f1(r.t), f1(r.w + 5), f1(r.h)))
    if (w._text or "") == "" then drawText({ _text = "Title (optional)", _font = "GameFontDisableSmall" }, { l = r.l, t = r.t, w = r.w, h = r.h }, { middle = true })
    else drawText({ _text = w._text, _font = "ChatFontNormal", _nowrap = true }, { l = r.l, t = r.t, w = r.w, h = r.h }, { middle = true }) end
  elseif t == "InputScrollFrameTemplate" then
    skip[w.EditBox] = true; skip[w.CharCount] = true
    emit(string.format('<rect x="%s" y="%s" width="%s" height="%s" rx="3" fill="#000" fill-opacity="0.75" stroke="#7a7a7a"/>', f1(r.l - 4), f1(r.t - 4), f1(r.w + 8), f1(r.h + 8)))
    local txt = w.EditBox._text or ""
    if txt == "" then drawText({ _text = "Reply to this thread…  (Enter sends · Shift+Enter new line)", _font = "GameFontDisableSmall" }, { l = r.l + 2, t = r.t + 2, w = r.w - 4, h = r.h })
    else drawText({ _text = txt, _font = "ChatFontNormal" }, { l = r.l + 2, t = r.t + 2, w = r.w - 4, h = r.h }) end
  elseif t == "SearchBoxTemplate" then
    skip[w.Instructions] = true
    emit(string.format('<rect x="%s" y="%s" width="%s" height="%s" rx="9" fill="#000" fill-opacity="0.75" stroke="#8a8a8a"/>', f1(r.l - 4), f1(r.t), f1(r.w + 4), f1(r.h)))
    emit(string.format('<circle cx="%s" cy="%s" r="4" fill="none" stroke="#bbb" stroke-width="1.5"/><line x1="%s" y1="%s" x2="%s" y2="%s" stroke="#bbb" stroke-width="1.5"/>',
      f1(r.l + 6), f1(r.t + r.h / 2 - 1), f1(r.l + 9), f1(r.t + r.h / 2 + 2), f1(r.l + 12), f1(r.t + r.h / 2 + 5)))
    local txt = w._text or ""
    drawText({ _text = txt ~= "" and txt or w.Instructions._text, _font = txt ~= "" and "GameFontHighlightSmall" or "GameFontDisableSmall" }, { l = r.l + 16, t = r.t, w = r.w - 16, h = r.h }, { middle = true })
  elseif t == "UIPanelScrollFrameTemplate" then
    skip[w.ScrollBar] = true
    local c = w._scrollChild
    if c and (c._h or 0) > r.h + 1 then
      local x = r.l + r.w + 6
      emit(string.format('<rect x="%s" y="%s" width="12" height="%s" rx="6" fill="#000" fill-opacity="0.55" stroke="#4a3a22"/>', f1(x), f1(r.t), f1(r.h)))
      local frac = r.h / c._h
      local th = math.max(18, r.h * frac)
      local ty = (w._name == "T3ForWoWHistory") and (r.t + r.h - th) or r.t
      emit(string.format('<rect x="%s" y="%s" width="10" height="%s" rx="5" fill="url(#thumb)"/>', f1(x + 1), f1(ty), f1(th)))
    end
  end
end

local clipN = 0
local function drawFrame(w)
  if skip[w] or not w._shown then return end
  decorate(w)
  local regions, frames = {}, {}
  for i, c in ipairs(w._children) do
    if c._kind == "Texture" or c._kind == "FontString" then regions[#regions + 1] = { c, i }
    elseif c._kind ~= "AnimationGroup" and c._kind ~= "Animation" then frames[#frames + 1] = c end
  end
  table.sort(regions, function(a, b)
    local la, lb = LAYER[a[1]._layer or "ARTWORK"] or 3, LAYER[b[1]._layer or "ARTWORK"] or 3
    if la ~= lb then return la < lb end
    return a[2] < b[2]
  end)
  local op = (w._alpha or 1)
  if op < 1 then emit(string.format('<g opacity="%s">', f1(op))) end
  for _, rg in ipairs(regions) do
    local c = rg[1]
    if c._shown and not skip[c] then
      if c._kind == "Texture" then drawTexture(c) else drawText(c, rect(c)) end
    end
  end
  local clip = w._kind == "ScrollFrame" or (w._template == "UIPanelScrollFrameTemplate")
  if clip then
    clipN = clipN + 1
    local r = rect(w)
    emit(string.format('<clipPath id="clip%d"><rect x="%s" y="%s" width="%s" height="%s"/></clipPath><g clip-path="url(#clip%d)">', clipN, f1(r.l), f1(r.t), f1(r.w), f1(r.h), clipN))
  end
  for _, c in ipairs(frames) do drawFrame(c) end
  if clip then emit('</g>') end
  if op < 1 then emit('</g>') end
end

local DEFS = [[
<defs>
  <linearGradient id="parchment" x1="0" y1="0" x2="0.3" y2="1"><stop offset="0" stop-color="#efdcb0"/><stop offset="0.55" stop-color="#e2c896"/><stop offset="1" stop-color="#d2b37c"/></linearGradient>
  <radialGradient id="vignette" cx="0.5" cy="0.45" r="0.75"><stop offset="0.6" stop-color="#5a3a10" stop-opacity="0"/><stop offset="1" stop-color="#5a3a10" stop-opacity="0.35"/></radialGradient>
  <linearGradient id="questlog" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2a2016"/><stop offset="0.5" stop-color="#1b150e"/><stop offset="1" stop-color="#120d08"/></linearGradient>
  <linearGradient id="divider" x1="0" x2="1"><stop offset="0" stop-color="#7a5320" stop-opacity="0"/><stop offset="0.15" stop-color="#7a5320"/><stop offset="0.85" stop-color="#7a5320"/><stop offset="1" stop-color="#7a5320" stop-opacity="0"/></linearGradient>
  <linearGradient id="header" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#4a3820"/><stop offset="0.5" stop-color="#2e2214"/><stop offset="1" stop-color="#1e160c"/></linearGradient>
  <linearGradient id="selglow" x1="0" x2="1"><stop offset="0" stop-color="currentColor" stop-opacity="0.35"/><stop offset="1" stop-color="currentColor" stop-opacity="0.05"/></linearGradient>
  <linearGradient id="marble" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#232323"/><stop offset="1" stop-color="#151515"/></linearGradient>
  <linearGradient id="metal" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#8c8c8c"/><stop offset="0.5" stop-color="#4a4a4a"/><stop offset="1" stop-color="#6a6a6a"/></linearGradient>
  <linearGradient id="titlebar" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3a3a3a"/><stop offset="1" stop-color="#1a1a1a"/></linearGradient>
  <radialGradient id="portrait" cx="0.4" cy="0.35" r="0.8"><stop offset="0" stop-color="#5a4a30"/><stop offset="1" stop-color="#1a120a"/></radialGradient>
  <linearGradient id="redbtn" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#a51b0b"/><stop offset="0.55" stop-color="#6e0b02"/><stop offset="1" stop-color="#4a0500"/></linearGradient>
  <linearGradient id="greybtn" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#4a4a4a"/><stop offset="1" stop-color="#262626"/></linearGradient>
  <linearGradient id="thumb" x1="0" x2="1"><stop offset="0" stop-color="#b08a3e"/><stop offset="1" stop-color="#6b5226"/></linearGradient>
  <linearGradient id="world" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3b4a5a"/><stop offset="0.6" stop-color="#2b3324"/><stop offset="1" stop-color="#1b2016"/></linearGradient>
</defs>]]

local function svg(roots, view, caption)
  out, cache, skip, clipN = {}, {}, {}, 0
  local pad = 16
  local W, H = view.w + pad * 2, view.h + pad * 2 + 30
  emit(string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="%s %s %d %d">', W, H, f1(view.l - pad), f1(view.t - pad), W, H))
  emit(DEFS)
  emit(string.format('<rect x="%s" y="%s" width="%d" height="%d" fill="url(#world)"/>', f1(view.l - pad), f1(view.t - pad), W, H))
  for _, w in ipairs(roots) do drawFrame(w) end
  local y = view.t + view.h + pad + 4
  emit(string.format('<rect x="%s" y="%s" width="%d" height="26" fill="#000" fill-opacity="0.8"/>', f1(view.l - pad), f1(y - 2), W))
  emit(string.format('<text x="%s" y="%s" font-family="Arial,sans-serif" font-size="11" fill="#ff6060" font-weight="bold">%s</text>', f1(view.l - pad + 8), f1(y + 9), esc(WATERMARK)))
  emit(string.format('<text x="%s" y="%s" font-family="Arial,sans-serif" font-size="10" fill="#cccccc">%s</text>', f1(view.l - pad + 8), f1(y + 21), esc(caption)))
  emit('</svg>')
  return table.concat(out, "\n")
end

-- MARK: synthetic scenes

local function rec(...) return { ... } end
local function scene()
  local Stub, env, ns = boot()
  local now = Stub.now
  local ST = rec("st", "online", "connected", tostring(now), "", tostring(now + 40 * 86400), "approval-required", "60")
  local T = function(id, p, title, status, pending, ago, summary, mode, canReply)
    return rec("t", id, p, title, status, tostring(pending), tostring(now - ago), "0", mode or "approval-required", canReply or "1", summary or "")
  end
  local M = function(tid, id, pos, kind, author, ago, text) return rec("m", tid, id, tostring(pos), kind, "completed", author, tostring(now - ago), text, "0") end
  local recs = {
    ST, rec("p", "p1", "Raid Planner"), rec("p", "p2", "Guild Website"), rec("p", "p3", "Addon Toolkit"),
    T("t-work", "p1", "Split the loot parser", "running", 0, 14, "Editing Lexer.lua"),
    T("t-done", "p1", "Fix tooltip anchoring", "completed", 0, 3 * 3600, "Patched Tooltip.lua; 12 tests pass"),
    T("t-full", "p1", "Release checklist", "completed", 0, 5 * 3600, "", "full-access", "0"),
    T("t-need", "p2", "Deploy the staging site", "running", 1, 50, "Asked to run deploy.sh"),
    T("t-queue", "p2", "Write the changelog", "queued", 0, 40, ""),
    T("t-fail", "p3", "Bump the Interface version", "failed", 0, 2 * 3600, "Build step exited with code 1"),
    T("t-stop", "p3", "Profile memory use", "interrupted", 0, 26 * 3600, ""),
    M("t-work", "w1", 1, "user", "wow", 600, "Can you split the loot parser into a lexer and a parser, and keep the old API working?"),
    M("t-work", "w2", 2, "assistant", "t3", 420,
      "## Plan\nI'll split `LootParser.lua` into two modules:\n\n1. **Lexer** — turns chat lines into tokens\n2. **Parser** — builds loot records\n\n" ..
      "- [x] Read the current parser\n- [x] Wrote tests for the old API\n- [ ] Move tokenising into `Lexer.lua`\n\n" ..
      "> The public `LootParser.parse(line)` call stays exactly the same.\n\n```lua\nlocal tokens = Lexer.scan(line)\nreturn Parser.build(tokens)\n```\n" ..
      "Notes in the [design doc](https://github.com/example/raid-planner/wiki/parser)."),
    M("t-work", "w3", 3, "activity", "tool", 60, "Edited LootParser.lua, Lexer.lua (+84 -31)"),
    M("t-work", "w4", 4, "activity", "tool", 14, "Running tests: busted spec/"),
    rec("h", "t-work", "1", "0", "0"),
    M("t-need", "n1", 1, "user", "wow", 900, "Ship the staging build once the tests pass."),
    M("t-need", "n2", 2, "assistant", "t3", 120, "All **41 tests pass**. To deploy I need your approval to run:\n\n```\n./deploy.sh staging\n```\nThis uploads the build to the *staging* server only."),
    M("t-need", "n3", 3, "activity", "tool", 50, "Waiting for approval: run ./deploy.sh staging"),
    rec("h", "t-need", "1", "0", "0"),
    M("t-full", "f1", 1, "user", "you", 6 * 3600, "Run the release checklist and tag v2.4."),
    M("t-full", "f2", 2, "assistant", "t3", 5 * 3600, "Checklist done:\n- [x] Changelog updated\n- [x] Version bumped to **2.4.0**\n- [ ] Tag not pushed (needs your OK in T3)"),
    rec("h", "t-full", "1", "0", "0"),
  }
  deliver(ns, Stub, 1, recs)
  Stub.advance(4)
  return Stub, env, ns
end

local function journal(name, caption, prep)
  local Stub, env, ns = scene()
  prep(Stub, env, ns)
  ns.Window.refresh(); ns.Tracker.refresh()
  assert(#Stub.violations == 0, table.concat(Stub.violations, "; "))
  local f = env.T3ForWoWWindow
  cache = {}
  local r = { l = 160, t = 90, w = f._w, h = f._h }
  f:ClearAllPoints(); f:SetPoint("TOPLEFT", env.UIParent, "TOPLEFT", 160, -90)
  local file = OUT .. "/" .. name .. ".svg"
  local fh = assert(io.open(file, "wb")); fh:write(svg({ f }, { l = r.l - 14, t = r.t - 14, w = r.w + 14, h = r.h + 14 }, caption)); fh:close()
  print("wrote " .. file)
  return ns
end

local function tracker(name, caption, prep)
  local Stub, env, ns = scene()
  prep(Stub, env, ns)
  ns.Tracker.refresh()
  assert(#Stub.violations == 0, table.concat(Stub.violations, "; "))
  local f = env.T3ForWoWTracker
  f:ClearAllPoints(); f:SetPoint("TOPLEFT", env.UIParent, "TOPLEFT", 24, -24)
  local file = OUT .. "/" .. name .. ".svg"
  local fh = assert(io.open(file, "wb")); fh:write(svg({ f }, { l = 8, t = 8, w = 720, h = f._h + 24 }, caption)); fh:close()
  print("wrote " .. file)
end

local function stale(Stub, env, ns) Stub.onLoadSlot = function() return nil end; Stub.jump(3600) end

journal("journal-working", "Agent working: spinner turns (live link, running run). Markdown reply rendered on parchment. Needs-you project sorted first.",
  function(Stub, env, ns) ns.App:openThread("t-work") end)
journal("journal-needs-you", "Needs you: quest '!' mark, orange tag, 'answer in T3'. Inline/fenced code and emphasis rendered natively.",
  function(Stub, env, ns) ns.App:openThread("t-need"); env.T3ForWoWWindow.composer.EditBox:SetText("Approved in T3 — go ahead.") end)
journal("journal-stale-collapsed", "Link silent for 1h: every state shows 'Unknown', no spinner anywhere. 'Addon Toolkit' header collapsed.",
  function(Stub, env, ns) ns.App:openThread("t-work"); ns.Window.toggleProject("p3"); stale(Stub, env, ns) end)
journal("journal-readonly-finished", "Finished run ('?' mark, results not verified) on a Full-access thread: read-only from WoW, Send disabled.",
  function(Stub, env, ns) ns.App:openThread("t-full") end)
tracker("tracker-live", "Tracker: needs-you first (pulsing header), spinner only on the running thread.", function() end)
tracker("tracker-stale", "Tracker with a silent link: header says 'App silent', no spinner, stale states grey.", stale)
