-- Every positional argument of `:Ai` has a line in lib.nvim's option float.
--
-- The text comes from the `desc` of each ArgSpec in ai.bindings.usrcmds (`provider {name}`,
-- `key [profile] [provider]`); `:Ai` has no flags or key=value pairs. An argument without one shows
-- up as a bare row in the cheatsheet, so this fails until it is described. The actions module is a
-- recorder, as in usrcmds_spec.lua: the spec needs neither ui.nvim nor a provider.
---@diagnostic disable: missing-fields, undefined-field

describe("ai.bindings.usrcmds option float", function()
  local saved_actions

  before_each(function()
    saved_actions = package.loaded["ai.bindings.actions"]
    package.loaded["ai.bindings.actions"] = {}
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

  it("describes every flag, key=value pair and positional argument of :Ai", function()
    local composer = require("lib.nvim.bindings.usercmd.composer")

    -- A lib.nvim older than `help.undocumented` cannot answer the question; that is a missing
    -- feature of the dependency, not a defect of this plugin.
    if type(composer.help.undocumented) ~= "function" then
      return
    end

    assert.is_not_nil(composer.registry().Ai, ":Ai is registered through the composer")

    local missing = {}
    for _, m in ipairs(composer.help.undocumented("Ai", { args = true })) do
      missing[#missing + 1] = ("%s %s %s"):format(m.kind, m.route, m.name)
    end
    assert.equals(0, #missing, ":Ai entries without a help text: " .. table.concat(missing, ", "))
  end)

  it("keeps the argument texts to one line without a trailing period, <= 80 characters", function()
    local composer = require("lib.nvim.bindings.usercmd.composer")

    local texts = {}
    for _, route in ipairs(composer.registry().Ai:spec().routes) do
      for _, arg in ipairs(route.args or {}) do
        if arg.desc then
          texts[#texts + 1] = arg.desc
        end
        for _, text in pairs(arg.enum_desc or {}) do
          texts[#texts + 1] = text
        end
      end
    end
    assert.is_true(#texts >= 5, "found the texts of provider {name} and key [profile] [provider]")

    local malformed = {}
    for _, text in ipairs(texts) do
      if text:find("\n", 1, true) or text:sub(-1) == "." or #text > 80 then
        malformed[#malformed + 1] = text
      end
    end
    assert.equals(0, #malformed, "malformed texts: " .. table.concat(malformed, " | "))
  end)

  it("only describes values the argument really offers (enum_desc keys)", function()
    local composer = require("lib.nvim.bindings.usercmd.composer")

    local stray = {}
    for _, route in ipairs(composer.registry().Ai:spec().routes) do
      for _, arg in ipairs(route.args or {}) do
        local offered = {}
        for _, value in ipairs(arg.enum or arg.values or {}) do
          offered[value] = true
        end
        for value in pairs(arg.enum_desc or {}) do
          if not offered[value] then
            stray[#stray + 1] = arg.name .. "=" .. value
          end
        end
      end
    end
    assert.equals(0, #stray, "enum_desc keys that are no value: " .. table.concat(stray, ", "))
  end)
end)
