---@module 'ai.completion.context'
--- Cursor-relative context extraction for inline completion: the text
--- immediately before and after the cursor, bounded by a line window.
--- `ai.context`'s own `assemble()` only knows whole-buffer/selection/
--- diagnostics/cwd -- nothing cursor-relative -- so this is a separate,
--- smaller module rather than a bolt-on to that one. Reuses
--- `lib.nvim.harvest.scope`'s existing `"range"` kind (already used by
--- `ai.context`'s own `add_scope()`) for the surrounding lines; no new
--- harvest-scope kind was needed.

local M = {}

---@internal
---@param scope table `lib.nvim.harvest.scope`
---@param bufnr integer
---@param line1 integer
---@param line2 integer
---@return string[] lines empty on any error or an out-of-range/empty result
local function resolve_lines(scope, bufnr, line1, line2)
  local ok, sources = pcall(scope.resolve, "range", { bufnr = bufnr, line1 = line1, line2 = line2 })
  if ok and sources and sources[1] then
    return sources[1].lines
  end
  return {}
end

---Extract the text immediately before and after the cursor in the current
---window's buffer, each bounded to `opts.max_lines` lines of surrounding
---context.
---@param opts? { max_lines?: integer, bufnr?: integer }
---@return string prefix, string suffix
function M.extract(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local max_lines = opts.max_lines or 60
  local scope = require("lib.nvim.harvest.scope")

  -- 1-indexed row, 0-indexed column -- matches nvim_win_get_cursor's own
  -- convention, not extmark's 0-indexed row.
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1], cursor[2]
  local current_line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""

  local before_on_cursor_line = current_line:sub(1, col)
  local after_on_cursor_line = current_line:sub(col + 1)

  local before_lines = resolve_lines(scope, bufnr, row - max_lines, row - 1)
  local after_lines = resolve_lines(scope, bufnr, row + 1, row + max_lines)

  local prefix_parts = {}
  for _, line in ipairs(before_lines) do
    prefix_parts[#prefix_parts + 1] = line
  end
  prefix_parts[#prefix_parts + 1] = before_on_cursor_line

  local suffix_parts = { after_on_cursor_line }
  for _, line in ipairs(after_lines) do
    suffix_parts[#suffix_parts + 1] = line
  end

  return table.concat(prefix_parts, "\n"), table.concat(suffix_parts, "\n")
end

return M
