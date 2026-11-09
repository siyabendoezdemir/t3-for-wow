-- Byte helpers: big-endian integers, CRC-32 (IEEE), netstrings, 6-bit symbol packing.
-- Pure arithmetic (no bit library needed), so the same file runs in WoW and plain Lua 5.1.
local _, ns = ...
local Bytes = {}
ns.Bytes = Bytes

local floor, char, byte, concat = math.floor, string.char, string.byte, table.concat

local function bxor(a, b)
  local r, p = 0, 1
  while a > 0 or b > 0 do
    local x, y = a % 2, b % 2
    if x ~= y then r = r + p end
    a, b, p = floor(a / 2), floor(b / 2), p * 2
  end
  return r
end
Bytes.bxor = bxor

local CRC = {}
for i = 0, 255 do
  local c = i
  for _ = 1, 8 do
    if c % 2 == 1 then c = bxor(floor(c / 2), 0xEDB88320) else c = floor(c / 2) end
  end
  CRC[i] = c
end

function Bytes.crc32(s)
  local c = 0xFFFFFFFF
  for i = 1, #s do
    c = bxor(CRC[bxor(c % 256, byte(s, i))], floor(c / 256))
  end
  return bxor(c, 0xFFFFFFFF)
end

function Bytes.u16(n) return char(floor(n / 256) % 256, n % 256) end
function Bytes.u32(n) return char(floor(n / 16777216) % 256, floor(n / 65536) % 256, floor(n / 256) % 256, n % 256) end
function Bytes.readU16(s, i) local a, b = byte(s, i, i + 1); return a * 256 + b end
function Bytes.readU32(s, i) local a, b, c, d = byte(s, i, i + 3); return ((a * 256 + b) * 256 + c) * 256 + d end

function Bytes.netstrings(list)
  local out = {}
  for i = 1, #list do local v = tostring(list[i]); out[#out + 1] = #v .. ":" .. v end
  return concat(out)
end

-- Returns an array of strings, or nil if the input is not an exact netstring sequence.
function Bytes.parseNetstrings(s, maxFields)
  local out, i, n = {}, 1, #s
  maxFields = maxFields or 4096
  while i <= n do
    local colon = s:find(":", i, true)
    if not colon or colon - i > 8 or colon == i then return nil end
    local lenStr = s:sub(i, colon - 1)
    if not lenStr:match("^%d+$") then return nil end
    local len = tonumber(lenStr)
    if colon + len > n then return nil end
    out[#out + 1] = s:sub(colon + 1, colon + len)
    if #out > maxFields then return nil end
    i = colon + len + 1
  end
  return out
end

-- 3 bytes -> 4 six-bit symbols, big-endian bit order, zero padded.
function Bytes.toSymbols(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = byte(s, i, i + 2)
    local v = ((a * 256) + (b or 0)) * 256 + (c or 0)
    out[#out + 1] = floor(v / 262144) % 64
    out[#out + 1] = floor(v / 4096) % 64
    out[#out + 1] = floor(v / 64) % 64
    out[#out + 1] = v % 64
  end
  return out
end

function Bytes.fromSymbols(syms)
  local out = {}
  for i = 1, #syms - 3, 4 do
    local v = ((syms[i] * 64 + syms[i + 1]) * 64 + syms[i + 2]) * 64 + syms[i + 3]
    out[#out + 1] = char(floor(v / 65536) % 256, floor(v / 256) % 256, v % 256)
  end
  return concat(out)
end
