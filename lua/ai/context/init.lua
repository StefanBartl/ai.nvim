---@module 'ai.context'
--- Assembles an `Ai.ContextDefaults` descriptor into one text block a
--- prompt can be prefixed with. A thin wrapper over
--- `lib.nvim.harvest.scope` for buffer/selection/cwd -- it already returns
--- exactly the shape (`file`/`bufnr`/`lines`/`first`) a prompt builder
--- needs -- plus `ai.context.diagnostics` for the one section too
--- AI-specific to belong in a generic harvest scope.

require("ai.@types")

local diagnostics = require("ai.context.diagnostics")

local M = {}

---@internal
---@param source Lib.Harvest.Source
---@return string
local function format_source(source)
  local header = source.file or ("[buffer " .. tostring(source.bufnr) .. "]")
  local parts = { "```", "-- " .. header }
  local first = source.first or 1
  for i, line in ipairs(source.lines) do
    parts[#parts + 1] = string.format("%d: %s", first + i - 1, line)
  end
  parts[#parts + 1] = "```"
  return table.concat(parts, "\n")
end

---@internal
---Resolve a `lib.nvim.harvest.scope` kind and append every source it
---returns, formatted, to `sections`. A scope that errors or resolves to
---nothing is silently skipped -- see `M.assemble`'s own doc for why.
---@param sections string[]
---@param scope Lib.Harvest.Scope
---@param kind string
---@param args table|nil
local function add_scope(sections, scope, kind, args)
  local ok, sources = pcall(scope.resolve, kind, args)
  if not ok or not sources then
    return
  end
  for _, s in ipairs(sources) do
    sections[#sections + 1] = format_source(s)
  end
end

---Build the context block for `opts`. Every section is best-effort: a scope
---that resolves to nothing (no visual selection active, no diagnostics
---present) is silently omitted rather than padding the prompt with an empty
---section. Flags are independent, not mutually exclusive -- `buffer` and
---`selection` can both be true, matching the concept's own example
---(`context = { buffer = true, selection = true, diagnostics = true }`).
---@param opts Ai.ContextDefaults|nil
---@return string block empty string if nothing was requested or resolved
function M.assemble(opts)
  opts = opts or {}
  local scope = require("lib.nvim.harvest.scope")
  local sections = {}

  if opts.buffer then
    add_scope(sections, scope, "buffer")
  end

  if opts.selection then
    -- The last visual selection's marks -- valid right after leaving visual
    -- mode, or when the caller is itself invoked from a visual-mode mapping.
    local line1 = vim.fn.getpos("'<")[2]
    local line2 = vim.fn.getpos("'>")[2]
    if line1 > 0 and line2 >= line1 then
      add_scope(sections, scope, "range", { line1 = line1, line2 = line2 })
    end
  end

  if opts.diagnostics then
    local bufnr = vim.api.nvim_get_current_buf()
    local diag_lines = diagnostics.collect(bufnr)
    if #diag_lines > 0 then
      sections[#sections + 1] = "Diagnostics:\n" .. table.concat(diag_lines, "\n")
    end
  end

  if opts.cwd then
    add_scope(sections, scope, "cwd")
  end

  return table.concat(sections, "\n\n")
end

return M
