-- Strict headless stub of the WoW: Forever UI API, just enough for the addon. SYNTHETIC.
-- * Unknown widget methods raise errors (catches typos/APIs the addon assumes).
-- * Template names, font objects and texture paths are checked against the pinned client UI
--   source in .deps (wow-ui-source 1.60.1.70862) when it is present.
local Stub = {}

local REF = (...) and ((...) .. "/.deps/wow-ui-source-9dc84f0d3bbae1768ac3405b3716000bd93eda06/Interface") or nil
-- Reference lookups are cached for the whole test process (the stub is reloaded per boot).
local CACHE = rawget(_G, "__T3STUB_CACHE") or {}
rawset(_G, "__T3STUB_CACHE", CACHE)
local function ref()
  if CACHE.ref ~= nil then return CACHE.ref end
  CACHE.ref = false
  if not REF then return false end
  local p = io.popen('grep -rhoE \'name="[A-Za-z0-9_]+"\' "' .. REF .. '" --include=*.xml 2>/dev/null | sort -u')
  local names = {}
  for line in p:lines() do names[line:match('name="(.-)"')] = true end
  p:close()
  if next(names) then CACHE.ref = { names = names } end
  return CACHE.ref
end
function Stub.knownName(n) local r = ref(); return not r or r.names[n] == true end
function Stub.knownTexture(path)
  if not REF then return true end
  CACHE.tex = CACHE.tex or {}
  if CACHE.tex[path] ~= nil then return CACHE.tex[path] end
  local found = false
  for _, variant in ipairs({ path, (path:gsub("\\", "\\\\")) }) do
    local f = io.open("/tmp/t3stub-needle", "w"); f:write(variant); f:close()
    local p = io.popen('grep -rlF -f /tmp/t3stub-needle "' .. REF .. '" 2>/dev/null | head -1')
    if p:read("*l") then found = true end
    p:close()
    if found then break end
  end
  CACHE.tex[path] = found
  return found
end

-- Atlas names referenced anywhere in the pinned client UI (atlas="…" or SetAtlas("…")).
function Stub.knownAtlas(name)
  if not REF then return true end
  CACHE.atlas = CACHE.atlas or {}
  if CACHE.atlas[name] ~= nil then return CACHE.atlas[name] end
  local f = io.open("/tmp/t3stub-atlas", "w"); f:write('"' .. name .. '"'); f:close()
  local p = io.popen('grep -rlF -f /tmp/t3stub-atlas "' .. REF .. '" 2>/dev/null | head -1')
  local hit = p:read("*l") ~= nil; p:close()
  CACHE.atlas[name] = hit
  return hit
end

