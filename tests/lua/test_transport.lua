local H = ...
local test, eq, ok = H.test, H.eq, H.ok

local function rig(slotCount, deliveries)
  local n = H.loadAddon(H.CORE)
  local clock = 1000
  local tr
  local env = { clock = function() return clock end, random = function() return 4242 end, slotCount = slotCount }
  env.loadSlot = function(k)
    local p = deliveries[k]
    if p == false then return false, "DISABLED" end
    tr:onDeliver(k, p and p(tr, k) or "")
    return true
  end
  tr = n.Transport.new(env)
  return n, tr, function(dt) clock = clock + dt; return clock end
end
local function payload(n, slot, session, version, records)
  local list = { "T3D1", tostring(slot), "9", tostring(session), tostring(version), "0", "1000", tostring(#records) }
  for _, r in ipairs(records) do list[#list + 1] = n.Bytes.netstrings(r) end
  return n.Bytes.netstrings(list)
end

test("transport loads slots in order, acks the applied version and retires requests", function()
  local n, tr, adv
  local deliveries = {}
  deliveries[1] = function(t, k) return payload(n, k, t.gameSession, 3, { { "r", "1", "accepted", "", "a", "m" } }) end
  n, tr, adv = rig(10, deliveries)
  local id = tr.outbox:send("a", "hi")
  eq(tr:step(adv(1)), nil, "dwell before the first load")
  eq(tr:step(adv(5)), 1)
  eq(tr.deliveryAck, 3); eq(tr.epochAck, 9); eq(tr.nextSlot, 2)
  eq(tr.outbox:get(id).state, "accepted")
  local f = n.Frame.encode and tr:frame()
  eq(n.Bytes.readU32(f, 15), 3)
  eq(n.Bytes.readU16(f, 19), 2)
end)

test("empty or stale slots count as bridge silence and back off", function()
  local n, tr, adv = rig(10, {})
  tr:step(adv(5))
  eq(tr.silent, 1)
  ok(tr.expected >= 60)
end)

test("a slot that cannot load (disabled in AddOns list) is reported and not consumed", function()
  local n, tr, adv = rig(10, { [1] = false })
  eq(tr:step(adv(5)), nil)
  eq(tr.loadError, "DISABLED"); eq(tr.used, 0); eq(tr.nextSlot, 1)
end)

test("exhaustion stops loading and is announced in the frame flags", function()
  local n, tr, adv = rig(2, {})
  tr:step(adv(5)); tr:step(adv(30000)) -- governor spreads 2 slots over the horizon
  eq(tr.nextSlot, 0)
  ok(tr:budgetStatus().exhausted)
  eq(tr:step(adv(10000)), nil)
  local f = tr:frame()
  eq(f:byte(23) % 4 >= 2, true)
end)
