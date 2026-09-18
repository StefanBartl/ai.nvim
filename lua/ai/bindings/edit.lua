---@module 'ai.bindings.edit'
--- Buffer-editing helpers for the rewrite/append/prepend actions: resolving
--- which lines a request targets, fencing them as a code block for the
--- prompt, and parsing a model's response back into replacement lines.
--- Pure functions -- no `ai.ask`/notify/progress wiring here, that is
--- `ai.bindings.actions`'s job -- so this is the part of the feature
--- straightforward to unit test, same split as `ai.completion.prompt` vs
--- `ai.completion.init`.

local M = {}

---Resolve which lines an edit action targets. An explicit `range` (from a
---`:Ai` command's `-range`, or the Visual selection just left) wins; with no
---range, the target is the line under the cursor. Swaps a backwards range
---(`line2 < line1`) rather than passing it through -- belt-and-suspenders,
---not a fix for `:10,5Ai rewrite` specifically: Neovim's own command
---dispatch already rejects/reorders a backwards `-range` before a route ever
---runs, and Visual marks (`'<`/`'>`) are always buffer-ordered regardless of
---drag direction, so neither of this module's two real callers can hand a
---reversed pair in practice. `range` is still a public part of this
---function's own contract (anything can call `rewrite_prompt(prompt, {line1
---= 10, line2 = 5})` directly, bypassing both), and the swap costs nothing.
---@param range? {line1: integer, line2: integer}
---@param winid? integer Defaults to the current window
---@return integer line1
---@return integer line2
function M.resolve_range(range, winid)
  if range and range.line1 and range.line1 > 0 then
    local line1, line2 = range.line1, range.line2
    if line2 < line1 then
      line1, line2 = line2, line1
    end
    return line1, line2
  end
  local cursor_line = vim.api.nvim_win_get_cursor(winid or 0)[1]
  return cursor_line, cursor_line
end

---Whether `bufnr` is no longer safe to write an edit into: deleted/wiped
---outright, or changed since `tick` (a `nvim_buf_get_changedtick()` snapshot
---taken when the request was sent). Both matter because `ai.ask` is async --
---the whole round-trip is a window in which the target buffer can be closed,
---or its lines can shift out from under a `line1`/`line2` captured before
---the request went out, which would otherwise make `apply` overwrite the
---wrong lines silently rather than erroring.
---@param bufnr integer
---@param tick integer
---@return boolean
function M.buffer_changed(bufnr, tick)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return true
  end
  return vim.api.nvim_buf_get_changedtick(bufnr) ~= tick
end

---Fence `bufnr`'s `line1..line2` (1-indexed, inclusive) as a labelled code
---block for a prompt.
---@param bufnr integer
---@param line1 integer
---@param line2 integer
---@return string
function M.code_block(bufnr, line1, line2)
  local lines = vim.api.nvim_buf_get_lines(bufnr, line1 - 1, line2, false)
  local ft = vim.bo[bufnr].filetype
  return "```" .. ft .. "\n" .. table.concat(lines, "\n") .. "\n```"
end

---Truncation-indicating `stop_reason`/`finish_reason` values across the five
---built-in providers -- never normalized to one shared vocabulary elsewhere
---in this codebase, so this is a best-effort superset: Anthropic/loomAI use
---`"max_tokens"`, Gemini's (upper-cased) `finish_reason` is `"MAX_TOKENS"`,
---OpenAI/Ollama use `"length"`. Case-folded before lookup.
---@internal
local TRUNCATED_STOP_REASONS = { max_tokens = true, length = true }

---Whether a response's `stop_reason` indicates the model was cut off before
---finishing, rather than stopping on its own -- e.g. a provider's
---`max_tokens` cap hit mid-rewrite. A non-string (including `nil`, the
---common case: not every provider sets one) is never truncated.
---@param stop_reason string|nil
---@return boolean
function M.is_truncated(stop_reason)
  if type(stop_reason) ~= "string" then
    return false
  end
  return TRUNCATED_STOP_REASONS[stop_reason:lower()] == true
end

---Parse a model's response into replacement/insertion lines: normalizes
---CRLF/CR to LF, trims surrounding whitespace, and extracts the first
---fenced code block if the response has one -- models routinely wrap
---anything code-shaped in a fence regardless of being told not to (same
---defensive intent as `ai.completion.prompt.parse`, but not anchored to the
---whole string the way that one is): searching for the first fence rather
---than requiring the *entire* trimmed response to be exactly one fence means
---a leading sentence of commentary or a second, unwanted fenced block after
---the first doesn't defeat the strip. The one deliberate trade-off is
---content that legitimately contains a literal "```" outside of a fence
---(e.g. rewriting a markdown file) -- rare enough, and consistent with the
---same limitation `ai.completion.prompt.parse` already accepts.
---@param text string|nil
---@return string[] lines empty when `text` is nil/blank
function M.parse_lines(text)
  if type(text) ~= "string" then
    return {}
  end
  -- `vim.trim`, not the classic `text:match("^%s*(.-)%s*$")` trim idiom:
  -- that pattern is quadratic in the length of any whitespace run inside
  -- the string (the lazy `(.-)` re-probes the greedy `%s*$` suffix at every
  -- offset within the run, and a naive `gsub("%s+$", "")` has the same
  -- problem since it isn't `^`-anchored and gets retried at every position)
  -- -- `res.text` here is a full, unstreamed provider response with no
  -- upper size bound from most of this codebase's providers. `vim.trim`'s
  -- own source comments on exactly this and does it in two linear passes.
  local normalized = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  local trimmed = vim.trim(normalized)
  if trimmed == "" then
    return {}
  end
  local fenced = trimmed:match("```[%w_+-]*\n(.-)\n?```")
  local body = fenced or trimmed
  return vim.split(body, "\n", { plain = true })
end

return M
