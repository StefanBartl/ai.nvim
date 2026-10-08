-- The state fixture of the documentation specs (TESTS/docs_support.lua) promises to
-- put the editor back as it was. A key it restores must come back with the options
-- it had: Nvim's own insert <Tab> is an expr map with `replace_keycodes`, and when
-- that option is lost the key inserts the text "<Tab>" instead of a tab -- a broken
-- default for every later case in the same file.
---@diagnostic disable: need-check-nil
package.path = vim.fn.getcwd() .. "/TESTS/?.lua;" .. package.path
local S = require("docs_support")

describe("docs_support.restore_maps", function()
  -- Probe keys that no editor default or plugin owns.
  local EXPR_LHS = "<Plug>(ai-docs-support-expr)"
  local PLAIN_LHS = "<Plug>(ai-docs-support-plain)"

  local function map_of(lhs)
    local map = vim.fn.maparg(lhs, "i", false, true)
    if type(map) == "table" and map.lhs ~= nil then
      return map
    end
    return nil
  end

  after_each(function()
    pcall(vim.keymap.del, "i", EXPR_LHS)
    pcall(vim.keymap.del, "i", PLAIN_LHS)
  end)

  it("brings back an expr map with its keycode replacement, like Nvim's own <Tab>", function()
    vim.keymap.set("i", EXPR_LHS, function()
      return "<Tab>"
    end, { expr = true, replace_keycodes = true, desc = "probe expr" })
    local before = S.snapshot_maps()
    -- a case replaces it with a map of its own
    vim.keymap.set("i", EXPR_LHS, "x", { desc = "replacement" })

    S.restore_maps(before)

    local map = map_of(EXPR_LHS)
    assert.is_truthy(map)
    assert.are.equal("probe expr", map.desc)
    assert.are.equal(1, map.expr)
    assert.are.equal(1, map.replace_keycodes)
  end)

  it("brings back a plain map without keycode replacement", function()
    vim.keymap.set("i", PLAIN_LHS, "x", { desc = "probe plain", silent = true })
    local before = S.snapshot_maps()
    vim.keymap.del("i", PLAIN_LHS)

    S.restore_maps(before)

    local map = map_of(PLAIN_LHS)
    assert.is_truthy(map)
    assert.are.equal("probe plain", map.desc)
    assert.are.equal(0, map.expr)
    assert.are.equal(0, map.replace_keycodes)
    assert.are.equal(1, map.silent)
  end)

  it("removes a key that was added after the snapshot", function()
    local before = S.snapshot_maps()
    vim.keymap.set("i", PLAIN_LHS, "x", { desc = "added by a case" })

    S.restore_maps(before)

    assert.is_nil(map_of(PLAIN_LHS))
  end)
end)
