-- Minimal test harness for plain Lua 5.1 (the dialect WoW embeds). SYNTHETIC only.
local H = { tests = {}, failures = 0, passed = 0 }
local ROOT = (...) or "."
H.ROOT = ROOT

function H.test(name, fn) H.tests[#H.tests + 1] = { name = name, fn = fn } end

local function fmt(v)
  if type(v) == "string" then return string.format("%q", v) end
  return tostring(v)
end
function H.eq(a, b, msg)
  if a ~= b then error((msg or "values differ") .. ": expected " .. fmt(b) .. ", got " .. fmt(a), 2) end
end
function H.ok(v, msg) if not v then error(msg or "expected truthy", 2) end end
function H.fails(fn, pattern)
  local ok, err = pcall(fn)
  if ok then error("expected failure", 2) end
  if pattern and not tostring(err):find(pattern) then error("wrong error: " .. tostring(err), 2) end
end

-- Load addon files the way the WoW client does: each file gets (addonName, namespaceTable).
function H.loadAddon(files, ns, env)
  ns = ns or {}
  for _, f in ipairs(files) do
    local chunk, err = loadfile(ROOT .. "/addon/T3ForWoW/" .. f)
    if not chunk then error(err) end
    if env then setfenv(chunk, env) end
    chunk("T3ForWoW", ns)
  end
  return ns
end
H.CORE = { "Core/Bytes.lua", "Core/Text.lua", "Core/Markdown.lua", "Core/Frame.lua", "Core/Delivery.lua", "Core/Budget.lua", "Core/Outbox.lua", "Core/Model.lua", "Core/Transport.lua" }

function H.readFile(p) local f = assert(io.open(p, "rb")); local s = f:read("*a"); f:close(); return s end
function H.writeFile(p, s) local f = assert(io.open(p, "wb")); f:write(s); f:close() end

function H.run()
  for _, t in ipairs(H.tests) do
    local ok, err = pcall(t.fn)
    if ok then H.passed = H.passed + 1 else H.failures = H.failures + 1; print("FAIL " .. t.name .. "\n     " .. tostring(err)) end
  end
  print(string.format("lua tests: %d passed, %d failed", H.passed, H.failures))
  return H.failures == 0
end
return H
