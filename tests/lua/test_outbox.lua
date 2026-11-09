local H = ...
local test, eq, ok, fails = H.test, H.eq, H.ok, H.fails
local function N() return H.loadAddon(H.CORE) end

test("send request is bound to its thread and gets a fresh reqId", function()
  local n = N(); local o = n.Outbox.new()
  local a = o:send("thread:A", "hello")
  local b = o:send("thread:B", "hi")
  ok(a ~= b)
  eq(o:get(a).threadId, "thread:A")
  local f = n.Bytes.parseNetstrings(o:get(a).body)
  eq(f[1], "S"); eq(f[2], "thread:A"); eq(f[3], "hello")
end)

test("empty, oversized and too many pending requests are refused locally", function()
  local n = N(); local o = n.Outbox.new()
  eq(select(2, o:send("t", "   ")), "empty")
  eq(select(2, o:send("t", string.rep("x", 4097))), "too long")
  for i = 1, 16 do ok(o:send("t", "m" .. i)) end
  eq(select(2, o:send("t", "one more")), "busy")
end)

test("chunks fit the frame budget, round-robin across pending requests", function()
  local n = N(); local o = n.Outbox.new()
  local big = o:send("t", string.rep("a", 2000))
  local small = o:send("t", "b")
  local seen = {}
  for _ = 1, 20 do
    local chunks = o:nextChunks(n.Frame.MAX_PAYLOAD)
    local size = 0
    for _, c in ipairs(chunks) do size = size + 8 + #c.data; seen[c.reqId .. ":" .. c.index] = true end
    ok(size <= n.Frame.MAX_PAYLOAD)
  end
  ok(seen[small .. ":0"], "small request not starved")
  local count = o:get(big).chunkCount
  for i = 0, count - 1 do ok(seen[big .. ":" .. i], "chunk " .. i) end
end)

test("bridge acknowledgement (any r record) stops retransmission; state is kept for the UI", function()
  local n = N(); local o = n.Outbox.new()
  local id = o:send("t", "x")
  o:ack(id, "accepted")
  eq(#o:nextChunks(n.Frame.MAX_PAYLOAD), 0)
  eq(o:get(id).state, "accepted")
end)

test("new thread and watch requests carry their target ids", function()
  local n = N(); local o = n.Outbox.new()
  local id = o:newThread("project:1", "Title", "Do the thing")
  local f = n.Bytes.parseNetstrings(o:get(id).body)
  eq(f[1], "N"); eq(f[2], "project:1"); eq(f[3], "Title"); eq(f[4], "Do the thing")
  local w = o:watch("thread:9")
  eq(n.Bytes.parseNetstrings(o:get(w).body)[2], "thread:9")
  -- watching the same thread twice while pending is coalesced
  eq(o:watch("thread:9"), w)
end)

test("partial requests expire; unacknowledged sends stay visible as unconfirmed", function()
  local n = N(); local clock = 0
  local o = n.Outbox.new(function() return clock end)
  local id = o:send("t", "x")
  clock = 400
  o:expire()
  eq(o:get(id).state, "unconfirmed")
  eq(#o:nextChunks(n.Frame.MAX_PAYLOAD), 1, "still retransmitted (the bridge may be offline)")
end)
