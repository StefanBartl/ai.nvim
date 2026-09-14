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
    .. "explain. Do not use markdown code fences. If nothing sensible can "
    .. "be inserted, output nothing."

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

---Strip a markdown code fence and surrounding whitespace a model adds
---despite the system prompt telling it not to -- instruct models routinely
---wrap anything that looks like code in a fence regardless of instructions.
---@param text string|nil Defensively typed: a provider's response field is
---not guaranteed non-nil by every caller
---@return string
function M.parse(text)
  if type(text) ~= "string" then
    return ""
  end
  local trimmed = text:match("^%s*(.-)%s*$")
  local fenced = trimmed:match("^```[%w_+-]*\n(.-)\n?```$")
  if fenced then
    return fenced
  end
  return trimmed
end

return M
