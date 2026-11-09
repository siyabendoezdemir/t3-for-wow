-- Runs every Lua test file. Usage: lua tests/lua/run.lua [repo-root]
local root = arg[1] or "."
local H = dofile(root .. "/tests/lua/harness.lua")
H.ROOT = root
local files = { "test_codec.lua", "test_markdown.lua", "test_delivery.lua", "test_budget.lua", "test_outbox.lua", "test_model.lua", "test_transport.lua", "test_ui.lua", "test_probe.lua" }
for _, f in ipairs(files) do
  local p = root .. "/tests/lua/" .. f
  local fh = io.open(p, "r")
  if fh then fh:close(); assert(loadfile(p))(H) end
end
os.exit(H.run() and 0 or 1)
