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

    it("does not warn about the documented completion.provider/completion.model options", function()
      local config = require("ai.config")
      config.setup({ completion = { provider = "ollama", model = "llama3.2" } })
      assert.are.equal(0, #messages)
    end)

    it("warns about a typo'd key that happens to share a name with an open-shape key", function()
      -- `model`/`provider_order` are open-shape only at the top level -- a
      -- different, fixed-shape table that happens to have a key spelled the
      -- same way (not a real `ui` option) must still be caught.
      local config = require("ai.config")
      config.setup({ ui = { model = "double" } })
      assert.are.equal(1, #messages)
      assert.is_true(messages[1]:find("ui.model", 1, true) ~= nil)
    end)
  end)

  describe("invalid value degradation", function()
    it("drops a wrong-typed provider_order to the default instead of merging it", function()
      local config = require("ai.config")
      local cfg = config.setup({ provider_order = "claude" })
      assert.are.same({ "claude", "ollama", "openai", "gemini", "loomai" }, cfg.provider_order)
      assert.are.equal(1, #config.issues())
      assert.is_true(config.issues()[1]:find("provider_order", 1, true) ~= nil)
    end)

    it(
      "drops an unrecognized completion.trigger to the default instead of a silent typo",
      function()
        local config = require("ai.config")
        local cfg = config.setup({ completion = { trigger = "atuo" } })
        assert.are.equal("manual", cfg.completion.trigger)
        assert.are.equal(1, #config.issues())
        assert.is_true(config.issues()[1]:find("completion.trigger", 1, true) ~= nil)
      end
    )

    it("drops a wrong-typed timeout_ms to the default", function()
      local config = require("ai.config")
      local cfg = config.setup({ timeout_ms = "60s" })
      assert.are.equal(60000, cfg.timeout_ms)
      assert.are.equal(1, #config.issues())
    end)

    it("issues() is empty when every value is well-typed", function()
      local config = require("ai.config")
      config.setup({ provider_order = { "ollama" }, completion = { trigger = "auto" } })
      assert.are.equal(0, #config.issues())
    end)
  end)
end)
