-- ai.usage -- the usage reporter behind `ai.ask`/`ai.stream`.
--
-- The sender is injected (`usage._set_sender`), so nothing is spawned: every
-- test reads the URL and the decoded body the module *would* have sent. Fake
-- providers are registered by explicit id (as init_spec.lua does), so the
-- resolution path of `ai.init` is the real one and the per-provider token
-- normalization is keyed by the ids the real backends use.
--
-- The test body itself is the guard against a nil field (busted fails loudly
-- on an actual nil-index error), so need-check-nil noise on the captured
-- events is suppressed file-wide; the fakes implement only what each test
-- exercises (missing-fields).
---@diagnostic disable: need-check-nil, missing-fields
describe("ai.usage", function()
  local sent ---@type { url: string, body: table }[]
  local fail_with ---@type string|nil
  local original_host

  ---@param id string
  ---@param result { ok: boolean, res: table }
  local function register(id, result)
    require("ai.providers").register({
      id = id,
      available = function()
        return true
      end,
      ask = function(_, cb)
        cb(result.ok, result.res)
      end,
      stream = function(_, handlers)
        if result.ok then
          handlers.on_done(result.res)
        else
          handlers.on_error(result.res)
        end
        return nil
      end,
    })
  end

  ---@param opts? table user options merged over DEFAULTS
  local function configure(opts)
    require("ai.config").setup(opts or { usage = { report = true } })
    require("ai.usage")._set_sender(function(url, body, on_failure)
      sent[#sent + 1] = { url = url, body = vim.json.decode(body) }
      if fail_with then
        on_failure(fail_with)
      end
    end)
  end

  before_each(function()
    for _, name in ipairs({ "ai", "ai.config", "ai.providers", "ai.usage", "ai.policy" }) do
      package.loaded[name] = nil
    end
    sent, fail_with = {}, nil
    original_host = vim.env.AI_DESKTOP_HOST
    vim.env.AI_DESKTOP_HOST = nil
  end)

  after_each(function()
    vim.env.AI_DESKTOP_HOST = original_host
    package.loaded["lib.nvim.notify"] = nil
    package.loaded["lib.nvim.net.curl"] = nil
    package.loaded["ai.providers.transport"] = nil
    package.loaded["ai.usage"] = nil
  end)

  describe("switch", function()
    it("off by default: a finished request sends nothing", function()
      configure({})
      register("claude", { ok = true, res = { text = "hi", provider = "claude" } })
      require("ai").ask({ prompt = "q", provider = "claude" }, function() end)
      assert.are.equal(0, #sent)
      assert.is_false(require("ai.usage").enabled())
    end)

    it("report = true: exactly one event per ask, after the callback's result", function()
      configure()
      register("claude", {
        ok = true,
        res = { text = "hi", provider = "claude", usage = { input_tokens = 7, output_tokens = 2 } },
      })
      local got
      require("ai").ask({ prompt = "q", provider = "claude", model = "claude-x" }, function(ok, res)
        got = { ok, res.text }
      end)
      assert.are.same({ true, "hi" }, got)
      assert.are.equal(1, #sent)
      local ev = sent[1].body
      assert.are.equal("claude", ev.provider)
      assert.are.equal("claude-x", ev.model)
      assert.is_false(ev.stream)
      assert.is_true(ev.ok)
      assert.are.equal(7, ev.prompt_tokens)
      assert.are.equal(2, ev.completion_tokens)
      assert.are.equal("number", type(ev.duration_ms))
      assert.is_true(ev.duration_ms >= 0 and ev.duration_ms % 1 == 0)
      assert.is_nil(ev.error_kind)
    end)

    it("the ai_desktop provider is not reported (the server records it itself)", function()
      configure()
      register("ai_desktop", { ok = true, res = { text = "hi", provider = "ai_desktop" } })
      require("ai").ask({ prompt = "q", provider = "ai_desktop" }, function() end)
      assert.are.equal(0, #sent)
    end)
  end)

  describe("token normalization", function()
    local cases = {
      { "claude", { input_tokens = 11, output_tokens = 3 }, 11, 3 },
      { "claude-cli", { input_tokens = 5, output_tokens = 1 }, 5, 1 },
      { "openai", { prompt_tokens = 20, completion_tokens = 4 }, 20, 4 },
      -- the Copilot CLI reports premium requests, not tokens (TESTS/ai/fixtures/fake_copilot.lua)
      { "copilot", { premiumRequests = 1 }, 0, 0 },
      { "gemini", { promptTokenCount = 30, candidatesTokenCount = 6 }, 30, 6 },
      { "ollama", { prompt_eval_count = 9, eval_count = 9 }, 0, 0 },
    }
    for _, case in ipairs(cases) do
      local id, usage_table, want_prompt, want_completion = case[1], case[2], case[3], case[4]
      it(id .. ": reads its own usage fields", function()
        configure()
        register(id, { ok = true, res = { text = "", provider = id, usage = usage_table } })
        require("ai").ask({ prompt = "q", provider = id }, function() end)
        assert.are.equal(1, #sent)
        assert.are.equal(want_prompt, sent[1].body.prompt_tokens)
        assert.are.equal(want_completion, sent[1].body.completion_tokens)
      end)
    end

    it("a missing or malformed count is 0, never negative or fractional", function()
      local usage = require("ai.usage")
      assert.are.same({ 0, 0 }, { usage.tokens("claude", nil) })
      assert.are.same({ 0, 0 }, { usage.tokens("claude", { input_tokens = "7" }) })
      assert.are.same({ 0, 0 }, { usage.tokens("openai", { prompt_tokens = -3 }) })
      assert.are.same({ 2, 0 }, { usage.tokens("openai", { prompt_tokens = 2.9 }) })
      assert.are.same({ 0, 0 }, { usage.tokens("unknown", { prompt_tokens = 4 }) })
    end)
  end)

  describe("failure", function()
    it("ask error: ok = false with the error kind, no tokens, no message", function()
      configure()
      local lib_error = require("lib.lua.error")
      register("openai", {
        ok = false,
        res = lib_error.new("api_error", "openai error: the prompt 'secret' was refused"),
      })
      require("ai").ask({ prompt = "secret", provider = "openai" }, function() end)
      assert.are.equal(1, #sent)
      local ev = sent[1].body
      assert.is_false(ev.ok)
      assert.are.equal("api_error", ev.error_kind)
      assert.are.equal(0, ev.prompt_tokens)
      assert.is_nil(ev.message)
      assert.is_nil(vim.json.encode(ev):find("secret", 1, true))
    end)

    it("a provider that never resolves sends nothing (no request happened)", function()
      configure()
      local ok
      require("ai").ask({ prompt = "q", provider = "no-such-provider" }, function(a)
        ok = a
      end)
      assert.is_false(ok)
      assert.are.equal(0, #sent)
    end)

    it("a sender failure is swallowed and mentioned once per session, at DEBUG", function()
      local levels = {}
      package.loaded["lib.nvim.notify"] = {
        create = function()
          local n = {}
          for _, level in ipairs({ "debug", "info", "warn", "error" }) do
            n[level] = function()
              levels[#levels + 1] = level
            end
          end
          return n
        end,
      }
      configure()
      fail_with = "connection refused"
      register("claude", { ok = true, res = { text = "", provider = "claude" } })
      local results = {}
      for _ = 1, 3 do
        require("ai").ask({ prompt = "q", provider = "claude" }, function(ok)
          results[#results + 1] = ok
        end)
      end
      assert.are.same({ true, true, true }, results)
      assert.are.equal(3, #sent)
      assert.are.same({ "debug" }, levels)
    end)
  end)

  describe("stream", function()
    it("on_done: one event with stream = true", function()
      configure()
      register("gemini", {
        ok = true,
        res = {
          text = "",
          provider = "gemini",
          usage = { promptTokenCount = 3, candidatesTokenCount = 1 },
        },
      })
      local done = 0
      require("ai").stream({ prompt = "q", provider = "gemini", model = "gemini-x" }, {
        on_done = function()
          done = done + 1
        end,
      })
      assert.are.equal(1, done)
      assert.are.equal(1, #sent)
      assert.is_true(sent[1].body.stream)
      assert.is_true(sent[1].body.ok)
      assert.are.equal("gemini-x", sent[1].body.model)
      assert.are.equal(3, sent[1].body.prompt_tokens)
    end)

    it("on_error: ok = false with the kind; the caller's handler still runs", function()
      configure()
      register("claude", {
        ok = false,
        res = require("lib.lua.error").new("timeout", "claude: timed out"),
      })
      local seen
      require("ai").stream({ prompt = "q", provider = "claude" }, {
        on_error = function(err)
          seen = err.kind
        end,
      })
      assert.are.equal("timeout", seen)
      assert.are.equal(1, #sent)
      assert.is_false(sent[1].body.ok)
      assert.are.equal("timeout", sent[1].body.error_kind)
      assert.is_true(sent[1].body.stream)
    end)

    it("a provider whose stream fires on_error and then on_done reports once", function()
      configure()
      require("ai.providers").register({
        id = "flaky",
        available = function()
          return true
        end,
        stream = function(_, handlers)
          handlers.on_error(require("lib.lua.error").new("network_error", "boom"))
          handlers.on_done({ text = "", provider = "flaky" })
          return nil
        end,
      })
      require("ai").stream({ prompt = "q", provider = "flaky" }, {})
      assert.are.equal(1, #sent)
      assert.is_false(sent[1].body.ok)
    end)
  end)

  describe("privacy", function()
    it("the body carries only the allow-listed fields, whatever the result holds", function()
      configure()
      register("claude", {
        ok = true,
        res = {
          text = "the answer text",
          prompt = "the prompt",
          system = "the system prompt",
          messages = { { role = "user", content = "hello" } },
          input = "x",
          output = "y",
          content = "z",
          response = "r",
          provider = "claude",
          usage = { input_tokens = 1, output_tokens = 1, cache_read_input_tokens = 5 },
        },
      })
      require("ai").ask(
        { prompt = "the prompt", system = "the system prompt", provider = "claude" },
        function() end
      )
      assert.are.equal(1, #sent)
      local keys = vim.tbl_keys(sent[1].body)
      table.sort(keys)
      local allowed = {}
      for _, k in ipairs(require("ai.usage").FIELDS) do
        allowed[k] = true
      end
      for _, k in ipairs(keys) do
        assert.is_true(allowed[k] == true, "unexpected field in the usage event: " .. k)
      end
      -- `error_kind` is absent on success; the other seven are always there.
      assert.are.same({
        "completion_tokens",
        "duration_ms",
        "model",
        "ok",
        "prompt_tokens",
        "provider",
        "stream",
      }, keys)
      assert.is_nil(vim.json.encode(sent[1].body):find("the ", 1, true))
    end)

    it("event(): every key comes from FIELDS, even for a result with extra scalars", function()
      local usage = require("ai.usage")
      local ev = usage.event({
        provider = "openai",
        model = "m",
        stream = false,
        ok = false,
        res = { kind = "api_error", message = "quoted prompt here", text = "t" },
        duration_ms = 12.7,
      })
      assert.are.same({
        provider = "openai",
        model = "m",
        stream = false,
        ok = false,
        error_kind = "api_error",
        prompt_tokens = 0,
        completion_tokens = 0,
        duration_ms = 12,
      }, ev)
    end)
  end)

  describe("host", function()
    it(
      "defaults to the ai_desktop provider's host (AI_DESKTOP_HOST), path /usage/events",
      function()
        vim.env.AI_DESKTOP_HOST = "http://10.0.0.5:9090/"
        configure()
        register("claude", { ok = true, res = { text = "", provider = "claude" } })
        require("ai").ask({ prompt = "q", provider = "claude" }, function() end)
        assert.are.equal("http://10.0.0.5:9090/usage/events", sent[1].url)
      end
    )

    it("usage.host wins over the environment", function()
      vim.env.AI_DESKTOP_HOST = "http://10.0.0.5:9090"
      configure({ usage = { report = true, host = "http://localhost:7777" } })
      register("claude", { ok = true, res = { text = "", provider = "claude" } })
      require("ai").ask({ prompt = "q", provider = "claude" }, function() end)
      assert.are.equal("http://localhost:7777/usage/events", sent[1].url)
    end)

    it("without either it is the built-in default", function()
      configure()
      assert.are.equal("http://127.0.0.1:8080", require("ai.usage").host())
    end)
  end)

  describe("config validation", function()
    it(
      "a non-boolean report and a non-string host drop to their defaults, recorded as issues",
      function()
        local cfg = require("ai.config").setup({ usage = { report = "yes", host = 42 } })
        assert.is_false(cfg.usage.report)
        assert.is_false(cfg.usage.host)
        local issues = table.concat(require("ai.config").issues(), "\n")
        assert.is_truthy(issues:find("usage.report", 1, true))
        assert.is_truthy(issues:find("usage.host", 1, true))
      end
    )
  end)

  describe("default sender", function()
    it("posts JSON through ai.providers.transport with a short timeout", function()
      local calls = {}
      package.loaded["ai.providers.transport"] = nil
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(url, opts, cb)
          calls[#calls + 1] = { url = url, opts = opts }
          cb(true, { ok = true })
        end,
      }
      require("ai.config").setup({ usage = { report = true, host = "http://h:1" } })
      local usage = require("ai.usage")
      usage._set_sender(nil) -- the real one
      register("claude", { ok = true, res = { text = "", provider = "claude" } })
      require("ai").ask({ prompt = "q", provider = "claude" }, function() end)
      assert.are.equal(1, #calls)
      assert.are.equal("http://h:1/usage/events", calls[1].url)
      assert.are.equal("POST", calls[1].opts.method)
      assert.are.equal("application/json", calls[1].opts.headers["Content-Type"])
      -- transport adds its grace on top of the reporter's own short timeout
      assert.is_true(calls[1].opts.timeout_ms <= usage.TIMEOUT_MS + 2000)
      local body = vim.json.decode(calls[1].opts.body)
      assert.are.equal("claude", body.provider)
    end)
  end)
end)
