-- Markdown → clean WoW-native text for FontStrings (colour codes + plain glyphs from WoW's font set).
-- Safe by construction: every line of agent text is |-escaped (Text.safe) BEFORE this module adds its
-- own |c…|r codes, so agent text can never produce colour, texture, link or other escapes.
-- Supported: # headings, **bold**/__bold__, *italic*/_italic_, ~~strike~~, `code`, ``` fenced code ```,
-- - * + bullets (nested by indent), 1. / 1) numbered lists, - [ ] / - [x] tasks, > quotes, --- rules,
-- [text](url) links (text + muted host), | tables |. Unknown syntax is shown as plain text.
local _, ns = ...
local Markdown = { MAX_OUTPUT = 12000 }
ns.Markdown = Markdown

Markdown.THEMES = {
  -- dark ink on the journal parchment (body colour comes from the parchment font)
  parchment = { h1 = "5c1a00", h2 = "5c1a00", h3 = "7a4a10", bold = "1a0d00", italic = "6b4a2a", code = "1f4f7a",
                link = "1f4f7a", muted = "7a6a50", rule = "8a6a3a", done = "2e6b1f" },
  -- light text on dark surfaces
  dark = { h1 = "ffd100", h2 = "ffd100", h3 = "ffe38a", bold = "ffffff", italic = "c8c8c8", code = "9ad0ff",
           link = "66bbff", muted = "9a9a9a", rule = "806030", done = "6ad35a" },
}

local function c(hex, s) return "|cff" .. hex .. s .. "|r" end

local function inline(s, th)
  s = ns.Text.safe(s)
  local codes = {}
  s = s:gsub("`([^`]+)`", function(x) codes[#codes + 1] = x; return "\1" .. #codes .. "\2" end)
  s = s:gsub("%[([^%]]+)%]%(([^%)%s]+)%)", function(t, u)
    local host = u:match("^%a[%w+.-]*://([^/?#]+)") or u
    return c(th.link, t) .. " " .. c(th.muted, "(" .. host .. ")")
  end)
  s = s:gsub("%*%*(.-%S)%*%*", function(x) return c(th.bold, x) end)
  s = s:gsub("__(.-%S)__", function(x) return c(th.bold, x) end)
  s = s:gsub("~~(.-%S)~~", function(x) return c(th.muted, x) end)
  s = s:gsub("%*([^%*%s][^%*]-)%*", function(x) return c(th.italic, x) end)
  s = s:gsub("%f[%w_]_([^_]+)_%f[^%w_]", function(x) return c(th.italic, x) end)
  s = s:gsub("\1(%d+)\2", function(n) return c(th.code, codes[tonumber(n)]) end)
  return s
end

local function isRule(line) return line:match("^%s*%-%s*%-%s*%-[%s%-]*$") or line:match("^%s*%*%s*%*%s*%*[%s%*]*$") or line:match("^%s*_%s*_%s*_[%s_]*$") end

local function tableRow(line)
  if not line:match("^%s*|.*|%s*$") then return nil end
  local cells = {}
  local body = line:gsub("^%s*|", ""):gsub("|%s*$", "")
  local start = 1
  while true do   -- explicit split: Lua 5.1 gmatch would also yield empty matches between bars
    local bar = body:find("|", start, true)
    cells[#cells + 1] = body:sub(start, (bar or #body + 1) - 1):match("^%s*(.-)%s*$")
    if not bar then break end
    start = bar + 1
  end
  local sep = true
  for _, x in ipairs(cells) do if not x:match("^:?%-+:?$") then sep = false end end
  return cells, sep
end

function Markdown.render(text, theme)
  local th = Markdown.THEMES[theme] or Markdown.THEMES.dark
  local out, used, blank, inCode = {}, 0, true, false
  local function emit(line)
    if used > Markdown.MAX_OUTPUT then return end
    if line == "" then if blank then return end; blank = true else blank = false end
    used = used + #line + 1
    if used > Markdown.MAX_OUTPUT then out[#out + 1] = c(th.muted, "…"); return end
    out[#out + 1] = line
  end
  for raw in ((text or ""):gsub("\r\n?", "\n") .. "\n"):gmatch("([^\n]*)\n") do
    if raw:match("^%s*```") or raw:match("^%s*~~~") then
      inCode = not inCode
    elseif inCode then
      emit("    " .. c(th.code, ns.Text.safe(raw)))
    elseif raw:match("^%s*$") then
      emit("")
    else
      local hashes, title = raw:match("^%s*(#+)%s+(.-)%s*#*%s*$")
      local cells, sep = tableRow(raw)
      if hashes and #hashes <= 6 then
        if not blank and #out > 0 then emit("") end
        emit(c(#hashes == 1 and th.h1 or #hashes == 2 and th.h2 or th.h3, inline(title, th)))
      elseif isRule(raw) then
        emit(c(th.rule, "———————"))
      elseif cells then
        if not sep then
          local parts = {}
          for i, x in ipairs(cells) do parts[i] = inline(x, th) end
          emit(table.concat(parts, c(th.muted, "  ·  ")))
        end
      elseif raw:match("^%s*>") then
        emit(c(th.muted, "¦ ") .. inline(raw:match("^%s*>%s?(.*)$"), th))
      else
        local ind, bullet, rest = raw:match("^(%s*)([%-%*%+])%s+(.*)$")
        local nind, num, nrest = raw:match("^(%s*)(%d+)[%.%)]%s+(.*)$")
        if bullet then
          local pad = string.rep("    ", math.min(3, math.floor(#ind / 2)))
          local box, item = rest:match("^%[([ xX])%]%s+(.*)$")
          if box then
            local mark = box == " " and c(th.muted, "[ ]") or c(th.done, "[x]")
            emit(pad .. "• " .. mark .. " " .. inline(item, th))
          else
            emit(pad .. "• " .. inline(rest, th))
          end
        elseif num then
          emit(string.rep("    ", math.min(3, math.floor(#nind / 2))) .. num .. ". " .. inline(nrest, th))
        else
          emit(inline(raw:match("^%s*(.-)%s*$"), th))
        end
      end
    end
  end
  while out[#out] == "" do out[#out] = nil end
  return table.concat(out, "\n")
end
