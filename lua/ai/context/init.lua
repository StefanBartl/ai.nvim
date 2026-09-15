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
--- Flattened JSON/YAML/XML block under the cursor, via `data.nvim`
--- (optional soft dep, same `pcall(require, ...)` treatment as every other
--- integration in this file). Reuses `data.detect`/`data.scope.resolve`
--- exactly as `:Data` itself does -- `cmd.range = 0` means "no explicit
--- range", so both fall through to data.nvim's own fenced-block-under-
--- cursor guess, then whole-buffer. Silent no-op (no section appended) when
--- data.nvim is absent, the cursor isn't in a recognizable block, or the
--- block fails to decode (e.g. mid-edit) -- context assembly never errors
--- the caller's request over a best-effort section.
---@param sections string[]
local function add_structured_data_scope(sections)
  local ok_detect, detect = pcall(require, "data.detect")
  local ok_scope, scope_resolve = pcall(require, "data.scope.resolve")
  local ok_format, formats = pcall(require, "data.format")
  if not (ok_detect and ok_scope and ok_format) then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local cmd = { range = 0, line1 = 0, line2 = 0 }
  local fmt = detect.format(bufnr, cmd)
  if not fmt then
    return
  end

  local formatter = formats.get(fmt)
  if not formatter then
    return
  end

  local s0, e0 = scope_resolve.lines(bufnr, cmd, fmt)
  local src = vim.api.nvim_buf_get_lines(bufnr, s0, e0 + 1, false)
  if #src == 0 then
    return
  end

  -- `formatter.decode` returns `nil, err` (not a thrown error) for invalid
  -- input -- same `Data.Formatter` contract `data/init.lua`'s own
  -- `safe_call` guards against, so both layers need checking: the `pcall`
  -- for a genuine runtime error, and `value == nil` for a clean decode
  -- failure. A legitimate top-level JSON `null` decodes to `lib.lua.null`'s
  -- sentinel table, never bare Lua `nil`, so this can't misfire on that.
  local ok_decode, value = pcall(formatter.decode, table.concat(src, "\n"))
  if not ok_decode or value == nil then
    return
  end

  local ok_render, rendered = pcall(formatter.render, value, "lines", {})
  if not ok_render or not rendered or #rendered == 0 then
    return
  end

  sections[#sections + 1] = ("Structured data (%s) under cursor:\n```\n%s\n```"):format(
    fmt,
    table.concat(rendered, "\n")
  )
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

  if opts.structured_data then
    add_structured_data_scope(sections)
  end

  return table.concat(sections, "\n\n")
end

return M
