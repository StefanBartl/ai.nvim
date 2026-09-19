-- Covers `ai.providers.models`: the per-provider known-model registry
-- backing the "Modell-Registry pro Provider" roadmap item. The module is a
-- pure data lookup (no state to reset between tests), so there is no
-- before_each/package.loaded dance here the way providers_spec.lua needs.

describe("ai.providers.models", function()
  local models = require("ai.providers.models")

  describe("is_known()", function()
    it("accepts a known model for a provider with a fixed catalogue", function()
      assert.is_true(models.is_known("claude", "claude-opus-4-5"))
      assert.is_true(models.is_known("gemini", "gemini-2.5-flash"))
      assert.is_true(models.is_known("openai", "gpt-4o"))
    end)

    it("rejects an unknown model for a provider with a fixed catalogue", function()
      assert.is_false(models.is_known("claude", "claude-nonexistent-9"))
      assert.is_false(models.is_known("openai", "totally-not-a-model"))
    end)

    it("treats ollama as open-ended -- any local model name is accepted", function()
      assert.is_true(models.is_known("ollama", "llama3.2"))
      assert.is_true(models.is_known("ollama", "whatever-the-user-pulled-locally"))
    end)

    it("treats loomai as open-ended for the same reason as ollama", function()
      assert.is_true(models.is_known("loomai", "any-local-model"))
    end)

    it("does not flag a provider it has never heard of (e.g. a custom one)", function()
      assert.is_true(models.is_known("some-custom-provider", "whatever"))
    end)
  end)

  describe("is_validated()", function()
    it("is true for providers with a fixed catalogue", function()
      assert.is_true(models.is_validated("claude"))
      assert.is_true(models.is_validated("gemini"))
      assert.is_true(models.is_validated("openai"))
    end)

    it("is false for the open-ended local providers", function()
      assert.is_false(models.is_validated("ollama"))
      assert.is_false(models.is_validated("loomai"))
    end)

    it("is false for an unregistered/custom provider id", function()
      assert.is_false(models.is_validated("some-custom-provider"))
    end)
  end)

  describe("check_config()", function()
    it("returns no issues when every configured model is known", function()
      local issues = models.check_config({
        provider = "claude",
        model = { claude = "claude-opus-4-5", openai = "gpt-4o" },
      })
      assert.are.same({}, issues)
    end)

    it("returns no issues when cfg.model is empty (provider's own default applies)", function()
      assert.are.same({}, models.check_config({ provider = "claude", model = {} }))
    end)

    it("reports an unknown per-provider default model", function()
      local issues = models.check_config({
        provider = "claude",
        model = { claude = "claude-nonexistent-9" },
      })
      assert.are.equal(1, #issues)
      assert.is_true(issues[1]:find("claude-nonexistent-9", 1, true) ~= nil)
      assert.is_true(issues[1]:find("claude", 1, true) ~= nil)
    end)

    it("never reports an ollama/loomai model, however unusual", function()
      local issues = models.check_config({
        provider = "ollama",
        model = { ollama = "my-custom-finetune", loomai = "whatever-is-loaded" },
      })
      assert.are.same({}, issues)
    end)

    it("reports an unknown completion.model against completion.provider", function()
      local issues = models.check_config({
        provider = "claude",
        model = {},
        completion = { provider = "openai", model = "not-a-real-model" },
      })
      assert.are.equal(1, #issues)
      assert.is_true(issues[1]:find("not-a-real-model", 1, true) ~= nil)
      assert.is_true(issues[1]:find("openai", 1, true) ~= nil)
    end)

    it("falls back to cfg.provider when completion.provider is unset", function()
      local issues = models.check_config({
        provider = "claude",
        model = {},
        completion = { provider = false, model = "claude-nonexistent-9" },
      })
      assert.are.equal(1, #issues)
      assert.is_true(issues[1]:find("claude", 1, true) ~= nil)
    end)

    it("ignores completion.model when it is false (unset, per DEFAULTS)", function()
      local issues = models.check_config({
        provider = "claude",
        model = {},
        completion = { provider = false, model = false },
      })
      assert.are.same({}, issues)
    end)

    it("handles a cfg with no model/completion tables at all", function()
      assert.are.same({}, models.check_config({ provider = "claude" }))
    end)
  end)
end)
