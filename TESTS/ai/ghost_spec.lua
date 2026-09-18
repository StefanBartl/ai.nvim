-- ai.ui.ghost renders through plain `vim.api` extmarks (`virt_text_pos =
-- "inline"` + `virt_lines`), not a `ui.kit` surface/popup -- see
-- TESTS/minimal_init.lua's own note on why ui.nvim-touching modules aren't
-- otherwise covered here. This one needs nothing stubbed: a real scratch
-- buffer and the real extmark API are enough to exercise it headlessly.
describe("ai.ui.ghost", function()
  local bufnr

  before_each(function()
    package.loaded["ai.ui.ghost"] = nil
    bufnr = vim.api.nvim_create_buf(false, true)
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it("has nothing shown before the first show()", function()
    local ghost = require("ai.ui.ghost")
    assert.is_nil(ghost.current())
  end)

  it("show() records the suggestion as current, with the exact text given", function()
    local ghost = require("ai.ui.ghost")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local x = " })
    ghost.show(bufnr, 0, 10, "1")
    local shown = ghost.current()
    assert.are.equal(bufnr, shown.bufnr)
    assert.are.equal(0, shown.row)
    assert.are.equal(10, shown.col)
    assert.are.equal("1", shown.text)
  end)

  it("show('') is a no-op -- nothing becomes current", function()
    local ghost = require("ai.ui.ghost")
    ghost.show(bufnr, 0, 0, "")
    assert.is_nil(ghost.current())
  end)

  it("a second show() replaces the first, even in a different buffer", function()
    local ghost = require("ai.ui.ghost")
    local other = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(other, 0, -1, false, { "line one", "line two" })
    ghost.show(bufnr, 0, 0, "first")
    ghost.show(other, 1, 2, "second")
    local shown = ghost.current()
    assert.are.equal(other, shown.bufnr)
    assert.are.equal("second", shown.text)
    vim.api.nvim_buf_delete(other, { force = true })
  end)

  it("clear() drops the current suggestion", function()
    local ghost = require("ai.ui.ghost")
    ghost.show(bufnr, 0, 0, "x")
    ghost.clear()
    assert.is_nil(ghost.current())
  end)

  it("clear() is safe to call twice in a row", function()
    local ghost = require("ai.ui.ghost")
    ghost.show(bufnr, 0, 0, "x")
    ghost.clear()
    assert.has_no.errors(function()
      ghost.clear()
    end)
    assert.is_nil(ghost.current())
  end)

  it("clear() is safe when the shown suggestion's buffer was since deleted", function()
    local ghost = require("ai.ui.ghost")
    local scratch = vim.api.nvim_create_buf(false, true)
    ghost.show(scratch, 0, 0, "x")
    vim.api.nvim_buf_delete(scratch, { force = true })
    assert.has_no.errors(function()
      ghost.clear()
    end)
    assert.is_nil(ghost.current())
  end)

  it("show() with a multi-line suggestion still records the whole text on current()", function()
    local ghost = require("ai.ui.ghost")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
    ghost.show(bufnr, 0, 0, "line1\nline2\nline3")
    assert.are.equal("line1\nline2\nline3", ghost.current().text)
  end)
end)
