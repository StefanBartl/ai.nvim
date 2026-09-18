-- ai.completion.context.extract() only touches vim.api (current window's
-- cursor, buffer lines) and lib.nvim.harvest.scope -- both real in a headless
-- run, no ui.kit/network seam involved, so this needs no stubbing at all.
describe("ai.completion.context", function()
  local bufnr

  before_each(function()
    package.loaded["ai.completion.context"] = nil
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  ---@param row integer 1-indexed
  ---@param col integer 0-indexed
  local function set_cursor(row, col)
    vim.api.nvim_win_set_cursor(0, { row, col })
  end

  it("splits the cursor line at the byte column into prefix/suffix", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
    set_cursor(1, 5) -- right after "hello"
    local prefix, suffix = require("ai.completion.context").extract()
    assert.are.equal("hello", prefix)
    assert.are.equal(" world", suffix)
  end)

  it("includes every line before the cursor line in the prefix, in order", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "line1", "line2", "line3" })
    set_cursor(3, 2) -- inside "line3", after "li"
    local prefix, suffix = require("ai.completion.context").extract()
    assert.are.equal("line1\nline2\nli", prefix)
    assert.are.equal("ne3", suffix)
  end)

  it("includes every line after the cursor line in the suffix, in order", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "line1", "line2", "line3" })
    set_cursor(1, 0)
    local prefix, suffix = require("ai.completion.context").extract()
    assert.are.equal("", prefix)
    assert.are.equal("line1\nline2\nline3", suffix)
  end)

  it("bounds the surrounding context to opts.max_lines on each side", function()
    local lines = {}
    for i = 1, 10 do
      lines[i] = "l" .. i
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    set_cursor(5, 0) -- "l5", two lines of before-context, two of after when max_lines=2
    local prefix, suffix = require("ai.completion.context").extract({ max_lines = 2 })
    assert.are.equal("l3\nl4\n", prefix)
    assert.are.equal("l5\nl6\nl7", suffix)
  end)

  it("at the first line, the prefix is just the cursor line's own before-text", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "abc", "def" })
    set_cursor(1, 1)
    local prefix = require("ai.completion.context").extract()
    assert.are.equal("a", prefix)
  end)

  it("at the last line, the suffix is just the cursor line's own after-text", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "abc", "def" })
    set_cursor(2, 1)
    local _, suffix = require("ai.completion.context").extract()
    assert.are.equal("ef", suffix)
  end)

  it("an empty buffer yields empty prefix and suffix", function()
    set_cursor(1, 0)
    local prefix, suffix = require("ai.completion.context").extract()
    assert.are.equal("", prefix)
    assert.are.equal("", suffix)
  end)

  it(
    "opts.bufnr picks which buffer's text is read, but the cursor position "
      .. "still comes from the current window",
    function()
      -- extract()'s own comment: `cursor = vim.api.nvim_win_get_cursor(0)` is
      -- unconditional -- `opts.bufnr` only changes which buffer's lines that
      -- row/col is read against, not where row/col themselves come from.
      -- Not exercised by any real caller today (`ai.completion.trigger()`
      -- never passes `opts.bufnr`), but the contract is worth pinning since a
      -- future caller reading it from `M.extract`'s own doc comment would
      -- reasonably expect the cursor to follow the given buffer instead.
      local other = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(other, 0, -1, false, { "ZZZZZZZZZZ" })

      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "0123456789" })
      set_cursor(1, 3) -- current window's cursor: row 1, col 3

      local prefix, suffix = require("ai.completion.context").extract({ bufnr = other })
      assert.are.equal("ZZZ", prefix)
      assert.are.equal("ZZZZZZZ", suffix)

      vim.api.nvim_buf_delete(other, { force = true })
    end
  )
end)
