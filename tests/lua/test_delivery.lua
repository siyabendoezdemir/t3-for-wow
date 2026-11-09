local H = ...
local test, eq, ok = H.test, H.eq, H.ok
local function N() return H.loadAddon(H.CORE) end

local function payload(n, fields, records)
  local B = n.Bytes
  local list = { "T3D1" }
  for _, f in ipairs(fields) do list[#list + 1] = f end
  list[#list + 1] = tostring(#records)
  for _, r in ipairs(records) do list[#list + 1] = B.netstrings(r) end
  return B.netstrings(list)
end

test("valid delivery parses with records", function()
  local n = N()
  local p = payload(n, { "3", "77", "123456", "9", "0", "2000" }, { { "p", "p1", "Alpha" } })
  local d = assert(n.Delivery.parse(p, { slot = 3, gameSession = 123456 }))
  eq(d.version, 9); eq(d.epoch, 77); eq(#d.records, 1); eq(d.records[1][3], "Alpha")
end)

test("wrong slot, stale session, bad count and malformed records are rejected", function()
  local n = N()
  local good = { "3", "77", "123456", "9", "0", "2000" }
  eq(select(2, n.Delivery.parse(payload(n, good, {}), { slot = 4, gameSession = 123456 })), "wrong slot")
  eq(select(2, n.Delivery.parse(payload(n, good, {}), { slot = 3, gameSession = 1 })), "stale session")
  eq(select(2, n.Delivery.parse(payload(n, good, { { "p", "only-two" } }), { slot = 3, gameSession = 123456 })), "bad record")
  eq(select(2, n.Delivery.parse(payload(n, good, { { "zz", "a", "b" } }), { slot = 3, gameSession = 123456 })), "bad record")
  eq(select(2, n.Delivery.parse("", { slot = 3, gameSession = 1 })), "empty")
  eq(select(2, n.Delivery.parse("4:T3D0", { slot = 3, gameSession = 1 })), "bad header")
end)

test("installer placeholder slot is recognised as empty", function()
  local n = N()
  eq(select(2, n.Delivery.parse("", { slot = 1, gameSession = 1 })), "empty")
end)
