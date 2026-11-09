-- The pixel strip the bridge reads (docs/PROTOCOL.md section 1). Top-centre of the screen,
-- parentless so it stays drawn when the player hides the interface (Alt+Z), whole physical pixels.
local _, ns = ...
local Strip = { CELL_PX = 3 }
ns.Strip = Strip

function Strip.create()
  local f = CreateFrame("Frame", "T3ForWoWStrip", nil)
  f:SetFrameStrata("TOOLTIP")
  f:SetFrameLevel(10000)
  f:SetClampedToScreen(true)
  f.cells = {}
  Strip.frame = f
  Strip.layout()
  return f
end

function Strip.unit()
  local _, physH = GetPhysicalScreenSize()
  local scale = Strip.frame:GetEffectiveScale()
  if not physH or physH <= 0 or not scale or scale <= 0 then return 1 end
  return (768 / physH) / scale
end

function Strip.layout()
  local f = Strip.frame
  local u = Strip.unit() * Strip.CELL_PX
  f.cellSize = u
  f:ClearAllPoints()
  f:SetPoint("TOP", nil, "TOP", 0, 0)
  f:SetSize(ns.Frame.COLS * u, ns.Frame.MAX_ROWS * u)
  for i, t in pairs(f.cells) do
    local c, r = (i - 1) % ns.Frame.COLS, math.floor((i - 1) / ns.Frame.COLS)
    t:SetSize(u, u)
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", f, "TOPLEFT", c * u, -r * u)
  end
end

local function cell(f, i)
  local t = f.cells[i]
  if t then return t end
  t = f:CreateTexture(nil, "OVERLAY")
  t:SetSnapToPixelGrid(false)
  t:SetTexelSnappingBias(0)
  local c, r = (i - 1) % ns.Frame.COLS, math.floor((i - 1) / ns.Frame.COLS)
  t:SetSize(f.cellSize, f.cellSize)
  t:SetPoint("TOPLEFT", f, "TOPLEFT", c * f.cellSize, -r * f.cellSize)
  f.cells[i] = t
  return t
end

-- Paint frame bytes. Only changed cells are touched; unused rows are hidden.
function Strip.paint(bytes)
  local f = Strip.frame
  local grid = ns.Frame.grid(bytes)
  local n = grid.rows * ns.Frame.COLS
  for i = 1, n do
    local c = grid.cells[i]
    local t = cell(f, i)
    local key = c[1] * 65536 + c[2] * 256 + c[3]
    if t.key ~= key then t:SetColorTexture(c[1] / 255, c[2] / 255, c[3] / 255, 1); t.key = key end
    if not t:IsShown() then t:Show() end
  end
  for i = n + 1, #f.cells do if f.cells[i]:IsShown() then f.cells[i]:Hide() end end
  f.rows = grid.rows
end
