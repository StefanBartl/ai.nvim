-- `keymaps = false` / `keymaps.enable = false` is the documented way to bind
-- nothing: setup() must not raise on the boolean form, and the insert-mode
-- completion keys (<Tab>, <C-]>, <C-\><C-a>) are keys ai.nvim binds too.
---@diagnostic disable: need-check-nil
package.path = vim.fn.getcwd() .. "/TESTS/?.lua;" .. package.path
local S = require("docs_support")

describe("ai.setup keymaps switch (REL-20)", function()
  -- Nvim itself maps <Tab> (snippet jump), so "bound" means: bound by ai.nvim.
  local function insert_map(lhs)
    local map = vim.fn.maparg(lhs, "i", false, true)
    if
      type(map) == "table"
      and map.lhs ~= nil
      and (map.desc or ""):find("completion suggestion")
    then
      return map
    end
    return nil
  end

  local function fresh_setup(opts)
    package.loaded["ai"] = nil
    package.loaded["ai.config"] = nil
    package.loaded["ai.completion"] = nil
    local ok = require("ai").setup(vim.tbl_deep_extend("force", {
      -- nothing but the keymaps under test
      usercmds = { enable = false },
      which_key = { enable = false },
      completion = { enable = true },
    }, opts))
    return ok
  end

  S.isolate_install()

  after_each(function()
    package.loaded["ai"] = nil
    package.loaded["ai.config"] = nil
    package.loaded["ai.completion"] = nil
  end)

  it("does not raise on keymaps = false", function()
    local ok, res = pcall(fresh_setup, { keymaps = false })
    assert.is_true(ok, tostring(res))
    assert.is_true(res)
  end)

  it("stores keymaps = false as a disabled switch", function()
    fresh_setup({ keymaps = false })
    assert.is_false(require("ai.config").get().keymaps.enable)
  end)

  it("binds no completion insert key with keymaps = false", function()
    fresh_setup({ keymaps = false })
    assert.is_nil(insert_map("<Tab>"))
    assert.is_nil(insert_map("<C-]>"))
    assert.is_nil(insert_map("<C-\\><C-a>"))
  end)

  it("binds no completion insert key with keymaps.enable = false", function()
    fresh_setup({ keymaps = { enable = false } })
    assert.is_nil(insert_map("<Tab>"))
    assert.is_nil(insert_map("<C-]>"))
    assert.is_nil(insert_map("<C-\\><C-a>"))
  end)

  it("still binds the completion keys by default", function()
    fresh_setup({})
    assert.is_truthy(insert_map("<Tab>"))
    assert.is_truthy(insert_map("<C-]>"))
  end)
end)
