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
        elseif fake_mode == "fail" then
          -- fails at once, inside ask(): a missing key or a refused argument
          cb(false, { kind = "api_error", message = "nope" })
        elseif fake_mode == "nokey" then
          cb(false, { kind = "missing_api_key", message = "no key", data = { profile = "work" } })
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

  describe("input that is not what the contract says", function()
    -- Every refusal is a callback, not an exception out of ask(). The one thing that
    -- raises is ai.ask's own check of the request (a table with a string prompt),
    -- as it does without `bulk`; see "a call that is no request at all" below.
    local function asks_without_raising(req, results)
      local ok, err = pcall(ask, req, results)
      assert.is_true(ok, tostring(err))
    end

    it("counts a NUL byte as one character instead of raising E976", function()
      fake_mode = "now"
      local results = {}
      asks_without_raising(req_of(nil, { prompt = "a\0b", system = "\0" }), results)
      wait_for(function()
        return #results == 1
      end)
      assert.is_true(results[1].ok)
      assert.are.equal(4, results[1].res.bulk.chars)
    end)

    it("a NUL byte over max_chars is a bulk_limit with the real count", function()
      local results = {}
      asks_without_raising(req_of({ max_chars = 5 }, { prompt = "abc\0def" }), results)
      wait_for(function()
        return #results == 1
      end)
      assert.are.equal("bulk_limit", results[1].res.kind)
      assert.are.equal(7, results[1].res.data.chars)
      assert.are.equal(0, #calls)
    end)

    it("counts invalid UTF-8 byte by byte, so it cannot slip under max_chars", function()
      local results = {}
      asks_without_raising(req_of({ max_chars = 5 }, { prompt = ("\128"):rep(10) }), results)
      wait_for(function()
        return #results == 1
      end)
      assert.are.equal("bulk_limit", results[1].res.kind)
      assert.are.equal(10, results[1].res.data.chars)
    end)

    it(
      "a malformed prompt, system, attachments, provider or timeout_ms is invalid_request",
      function()
        local bad = {
          { system = {} },
          { system = 5 },
          { attachments = 5 },
          { provider = 5 },
          { timeout_ms = "abc" },
          { timeout_ms = 0 },
          { timeout_ms = 0 / 0 },
          { temperature = "hot" },
        }
        local results = {}
        for _, extra in ipairs(bad) do
          asks_without_raising(req_of(nil, extra), results)
        end
        asks_without_raising(req_of({ temperature = 0 / 0 }), results)
        asks_without_raising(req_of({ temperature = math.huge }), results)
        -- bulk.ask() is also reachable without ai.ask()'s own check of the prompt
        require("ai.bulk").ask(
          { prompt = 5, bulk = { label = "x", max_chars = 1 } },
          function(ok, err)
            results[#results + 1] = { ok = ok, res = err }
          end,
          { resolve = function() end, dispatch = function() end }
        )
        wait_for(function()
          return #results == #bad + 3
        end)
        assert.are.equal(#bad + 3, #results)
        for i, r in ipairs(results) do
          assert.is_false(r.ok, "case " .. i)
          assert.are.equal("invalid_request", r.res.kind, "case " .. i)
        end
        assert.are.equal(0, #calls)
        assert.are.equal(0, bulk.usage().session_chars)
      end
    )

    it("an error while preparing the request reaches the callback and costs nothing", function()
      package.loaded["ai.context"] = {
        assemble = function()
          error("context boom")
        end,
      }
      local results = {}
      asks_without_raising(req_of(), results)
      package.loaded["ai.context"] = nil
      wait_for(function()
        return #results == 1
      end)
      assert.is_false(results[1].ok)
      assert.are.equal("invalid_request", results[1].res.kind)
      assert.is_truthy(results[1].res.message:find("context boom", 1, true))
      assert.are.equal(0, bulk.usage().session_chars)
      assert.are.equal(0, #calls)
    end)

    -- The documented exception (docs/bulk.md, doc/ai.txt, the ai.bulk header): a call
    -- that is no request at all is a programming error, bulk or not, and asserts in
    -- ai.ask before bulk is reached. Pinned so that a change either way updates the docs.
    it("a call that is no request at all raises from ai.ask, as without bulk", function()
      local results = {}
      local function collect(ok, res)
        results[#results + 1] = { ok = ok, res = res }
      end
      local bulk_opts = { label = "x", max_chars = 10 }
      local cases = {
        { "no request", nil },
        { "a request that is not a table", "hello" },
        { "no prompt", { bulk = bulk_opts } },
        { "a prompt that is not a string", { prompt = 5, bulk = bulk_opts } },
        { "the same without bulk", { prompt = 5 } },
      }
      for _, case in ipairs(cases) do
        local ok, err = pcall(ai.ask, case[2], collect)
        assert.is_false(ok, case[1])
        assert.is_truthy(tostring(err):find("req.prompt is required", 1, true), case[1])
      end
      vim.wait(30)
      assert.are.equal(0, #results)
      assert.are.equal(0, #calls)
      assert.are.equal(0, bulk.usage().session_chars)
    end)
  end)

  describe("temperature", function()
    it("bulk.temperature = false also drops a temperature the request carries", function()
      fake_mode = "now"
      local results = {}
      ask(req_of({ temperature = false }, { temperature = 0.9 }), results)
      wait_for(function()
        return #results == 1
      end)
      assert.is_nil(calls[1].req.temperature)
      assert.is_nil(results[1].res.bulk.temperature)
      assert.is_false(results[1].res.bulk.deterministic)
    end)

    it(
      "bulk.temperature, when set, wins over the request's, and res.bulk says what went",
      function()
        fake_mode = "now"
        local results = {}
        ask(req_of({ temperature = 0.2 }, { temperature = 0.9 }), results)
        wait_for(function()
          return #results == 1
        end)
        assert.are.equal(0.2, calls[1].req.temperature)
        assert.are.equal(0.2, results[1].res.bulk.temperature)
        assert.is_false(results[1].res.bulk.deterministic)
      end
    )

    it("the request's own temperature stands when bulk.temperature is not set", function()
      fake_mode = "now"
      local results = {}
      ask(req_of(nil, { temperature = 0.9 }), results)
      ask(req_of({ label = "zero" }, { temperature = 0 }), results)
      wait_for(function()
        return #results == 2
      end)
      assert.are.equal(0.9, calls[1].req.temperature)
      assert.are.equal(0.9, results[1].res.bulk.temperature)
      assert.is_false(results[1].res.bulk.deterministic)
      assert.are.equal(0, calls[2].req.temperature)
      assert.is_true(results[2].res.bulk.deterministic)
    end)

    it("a provider without a temperature parameter is not handed the request's", function()
      local results = {}
      ask(req_of(nil, { provider = "plain", temperature = 0.5 }), results)
      wait_for(function()
        return #results == 1
      end)
      assert.is_nil(calls[1].req.temperature)
      assert.is_nil(results[1].res.bulk.temperature)
    end)

    local function hinted(bulk_opts, message)
      local results = {}
      ask(req_of(bulk_opts), results)
      calls[1].cb(false, { kind = "api_error", message = message })
      wait_for(function()
        return #results == 1
      end)
      return results[1].res.message
    end

    it("an error that names the temperature says how to send none", function()
      local message = hinted(nil, "Unsupported value: 'temperature' does not support 0.")
      assert.are.equal(
        "Unsupported value: 'temperature' does not support 0."
          .. " (bulk sent temperature = 0; set bulk.temperature = false to send none)",
        message
      )
    end)

    it("an error that does not name it is passed on unchanged", function()
      assert.are.equal("rate limited", hinted(nil, "rate limited"))
    end)

    it("no hint when no temperature was sent", function()
      assert.are.equal(
        "temperature is fixed",
        hinted({ temperature = false }, "temperature is fixed")
      )
    end)
  end)

  describe("config.bulk.max_session_chars fails closed", function()
    local original_notify, notices

    before_each(function()
      original_notify = vim.notify
      notices = {}
      vim.notify = function(msg)
        notices[#notices + 1] = msg
      end
    end)

    after_each(function()
      vim.notify = original_notify
    end)

    ---One request under `opts`; returns its result.
    local function one_request(opts)
      require("ai.config").setup(opts)
      fake_mode = "now"
      local results = {}
      ask(req_of(), results)
      wait_for(function()
        return #results == 1
      end)
      return results[1]
    end

    local function assert_refused(r)
      assert.is_false(r.ok)
      assert.are.equal("bulk_limit", r.res.kind)
      assert.are.equal("max_session_chars", r.res.data.reason)
      assert.are.equal(0, #calls)
    end

    it("0 is a cap: every bulk request is refused, without a warning", function()
      assert_refused(one_request({ bulk = { max_session_chars = 0 } }))
      assert.are.equal(0, #notices)
      assert.are.same({}, require("ai.config").issues())
    end)

    for label, value in pairs({
      ["a negative number"] = -5,
      ["a string"] = "100",
      ["true"] = true,
      ["NaN"] = 0 / 0,
    }) do
      it(("%s refuses every bulk request and says so at once"):format(label), function()
        assert_refused(one_request({ bulk = { max_session_chars = value } }))
        local config = require("ai.config")
        assert.are.equal(1, #config.issues())
        assert.is_truthy(config.issues()[1]:find("bulk.max_session_chars", 1, true))
        assert.are.equal(1, #notices)
        assert.is_truthy(notices[1]:find("every bulk request is refused", 1, true))
      end)
    end

    it("a misspelt key under bulk refuses every bulk request instead of lifting the cap", function()
      assert_refused(one_request({ bulk = { max_sesion_chars = 100 } }))
      local config = require("ai.config")
      assert.are.equal(1, #config.issues())
      assert.is_truthy(config.issues()[1]:find("bulk.max_sesion_chars", 1, true))
      assert.are.equal(1, #notices)
    end)

    it("a bulk option that is not a table refuses every bulk request", function()
      assert_refused(one_request({ bulk = "500000" }))
      assert.are.equal(1, #require("ai.config").issues())
      assert.are.equal(1, #notices)
    end)

    it("a value that got into the live config unchecked refuses too", function()
      require("ai.config").setup({})
      require("ai.config").get().bulk.max_session_chars = "10"
      fake_mode = "now"
      local results = {}
      ask(req_of(), results)
      wait_for(function()
        return #results == 1
      end)
      assert_refused(results[1])
    end)

    it("false and a number that fits are as before, and quiet", function()
      local r = one_request({ bulk = { max_session_chars = false } })
      assert.is_true(r.ok)
      require("ai.bulk").reset()
      local r2 = one_request({ bulk = { max_session_chars = 5 } })
      assert.is_true(r2.ok)
      assert.are.equal(0, #notices)
      assert.are.same({}, require("ai.config").issues())
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
        -- the group stays (its jobs were running), with the budget reset to 0
        assert.are.equal(0, bulk.usage("run").label_chars)
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

    it("usage().queued follows starts, kills of waiting jobs and cancel(label)", function()
      local results = {}
      ask(req_of(), results)
      local q1 = ask(req_of(), results)
      ask(req_of(), results)
      ask(req_of(), results)
      assert.are.equal(3, bulk.usage("run").queued)
      q1:kill()
      assert.are.equal(2, bulk.usage("run").queued)
      calls[1].cb(true, { text = "a", provider = "fake" })
      assert.are.equal(2, #calls) -- the killed one was skipped
      assert.are.equal(1, bulk.usage("run").queued)
      assert.are.equal(1, bulk.usage("run").active)
      bulk.cancel("run")
      assert.are.equal(0, bulk.usage("run").queued)
      assert.are.equal(0, bulk.usage("run").active)
      ask(req_of(), results)
      assert.are.equal(3, #calls)
      assert.are.equal(0, bulk.usage("run").queued)
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

  describe("a command key source that is still running", function()
    ---@type function[]
    local fetches

    before_each(function()
      fetches = {}
      package.loaded["ai.keys"] = {
        needs_fetch = function()
          return true
        end,
        fetch = function(_, on_key)
          fetches[#fetches + 1] = on_key
          return function() end
        end,
      }
    end)

    after_each(function()
      package.loaded["ai.keys"] = nil
    end)

    it("sends the request once the key arrives", function()
      local results = {}
      ask(req_of(), results)
      assert.are.equal(1, #fetches)
      assert.are.equal(0, #calls)
      fetches[1](true)
      assert.are.equal(1, #calls)
    end)

    it("kill() before the key arrives: the request is never sent", function()
      local results = {}
      local handle = ask(req_of(), results)
      handle:kill()
      fetches[1](true)
      assert.are.equal(0, #calls)
      wait_for(function()
        return #results == 1
      end)
      assert.are.equal("cancelled", results[1].res.kind)
    end)

    it("cancel(label) before the key arrives: nothing is sent", function()
      local results = {}
      ask(req_of({ concurrency = 2 }), results)
      ask(req_of({ concurrency = 2 }), results)
      assert.are.equal(2, bulk.cancel("run"))
      for _, on_key in ipairs(fetches) do
        on_key(true)
      end
      assert.are.equal(0, #calls)
    end)

    it("the watchdog giving up before the key arrives: nothing is sent", function()
      bulk.watchdog_grace_ms = 10
      local results = {}
      ask(req_of(nil, { timeout_ms = 20 }), results)
      wait_for(function()
        return #results == 1
      end)
      assert.are.equal("timeout", results[1].res.kind)
      fetches[1](true)
      assert.are.equal(0, #calls)
    end)

    it("a failed key after the request was cancelled calls nothing back twice", function()
      local results = {}
      local handle = ask(req_of(), results)
      handle:kill()
      fetches[1](false, { kind = "missing_api_key", message = "no key" })
      vim.wait(30)
      assert.are.equal(1, #results)
      assert.are.equal("cancelled", results[1].res.kind)
    end)
  end)

  describe("a key that cannot be had", function()
    local function missing_key()
      return { kind = "missing_api_key", message = "locked vault", data = { profile = "work" } }
    end

    it("fails the waiting requests of that provider at once, the first callback first", function()
      local results = {}
      -- The errors are copies of one another, so the order is told by which request a
      -- callback belongs to: each request gets its own tagged callback.
      local order = {}
      local function ask_tagged(tag, req)
        return ai.ask(req, function(ok, res)
          order[#order + 1] = tag
          results[#results + 1] = { ok = ok, res = res }
        end)
      end
      ask_tagged("sent", req_of()) -- held
      for i = 1, 5 do
        ask_tagged("waiting" .. i, req_of(nil, { prompt = "p" .. i }))
      end
      calls[1].cb(false, missing_key())
      wait_for(function()
        return #results == 6
      end)
      assert.are.equal(6, #results)
      assert.same({ "sent", "waiting1", "waiting2", "waiting3", "waiting4", "waiting5" }, order)
      assert.are.equal(1, #calls) -- nothing was started again, so no key command either
      for _, r in ipairs(results) do
        assert.is_false(r.ok)
        assert.are.equal("missing_api_key", r.res.kind)
        assert.are.equal("locked vault", r.res.message)
        assert.are.equal("work", r.res.data.profile)
      end
      assert.are_not.equal(results[1].res, results[2].res) -- each callback gets its own error
      assert.same({ active = 0, queued = 0 }, {
        active = bulk.usage("run").active,
        queued = bulk.usage("run").queued,
      })
      -- the one that was sent keeps its cost, the ones that never started give theirs back
      assert.are.equal(5, bulk.usage("run").label_chars)
      assert.are.equal(5, bulk.usage().session_chars)
    end)

    it("does so when the provider fails inside ask() too", function()
      local results = {}
      ask(req_of(), results) -- held
      for _ = 1, 5 do
        ask(req_of(), results)
      end
      fake_mode = "nokey"
      calls[1].cb(true, { text = "first", provider = "fake" })
      wait_for(function()
        return #results == 6
      end)
      assert.are.equal(6, #results)
      assert.is_true(results[1].ok)
      assert.are.equal(2, #calls) -- the second one found no key, the rest never tried
      for i = 2, 6 do
        assert.are.equal("missing_api_key", results[i].res.kind)
      end
      assert.are.equal(0, bulk.usage("run").queued)
      assert.are.equal(0, bulk.usage("run").active)
    end)

    it("leaves what waits for another provider alone", function()
      local results = {}
      ask(req_of(), results) -- held
      ask(req_of(nil, { provider = "plain", prompt = "other" }), results)
      ask(req_of(), results)
      calls[1].cb(false, missing_key())
      wait_for(function()
        return #results == 3
      end)
      assert.are.equal("missing_api_key", results[1].res.kind)
      local by_provider = {}
      for _, r in ipairs(results) do
        by_provider[#by_provider + 1] = r.ok and r.res.provider or r.res.kind
      end
      table.sort(by_provider)
      assert.same({ "missing_api_key", "missing_api_key", "plain" }, by_provider)
      assert.are.equal(2, #calls) -- the held one, and "plain" which answered
    end)

    it("is for a missing key only: any other error leaves the queue running", function()
      local results = {}
      ask(req_of(), results)
      ask(req_of(nil, { prompt = "second" }), results)
      calls[1].cb(false, { kind = "api_error", message = "overloaded" })
      assert.are.equal(2, #calls)
      assert.are.equal("second", calls[2].req.prompt)
    end)

    -- A custom provider (providers.register) answers with whatever it likes. An error
    -- that is not a well-formed LibErrorValue must still end the waiting requests and
    -- leave the label usable: the copies are built by lib_error.new, which asserts on
    -- a message that is not a string.
    local not_well_formed = {
      {
        name = "no message",
        make = function()
          return { kind = "missing_api_key" }
        end,
      },
      {
        name = "a message that is not a string",
        make = function()
          return { kind = "missing_api_key", message = 42, data = { profile = "work" } }
        end,
      },
    }
    for _, case in ipairs(not_well_formed) do
      it("an error with " .. case.name .. " still ends the waiting requests", function()
        local results = {}
        ask(req_of(), results) -- held
        for _ = 1, 3 do
          ask(req_of(), results)
        end
        local ok, err = pcall(calls[1].cb, false, case.make())
        assert.is_true(ok, tostring(err))
        wait_for(function()
          return #results == 4
        end)
        assert.are.equal(4, #results)
        assert.are.equal(1, #calls)
        for _, r in ipairs(results) do
          assert.is_false(r.ok)
          assert.are.equal("missing_api_key", r.res.kind)
        end
        -- the requests that never ran get a well-formed error
        for i = 2, 4 do
          assert.is_string(results[i].res.message)
        end
        assert.same({ active = 0, queued = 0 }, {
          active = bulk.usage("run").active,
          queued = bulk.usage("run").queued,
        })
        -- and the label still works: nothing is blocked for good
        fake_mode = "now"
        ask(req_of(), results)
        wait_for(function()
          return #results == 5
        end)
        assert.are.equal(5, #results)
        assert.is_true(results[5].ok)
      end)
    end

    it("an error that is not a table is a plain failure: the queue goes on", function()
      local results = {}
      ask(req_of(), results) -- held
      ask(req_of(nil, { prompt = "second" }), results)
      local ok, err = pcall(calls[1].cb, false, "missing_api_key")
      assert.is_true(ok, tostring(err))
      assert.are.equal(2, #calls)
      assert.are.equal("second", calls[2].req.prompt)
      wait_for(function()
        return #results == 1
      end)
      assert.are.equal("missing_api_key", results[1].res)
    end)

    it("a failure while ending the waiting requests does not block the label", function()
      local lib_error = require("lib.lua.error")
      local real_new = lib_error.new
      local results = {}
      ask(req_of(), results) -- held
      ask(req_of(nil, { prompt = "second" }), results) -- waits
      -- Whatever goes wrong in there, the queue must not stay held: make the copy of
      -- the error for the waiting request raise.
      lib_error.new = function(kind, message, data)
        if kind == "missing_api_key" then
          error("copy boom")
        end
        return real_new(kind, message, data)
      end
      pcall(calls[1].cb, false, missing_key())
      lib_error.new = real_new
      wait_for(function()
        return #results >= 1
      end)
      assert.are.equal("missing_api_key", results[1].res.kind) -- the first callback was not lost
      -- the waiting request was not ended by the failure, so the label went on with it
      assert.are.equal(2, #calls)
      assert.are.equal("second", calls[2].req.prompt)
      calls[2].cb(true, { text = "ok", provider = "fake" })
      fake_mode = "now"
      ask(req_of(), results)
      wait_for(function()
        return #results == 3
      end)
      assert.are.equal(3, #results)
      assert.is_true(results[2].ok)
      assert.is_true(results[3].ok)
    end)
  end)

  describe("the queue drain", function()
    it("survives a long queue behind a provider that fails at once", function()
      local queued = 4000
      local results = {}
      ask(req_of(), results) -- held: it occupies the only slot
      for _ = 1, queued do
        ask(req_of(), results)
      end
      assert.are.equal(queued, bulk.usage("run").queued)
      fake_mode = "fail"
      -- Answering the first one starts the rest: each fails inside ask(), so
      -- finishing one starts the next on the same stack.
      calls[1].cb(true, { text = "first", provider = "fake" })
      vim.wait(10000, function()
        return #results == queued + 1
      end, 5)
      assert.are.equal(queued + 1, #results)
      assert.are.equal(queued + 1, #calls)
      assert.same({ active = 0, queued = 0 }, {
        active = bulk.usage("run").active,
        queued = bulk.usage("run").queued,
      })
      -- and the label still works
      fake_mode = "now"
      ask(req_of(), results)
      vim.wait(1000, function()
        return #results == queued + 2
      end, 5)
      assert.is_true(results[queued + 2].ok)
    end)

    it("keeps the callback order of a drain that fails at once", function()
      local results = {}
      ask(req_of(nil, { prompt = "p0" }), results)
      for i = 1, 5 do
        ask(req_of(nil, { prompt = "p" .. i }), results)
      end
      fake_mode = "fail"
      calls[1].cb(true, { text = "p0", provider = "fake" })
      wait_for(function()
        return #results == 6
      end)
      assert.are.equal("p0", results[1].res.text)
      for i = 2, 6 do
        assert.is_false(results[i].ok)
      end
      assert.are.equal(6, #calls)
      assert.are.equal("p5", calls[6].req.prompt)
    end)

    it("a job whose start raises ends with network_error and frees its slot", function()
      local new_timer = vim.uv.new_timer
      vim.uv.new_timer = function()
        error("no timer for you")
      end
      local results = {}
      local ok, err = pcall(function()
        ask(req_of(), results)
        ask(req_of(), results)
      end)
      vim.uv.new_timer = new_timer
      assert.is_true(ok, tostring(err))
      wait_for(function()
        return #results == 2
      end)
      assert.are.equal(2, #results)
      for _, r in ipairs(results) do
        assert.is_false(r.ok)
        assert.are.equal("network_error", r.res.kind)
      end
      assert.are.equal(0, bulk.usage("run").active)
      assert.are.equal(0, bulk.usage("run").queued)
      -- the label is not stuck
      ask(req_of(), results)
      assert.are.equal(1, #calls)
    end)

    it("a huge timeout_ms from the config is clamped before it arms the watchdog", function()
      local new_timer = vim.uv.new_timer
      local armed
      vim.uv.new_timer = function()
        local real = new_timer()
        return {
          start = function(_, ms, rep, on_fire)
            armed = ms
            return real:start(ms, rep, on_fire)
          end,
          stop = function()
            return real:stop()
          end,
          close = function()
            return real:close()
          end,
          is_closing = function()
            return real:is_closing()
          end,
        }
      end
      require("ai.config").setup({ timeout_ms = 1e300 })
      local results = {}
      pcall(ask, req_of(), results)
      vim.uv.new_timer = new_timer
      assert.are.equal(3600000 + bulk.watchdog_grace_ms, armed)
      bulk.cancel("run")
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

  describe(":Ai info", function()
    it("shows the session cap, what was used, and a grant for bulk requests", function()
      local lines
      package.loaded["ui.kit"] = {
        popup = function(o)
          lines = o.lines
        end,
      }
      require("ai.config").setup({
        bulk = { max_session_chars = 1000 },
        policy = { allowed = { "plain" } },
      })
      policy.grant_bulk("fake")
      fake_mode = "now"
      ask(req_of(nil, { provider = "plain" }), {})
      require("ai.bindings.actions").info()
      package.loaded["ui.kit"] = nil
      local text = table.concat(lines, "\n")
      assert.is_truthy(text:find("bulk: session cap 1000 characters, 5 characters used", 1, true))
      assert.is_truthy(text:find("session grant for bulk requests outside the list: fake", 1, true))
    end)

    it("says no cap when there is none", function()
      local lines
      package.loaded["ui.kit"] = {
        popup = function(o)
          lines = o.lines
        end,
      }
      require("ai.config").setup({})
      require("ai.bindings.actions").info()
      package.loaded["ui.kit"] = nil
      assert.is_truthy(
        table.concat(lines, "\n"):find("bulk: session cap none, 0 characters used", 1, true)
      )
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

    it("every other built-in says an explicit false, like capabilities.web", function()
      providers.load_builtin()
      local takes = { claude = true, openai = true, gemini = true, ollama = true }
      local counted = 0
      for _, id in ipairs(providers.ids()) do
        if id ~= "fake" and id ~= "plain" then
          counted = counted + 1
          assert.are.equal(
            takes[id] == true,
            providers.get(id).capabilities.temperature,
            id .. ": temperature must be an explicit boolean"
          )
        end
      end
      assert.is_true(counted >= 7)
    end)

    it("capability_names shows the temperature, last", function()
      assert.same(
        { "streaming", "web", "temperature" },
        providers.capability_names({
          capabilities = { temperature = true, web = true, streaming = true },
        })
      )
      assert.same({}, providers.capability_names({ capabilities = { temperature = false } }))
    end)
  end)
end)
