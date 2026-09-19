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

  describe("M.OPEN_ENDED", function()
    it(
      "accounts for every built-in provider -- each one is either in the "
        .. "fixed catalogue (M.KNOWN) or explicitly declared open-ended "
        .. "(M.OPEN_ENDED), never neither (the exact gap M.OPEN_ENDED's own "
        .. "module-doc comment says it exists to catch: a provider that "
        .. "should get a real catalogue but was never given one)",
      function()
        package.loaded["ai.providers"] = nil
        local providers = require("ai.providers")
        providers.load_builtin()
        for _, id in ipairs(providers.ids()) do
          assert.is_true(
            models.KNOWN[id] ~= nil or models.OPEN_ENDED[id] == true,
            (
              "provider %q has neither a M.KNOWN catalogue nor a M.OPEN_ENDED "
              .. "entry in lua/ai/providers/models.lua -- add one"
            ):format(id)
          )
        end
      end
    )
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

    describe("resolving a literal 'auto' provider", function()
      before_each(function()
        -- Fresh registry per test, same convention as providers_spec.lua --
        -- these tests register fake providers and must not leak into each
        -- other (or into `M.resolve`'s own `load_builtin()` fallback, which
        -- only fires when the registry is completely empty).
        package.loaded["ai.providers"] = nil
      end)

      it(
        "resolves cfg.provider = 'auto' through provider_order before "
          .. "checking completion.model, instead of treating the literal "
          .. "string 'auto' as a provider id (which is vacuously always "
          .. "known and never flags anything)",
        function()
          local providers = require("ai.providers")
          providers.register({
            id = "claude",
            available = function()
              return true
            end,
          })
          local issues = models.check_config({
            provider = "auto",
            provider_order = { "claude" },
            model = {},
            completion = { provider = false, model = "claude-nonexistent-9" },
          })
          assert.are.equal(1, #issues)
          assert.is_true(issues[1]:find("claude-nonexistent-9", 1, true) ~= nil)
          assert.is_true(issues[1]:find("claude", 1, true) ~= nil)
        end
      )

      it("also resolves completion.provider = 'auto', not just cfg.provider", function()
        local providers = require("ai.providers")
        providers.register({
          id = "openai",
          available = function()
            return true
          end,
        })
        local issues = models.check_config({
          provider = "claude",
          provider_order = { "openai" },
          model = {},
          completion = { provider = "auto", model = "not-a-real-model" },
        })
        assert.are.equal(1, #issues)
        assert.is_true(issues[1]:find("not-a-real-model", 1, true) ~= nil)
        assert.is_true(issues[1]:find("openai", 1, true) ~= nil)
      end)

      it(
        "falls back to the literal 'auto' with no false positive when "
          .. "nothing in provider_order is available",
        function()
          local providers = require("ai.providers")
          providers.register({
            id = "claude",
            available = function()
              return false
            end,
          })
          local issues = models.check_config({
            provider = "auto",
            provider_order = { "claude" },
            model = {},
            completion = { provider = false, model = "claude-nonexistent-9" },
          })
          assert.are.same({}, issues)
        end
      )
    end)
  end)
end)
