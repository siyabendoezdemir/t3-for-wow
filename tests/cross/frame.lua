-- Lua side of the cross-language check: encode a frame with the real addon code and draw it as
-- the strip would be drawn (PPM). Also verifies a Swift-written slot with the client's loader rules.
local root, mode, a, b = arg[1], arg[2], arg[3], arg[4]
local H = dofile(root .. "/tests/lua/harness.lua"); H.ROOT = root
local ns = H.loadAddon(H.CORE)
if mode == "frame" then
  local o = ns.Outbox.new(function() return 0 end)
  o:send("thread:é|x", "multi\nline \"quoted\" reply é")
  local bytes = ns.Frame.encode({ gameSession = 123456789, frameSeq = 42, epochAck = 7, deliveryAck = 99, nextSlot = 12, slotCount = 480, flags = 5, chunks = o:nextChunks(ns.Frame.MAX_PAYLOAD) })
  local g = ns.Frame.grid(bytes)
  local cell, W, Hh = 4, 80 * 4 + 64, 16 * 4 + 30
  local px = {}
  for i = 1, W * Hh do px[i] = "\60\40\20" end
  for i, c in ipairs(g.cells) do
    local cx, cy = 31 + ((i - 1) % 80) * cell, 7 + math.floor((i - 1) / 80) * cell
    for dy = 0, cell - 1 do for dx = 0, cell - 1 do px[(cy + dy) * W + cx + dx + 1] = string.char(c[1], c[2], c[3]) end end
  end
  H.writeFile(a, "P6\n" .. W .. " " .. Hh .. "\n255\n" .. table.concat(px))
elseif mode == "slot" then
  local src = H.readFile(a)
  assert(src:match('^T3ForWoW_Deliver%(%d+,"[^"\n]*"%)\n$'), "slot file is not the single safe call")
  assert(ns.Delivery.unescape(src:match('"(.*)"')), "literal uses only the documented alphabet")
  local got
  local chunk = assert(loadstring(src))
  setfenv(chunk, { T3ForWoW_Deliver = function(k, p) got = ns.Delivery.parse(p, { slot = k, gameSession = tonumber(b) }) end })
  chunk()
  assert(got, "delivery did not parse")
  local m
  for _, r in ipairs(got.records) do if r[1] == "m" then m = r end end
  local want = "quote\" back\\slash ]] --[[ é 日本 |TInterface\\x|t \0nul\nline2"
  assert(m and m[9] == want, "text mismatch: " .. tostring(m and m[9]))
  assert(ns.Text.safe(m[9]):find("||TInterface"), "display escaping")
  print("LUA_SLOT_OK records=" .. #got.records)
end
