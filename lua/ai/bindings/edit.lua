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
---range, the target is the line under the cursor.
---@param range? {line1: integer, line2: integer}
---@param winid? integer Defaults to the current window
---@return integer line1
---@return integer line2
function M.resolve_range(range, winid)
  if range and range.line1 and range.line1 > 0 then
    return range.line1, range.line2
  end
  local cursor_line = vim.api.nvim_win_get_cursor(winid or 0)[1]
  return cursor_line, cursor_line
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

---Parse a model's response into replacement/insertion lines: trims
---whitespace and strips a single markdown code fence a model added despite
---being told not to -- models routinely wrap anything code-shaped in one
---regardless of instructions (same defensive parse as
---`ai.completion.prompt.parse`).
---@param text string|nil
---@return string[] lines empty when `text` is nil/blank
function M.parse_lines(text)
  if type(text) ~= "string" then
    return {}
  end
  local trimmed = text:match("^%s*(.-)%s*$")
  if trimmed == "" then
    return {}
  end
  local fenced = trimmed:match("^```[%w_+-]*\n(.-)\n?```$")
  local body = fenced or trimmed
  return vim.split(body, "\n", { plain = true })
end

return M
