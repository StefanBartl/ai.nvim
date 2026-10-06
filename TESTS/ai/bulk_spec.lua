-- ai.bulk: the guard rails of `ai.ask({ bulk = {...} })`, against a fake
-- provider (no network). Every bulk callback is asynchronous, so the tests wait
-- with `vim.wait`.
---@diagnostic disable: missing-fields, need-check-nil

describe("ai.bulk", function()
  local ai, policy, bulk, providers
  ---@type { req: table, cb: function }[]
  local calls
  local fake_mode

  local function wait_for(pred)
    vim.wait(1000, pred, 5)
  end

  ---@param extra? table bulk fields
  ---@param req? table request fields
  local function req_of(extra, req)
    return vim.tbl_extend("force", {
      prompt = "hello",
      provider = "fake",
      bulk = vim.tbl_extend("force", { label = "run", max_chars = 100 }, extra or {}),
    }, req or {})
  end

  ---Ask and collect the callbacks into `results`.
  local function ask(req, results)
    return ai.ask(req, function(ok, res)
      results[#results + 1] = { ok = ok, res = res }
    end)
  end

  before_each(function()
    for _, mod in ipairs({ "ai", "ai.config", "ai.providers", "ai.policy", "ai.bulk" }) do
      package.loaded[mod] = nil
    end
    ai = require("ai")
    policy = require("ai.policy")
    bulk = require("ai.bulk")
    providers = require("ai.providers")
    require("ai.config").setup({})
    calls = {}
    fake_mode = "hold"
    providers.register({
      id = "fake",
      default_model = "fake-1",
      capabilities = { temperature = true },
      available = function()
        return true
      end,
      ask = function(req, cb)
        calls[#calls + 1] = { req = req, cb = cb }
        if fake_mode == "now" then
          cb(true, { text = "ok:" .. req.prompt, provider = "fake" })
        elseif fake_mode == "raise" then
          error("boom")
        end
      end,
    })
    providers.register({
      id = "plain",
      capabilities = {},
      available = function()
        return true
      end,
      ask = function(req, cb)
        calls[#calls + 1] = { req = req, cb = cb }
        cb(true, { text = "ok", provider = "plain" })
      end,
    })
  end)

  describe("limits", function()
    it("answers a request that is fine, naming provider, model and temperature", function()
      fake_mode = "now"
      local results = {}
      ask(req_of(), results)
      wait_for(function()
        return #results == 1
      end)
      assert.is_true(results[1].ok)
      assert.are.equal("ok:hello", results[1].res.text)
      assert.same({
        provider = "fake",
        model = "fake-1",
        label = "run",
        temperature = 0,
        deterministic = true,
        chars = 5,
      }, results[1].res.bulk)
      assert.are.equal(0, calls[1].req.temperature)
      assert.is_nil(calls[1].req.bulk)
    end)

    it("the configured or requested model wins over the provider default", function()
      fake_mode = "now"
      local results = {}
      ask(req_of(nil, { model = "m-2" }), results)
      wait_for(function()
        return #results == 1
      end)
      assert.are.equal("m-2", results[1].res.bulk.model)
    end)

    it("a provider without a temperature parameter gets none and is not deterministic", function()
      local results = {}
      ask(req_of(nil, { provider = "plain" }), results)
      wait_for(function()
        return #results == 1
      end)
      assert.is_nil(calls[1].req.temperature)
      assert.is_false(results[1].res.bulk.deterministic)
      assert.are.equal("default", results[1].res.bulk.model)
    end)

    it("bulk.temperature overrides the default, false sends none", function()
      fake_mode = "now"
      local results = {}
      ask(req_of({ temperature = 0.3 }), results)
      ask(req_of({ temperature = false }), results)
      wait_for(function()
        return #results == 2
      end)
      assert.are.equal(0.3, calls[1].req.temperature)
      assert.is_nil(calls[2].req.temperature)
    end)

    it("refuses a request over max_chars without calling the provider", function()
      local results = {}
      ask(req_of({ max_chars = 4 }), results)
      wait_for(function()
        return #results == 1
      end)
      assert.is_false(results[1].ok)
      assert.are.equal("bulk_limit", results[1].res.kind)
      assert.are.equal("max_chars", results[1].res.data.reason)
      assert.are.equal(0, #calls)
    end)

    it("counts the system prompt and characters, not bytes", function()
      local results = {}
      -- 3 characters, 6 bytes, plus a 3-character system prompt
      ask(req_of({ max_chars = 5 }, { prompt = "äöü", system = "abc" }), results)
      wait_for(function()
        return #results == 1
      end)
      assert.are.equal("bulk_limit", results[1].res.kind)
      assert.are.equal(6, results[1].res.data.chars)
    end)

    it("the callback is never called inside ask", function()
      fake_mode = "now"
      local results = {}
      ask(req_of({ max_chars = 1 }), results)
      assert.are.equal(0, #results)
      ask(req_of(), results)
      assert.are.equal(0, #results)
      wait_for(function()
        return #results == 2
      end)
    end)

    it("max_total_chars caps a label, other labels are not affected", function()
      fake_mode = "now"
      local results = {}
      ask(req_of({ max_total_chars = 8 }), results) -- 5
      ask(req_of({ max_total_chars = 8 }), results) -- 10 > 8
      ask(req_of({ max_total_chars = 8, label = "other" }), results)
      wait_for(function()
        return #results == 3
      end)
      local by = {}
      for _, r in ipairs(results) do
        by[#by + 1] = r.ok and "ok" or r.res.data.reason
      end
      table.sort(by)
      assert.same({ "max_total_chars", "ok", "ok" }, by)
      assert.are.equal(2, #calls)
    end)

    it("reset(label) starts a fresh budget", function()
      fake_mode = "now"
      local results = {}
      ask(req_of({ max_total_chars = 6 }), results)
      wait_for(function()
        return #results == 1
      end)
      bulk.reset("run")
      ask(req_of({ max_total_chars = 6 }), results)
      wait_for(function()
        return #results == 2
      end)
      assert.is_true(results[2].ok)
    end)

    it("config.bulk.max_session_chars caps all bulk requests together", function()
      require("ai.config").setup({ bulk = { max_session_chars = 8 } })
      fake_mode = "now"
      local results = {}
      ask(req_of({ label = "a" }), results)
      ask(req_of({ label = "b" }), results)
      wait_for(function()
        return #results == 2
      end)
      local reasons = {}
      for _, r in ipairs(results) do
        reasons[#reasons + 1] = r.ok and "ok" or r.res.data.reason
      end
      table.sort(reasons)
      assert.same({ "max_session_chars", "ok" }, reasons)
      assert.are.equal(5, bulk.usage().session_chars)
    end)

    it("a malformed bulk table fails with invalid_request, not an exception", function()
      local results = {}
      ask(req_of({ label = false }), results)
      ask(req_of({ max_chars = 0 }), results)
      ask(req_of({ max_chars = "x" }), results)
      ask(req_of({ concurrency = 0 }), results)
      ask(req_of({ max_total_chars = -1 }), results)
      ask(vim.tbl_extend("force", req_of(), { bulk = "yes" }), results)
      wait_for(function()
        return #results == 6
      end)
      for _, r in ipairs(results) do
        assert.is_false(r.ok)
        assert.are.equal("invalid_request", r.res.kind)
      end
      assert.are.equal(0, #calls)
    end)

    it("refuses attachments, context and the plain allow_unlisted", function()
      local results = {}
      ask(
        req_of(nil, { attachments = { { kind = "image", media_type = "image/png", data = "A" } } }),
        results
      )
      ask(req_of(nil, { context = { buffer = true } }), results)
      ask(req_of(nil, { allow_unlisted = true }), results)
      wait_for(function()
        return #results == 3
      end)
      for _, r in ipairs(results) do
        assert.are.equal("invalid_request", r.res.kind)
      end
      assert.are.equal(0, #calls)
    end)

    it("ai.stream refuses a bulk request", function()
      local err
      local handle = ai.stream(req_of(), {
        on_error = function(e)
          err = e
        end,
      })
      assert.is_nil(handle)
      assert.are.equal("invalid_request", err.kind)
    end)
  end)

  describe("concurrency", function()
    it("keeps at most `concurrency` requests in flight and starts queued ones in order", function()
      local results = {}
      for i = 1, 4 do
        ask(req_of({ concurrency = 2 }, { prompt = "p" .. i }), results)
      end
      assert.are.equal(2, #calls)
      assert.same({ active = 2, queued = 2 }, {
        active = bulk.usage("run").active,
        queued = bulk.usage("run").queued,
      })
      calls[1].cb(true, { text = "a", provider = "fake" })
      assert.are.equal(3, #calls)
      assert.are.equal("p3", calls[3].req.prompt)
      calls[2].cb(true, { text = "b", provider = "fake" })
      calls[3].cb(true, { text = "c", provider = "fake" })
      calls[4].cb(true, { text = "d", provider = "fake" })
      wait_for(function()
        return #results == 4
      end)
      assert.are.equal(4, #calls)
      assert.are.equal(0, bulk.usage("run").active)
    end)

    it("labels do not share slots", function()
      local results = {}
      ask(req_of({ label = "a" }), results)
      ask(req_of({ label = "b" }), results)
      assert.are.equal(2, #calls)
    end)

    it("defaults to one request at a time", function()
      local results = {}
      ask(req_of(), results)
      ask(req_of(), results)
      assert.are.equal(1, #calls)
    end)
  end)

  describe("callback exactly once", function()
    it("ignores a provider that answers twice", function()
      local results = {}
      ask(req_of(), results)
      calls[1].cb(true, { text = "a", provider = "fake" })
      calls[1].cb(true, { text = "b", provider = "fake" })
      calls[1].cb(false, { kind = "api_error", message = "x" })
      vim.wait(50)
      assert.are.equal(1, #results)
      assert.are.equal("a", results[1].res.text)
    end)

    it("turns a provider that raises into one network_error", function()
      fake_mode = "raise"
      local results = {}
      ask(req_of(), results)
      wait_for(function()
        return #results == 1
      end)
      vim.wait(30)
      assert.are.equal(1, #results)
      assert.are.equal("network_error", results[1].res.kind)
      assert.are.equal(0, bulk.usage("run").active)
    end)

    it("fails a provider that never answers instead of hanging", function()
      bulk.watchdog_grace_ms = 10
      local results = {}
      ask(req_of(nil, { timeout_ms = 20 }), results)
      wait_for(function()
        return #results == 1
      end)
      assert.are.equal("timeout", results[1].res.kind)
      assert.are.equal(0, bulk.usage("run").active)
      -- a late answer is dropped
      calls[1].cb(true, { text = "late", provider = "fake" })
      vim.wait(30)
      assert.are.equal(1, #results)
      bulk.watchdog_grace_ms = 5000
    end)
  end)

  describe("cancel", function()
    it(
      "kill() on an in-flight request calls back once with cancelled and drops the answer",
      function()
        local results = {}
        local handle = ask(req_of(), results)
        assert.is_false(handle:is_closing())
        handle:kill()
        handle:kill()
        calls[1].cb(true, { text = "late", provider = "fake" })
        wait_for(function()
          return #results == 1
        end)
        vim.wait(30)
        assert.are.equal(1, #results)
        assert.are.equal("cancelled", results[1].res.kind)
        assert.is_true(handle:is_closing())
        assert.are.equal(0, bulk.usage("run").active)
      end
    )

    it("kill() frees the slot, the next queued request starts", function()
      local results = {}
      local h1 = ask(req_of(), results)
      ask(req_of(nil, { prompt = "second" }), results)
      assert.are.equal(1, #calls)
      h1:kill()
      assert.are.equal(2, #calls)
      assert.are.equal("second", calls[2].req.prompt)
    end)

    it("a request killed before it started gives its characters back", function()
      local results = {}
      ask(req_of({ max_total_chars = 12 }), results)
      local queued = ask(req_of({ max_total_chars = 12 }), results)
      assert.are.equal(10, bulk.usage("run").label_chars)
      queued:kill()
      assert.are.equal(5, bulk.usage("run").label_chars)
      assert.are.equal(5, bulk.usage().session_chars)
      wait_for(function()
        return #results == 1
      end)
      assert.are.equal("cancelled", results[1].res.kind)
    end)

    it(
      "reset(label) while a job is queued: killing it does not refund into the new budget",
      function()
        local results = {}
        ask(req_of(), results)
        local queued = ask(req_of(), results)
        bulk.reset("run")
        assert.are.equal(0, bulk.usage("run").label_chars)
        queued:kill()
        assert.are.equal(0, bulk.usage("run").label_chars)
        assert.are.equal(0, bulk.usage().session_chars)
      end
    )

    it(
      "reset() keeps running jobs reachable through cancel(label) and never goes negative",
      function()
        local results = {}
        ask(req_of(), results)
        ask(req_of(), results)
        bulk.reset()
        assert.are.equal(0, bulk.usage().session_chars)
        assert.are.equal(2, bulk.cancel("run"))
        assert.are.equal(0, bulk.usage().session_chars)
        assert.are.equal(0, bulk.usage("run").label_chars or 0)
        wait_for(function()
          return #results == 2
        end)
        assert.are.equal("cancelled", results[1].res.kind)
        assert.are.equal("cancelled", results[2].res.kind)
      end
    )

    it("usage().queued does not count cancelled jobs that are still in the queue", function()
      local results = {}
      ask(req_of(), results)
      local q1 = ask(req_of(), results)
      ask(req_of(), results)
      assert.are.equal(2, bulk.usage("run").queued)
      q1:kill()
      assert.are.equal(1, bulk.usage("run").queued)
    end)

    it("a request that already started keeps its cost", function()
      local results = {}
      local h = ask(req_of(), results)
      h:kill()
      assert.are.equal(5, bulk.usage("run").label_chars)
    end)

    it("kill() after the answer is a no-op", function()
      local results = {}
      local h = ask(req_of(), results)
      calls[1].cb(true, { text = "a", provider = "fake" })
      h:kill()
      vim.wait(30)
      assert.are.equal(1, #results)
      assert.is_true(results[1].ok)
    end)

    it("cancel(label) ends queued and in-flight requests, each once", function()
      local results = {}
      for _ = 1, 3 do
        ask(req_of(), results)
      end
      assert.are.equal(3, bulk.cancel("run"))
      wait_for(function()
        return #results == 3
      end)
      vim.wait(30)
      assert.are.equal(3, #results)
      assert.are.equal(1, #calls) -- the queued ones never started
      for _, r in ipairs(results) do
        assert.are.equal("cancelled", r.res.kind)
      end
      assert.are.equal(0, bulk.cancel("nothing"))
    end)
  end)

  describe("policy", function()
    before_each(function()
      require("ai.config").setup({ policy = { allowed = { "plain" } } })
    end)

    local function refused(results)
      wait_for(function()
        return #results == 1
      end)
      return results[1]
    end

    it("refuses an unlisted provider with a message that says what to do", function()
      local results = {}
      ask(req_of(), results)
      local r = refused(results)
      assert.is_false(r.ok)
      assert.are.equal("provider_resolution", r.res.kind)
      assert.are.equal("policy", r.res.data.reason)
      assert.is_true(r.res.data.bulk)
      assert.is_truthy(r.res.message:find("grant_bulk", 1, true))
      assert.are.equal(0, #calls)
    end)

    it("serves a listed provider without a question", function()
      local results = {}
      ask(req_of(nil, { provider = "plain" }), results)
      wait_for(function()
        return #results == 1
      end)
      assert.is_true(results[1].ok)
    end)

    it("does not accept the plain allow_unlisted or a :Ai provider session grant", function()
      policy.grant("fake")
      local results = {}
      ask(req_of(), results)
      assert.are.equal("provider_resolution", refused(results).res.kind)
      assert.are.equal(0, #calls)
    end)

    it("grant_bulk(id) allows it for the session, and is listed", function()
      policy.grant_bulk("fake")
      assert.same({ "fake" }, ai.policy().bulk_granted)
      local results = {}
      ask(req_of(), results)
      wait_for(function()
        return #calls == 1
      end)
      calls[1].cb(true, { text = "x", provider = "fake" })
      wait_for(function()
        return #results == 1
      end)
      assert.is_true(results[1].ok)
    end)

    it("grant_bulk does not widen the plain policy", function()
      policy.grant_bulk("fake")
      assert.is_false(policy.is_allowed("fake"))
      assert.is_true(policy.is_bulk_allowed("fake"))
      policy.reset()
      assert.is_false(policy.is_bulk_allowed("fake"))
    end)

    it("bulk.allow_unlisted allows one request only", function()
      local results = {}
      ask(req_of({ allow_unlisted = true }), results)
      ask(req_of(), results)
      wait_for(function()
        return #results == 1
      end)
      assert.are.equal(1, #calls)
      assert.is_false(results[1].ok)
    end)

    it("auto never walks an unlisted provider, even with a bulk grant", function()
      policy.grant_bulk("fake")
      require("ai.config").setup({
        policy = { allowed = { "plain" } },
        provider_order = { "fake", "plain" },
      })
      local results = {}
      ask(req_of(nil, { provider = "auto" }), results)
      wait_for(function()
        return #results == 1
      end)
      assert.are.equal("plain", results[1].res.bulk.provider)
    end)

    it("an unrestricted machine needs no confirmation", function()
      require("ai.config").setup({})
      local results = {}
      ask(req_of(), results)
      assert.are.equal(1, #calls)
    end)
  end)

  describe("providers carry the temperature", function()
    local seen
    local function body_of(id, req)
      seen = nil
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, opts, cb)
          seen = opts.body
          cb(true, {})
        end,
      }
      for _, m in ipairs({ "ai.providers.transport", "ai.providers." .. id }) do
        package.loaded[m] = nil
      end
      require("ai.providers." .. id).ask(req, function() end)
      return vim.json.decode(seen)
    end

    after_each(function()
      package.loaded["lib.nvim.net.curl"] = nil
      for _, m in ipairs({ "claude", "openai", "gemini", "ollama" }) do
        package.loaded["ai.providers." .. m] = nil
      end
      package.loaded["ai.providers.transport"] = nil
    end)

    it("claude and openai: top-level temperature", function()
      for _, id in ipairs({ "claude", "openai" }) do
        assert.are.equal(
          0,
          body_of(id, { prompt = "x", api_key = "k", temperature = 0 }).temperature
        )
        assert.is_nil(body_of(id, { prompt = "x", api_key = "k" }).temperature)
      end
    end)

    it("gemini: generationConfig.temperature", function()
      local body = body_of("gemini", { prompt = "x", api_key = "k", temperature = 0 })
      assert.are.equal(0, body.generationConfig.temperature)
      assert.is_nil(body_of("gemini", { prompt = "x", api_key = "k" }).generationConfig)
    end)

    it("ollama: options.temperature", function()
      local body = body_of("ollama", { prompt = "x", temperature = 0 })
      assert.are.equal(0, body.options.temperature)
      assert.is_nil(body_of("ollama", { prompt = "x" }).options)
    end)

    it("the built-ins that take a temperature say so, and name a default model", function()
      for _, id in ipairs({ "claude", "openai", "gemini", "ollama" }) do
        local p = require("ai.providers." .. id)
        assert.is_true(p.capabilities.temperature)
        assert.is_string(p.default_model)
      end
    end)
  end)
end)
