-- Requests from the game to the bridge, carried in the pixel frame until acknowledged.
-- A request's identity (gameSession, reqId) is its idempotency key end to end.
local _, ns = ...
local B = ns.Bytes
local Outbox = { MAX_TEXT = 4096, MAX_PENDING = 16, CHUNK = 200, MAX_CHUNKS = 64, UNCONFIRMED_AFTER = 300 }
Outbox.__index = Outbox
ns.Outbox = Outbox

function Outbox.new(clock)
  return setmetatable({ clock = clock or (time or os.time), nextId = 1, items = {}, order = {}, cursor = 0 }, Outbox)
end

function Outbox:get(id) return self.items[id] end

function Outbox:pendingCount()
  local n = 0
  for _, id in ipairs(self.order) do if not self.items[id].acked then n = n + 1 end end
  return n
end

function Outbox:add(kind, fields, meta)
  if self:pendingCount() >= Outbox.MAX_PENDING then return nil, "busy" end
  local list = { kind }
  for i = 1, #fields do list[#list + 1] = fields[i] end
  local body = B.netstrings(list)
  local count = math.max(1, math.ceil(#body / Outbox.CHUNK))
  if count > Outbox.MAX_CHUNKS then return nil, "too long" end
  local id = self.nextId
  self.nextId = id + 1
  local item = { id = id, kind = kind, body = body, chunkCount = count, sentAt = self.clock(), state = "waiting", nextChunk = 0 }
  for k, v in pairs(meta or {}) do item[k] = v end
  self.items[id] = item
  self.order[#self.order + 1] = id
  return id
end

local function cleanText(text)
  if type(text) ~= "string" or not text:find("%S") then return nil, "empty" end
  if #text > Outbox.MAX_TEXT then return nil, "too long" end
  return text
end

function Outbox:send(threadId, text)
  local t, err = cleanText(text)
  if not t then return nil, err end
  return self:add("S", { threadId, t }, { threadId = threadId, text = t })
end

function Outbox:newThread(projectId, title, text)
  local t, err = cleanText(text)
  if not t then return nil, err end
  return self:add("N", { projectId, title or "", t }, { projectId = projectId, text = t })
end

function Outbox:watch(threadId)
  for _, id in ipairs(self.order) do
    local it = self.items[id]
    if it.kind == "W" and it.threadId == threadId and not it.acked then return id end
  end
  return self:add("W", { threadId }, { threadId = threadId })
end

function Outbox:older(threadId, beforePosition) return self:add("H", { threadId, tostring(beforePosition) }, { threadId = threadId }) end
function Outbox:resync() return self:add("Z", {}, {}) end

function Outbox:ack(id, state)
  local it = self.items[id]
  if not it then return end
  it.acked = true
  it.state = state
end

function Outbox:expire()
  local now = self.clock()
  for _, id in ipairs(self.order) do
    local it = self.items[id]
    if not it.acked and now - it.sentAt >= Outbox.UNCONFIRMED_AFTER then it.state = "unconfirmed" end
  end
end

-- Next chunks to show, round-robin over unacknowledged requests, within byteBudget.
function Outbox:nextChunks(byteBudget)
  local pending = {}
  for _, id in ipairs(self.order) do if not self.items[id].acked then pending[#pending + 1] = self.items[id] end end
  local out, used = {}, 0
  if #pending == 0 then return out end
  local guard = 0
  while guard < #pending * Outbox.MAX_CHUNKS do
    guard = guard + 1
    self.cursor = self.cursor % #pending + 1
    local it = pending[self.cursor]
    local i = it.nextChunk
    local data = it.body:sub(i * Outbox.CHUNK + 1, (i + 1) * Outbox.CHUNK)
    if used + 8 + #data > byteBudget then break end
    out[#out + 1] = { reqId = it.id, index = i, count = it.chunkCount, data = data }
    used = used + 8 + #data
    it.nextChunk = (i + 1) % it.chunkCount
    if #out >= #pending * it.chunkCount then break end
  end
  return out
end

-- Drop acknowledged non-send requests to keep memory bounded.
function Outbox:compact()
  local keep = {}
  for _, id in ipairs(self.order) do
    local it = self.items[id]
    if it.acked and it.kind ~= "S" and it.kind ~= "N" then self.items[id] = nil else keep[#keep + 1] = id end
  end
  self.order = keep
end
