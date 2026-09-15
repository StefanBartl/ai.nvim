describe("ai.config", function()
  before_each(function()
    package.loaded["ai.config"] = nil
  end)

  it("get() returns the defaults when setup() was never called", function()
    local config = require("ai.config")
    local cfg = config.get()
    assert.are.equal("auto", cfg.provider)
    assert.are.equal(60000, cfg.timeout_ms)
    assert.are.same({ "claude", "ollama", "openai", "gemini", "loomai" }, cfg.provider_order)
  end)

  it("setup() deep-merges user opts over the defaults", function()
    local config = require("ai.config")
    local cfg = config.setup({ provider = "ollama", ui = { panel_theme = "double" } })
    assert.are.equal("ollama", cfg.provider)
    assert.are.equal("double", cfg.ui.panel_theme)
    -- Untouched nested defaults survive the merge.
    assert.is_true(cfg.ui.enable)
    assert.are.equal(60000, cfg.timeout_ms)
  end)

  it("setup() never mutates the shared DEFAULTS table", function()
    local config = require("ai.config")
    config.setup({ provider_order = { "ollama" } })
    package.loaded["ai.config"] = nil
    local fresh = require("ai.config").get()
    assert.are.same({ "claude", "ollama", "openai", "gemini", "loomai" }, fresh.provider_order)
  end)

  it("set_provider() switches the active provider on the live config", function()
    local config = require("ai.config")
    config.setup({ provider = "auto" })
    config.set_provider("ollama")
    assert.are.equal("ollama", config.get().provider)
  end)

  describe("unknown key warnings", function()
    local original_notify
    local messages

    before_each(function()
      original_notify = vim.notify
      messages = {}
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.notify = function(msg, _level, _opts)
        messages[#messages + 1] = msg
      end
    end)

    after_each(function()
      vim.notify = original_notify
    end)

    it("warns about a typo'd nested key instead of silently dropping it", function()
      local config = require("ai.config")
      config.setup({ ui = { panel_them = "double" } })
      assert.are.equal(1, #messages)
      assert.is_true(messages[1]:find("ui.panel_them", 1, true) ~= nil)
    end)

    it("warns about an unknown top-level key", function()
      local config = require("ai.config")
      config.setup({ providr = "ollama" })
      assert.are.equal(1, #messages)
      assert.is_true(messages[1]:find("providr", 1, true) ~= nil)
    end)

    it("does not warn about a known key at any depth", function()
      local config = require("ai.config")
      config.setup({
        provider = "ollama",
        ui = { panel_theme = "double" },
        completion = { keymap = { accept = "<Tab>" } },
      })
      assert.are.equal(0, #messages)
    end)

    it("does not warn about an arbitrary provider id under model", function()
      local config = require("ai.config")
      config.setup({ model = { ["my-custom-provider"] = "some-model" } })
      assert.are.equal(0, #messages)
    end)

    it("does not warn about a custom provider_order entry", function()
      local config = require("ai.config")
      config.setup({ provider_order = { "my-custom-provider" } })
      assert.are.equal(0, #messages)
    end)
  end)
end)
