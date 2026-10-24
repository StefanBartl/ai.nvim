-- The provider for the native app was called `loomai` before it became `ai_desktop`: an old configuration, an old
-- allow-list and an old request keep working, and the code behind sees the current id.
describe("ai.providers.aliases", function()
  local aliases

  before_each(function()
    package.loaded["ai.providers.aliases"] = nil
    package.loaded["ai.providers"] = nil
    package.loaded["ai.config"] = nil
    aliases = require("ai.providers.aliases")
  end)

  it("canonical() maps the old id and leaves everything else alone", function()
    assert.are.equal("ai_desktop", aliases.canonical("loomai"))
    assert.are.equal("ai_desktop", aliases.canonical("ai_desktop"))
    assert.are.equal("claude", aliases.canonical("claude"))
    assert.is_nil(aliases.canonical(nil))
    assert.are.equal(5, aliases.canonical(5))
  end)

  it("canonical_list() replaces the alias in place and drops the duplicate where both are listed", function()
    local list = { "claude", "loomai", "ollama", "ai_desktop" }
    aliases.canonical_list(list)
    assert.are.same({ "claude", "ai_desktop", "ollama" }, list)
  end)

  it("canonical_keys() moves the alias key, and the current key wins when both are there", function()
    local one = { loomai = "llama3" }
    aliases.canonical_keys(one)
    assert.are.same({ ai_desktop = "llama3" }, one)
    local both = { loomai = "old", ai_desktop = "new" }
    aliases.canonical_keys(both)
    assert.are.same({ ai_desktop = "new" }, both)
  end)

  it("setup() takes the old id in the provider, the order, the models, the allow-list and an agent", function()
    local cfg = require("ai.config").setup({
      provider = "loomai",
      provider_order = { "ollama", "loomai" },
      model = { loomai = "claude-haiku-5-5" },
      policy = { allowed = { "loomai", "claude" } },
      agents = { fast = { provider = "loomai", model = "x" } },
    })
    assert.are.equal("ai_desktop", cfg.provider)
    assert.are.same({ "ollama", "ai_desktop" }, cfg.provider_order)
    assert.are.equal("claude-haiku-5-5", cfg.model.ai_desktop)
    assert.is_nil(cfg.model.loomai)
    assert.are.same({ "ai_desktop", "claude" }, cfg.policy.allowed)
    assert.are.equal("ai_desktop", cfg.agents.fast.provider)
  end)

  it("resolve() and get() take the old id for the provider with the current one", function()
    local providers = require("ai.providers")
    providers.register({
      id = "ai_desktop",
      available = function()
        return true
      end,
    })
    local p, err = providers.resolve("loomai", {})
    assert.is_nil(err)
    assert.are.equal("ai_desktop", p.id)
    assert.are.equal("ai_desktop", providers.get("loomai").id)
  end)
end)
