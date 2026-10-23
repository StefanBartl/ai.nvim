-- `:Ai info` names the provider `auto` resolves to, so the reader does not have to find it in a console.
---@diagnostic disable: missing-fields, need-check-nil

describe(":Ai info with provider = auto", function()
  local popup_lines, saved_kit, available

  local function reset()
    for _, name in ipairs({ "ai", "ai.config", "ai.providers", "ai.policy", "ai.bindings.actions" }) do
      package.loaded[name] = nil
    end
  end

  before_each(function()
    reset()
    saved_kit = package.loaded["ui.kit"]
    package.loaded["ui.kit"] = {
      popup = function(opts)
        popup_lines = opts.lines
      end,
    }
    available = { alpha = false, beta = true }
    local reg = require("ai.providers")
    for _, id in ipairs({ "alpha", "beta" }) do
      reg.register({
        id = id,
        available = function()
          return available[id]
        end,
        ask = function() end,
        stream = function()
          return nil
        end,
      })
    end
  end)

  after_each(function()
    package.loaded["ui.kit"] = saved_kit
    popup_lines = nil
    reset()
  end)

  ---@return string
  local function provider_line()
    require("ai.bindings.actions").info()
    return popup_lines[1]
  end

  it("names the first available provider of provider_order", function()
    require("ai.config").setup({ provider = "auto", provider_order = { "alpha", "beta" } })
    assert.are.equal("provider: auto (-> beta)", provider_line())
  end)

  it("says so when none is available", function()
    available.beta = false
    require("ai.config").setup({ provider = "auto", provider_order = { "alpha", "beta" } })
    assert.are.equal("provider: auto (-> none available)", provider_line())
  end)

  it("leaves an explicit provider as it is", function()
    require("ai.config").setup({ provider = "alpha", provider_order = { "alpha", "beta" } })
    assert.are.equal("provider: alpha", provider_line())
  end)
end)
