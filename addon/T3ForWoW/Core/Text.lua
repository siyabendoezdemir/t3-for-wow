-- Display helpers. Agent/tool text is untrusted: WoW interprets |c colour, |T texture, |H link and
-- |K escape sequences inside FontStrings, so every '|' is doubled before display. Control
-- characters other than newline/tab are dropped. Nothing is ever evaluated.
local _, ns = ...
local Text = {}
ns.Text = Text

function Text.safe(s)
  if type(s) ~= "string" then return "" end
  s = s:gsub("[%z\1-\8\11\12\14-\31\127]", "")
  return (s:gsub("|", "||"))
end

-- One display line: newlines folded, clipped by characters (UTF-8 aware), safe.
function Text.line(s, maxChars)
  s = (type(s) == "string" and s or ""):gsub("[\r\n\t]+", " ")
  if maxChars and #s > maxChars then
    local cut = maxChars
    while cut > 1 and s:byte(cut + 1) and s:byte(cut + 1) >= 128 and s:byte(cut + 1) < 192 do cut = cut - 1 end
    s = s:sub(1, cut) .. "…"
  end
  return Text.safe(s)
end

function Text.age(seconds)
  if not seconds or seconds < 0 then return "" end
  if seconds < 60 then return "now" end
  if seconds < 3600 then return math.floor(seconds / 60) .. "m" end
  if seconds < 86400 then return math.floor(seconds / 3600) .. "h" end
  return math.floor(seconds / 86400) .. "d"
end

local REQUEST = {
  waiting = "Waiting for the bridge…", sending = "Sending to T3…", accepted = "Delivered to T3",
  queued = "Queued in T3 — runs after the current turn", failed = "Not sent", rejected = "Refused by T3",
  unknown = "Unknown — check the thread in T3 before resending", unconfirmed = "Bridge has not confirmed yet",
  done = "",
}
function Text.request(state) return REQUEST[state] or "Unknown" end
