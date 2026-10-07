-- `:Ai provider` as the command line sees it: what the composer lets through
-- and offers. The action behind it is covered in policy_spec.lua (confirmation,
-- grants) with a stubbed ui.kit; here the actions module is a recorder, so the
-- spec needs neither ui.nvim nor a provider.
---@diagnostic disable: missing-fields, need-check-nil

describe("ai.bindings.usrcmds", function()
  local saved_actions, switched

  before_each(function()
    saved_actions = package.loaded["ai.bindings.actions"]
    switched = nil
    package.loaded["ai.bindings.actions"] = {
      set_provider = function(name)
        switched = name
      end,
    }
    package.loaded["ai.bindings.usrcmds"] = nil
    for _, name in ipairs({ "ai.config", "ai.providers", "ai.keys" }) do
      package.loaded[name] = nil
    end
    require("ai.config").setup({})
    require("ai.providers").load_builtin()
    require("ai.bindings.usrcmds").setup()
  end)

  after_each(function()
    pcall(vim.api.nvim_del_user_command, "Ai")
    package.loaded["ai.bindings.actions"] = saved_actions
    package.loaded["ai.bindings.usrcmds"] = nil
  end)

  it("`:Ai provider auto` reaches the action: auto is a valid choice, not an unknown id", function()
    vim.cmd("Ai provider auto")
    assert.are.equal("auto", switched)
  end)

  it("`:Ai provider <id>` still reaches the action with the id", function()
    vim.cmd("Ai provider gemini")
    assert.are.equal("gemini", switched)
  end)

  it("completes auto next to the provider ids, for `provider` only", function()
    local choices = vim.fn.getcompletion("Ai provider ", "cmdline")
    assert.is_true(vim.tbl_contains(choices, "auto"))
    assert.is_true(vim.tbl_contains(choices, "claude-cli"))
    -- `:Ai key <profile> <provider>` names a real provider; auto has no key profile
    local key_targets = vim.fn.getcompletion("Ai key reset ", "cmdline")
    assert.is_true(vim.tbl_contains(key_targets, "claude"))
    assert.is_false(vim.tbl_contains(key_targets, "auto"))
  end)
end)
