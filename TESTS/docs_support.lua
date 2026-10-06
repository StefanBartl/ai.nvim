-- Shared helpers of the documentation specs (docs_examples_spec.lua,
-- vimdoc_spec.lua): reading docs/*.md and doc/ai.txt, pulling fenced blocks and
-- tables out of them, running a documented snippet, and listing what is really
-- mapped. Everything works on the repo root (the specs run from there).
--
-- Not a spec: only `*_spec.lua` files are run. Each documentation spec puts
-- `TESTS/?.lua` on package.path itself, which is how this module is found.
local M = {}

M.ROOT = vim.fn.getcwd()
M.DOCS = M.ROOT .. "/docs/"

---@param path string
---@return string[]
function M.read_lines(path)
  local lines = {}
  for line in io.lines(path) do
    -- A CRLF checkout must not leave a carriage return on every line on a non-Windows read.
    lines[#lines + 1] = (line:gsub("\r$", ""))
  end
  return lines
end

---@param path string
---@return string
function M.read(path)
  return table.concat(M.read_lines(path), "\n")
end

---Every fenced block of `file` (relative to docs/), as `{ lang, code }`.
---@param file string
---@return { lang: string, code: string }[]
function M.fenced_blocks(file)
  local blocks, cur = {}, nil
  for _, line in ipairs(M.read_lines(M.DOCS .. file)) do
    local fence = line:match("^```(%S*)%s*$")
    if fence ~= nil then
      if cur then
        cur.code = table.concat(cur.lines, "\n")
        blocks[#blocks + 1] = cur
        cur = nil
      else
        cur = { lang = fence, lines = {} }
      end
    elseif cur then
      cur.lines[#cur.lines + 1] = line
    end
  end
  return blocks
end

---The single block of `file` whose code contains `needle` (plain match). A
---block is located by a stable substring of its own text, never by index:
---reordering the docs must not break the lookup, only removing the example does.
---@param file string
---@param needle string
---@return string
function M.block_with(file, needle)
  local hits = {}
  for _, b in ipairs(M.fenced_blocks(file)) do
    if b.code:find(needle, 1, true) then
      hits[#hits + 1] = b.code
    end
  end
  assert(
    #hits == 1,
    ("%s: expected exactly 1 block containing %q, found %d"):format(file, needle, #hits)
  )
  return hits[1]
end

---Data rows (header and separator dropped) of every GFM table in `file` whose
---header starts with the cells `header`, each row as its trimmed cell strings.
---@param file string
---@param header string[]
---@return string[][]
function M.table_rows(file, header)
  local rows = {}
  for _, tbl in ipairs(require("lib.nvim.markdown.table").parse(M.read_lines(M.DOCS .. file))) do
    local matches = true
    for i, cell in ipairs(header) do
      matches = matches and tbl.rows[1][i] == cell
    end
    if matches then
      for i = 2, #tbl.rows do
        rows[#rows + 1] = tbl.rows[i]
      end
    end
  end
  return rows
end

---Registry/lazy `mode` fields are `string|string[]`; normalize to a list.
---@param mode string|string[]|nil
---@return string[]
function M.mode_list(mode)
  return type(mode) == "table" and mode or { mode or "n" }
end

---Run `code` as a chunk with `overrides` shadowing globals; `require` is
---replaced so a doc's `require("ai")` can be pointed at a capturing stub
---while every other module stays real.
---@param code string
---@param name string chunk name for error messages
---@param ai_stub? table what `require("ai")` returns instead of the real one
---@param extra? table additional globals for the chunk
---@return any
function M.run_chunk(code, name, ai_stub, extra)
  local env = setmetatable({
    require = function(mod)
      if mod == "ai" and ai_stub then
        return ai_stub
      end
      return require(mod)
    end,
  }, { __index = _G })
  for k, v in pairs(extra or {}) do
    env[k] = v
  end
  -- loadstring + setfenv is the Lua 5.1 API Nvim guarantees; the 4-argument
  -- load() is a 5.2/LuaJIT extension.
  local fn, err = loadstring(code, "=" .. name)
  assert(fn, err)
  setfenv(fn, env)
  return fn()
end

---`lhs` as the raw bytes Neovim maps. nvim_get_keymap reports a literal space for
---a space leader, so both sides of a comparison go through this (`lhsraw`
---encodes Ctrl chords as modifier keys instead, which nvim_replace_termcodes
---does not).
---@param lhs string
---@return string
function M.raw(lhs)
  return vim.api.nvim_replace_termcodes(lhs, true, true, true)
end

---Every GLOBAL mapping in modes n/x/s/o/i/c/t/l (buffer-local maps are out of
---scope) as `{ mode, lhs, raw }`. A registry-independent view: a plain
---vim.keymap.set that bypassed the keymap registry shows up here. First proves,
---on a Ctrl chord, that `raw(nvim_get_keymap().lhs) == raw(lhs)`, so the
---normalization cannot rot silently on another Neovim version.
---@return { mode: string, lhs: string, raw: string }[]
function M.global_maps()
  local probe = "<F20><C-j>"
  vim.keymap.set("n", probe, "<Nop>")
  local seen = false
  for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
    seen = seen or M.raw(m.lhs) == M.raw(probe)
  end
  vim.keymap.del("n", probe)
  assert(seen, "raw(nvim_get_keymap().lhs) no longer equals raw(lhs) for a Ctrl chord")

  local maps = {}
  for _, mode in ipairs({ "n", "x", "s", "o", "i", "c", "t", "l" }) do
    for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
      maps[#maps + 1] = { mode = mode, lhs = m.lhs, raw = M.raw(m.lhs) }
    end
  end
  return maps
end

return M
