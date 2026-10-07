-- `keymaps = false` / `keymaps.enable = false` is the documented way to bind
-- nothing: setup() must not raise on the boolean form, and the insert-mode
-- completion keys (<Tab>, <C-]>, <C-\><C-a>) are keys ai.nvim binds too.
---@diagnostic disable: need-check-nil
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
  local INSERT_KEYS = { "<Tab>", "<C-]>", "<C-><C-a>" }

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

  local MODES = { "n", "i", "v", "x", "s", "o" }
  local before, saved

  local function snapshot()
    local seen = {}
    for _, mode in ipairs(MODES) do
      for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
        seen[mode .. "\0" .. map.lhs] = true
      end
    end
    return seen
  end

  before_each(function()
    vim.g.loaded_ai = nil
    before = snapshot()
    saved = {}
    for _, lhs in ipairs(INSERT_KEYS) do
      local map = vim.fn.maparg(lhs, "i", false, true)
      if type(map) == "table" and map.lhs ~= nil then
        saved[#saved + 1] = map
      end
    end
  end)

  after_each(function()
    -- unbind every key a setup registered and drop its autocmds, so no
    -- case leaves a key or an AiCompletion group behind
    for _, mode in ipairs(MODES) do
      for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
        if not before[mode .. "\0" .. map.lhs] then
          pcall(vim.api.nvim_del_keymap, mode, map.lhs)
        end
      end
    end
    for _, lhs in ipairs(INSERT_KEYS) do
      pcall(vim.keymap.del, "i", lhs)
    end
    for _, map in ipairs(saved) do
      vim.fn.mapset("i", false, map)
    end
    pcall(vim.api.nvim_del_augroup_by_name, "AiCompletion")
    pcall(vim.api.nvim_del_augroup_by_name, "ai_nvim")
    vim.g.loaded_ai = nil
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
