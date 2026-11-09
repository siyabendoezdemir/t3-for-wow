-- Bridge -> game delivery decoding (docs/PROTOCOL.md section 2). Data only: records are plain
-- strings; nothing here is ever evaluated as code.
local _, ns = ...
local B = ns.Bytes
local Delivery = { MAX_PAYLOAD = 65536, MAX_RECORDS = 2000 }
ns.Delivery = Delivery

-- Exact field counts (min, max) per record type.
local SHAPE = {
  st = { 8, 8 }, p = { 3, 3 }, t = { 11, 11 }, tl = { 1, 61 }, m = { 10, 10 },
  h = { 5, 5 }, r = { 6, 6 }, x = { 2, 2 },
}
Delivery.SHAPE = SHAPE

function Delivery.parseRecord(s)
  local f = B.parseNetstrings(s, 64)
  if not f or #f == 0 then return nil end
  local shape = SHAPE[f[1]]
  if not shape or #f < shape[1] or #f > shape[2] then return nil end
  return f
end

-- expect: { slot=, gameSession= }. Returns delivery table or nil, reason.
function Delivery.parse(payload, expect)
  if type(payload) ~= "string" then return nil, "not a string" end
  if payload == "" then return nil, "empty" end
  if #payload > Delivery.MAX_PAYLOAD then return nil, "too large" end
  local f = B.parseNetstrings(payload, Delivery.MAX_RECORDS + 8)
  if not f or #f < 8 or f[1] ~= "T3D1" then return nil, "bad header" end
  local slot, epoch, session, version, more, bridgeTime, count =
    tonumber(f[2]), tonumber(f[3]), tonumber(f[4]), tonumber(f[5]), f[6], tonumber(f[7]), tonumber(f[8])
  if not (slot and epoch and session and version and bridgeTime and count) then return nil, "bad header" end
  if slot ~= expect.slot then return nil, "wrong slot" end
  if session ~= expect.gameSession then return nil, "stale session" end
  if count ~= #f - 8 then return nil, "bad count" end
  local records = {}
  for i = 9, #f do
    local r = Delivery.parseRecord(f[i])
    if not r then return nil, "bad record" end
    records[#records + 1] = r
  end
  return { slot = slot, epoch = epoch, version = version, more = more == "1", bridgeTime = bridgeTime, records = records }
end

-- Strict decoder for the slot literal alphabet (used by tests and the cross-language check):
-- printable ASCII except '"' and '\', plus \ddd escapes (000-255).
function Delivery.unescape(lit)
  local out, i, n = {}, 1, #lit
  while i <= n do
    local c = lit:sub(i, i)
    if c == "\\" then
      local d = lit:sub(i + 1, i + 3)
      if not d:match("^%d%d%d$") or tonumber(d) > 255 then return nil end
      out[#out + 1] = string.char(tonumber(d)); i = i + 4
    else
      local b = c:byte()
      if b < 32 or b > 126 or c == '"' then return nil end
      out[#out + 1] = c; i = i + 1
    end
  end
  return table.concat(out)
end
