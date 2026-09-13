---@module 'ai.context.diagnostics'
--- Formats `vim.diagnostic.get()` for a buffer into a compact,
--- file:line:severity:message block a prompt can read reliably --
--- structured rather than raw text, since a model parses that shape more
--- reliably than prose (an open question the project's concept left
--- undecided; this is the answer chosen for v1). Too AI-specific to belong
--- in `lib.nvim.harvest` (a generic collection library), which is why it
--- lives here instead of being a `harvest.scope` token.

local M = {}

local SEVERITY_NAMES = {
  [vim.diagnostic.severity.ERROR] = "ERROR",
  [vim.diagnostic.severity.WARN] = "WARN",
  [vim.diagnostic.severity.INFO] = "INFO",
  [vim.diagnostic.severity.HINT] = "HINT",
}

---@param bufnr integer
---@return string[] lines empty when the buffer has no diagnostics
function M.collect(bufnr)
  local diags = vim.diagnostic.get(bufnr)
  if #diags == 0 then
    return {}
  end
  table.sort(diags, function(a, b)
    return a.lnum < b.lnum
  end)

  local name = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or ""
  local short = name ~= "" and vim.fn.fnamemodify(name, ":.") or "[No Name]"

  local lines = {}
  for _, d in ipairs(diags) do
    local severity = SEVERITY_NAMES[d.severity] or "UNKNOWN"
    lines[#lines + 1] = string.format("%s:%d: [%s] %s", short, d.lnum + 1, severity, d.message)
  end
  return lines
end

return M
