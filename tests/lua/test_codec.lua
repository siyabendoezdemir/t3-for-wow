local H = ...
local test, eq, ok, fails = H.test, H.eq, H.ok, H.fails

local function ns() return H.loadAddon(H.CORE) end

test("crc32 matches the IEEE reference vector", function()
  local B = ns().Bytes
  eq(B.crc32("123456789"), 0xCBF43926)
  eq(B.crc32(""), 0)
end)

test("u16/u32 big-endian round trip", function()
  local B = ns().Bytes
  eq(B.u32(0xDEADBEEF), "\222\173\190\239")
  eq(B.readU32("\222\173\190\239", 1), 0xDEADBEEF)
  eq(B.readU16(B.u16(65535), 1), 65535)
end)

test("netstrings encode and decode, rejecting malformed input", function()
  local B = ns().Bytes
  local s = B.netstrings({ "S", "thread:1", "héllo:\n" })
  eq(s, "1:S8:thread:18:h\195\169llo:\n")
  local out = B.parseNetstrings(s)
  eq(#out, 3); eq(out[3], "h\195\169llo:\n")
  eq(B.parseNetstrings("3:ab"), nil)
  eq(B.parseNetstrings("x:ab"), nil)
  eq(B.parseNetstrings("99999999:"), nil)
end)

test("6-bit symbol packing round trips arbitrary bytes", function()
  local B = ns().Bytes
  local bytes = ""
  for i = 0, 255 do bytes = bytes .. string.char(i) end
  local syms = B.toSymbols(bytes)
  eq(#syms, 344) -- ceil(256/3)*4
  for _, s in ipairs(syms) do ok(s >= 0 and s < 64) end
  eq(B.fromSymbols(syms):sub(1, 256), bytes)
end)

test("frame layout: header, chunks and CRC as documented", function()
  local N = ns()
  local bytes = N.Frame.encode({ gameSession = 0x01020304, frameSeq = 7, epochAck = 9, deliveryAck = 11,
    nextSlot = 3, slotCount = 480, flags = 5, chunks = { { reqId = 42, index = 0, count = 1, data = "1:Z" } } })
  eq(bytes:sub(1, 3), "3W\1")
  eq(N.Bytes.readU32(bytes, 5), 0x01020304)
  eq(N.Bytes.readU16(bytes, 19), 3)
  eq(N.Bytes.readU16(bytes, 21), 480)
  eq(bytes:byte(23), 5)
  eq(N.Bytes.readU16(bytes, 24), 11) -- payloadLen = 4+1+1+2+3
  eq(N.Bytes.readU32(bytes, 26), 42)
  local crc = N.Bytes.readU32(bytes, #bytes - 3)
  eq(crc, N.Bytes.crc32(bytes:sub(1, #bytes - 4)))
  local rows = bytes:byte(4)
  ok(rows >= 2 and rows <= 16)
  ok(rows * 0 + (rows - 1) * 60 >= #bytes, "rows hold the frame")
end)

test("frame grid: finder, palette and end marker occupy row 0", function()
  local N = ns()
  local grid = N.Frame.grid(N.Frame.encode({ gameSession = 1, frameSeq = 1, epochAck = 0, deliveryAck = 0, nextSlot = 1, slotCount = 10, flags = 0, chunks = {} }))
  eq(#grid.cells, grid.rows * 80)
  local c = grid.cells
  eq(table.concat(c[1], ","), "0,255,255"); eq(table.concat(c[2], ","), "255,255,0")
  eq(table.concat(c[9], ","), "0,0,0") -- palette symbol 0
  eq(table.concat(c[9 + 63], ","), "255,255,255") -- symbol 63
  eq(table.concat(c[80], ","), "0,255,255")
end)

test("Lua string literal decoding accepts only the documented escape set", function()
  local D = ns().Delivery
  eq(D.unescape("ab\\092\\034\\010"), "ab\\\"\n")
  eq(D.unescape("\\256"), nil)
end)