Stub.violations = {}
local function violation(msg) Stub.violations[#Stub.violations + 1] = msg end

local COMMON = { "SetSize", "SetWidth", "SetHeight", "GetWidth", "GetHeight", "SetPoint", "ClearAllPoints", "SetAllPoints", "GetPoint",
  "Show", "Hide", "IsShown", "SetShown", "SetAlpha", "GetAlpha", "GetParent", "GetName" }
local METHODS = {
  Frame = { "SetMovable", "SetClampedToScreen", "EnableMouse", "RegisterForDrag", "SetScript", "HookScript", "GetScript", "StartMoving",
    "StopMovingOrSizing", "CreateFontString", "CreateTexture", "CreateAnimationGroup", "SetFrameStrata", "SetFrameLevel",
    "GetEffectiveScale", "RegisterEvent", "SetScrollChild", "SetVerticalScroll", "GetVerticalScrollRange", "SetScale", "SetClipsChildren" },
  Button = { "RegisterForClicks", "SetHighlightTexture", "SetText", "GetText", "Enable", "Disable", "IsEnabled", "Click" },
  EditBox = { "SetAutoFocus", "SetMaxLetters", "SetMaxBytes", "SetFontObject", "SetFocus", "ClearFocus", "HasFocus", "Insert", "GetText", "SetText" },
  FontString = { "SetJustifyH", "SetJustifyV", "SetText", "GetText", "SetWordWrap", "SetTextColor", "SetSpacing", "GetStringHeight", "SetFontObject", "SetFont",
                 "SetMaxLines", "SetNonSpaceWrap", "GetStringWidth" },
  Texture = { "SetTexture", "SetColorTexture", "SetBlendMode", "SetVertexColor", "SetSnapToPixelGrid", "SetTexelSnappingBias", "GetTexture",
              "SetAtlas", "GetAtlas", "SetTexCoord", "SetDesaturated", "CreateAnimationGroup" },
  AnimationGroup = { "CreateAnimation", "SetLooping", "Play", "Stop", "IsPlaying" },
  Animation = { "SetFromAlpha", "SetToAlpha", "SetDuration", "SetSmoothing", "SetDegrees", "SetOrigin" },
}
local KINDS = { Frame = { "Frame" }, ScrollFrame = { "Frame" }, Button = { "Frame", "Button" }, EditBox = { "Frame", "EditBox" },
  FontString = { "FontString" }, Texture = { "Texture" }, AnimationGroup = { "AnimationGroup" }, Animation = { "Animation" } }

local Widget = {}
function Widget.new(kind, name, parent)
  local w = { _kind = kind, _name = name, _parent = parent, _shown = true, _points = {}, _scripts = {}, _children = {}, _text = "", _w = 0, _h = 0 }
  local allowed = {}
  for _, m in ipairs(COMMON) do allowed[m] = true end
  for _, k in ipairs(KINDS[kind] or {}) do for _, m in ipairs(METHODS[k]) do allowed[m] = true end end
  if kind == "Animation" or kind == "AnimationGroup" then allowed.SetPoint = nil end
  setmetatable(w, { __index = function(t, k)
    if Widget[k] and allowed[k] then return Widget[k] end
    if allowed[k] then return function() end end
    if type(k) ~= "string" or not k:match("^%u") then return nil end -- plain fields set by the addon
    error("stub: " .. kind .. " has no method " .. tostring(k), 2)
  end })
  if parent then parent._children[#parent._children + 1] = w end
  if name then _G[name] = w end
  return w
end
function Widget:SetSize(w, h) self._w, self._h = w, h end
function Widget:SetWidth(w) self._w = w end
function Widget:SetHeight(h) self._h = h end
function Widget:GetWidth() return self._w end
function Widget:GetHeight() return self._h end
function Widget:SetPoint(...) self._points[#self._points + 1] = { ... } end
function Widget:GetPoint() local p = self._points[1] or { "CENTER", nil, "CENTER", 0, 0 }; return p[1], p[2], p[3], p[4], p[5] end
function Widget:ClearAllPoints() self._points = {} end
function Widget:Show() if not self._shown then self._shown = true; if self._scripts.OnShow then self._scripts.OnShow(self) end end end
function Widget:Hide() if self._shown then self._shown = false; if self._scripts.OnHide then self._scripts.OnHide(self) end end end
function Widget:IsShown() return self._shown end
function Widget:SetShown(v) if v then self:Show() else self:Hide() end end
function Widget:GetParent() return self._parent end
function Widget:GetName() return self._name end
function Widget:SetScript(e, fn) self._scripts[e] = fn end
function Widget:GetScript(e) return self._scripts[e] end
function Widget:HookScript(e, fn) local old = self._scripts[e]; self._scripts[e] = function(...) if old then old(...) end fn(...) end end
function Widget:CreateFontString(name, layer, font)
  if font and not Stub.knownName(font) then violation("unknown font object " .. font) end
  local w = Widget.new("FontString", name, self); w._font = font; w._layer = layer
  return w
end
function Widget:CreateTexture(name, layer) local w = Widget.new("Texture", name, self); w._layer = layer; return w end
function Widget:CreateAnimationGroup() return Widget.new("AnimationGroup", nil, self) end
function Widget:CreateAnimation(kind)
  if kind ~= "Alpha" and kind ~= "Rotation" and kind ~= "Translation" and kind ~= "Scale" then violation("unknown animation type " .. tostring(kind)) end
  local a = Widget.new("Animation", nil, self); a._type = kind; return a
end
function Widget:SetDegrees(d) self._degrees = d end
function Widget:SetAtlas(name, useAtlasSize)
  self._useAtlasSize = useAtlasSize
  if not Stub.knownAtlas(name) then violation("atlas not referenced by the client UI: " .. tostring(name)) end
  self._atlas = name; self._texture = nil; self._color = nil
end
function Widget:GetAtlas() return self._atlas end
function Widget:SetAlpha(a) self._alpha = a end
function Widget:GetAlpha() return self._alpha or 1 end
function Widget:SetFontObject(font) if type(font) == "string" and not Stub.knownName(font) then violation("unknown font object " .. font) end; self._font = font end
function Widget:GetStringWidth() return #(self._text or "") * 6 end
function Widget:Play() self._playing = true end
function Widget:Stop() self._playing = false end
function Widget:IsPlaying() return self._playing == true end
function Widget:SetText(t) self._text = t or "" ; if self._kind == "EditBox" and self._scripts.OnTextChanged then self._scripts.OnTextChanged(self, false) end end
function Widget:GetText() return self._text end
function Widget:Insert(t) self._text = self._text .. t end
function Widget:SetFocus() Stub.focus = self end
function Widget:ClearFocus() if Stub.focus == self then Stub.focus = nil end end
function Widget:HasFocus() return Stub.focus == self end
function Widget:GetEffectiveScale() return Stub.uiScale or 1 end
function Widget:GetStringHeight()
  if Stub.measure then return Stub.measure(self) end   -- preview renderer: real wrapping
  local n = 1; for _ in self._text:gmatch("\n") do n = n + 1 end; return n * 14
end
-- Recorded only so the synthetic preview renderer can draw the layout; no behaviour depends on them.
function Widget:SetAllPoints(rel) self._allPoints = rel or true end
function Widget:SetTextColor(r, g, b) self._textColor = { r, g, b } end
function Widget:SetVertexColor(r, g, b, a) self._vertex = { r, g, b, a } end
function Widget:SetScrollChild(c) self._scrollChild = c; c._scrollOwner = self end
function Widget:SetWordWrap(v) self._nowrap = not v end
function Widget:SetMaxLines(n) self._maxLines = n end
function Widget:SetJustifyH(j) self._justify = j end
function Widget:SetVerticalScroll(v) self._vscroll = v end
function Widget:SetSpacing(v) self._spacing = v end
function Widget:GetVerticalScrollRange() return 0 end
function Widget:Enable() self._enabled = true end
function Widget:Disable() self._enabled = false end
function Widget:IsEnabled() return self._enabled ~= false end
function Widget:Click(button) if self._scripts.OnClick and self:IsEnabled() then self._scripts.OnClick(self, button or "LeftButton") end end
function Widget:SetTexture(path)
  if type(path) == "string" and not Stub.knownTexture(path) then violation("texture path not referenced by the client UI: " .. path) end
  self._texture = path; self._color = nil
end
function Widget:GetTexture() return self._texture end
function Widget:SetColorTexture(r, g, b, a) self._color = { r, g, b, a }; self._atlas = nil; self._texture = nil end
function Widget:SetHighlightTexture(path)
  if type(path) == "string" and not Stub.knownTexture(path) then violation("texture path not referenced by the client UI: " .. path) end
  self._highlight = path
end
function Widget:SetFont(path) return Stub.fontExists and Stub.fontExists(path) or false end

function Widget:RegisterEvent(e) Stub.events[e] = Stub.events[e] or {}; table.insert(Stub.events[e], self) end

-- Template children the addon relies on (checked against the pinned XML in StubTests).
local TEMPLATE_CHILDREN = {
  PortraitFrameTemplate = function(w)
    w.PortraitContainer = Widget.new("Frame", nil, w); w.PortraitContainer.portrait = Widget.new("Texture", nil, w.PortraitContainer)
    w.TitleContainer = Widget.new("Frame", nil, w); w.TitleContainer.TitleText = Widget.new("FontString", nil, w.TitleContainer)
    w.CloseButton = Widget.new("Button", nil, w); w.Bg = Widget.new("Texture", nil, w)
    -- PortraitFrameMixin / TitledPanelMixin API the addon uses
    rawset(w, "SetPortraitToAsset", function(self, tex) self.PortraitContainer.portrait:SetTexture(tex) end)
    rawset(w, "SetTitle", function(self, t) self.TitleContainer.TitleText:SetText(t) end)
  end,
  InsetFrameTemplate = function(w) w.Bg = Widget.new("Texture", nil, w) end,
  SearchBoxTemplate = function(w) w.Instructions = Widget.new("FontString", nil, w) end,
  UIPanelScrollFrameTemplate = function(w) w.ScrollBar = Widget.new("Frame", nil, w) end,
  BasicFrameTemplateWithInset = function(w) w.TitleText = Widget.new("FontString", nil, w) end,
  InputScrollFrameTemplate = function(w) w.EditBox = Widget.new("EditBox", nil, w); w.CharCount = Widget.new("FontString", nil, w) end,
}

function Stub.install(env)
  Stub.events, Stub.tickers, Stub.violations, Stub.reloads, Stub.menus = {}, {}, {}, 0, {}
  Stub.now, Stub.gameTime = 1794160000, 100
  local G = env or _G
  G.CreateFrame = function(kind, name, parent, template)
    if template then
      for t in template:gmatch("[^,%s]+") do if not Stub.knownName(t) then violation("unknown template " .. t) end end
    end
    local w = Widget.new(kind, name, parent)
    w._template = template
    if kind ~= "Frame" or template then w._shown = true end
    if template and TEMPLATE_CHILDREN[template] then TEMPLATE_CHILDREN[template](w) end
    return w
  end
  G.UIParent = Widget.new("Frame", "UIParent")
  G.GameTooltip = setmetatable({ lines = {} }, { __index = function(t, k)
    return ({ SetOwner = function() end, SetText = function(self, s) self.lines = { s } end, AddLine = function(self, s) self.lines[#self.lines + 1] = s end,
      Show = function() end, Hide = function() end })[k] end })
  G.UISpecialFrames = {}
  Stub.chat = {}
  G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) Stub.chat[#Stub.chat + 1] = m end }
  G.tinsert = table.insert
  G.time = function() return Stub.now end
  G.GetTime = function() return Stub.gameTime end
  G.GetPhysicalScreenSize = function() return 2880, 1800 end
  G.IsShiftKeyDown = function() return Stub.shift == true end
  G.ReloadUI = function() Stub.reloads = Stub.reloads + 1 end
  G.SlashCmdList = {}
  G.MenuUtil = { CreateContextMenu = function(owner, gen)
    local root = { items = {} }
    function root:CreateRadio(label, isSel, onSel) self.items[#self.items + 1] = { label = label, select = onSel } end
    gen(owner, root); Stub.menus[#Stub.menus + 1] = root
  end }
  G.C_Timer = { NewTicker = function(s, fn)
    local t = { every = s, acc = 0 }
    local wrapped = function() if t.cancelled then return end; t.acc = t.acc + 0.25; if t.acc + 1e-9 >= s then t.acc = 0; fn() end end
    function t:Cancel() self.cancelled = true end
    Stub.tickers[#Stub.tickers + 1] = wrapped
    return t
  end, After = function(_, fn) fn() end }
  Stub.slots = {}
  G.C_AddOns = {
    DoesAddOnExist = function(n) local k = tonumber(n:match("^T3ForWoW_Slot(%d+)$")); return k ~= nil and k <= (Stub.slotCount or 0) end,
    LoadAddOn = function(n)
      local k = tonumber(n:match("^T3ForWoW_Slot(%d+)$"))
      if Stub.slotsDisabled then return false, "DISABLED" end
      if not k or k > (Stub.slotCount or 0) then return false, "MISSING" end
      if Stub.slots[k] then return true end -- already loaded: the client does not re-run it
      Stub.slots[k] = true
      local p = Stub.onLoadSlot and Stub.onLoadSlot(k) or ""
      G.T3ForWoW_Deliver(k, p)
      return true
    end,
  }
  return G
end

function Stub.fire(event, ...) for _, f in ipairs(Stub.events[event] or {}) do f._scripts.OnEvent(f, event, ...) end end
-- Jump the clock without simulating every tick in between, then run one tick.
function Stub.jump(seconds)
  Stub.gameTime = Stub.gameTime + seconds
  for _, fn in ipairs(Stub.tickers) do fn() end
end
function Stub.advance(seconds)
  local steps = math.floor(seconds / 0.25)
  for _ = 1, steps do Stub.gameTime = Stub.gameTime + 0.25; for _, fn in ipairs(Stub.tickers) do fn() end end
end
return Stub
