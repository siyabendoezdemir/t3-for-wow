-- Game -> bridge pixel frame (docs/PROTOCOL.md section 1).
local _, ns = ...
local B = ns.Bytes
local Frame = { COLS = 80, BYTES_PER_ROW = 60, MIN_ROWS = 2, MAX_ROWS = 16, HEADER = 25 }
ns.Frame = Frame

local L = { 0, 85, 170, 255 }
local C, Y, K, W = { 0, 255, 255 }, { 255, 255, 0 }, { 0, 0, 0 }, { 255, 255, 255 }
Frame.FINDER = { C, Y, C, Y, K, W, K, W }
Frame.ENDMARK = { W, K, W, K, Y, C, Y, C }

function Frame.symbolColor(s)
  local f = math.floor
  return { L[f(s / 16) % 4 + 1], L[f(s / 4) % 4 + 1], L[s % 4 + 1] }
end

Frame.MAX_PAYLOAD = (Frame.MAX_ROWS - 1) * Frame.BYTES_PER_ROW - Frame.HEADER - 4

function Frame.rowsFor(totalBytes)
  local data = math.ceil(totalBytes / Frame.BYTES_PER_ROW)
  return math.max(Frame.MIN_ROWS, data + 1)
end

-- f: gameSession, frameSeq, epochAck, deliveryAck, nextSlot, slotCount, flags, chunks
function Frame.encode(f)
  local parts = {}
  for _, ch in ipairs(f.chunks or {}) do
    parts[#parts + 1] = B.u32(ch.reqId) .. string.char(ch.index, ch.count) .. B.u16(#ch.data) .. ch.data
  end
  local payload = table.concat(parts)
  assert(#payload <= Frame.MAX_PAYLOAD, "frame payload too large")
  local rows = Frame.rowsFor(Frame.HEADER + #payload + 4)
  local head = "3W" .. string.char(1, rows) .. B.u32(f.gameSession) .. B.u16(f.frameSeq % 65536)
    .. B.u32(f.epochAck) .. B.u32(f.deliveryAck) .. B.u16(f.nextSlot) .. B.u16(f.slotCount)
    .. string.char(f.flags % 256) .. B.u16(#payload)
  local body = head .. payload
  return body .. B.u32(B.crc32(body))
end

-- Returns { rows=, cells = { {r,g,b}, ... } } row-major, COLS per row.
function Frame.grid(bytes)
  local rows = bytes:byte(4)
  local cells = {}
  for i = 1, 8 do cells[i] = Frame.FINDER[i] end
  for s = 0, 63 do cells[9 + s] = Frame.symbolColor(s) end
  for i = 1, 8 do cells[72 + i] = Frame.ENDMARK[i] end
  local syms = B.toSymbols(bytes)
  local total = rows * Frame.COLS
  for i = Frame.COLS + 1, total do
    local s = syms[i - Frame.COLS] or 0
    cells[i] = Frame.symbolColor(s)
  end
  return { rows = rows, cells = cells }
end
