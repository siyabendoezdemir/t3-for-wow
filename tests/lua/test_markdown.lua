local H = ...
local test, eq, ok = H.test, H.eq, H.ok
local function MD() return H.loadAddon(H.CORE).Markdown end

-- Helper: strip our own colour codes to check the visible text.
local function visible(s) return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("||", "|")) end

test("markdown: headings become coloured title lines without the # marks", function()
  local out = MD().render("# Plan\n## Step one\n### Detail", "parchment")
  ok(not visible(out):find("#"), out)
  ok(visible(out):find("Plan") and visible(out):find("Step one") and visible(out):find("Detail"))
  ok(out:find("|c"), "headings coloured")
end)

test("markdown: bold, italic and inline code are styled, markers removed", function()
  local out = MD().render("Use **bold**, *soft* and `code()` here.", "parchment")
  eq(visible(out), "Use bold, soft and code() here.")
  ok(out:find("|c%x+bold|r") and out:find("|c%x+code%(%)|r"))
end)

test("markdown: bullets, nested bullets, numbers and task items read cleanly", function()
  local out = visible(MD().render("- one\n  - nested\n* two\n1. first\n2) second\n- [ ] todo\n- [x] done", "parchment"))
  ok(out:find("• one", 1, true)); ok(out:find("    • nested", 1, true), "nested bullet indented (• is in WoW's font set)")
  ok(out:find("• two", 1, true)); ok(out:find("1. first", 1, true)); ok(out:find("2. second", 1, true))
  ok(out:find("[ ] todo", 1, true)); ok(out:find("[x] done", 1, true))
end)

test("markdown: fenced code keeps lines verbatim (no inline formatting inside), indented and coloured", function()
  local out = MD().render("Before\n```lua\nlocal x = **1** -- not bold\nprint(x)\n```\nAfter", "parchment")
  local v = visible(out)
  ok(v:find("    local x = **1** -- not bold", 1, true), v)
  ok(v:find("    print(x)", 1, true)); ok(not v:find("```", 1, true)); ok(not v:find("lua\n", 1, true))
end)

test("markdown: links show their text plus a muted host; quotes and rules are drawn natively", function()
  local v = visible(MD().render("See [the docs](https://example.com/a/b).\n> quoted line\n---", "parchment"))
  ok(v:find("See the docs (example.com).", 1, true), v)
  ok(v:find("¦ quoted line", 1, true)); ok(v:find("———", 1, true))
end)

test("markdown: tables become readable rows; separator rows dropped", function()
  local v = visible(MD().render("| Name | State |\n|---|:---:|\n| api | ok |", "parchment"))
  ok(v:find("Name  ·  State", 1, true), v); ok(v:find("api  ·  ok", 1, true)); ok(not v:find("---", 1, true))
end)

test("markdown: agent text can never inject WoW escapes (colour, texture, link)", function()
  local evil = "**|cffff0000red|r** |TInterface\\Icons\\X:0|t |Hitem:1|h[x]|h `|K`"
  local out = MD().render(evil, "parchment")
  -- every '|' coming from the agent is doubled; our own codes are the only live ones
  local stripped = out:gsub("||", "")
  for code in stripped:gmatch("|(.)") do ok(code == "c" or code == "r", "unexpected live escape |" .. code) end
  ok(not out:find("[^|]|T") and not out:find("[^|]|H") and not out:find("[^|]|K"))
end)

test("markdown: only glyphs from WoW's Latin-1/Windows-1252 font set are introduced", function()
  local out = MD().render("# T\n- a\n  - b\n> q\n---\n| x | y |\n1. n\n[l](https://h/x)", "parchment")
  local allowed = { ["•"] = true, ["¦"] = true, ["—"] = true, ["·"] = true, ["…"] = true }
  for ch in out:gmatch("[\194-\244][\128-\191]+") do ok(allowed[ch], "glyph outside WoW font set: " .. ch) end
end)

test("markdown: dark theme uses light colours; plain text passes through unchanged", function()
  local M = MD()
  eq(M.render("just words", "dark"), "just words")
  ok(M.render("# Title", "dark") ~= M.render("# Title", "parchment"), "themes differ")
end)

test("markdown: long input is bounded and blank-line runs collapse", function()
  local M = MD()
  local out = M.render(string.rep("word ", 5000) .. "\n\n\n\n\nend", "parchment")
  ok(#out <= M.MAX_OUTPUT + 64, #out)
  ok(not M.render("a\n\n\n\nb", "parchment"):find("\n\n\n", 1, true))
end)
