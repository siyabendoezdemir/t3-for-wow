-- Small shared visual pieces built only from the client's own art.
local _, ns = ...
local Widgets = {}
ns.Widgets = Widgets

-- Status colours (WoW conventions: orange = needs you, blue = in progress, green = done, red = failed).
Widgets.KIND_COLOR = {
  needs = { 1.0, 0.55, 0.10 }, working = { 0.40, 0.73, 1.00 }, finished = { 0.25, 0.75, 0.25 },
  failed = { 1.0, 0.25, 0.25 }, stopped = { 0.62, 0.62, 0.62 }, idle = { 0.62, 0.62, 0.62 }, unknown = { 0.62, 0.62, 0.62 },
}
Widgets.KIND_HEX = { needs = "ff8c1a", working = "66bbff", finished = "40c040", failed = "ff4040", stopped = "9a9a9a", idle = "9a9a9a", unknown = "9a9a9a" }

-- The classic streaming spinner (Interface\COMMON\StreamCircle + StreamSpark, as in the client's
-- LoadingSpinnerTemplate), rotating only while `SetSpinning(true)`.
function Widgets.spinner(parent, size)
  local s = CreateFrame("Frame", nil, parent)
  s:SetSize(size, size)
  s.circle = s:CreateTexture(nil, "ARTWORK"); s.circle:SetAllPoints(); s.circle:SetTexture("Interface\\COMMON\\StreamCircle")
  s.spark = s:CreateTexture(nil, "OVERLAY"); s.spark:SetAllPoints(); s.spark:SetTexture("Interface\\COMMON\\StreamSpark")
  local g = s.spark:CreateAnimationGroup()
  local r = g:CreateAnimation("Rotation"); r:SetDegrees(-360); r:SetDuration(1.2)
  g:SetLooping("REPEAT")
  s.anim = g
  function s:SetSpinning(on)
    if on then self:Show(); if not g:IsPlaying() then g:Play() end
    else if g:IsPlaying() then g:Stop() end end
  end
  return s
end

-- Status icon for a work state: spinner while working, quest-style marks otherwise.
-- Returns a frame with :SetState(ws) where ws comes from Model:workState.
local ATLAS = { needs = "QuestNormal", finished = "QuestTurnin", failed = "common-icon-redx" }
function Widgets.statusIcon(parent, size)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(size, size)
  f.mark = f:CreateTexture(nil, "ARTWORK"); f.mark:SetAllPoints()
  f.spin = Widgets.spinner(f, size); f.spin:SetPoint("CENTER")
  function f:SetState(ws)
    local atlas = ATLAS[ws.kind]
    if ws.kind == "working" then
      self.mark:Hide(); self.spin:Show(); self.spin:SetSpinning(ws.animate)
      self.spin:SetAlpha(ws.animate and 1 or 0.45)          -- queued / waiting: dim, not spinning
    elseif atlas then
      self.spin:SetSpinning(false); self.spin:Hide(); self.mark:SetAtlas(atlas); self.mark:Show()
    else
      self.spin:SetSpinning(false); self.spin:Hide(); self.mark:Hide()
    end
  end
  return f
end
