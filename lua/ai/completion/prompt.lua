---@module 'ai.completion.prompt'
--- Builds the completion request's prompt/system strings from cursor
--- prefix/suffix text, and parses a model's raw response back into the bare
--- suggestion text. Pure functions -- no buffer/window access here, that is
--- `ai.completion.context`'s job -- so this is the one part of the
--- completion feature straightforward to unit test headlessly.
---
--- Not a true fill-in-middle (FIM) API call: Claude/OpenAI/Gemini's chat
--- endpoints don't expose one uniformly, so this frames the same task as a
--- chat prompt instead and relies on the model actually following the "no
--- explanation, no markdown" instruction. Quality/latency will vary by
--- provider/model -- needs a live-testing pass before relying on it, same
--- spirit as `providers/gemini.lua`'s own documented "not live-verified" gap.

local M = {}

---@param prefix string Buffer text before the cursor
---@param suffix string Buffer text after the cursor
---@param filetype string Current buffer's filetype, e.g. `"lua"` -- a
---best-effort hint passed straight through, not validated against a known list
---@return string prompt, string system
function M.build(prefix, suffix, filetype)
  local system = "You are a code-completion engine embedded in a text "
    .. "editor. Given the code immediately before and after the cursor, "
    .. "output ONLY the text that should be inserted at the cursor to "
    .. "continue it naturally. Do not repeat the given code. Do not "
    .. "explain. Do not use markdown code fences. Your output starts exactly "
    .. "at the cursor: include any space or line break that belongs between "
    .. "the code before the cursor and your continuation. If nothing "
    .. "sensible can be inserted, output nothing."

  local lang = (filetype ~= nil and filetype ~= "") and filetype or "text"
  local prompt = string.format(
    "Filetype: %s\n\n<code-before-cursor>\n%s\n</code-before-cursor>\n"
      .. "<code-after-cursor>\n%s\n</code-after-cursor>",
    lang,
    prefix,
    suffix
  )
  return prompt, system
end

---Strip a markdown code fence a model adds despite the system prompt telling
---it not to -- instruct models routinely wrap anything that looks like code in
---a fence regardless of instructions. Leading whitespace is KEPT: the prefix
---ends exactly at the cursor, so a leading space, line break or indentation is
---part of what gets inserted (`local x =` + `" 5"` must not become `=5`). Only
---one trailing line break is dropped; an all-blank answer is no suggestion.
---@param text string|nil Defensively typed: a provider's response field is
---not guaranteed non-nil by every caller
---@return string
function M.parse(text)
  if type(text) ~= "string" then
    return ""
  end
  -- CRLF / CR answers: the buffer gets "\n"-split lines, a "\r" would end up as ^M (and hide a fence)
  text = text:gsub("\r\n?", "\n")
  -- Linear trim: the response is unbounded, and `^%s*(.-)%s*$` is quadratic on
  -- a long run of blanks inside it. Used to detect a blank answer and a fence.
  local trimmed = require("ai.providers.util").trim(text)
  if trimmed == "" then
    return ""
  end
  local fenced = trimmed:match("^```[%w_+-]*\n(.-)\n?```$")
  if fenced then
    return fenced
  end
  return (text:gsub("\n$", "", 1))
end

---Fit a parsed suggestion to the text before the cursor: when the prefix already ends in a space or tab
---(`local x = |`, or an autoindented empty line), the blanks the model starts its answer with would be a
---second copy of them, so they are dropped. A leading line break is never touched.
---@param text string  # `M.parse`'s result
---@param prefix string  # the buffer text before the cursor, as sent
---@return string
function M.fit(text, prefix)
  if type(prefix) == "string" and prefix:match("[ \t]$") then
    return (text:gsub("^[ \t]+", "", 1))
  end
  return text
end

return M
