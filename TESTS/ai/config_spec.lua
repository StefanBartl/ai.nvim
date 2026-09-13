describe("ai.config", function()
  before_each(function()
    package.loaded["ai.config"] = nil
  end)

  it("get() returns the defaults when setup() was never called", function()
    local config = require("ai.config")
    local cfg = config.get()
    assert.are.equal("auto", cfg.provider)
    assert.are.equal(60000, cfg.timeout_ms)
    assert.are.same({ "claude", "ollama", "openai" }, cfg.provider_order)
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
    assert.are.same({ "claude", "ollama", "openai" }, fresh.provider_order)
  end)
end)
