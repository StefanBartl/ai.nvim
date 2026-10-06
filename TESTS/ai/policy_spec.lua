-- Test doubles implement only the `Ai.Provider` fields each test exercises, same
-- as providers_spec.lua. need-check-nil is suppressed: the test body is the guard.
---@diagnostic disable: missing-fields, need-check-nil

describe("ai.policy", function()
  local function reload()
    for _, name in ipairs({ "ai.config", "ai.policy", "ai.providers", "ai" }) do
      package.loaded[name] = nil
    end
  end

  ---@param id string
  ---@param available? boolean
  local function fake(id, available)
    return {
      id = id,
      available = function()
        return available ~= false
      end,
    }
  end

  ---@param providers table
  ---@param ids string[]
  local function register_all(providers, ids)
    for _, id in ipairs(ids) do
      providers.register(fake(id))
    end
  end

  before_each(reload)
  after_each(reload)

  describe("the allow-list itself", function()
    it("is unrestricted by default: every id is allowed and allowed() is nil", function()
      require("ai.config").setup({})
      local policy = require("ai.policy")
      assert.is_nil(policy.allowed())
      assert.is_false(policy.restricted())
      assert.is_true(policy.is_allowed("gemini"))
      assert.are.equal("no restriction", policy.describe())
    end)

    it("treats an empty allowed list as no restriction", function()
      require("ai.config").setup({ policy = { allowed = {} } })
      assert.is_false(require("ai.policy").restricted())
    end)

    it("restricts to exactly the listed ids", function()
      require("ai.config").setup({ policy = { allowed = { "copilot", "claude" } } })
      local policy = require("ai.policy")
      assert.is_true(policy.restricted())
      assert.is_true(policy.is_allowed("claude"))
      assert.is_true(policy.is_allowed("copilot"))
      assert.is_false(policy.is_allowed("gemini"))
      assert.are.equal("allowed: copilot, claude", policy.describe())
    end)

    it("allowed() returns a copy: changing it changes nothing", function()
      require("ai.config").setup({ policy = { allowed = { "claude" } } })
      local policy = require("ai.policy")
      table.insert(policy.allowed(), "gemini")
      assert.is_false(policy.is_allowed("gemini"))
    end)

    it("does not check ids against the registry: an id may be listed before it exists", function()
      require("ai.config").setup({ policy = { allowed = { "copilot" } } })
      assert.is_true(require("ai.policy").is_allowed("copilot"))
    end)

    it("filter() keeps the order and drops what is not allowed", function()
      require("ai.config").setup({ policy = { allowed = { "gemini", "claude" } } })
      local policy = require("ai.policy")
      assert.are.same({ "claude", "gemini" }, policy.filter({ "claude", "ollama", "gemini" }))
    end)

    it("a request with allow_unlisted passes for any id; without it nothing changes", function()
      require("ai.config").setup({ policy = { allowed = { "claude" } } })
      local policy = require("ai.policy")
      assert.is_true(policy.is_allowed("gemini", { prompt = "x", allow_unlisted = true }))
      assert.is_false(policy.is_allowed("gemini", { prompt = "x" }))
      assert.is_false(policy.is_allowed("gemini", { prompt = "x", allow_unlisted = false }))
    end)

    it("grant() allows an id for the session and reset() takes it back", function()
      require("ai.config").setup({ policy = { allowed = { "claude" } } })
      local policy = require("ai.policy")
      policy.grant("gemini")
      assert.is_true(policy.is_allowed("gemini"))
      assert.is_false(policy.is_listed("gemini"))
      assert.are.same({ "gemini" }, policy.granted())
      policy.reset()
      assert.is_false(policy.is_allowed("gemini"))
      assert.are.same({}, policy.granted())
    end)

    it("granted() does not list an id that is on the allow-list anyway", function()
      require("ai.config").setup({ policy = { allowed = { "claude" } } })
      local policy = require("ai.policy")
      policy.grant("claude")
      assert.are.same({}, policy.granted())
    end)
  end)

  describe("provider resolution", function()
    it("auto skips an available provider that the policy does not allow", function()
      require("ai.config").setup({ policy = { allowed = { "second" } } })
      local providers = require("ai.providers")
      register_all(providers, { "first", "second" })
      local p, err = providers.resolve("auto", { "first", "second" })
      assert.is_nil(err)
      assert.are.equal("second", p.id)
    end)

    it("auto behaves exactly as before without a policy", function()
      require("ai.config").setup({})
      local providers = require("ai.providers")
      register_all(providers, { "first", "second" })
      local p = providers.resolve("auto", { "first", "second" })
      assert.are.equal("first", p.id)
    end)

    it("auto with no allowed provider in the order fails and names the policy", function()
      require("ai.config").setup({ policy = { allowed = { "copilot" } } })
      local providers = require("ai.providers")
      register_all(providers, { "first" })
      local p, err = providers.resolve("auto", { "first" })
      assert.is_nil(p)
      assert.are.equal("provider_resolution", err.kind)
      assert.are.equal("policy", err.data.reason)
      assert.is_truthy(err.message:find("allowed: copilot", 1, true))
    end)

    it("auto lists in the error only the providers it was allowed to check", function()
      require("ai.config").setup({ policy = { allowed = { "second" } } })
      local providers = require("ai.providers")
      providers.register(fake("first", true))
      providers.register(fake("second", false))
      local p, err = providers.resolve("auto", { "first", "second" })
      assert.is_nil(p)
      assert.are.same({ "second" }, err.data.checked)
    end)

    it("an explicit id outside the list is refused before availability is asked", function()
      require("ai.config").setup({ policy = { allowed = { "claude" } } })
      local providers = require("ai.providers")
      local asked = false
      providers.register({
        id = "other",
        available = function()
          asked = true
          return true
        end,
      })
      local p, err = providers.resolve("other", { "other" })
      assert.is_nil(p)
      assert.are.equal("provider_resolution", err.kind)
      assert.are.equal("policy", err.data.reason)
      assert.are.equal("other", err.data.id)
      assert.are.same({ "claude" }, err.data.allowed)
      assert.is_false(asked)
    end)

    it("an explicit id outside the list passes with allow_unlisted", function()
      require("ai.config").setup({ policy = { allowed = { "claude" } } })
      local providers = require("ai.providers")
      register_all(providers, { "other" })
      local p, err = providers.resolve(
        "other",
        { "other" },
        { prompt = "x", allow_unlisted = true }
      )
      assert.is_nil(err)
      assert.are.equal("other", p.id)
    end)

    it("an explicit id outside the list passes after a session grant", function()
      require("ai.config").setup({ policy = { allowed = { "claude" } } })
      local providers = require("ai.providers")
      register_all(providers, { "other" })
      require("ai.policy").grant("other")
      local p = providers.resolve("other", { "other" })
      assert.are.equal("other", p.id)
    end)

    it("a session grant does not widen auto: only the explicit id passes", function()
      require("ai.config").setup({ policy = { allowed = { "second" } } })
      local providers = require("ai.providers")
      register_all(providers, { "first", "second" })
      local policy = require("ai.policy")
      policy.grant("first")
      local p = providers.resolve("auto", { "first", "second" })
      assert.are.equal("second", p.id)
      assert.are.same({ "second" }, policy.filter({ "first", "second" }))
      local named = providers.resolve("first", { "first", "second" })
      assert.are.equal("first", named.id)
    end)

    it("auto with allow_unlisted may walk the whole order", function()
      require("ai.config").setup({ policy = { allowed = { "second" } } })
      local providers = require("ai.providers")
      register_all(providers, { "first", "second" })
      local p = providers.resolve("auto", { "first", "second" }, { allow_unlisted = true })
      assert.are.equal("first", p.id)
    end)

    it("auto that fails only on availability is not tagged as a policy refusal", function()
      require("ai.config").setup({ policy = { allowed = { "first" } } })
      local providers = require("ai.providers")
      providers.register(fake("first", false))
      local p, err = providers.resolve("auto", { "first" })
      assert.is_nil(p)
      assert.are.equal("provider_resolution", err.kind)
      assert.is_nil(err.data.reason)
      assert.is_nil(err.message:find("allowed:", 1, true))
      assert.are.same({ "first" }, err.data.checked)
    end)

    it("an unknown id still reports 'unknown provider', not the policy", function()
      require("ai.config").setup({ policy = { allowed = { "claude" } } })
      local providers = require("ai.providers")
      register_all(providers, { "claude" })
      local _, err = providers.resolve("nope", {})
      assert.is_truthy(err.message:find("unknown provider", 1, true))
    end)
  end)

  describe("require('ai')", function()
    it("ask() fails with provider_resolution for a refused provider and never calls it", function()
      require("ai.config").setup({ policy = { allowed = { "claude" } } })
      local called = false
      require("ai.providers").register({
        id = "other",
        available = function()
          return true
        end,
        ask = function()
          called = true
        end,
      })
      local ok, err
      require("ai").ask({ prompt = "hi", provider = "other" }, function(a, b)
        ok, err = a, b
      end)
      assert.is_false(ok)
      assert.are.equal("provider_resolution", err.kind)
      assert.are.equal("policy", err.data.reason)
      assert.is_false(called)
    end)

    it("ask() reaches the provider when the request says allow_unlisted", function()
      require("ai.config").setup({ policy = { allowed = { "claude" } } })
      require("ai.providers").register({
        id = "other",
        available = function()
          return true
        end,
        ask = function(_, cb)
          cb(true, { text = "ok", provider = "other" })
        end,
      })
      local ok, res
      require("ai").ask({ prompt = "hi", provider = "other", allow_unlisted = true }, function(a, b)
        ok, res = a, b
      end)
      assert.is_true(ok)
      assert.are.equal("other", res.provider)
    end)

    it("stream() reports a refused provider through on_error", function()
      require("ai.config").setup({ policy = { allowed = { "claude" } } })
      register_all(require("ai.providers"), { "other" })
      local err
      require("ai").stream({ prompt = "hi", provider = "other" }, {
        on_error = function(e)
          err = e
        end,
      })
      assert.are.equal("policy", err.data.reason)
    end)

    it("policy() reports the list, the restriction and the session grants, as a copy", function()
      require("ai.config").setup({ policy = { allowed = { "claude" } } })
      require("ai.policy").grant("gemini")
      local p = require("ai").policy()
      assert.is_true(p.restricted)
      assert.are.same({ "claude" }, p.allowed)
      assert.are.same({ "gemini" }, p.granted)
      table.insert(p.allowed, "x")
      assert.are.same({ "claude" }, require("ai").policy().allowed)
    end)

    it("policy() on an unrestricted machine has allowed = nil", function()
      require("ai.config").setup({})
      local p = require("ai").policy()
      assert.is_false(p.restricted)
      assert.is_nil(p.allowed)
    end)
  end)

  describe("config", function()
    local original_notify

    before_each(function()
      original_notify = vim.notify
    end)

    after_each(function()
      vim.notify = original_notify
    end)

    it("accepts policy.allowed without any unknown-key warning", function()
      local warnings = {}
      vim.notify = function(msg)
        warnings[#warnings + 1] = msg
      end
      local config = require("ai.config")
      config.setup({ policy = { allowed = { "copilot", "claude" } } })
      assert.are.same({}, warnings)
      assert.are.same({}, config.issues())
      assert.are.same({ "copilot", "claude" }, config.get().policy.allowed)
    end)

    -- A malformed allow-list must not degrade to the default: the default is
    -- "no restriction", so a typo would switch the machine's rule off.
    for label, malformed in pairs({
      string = "claude",
      number = 5,
      ["a list with a non-string entry"] = { "claude", 5 },
      ["a map instead of a list"] = { claude = true, copilot = true },
      ["a list with a hole"] = { [1] = "claude", [3] = "copilot" },
    }) do
      it(("fails closed on a malformed policy.allowed (%s)"):format(label), function()
        local notices = {}
        vim.notify = function(msg)
          notices[#notices + 1] = msg
        end
        local config = require("ai.config")
        config.setup({ policy = { allowed = malformed } })
        local policy = require("ai.policy")
        assert.is_true(policy.restricted())
        assert.is_false(policy.is_allowed("gemini"))
        assert.is_false(policy.is_allowed("claude"))
        assert.are.equal(1, #config.issues())
        assert.is_truthy(config.issues()[1]:find("policy.allowed", 1, true))
        assert.is_truthy(config.issues()[1]:find("refused", 1, true))
        assert.are.equal(1, #notices)
        assert.is_truthy(notices[1]:find("every provider is refused", 1, true))
      end)
    end

    it("fails closed when policy itself is not a table", function()
      local notices = {}
      vim.notify = function(msg)
        notices[#notices + 1] = msg
      end
      local config = require("ai.config")
      config.setup({ policy = "claude" })
      local policy = require("ai.policy")
      assert.is_true(policy.restricted())
      assert.is_false(policy.is_allowed("claude"))
      assert.are.equal(1, #config.issues())
      assert.are.equal(1, #notices)
    end)

    it("a refused request under a malformed policy.allowed says why", function()
      require("ai.config").setup({ policy = { allowed = { claude = true } } })
      local providers = require("ai.providers")
      register_all(providers, { "claude" })
      local p, err = providers.resolve("claude", { "claude" })
      assert.is_nil(p)
      assert.are.equal("policy", err.data.reason)
      assert.is_truthy(err.message:find("<invalid policy.allowed>", 1, true))
      local _, auto_err = providers.resolve("auto", { "claude" })
      assert.are.equal("policy", auto_err.data.reason)
    end)

    it("an empty or absent policy.allowed is still no restriction, and quiet", function()
      local notices = {}
      vim.notify = function(msg)
        notices[#notices + 1] = msg
      end
      local config = require("ai.config")
      config.setup({ policy = { allowed = {} } })
      assert.is_false(require("ai.policy").restricted())
      config.setup({ policy = {} })
      assert.is_false(require("ai.policy").restricted())
      config.setup({})
      assert.is_false(require("ai.policy").restricted())
      assert.are.same({}, config.issues())
      assert.are.same({}, notices)
    end)

    it("a dict-shaped provider_order degrades to the default like any other bad value", function()
      local config = require("ai.config")
      config.setup({ provider_order = { claude = true } })
      assert.are.same(require("ai.config.DEFAULTS").provider_order, config.get().provider_order)
      assert.are.equal(1, #config.issues())
    end)

    -- A key under `policy` that ai.nvim does not know is a rule that was meant and
    -- is not in force. Ignoring it leaves the default, which is "no restriction", so
    -- it fails closed like a malformed `allowed` does.
    describe("an unknown key under policy", function()
      local notices

      before_each(function()
        notices = {}
        vim.notify = function(msg)
          notices[#notices + 1] = msg
        end
      end)

      it("fails closed: a typo'd allowed refuses every provider", function()
        local config = require("ai.config")
        config.setup({ policy = { alowed = { "claude" } } })
        local policy = require("ai.policy")
        assert.is_true(policy.restricted())
        assert.is_false(policy.is_allowed("claude"))
        assert.is_false(policy.is_allowed("gemini"))
        assert.is_true(policy.is_allowed("gemini", { prompt = "x", allow_unlisted = true }))
      end)

      it("is reported as an issue, naming the key and what happens", function()
        local config = require("ai.config")
        config.setup({ policy = { alowed = { "claude" } } })
        assert.are.equal(1, #config.issues())
        local issue = config.issues()[1]
        assert.is_truthy(issue:find("policy.alowed", 1, true))
        assert.is_truthy(issue:find("unknown", 1, true))
        assert.is_truthy(issue:find("refused", 1, true))
        assert.is_truthy(issue:find("allowed", 1, true), "says what policy does take")
      end)

      it("says so once when setup() runs, not twice", function()
        require("ai.config").setup({ policy = { alowed = { "claude" } } })
        assert.are.equal(1, #notices)
        assert.is_truthy(notices[1]:find("policy.alowed", 1, true))
        assert.is_truthy(notices[1]:find("refused", 1, true))
      end)

      it("fails closed when a list sits directly under policy", function()
        local config = require("ai.config")
        config.setup({ policy = { "claude" } })
        assert.is_false(require("ai.policy").is_allowed("claude"))
        assert.is_truthy(config.issues()[1]:find("policy.1", 1, true))
      end)

      it("beats a valid allowed next to it: nothing is allowed", function()
        local config = require("ai.config")
        config.setup({ policy = { allowed = { "claude" }, denied = { "gemini" } } })
        local policy = require("ai.policy")
        assert.is_true(policy.restricted())
        assert.is_false(policy.is_allowed("claude"))
        assert.are.equal(1, #config.issues())
        assert.is_truthy(config.issues()[1]:find("policy.denied", 1, true))
      end)

      it("names every unknown key, in a stable order", function()
        local config = require("ai.config")
        config.setup({ policy = { zeta = true, alowed = {} } })
        local issue = table.concat(config.issues(), "\n")
        local first = issue:find("policy.alowed", 1, true)
        local second = issue:find("policy.zeta", 1, true)
        assert.is_truthy(first)
        assert.is_truthy(second)
        assert.is_true(first < second)
      end)

      it("keeps the malformed-allowed report as well when both are wrong", function()
        local config = require("ai.config")
        config.setup({ policy = { allowed = "claude", alowed = {} } })
        local text = table.concat(config.issues(), "\n")
        assert.are.equal(2, #config.issues())
        assert.is_truthy(text:find("policy.allowed: invalid value", 1, true))
        assert.is_truthy(text:find("policy.alowed", 1, true))
        assert.is_false(require("ai.policy").is_allowed("claude"))
      end)

      it("makes a refused request say why", function()
        require("ai.config").setup({ policy = { alowed = { "claude" } } })
        local providers = require("ai.providers")
        register_all(providers, { "claude" })
        local p, err = providers.resolve("claude", { "claude" })
        assert.is_nil(p)
        assert.are.equal("policy", err.data.reason)
        assert.is_truthy(err.message:find("<unknown policy key>", 1, true), err.message)
        local _, auto_err = providers.resolve("auto", { "claude" })
        assert.are.equal("policy", auto_err.data.reason)
      end)

      it("stays in force on a second setup() with the same, untouched options", function()
        local config = require("ai.config")
        local opts = { policy = { alowed = { "claude" } } }
        config.setup(opts)
        assert.are.same({ policy = { alowed = { "claude" } } }, opts, "the caller's table is kept")
        config.setup(opts)
        assert.are.equal(1, #config.issues(), "reported again, not lost")
        assert.is_false(require("ai.policy").is_allowed("claude"))
      end)

      it("does not affect a policy that only has the known key, nor an empty one", function()
        local config = require("ai.config")
        config.setup({ policy = { allowed = { "claude" } } })
        assert.is_true(require("ai.policy").is_allowed("claude"))
        assert.are.same({}, config.issues())
        config.setup({ policy = {} })
        assert.is_false(require("ai.policy").restricted())
        assert.are.same({}, config.issues())
        assert.are.same({}, notices)
      end)

      it("is still a plain warning for an unknown key anywhere else", function()
        local config = require("ai.config")
        config.setup({ ui = { panel_them = "double" } })
        assert.are.equal(1, #notices)
        assert.is_truthy(notices[1]:find("ui.panel_them", 1, true))
        assert.is_false(require("ai.policy").restricted())
        assert.are.same({}, config.issues())
      end)
    end)
  end)

  describe(":Ai provider and :Ai info", function()
    local notices, popup_lines, confirm_answer, confirm_calls
    local saved_kit, saved_notify

    before_each(function()
      notices, popup_lines, confirm_calls = {}, nil, {}
      saved_kit = package.loaded["ui.kit"]
      saved_notify = package.loaded["lib.nvim.notify"]
      package.loaded["ui.kit"] = {
        -- ui.kit's custom-choices contract: the chosen label, or nil on cancel.
        confirm = function(opts)
          confirm_calls[#confirm_calls + 1] = opts
          opts.on_answer(confirm_answer)
        end,
        popup = function(opts)
          popup_lines = opts.lines
        end,
      }
      package.loaded["lib.nvim.notify"] = {
        create = function()
          return {
            info = function(m)
              notices[#notices + 1] = "info: " .. m
            end,
            warn = function(m)
              notices[#notices + 1] = "warn: " .. m
            end,
          }
        end,
      }
      package.loaded["ai.bindings.actions"] = nil
    end)

    after_each(function()
      package.loaded["ui.kit"] = saved_kit
      package.loaded["lib.nvim.notify"] = saved_notify
      package.loaded["ai.bindings.actions"] = nil
    end)

    it("sets a listed provider at once, without asking", function()
      confirm_answer = nil
      local config = require("ai.config")
      config.setup({ policy = { allowed = { "claude", "copilot" } } })
      require("ai.bindings.actions").set_provider("copilot")
      assert.are.equal("copilot", config.get().provider)
      assert.are.same({ "info: provider set to copilot" }, notices)
    end)

    it("sets any provider at once when there is no allow-list", function()
      local config = require("ai.config")
      config.setup({})
      require("ai.bindings.actions").set_provider("gemini")
      assert.are.equal("gemini", config.get().provider)
    end)

    it("asks before switching to an unlisted provider and grants it only on yes", function()
      confirm_answer = "Yes"
      local config = require("ai.config")
      config.setup({ provider = "claude", policy = { allowed = { "claude" } } })
      require("ai.bindings.actions").set_provider("gemini")
      assert.are.equal("gemini", config.get().provider)
      assert.is_true(require("ai.policy").is_allowed("gemini"))
      assert.is_truthy(notices[1]:find("this session only", 1, true))
    end)

    it("leaves everything unchanged when the confirmation is declined", function()
      confirm_answer = "No"
      local config = require("ai.config")
      config.setup({ provider = "claude", policy = { allowed = { "claude" } } })
      require("ai.bindings.actions").set_provider("gemini")
      assert.are.equal("claude", config.get().provider)
      assert.is_false(require("ai.policy").is_allowed("gemini"))
      assert.are.same({ "warn: provider unchanged" }, notices)
    end)

    it("treats a cancelled dialog (<Esc>, q, no answer) as declined", function()
      confirm_answer = nil
      local config = require("ai.config")
      config.setup({ provider = "claude", policy = { allowed = { "claude" } } })
      require("ai.bindings.actions").set_provider("gemini")
      assert.are.equal("claude", config.get().provider)
      assert.is_false(require("ai.policy").is_allowed("gemini"))
      assert.are.same({ "warn: provider unchanged" }, notices)
    end)

    it("sets auto at once on a restricted machine: it is no provider id to confirm", function()
      confirm_answer = "No"
      local config = require("ai.config")
      config.setup({ provider = "claude", policy = { allowed = { "claude" } } })
      require("ai.bindings.actions").set_provider("auto")
      assert.are.equal("auto", config.get().provider)
      assert.are.equal(0, #confirm_calls)
      -- not reported as a provider outside the list, and nothing granted for it
      assert.are.same({ "info: provider set to auto" }, notices)
      assert.are.same({}, require("ai.policy").granted())
    end)

    it("still walks only the listed providers once auto is set", function()
      confirm_answer = nil
      local config = require("ai.config")
      config.setup({
        provider = "claude",
        provider_order = { "gemini", "claude" },
        policy = { allowed = { "claude" } },
      })
      local providers = require("ai.providers")
      register_all(providers, { "claude", "gemini" })
      require("ai.bindings.actions").set_provider("auto")
      local p = providers.resolve(config.get().provider, config.get().provider_order)
      assert.are.equal("claude", p.id)
    end)

    it("opens the confirmation on 'No', so a stray <CR> declines", function()
      confirm_answer = "No"
      require("ai.config").setup({ provider = "claude", policy = { allowed = { "claude" } } })
      require("ai.bindings.actions").set_provider("gemini")
      assert.are.equal(1, #confirm_calls)
      assert.are.same({ "No", "Yes" }, confirm_calls[1].choices)
    end)

    it("does not ask again for a provider already granted in this session", function()
      confirm_answer = "Yes"
      local config = require("ai.config")
      config.setup({ provider = "claude", policy = { allowed = { "claude" } } })
      local actions = require("ai.bindings.actions")
      actions.set_provider("gemini")
      actions.set_provider("claude")
      actions.set_provider("gemini")
      assert.are.equal(1, #confirm_calls)
      assert.are.equal("gemini", config.get().provider)
      assert.is_truthy(notices[#notices]:find("this session only", 1, true))
    end)

    it("info shows the policy and marks providers outside it", function()
      local config = require("ai.config")
      config.setup({ policy = { allowed = { "claude" } } })
      local providers = require("ai.providers")
      register_all(providers, { "claude", "gemini" })
      require("ai.bindings.actions").info()
      local text = table.concat(popup_lines, "\n")
      assert.is_truthy(text:find("policy: allowed: claude", 1, true))
      assert.is_truthy(text:find("gemini: available [not allowed]", 1, true))
      assert.is_nil(text:find("claude: available [", 1, true))
    end)

    it("info says there is no restriction when there is no allow-list", function()
      require("ai.config").setup({})
      require("ai.bindings.actions").info()
      assert.is_truthy(table.concat(popup_lines, "\n"):find("policy: no restriction", 1, true))
    end)
  end)

  describe(":checkhealth", function()
    local report, saved

    before_each(function()
      report = {}
      saved = {}
      for _, fn in ipairs({ "start", "ok", "info", "warn", "error" }) do
        saved[fn] = vim.health[fn]
        vim.health[fn] = function(msg)
          report[#report + 1] = fn .. ": " .. tostring(msg)
        end
      end
    end)

    after_each(function()
      for fn, original in pairs(saved) do
        vim.health[fn] = original
      end
    end)

    ---@param needle string
    ---@return boolean
    local function reported(needle)
      for _, line in ipairs(report) do
        if line:find(needle, 1, true) then
          return true
        end
      end
      return false
    end

    it("says there is no allow-list on an unrestricted machine", function()
      require("ai.config").setup({})
      package.loaded["ai.health"] = nil
      require("ai.health").check()
      assert.is_true(reported("no allow-list"))
    end)

    it("does not call a session-granted provider refused", function()
      require("ai.config").setup({
        provider = "gemini",
        completion = { provider = "gemini" },
        policy = { allowed = { "claude" } },
      })
      require("ai.policy").grant("gemini")
      package.loaded["ai.health"] = nil
      require("ai.health").check()
      assert.is_false(reported('provider = "gemini" is not on the allow-list'))
      assert.is_false(reported('completion.provider = "gemini" is not on the allow-list'))
      assert.is_true(reported("gemini: allowed for this session outside the allow-list"))
    end)

    it("reports a malformed policy.allowed as an error, not as an allow-list", function()
      local original_notify = vim.notify
      vim.notify = function() end
      require("ai.config").setup({ policy = { allowed = "claude" } })
      vim.notify = original_notify
      package.loaded["ai.health"] = nil
      require("ai.health").check()
      assert.is_true(reported("error: config.policy.allowed is malformed"))
      assert.is_true(reported("warn: policy.allowed: invalid value"))
      assert.is_false(reported("<invalid policy.allowed>: listed"))
    end)

    it("reports an unknown key under policy as an error that names the cause", function()
      local original_notify = vim.notify
      vim.notify = function() end
      require("ai.config").setup({ policy = { alowed = { "claude" } } })
      vim.notify = original_notify
      package.loaded["ai.health"] = nil
      require("ai.health").check()
      assert.is_true(reported("error: config.policy has a key ai.nvim does not know"))
      assert.is_true(reported("warn: policy.alowed: unknown key"))
      assert.is_false(reported("config.policy.allowed is malformed"))
      assert.is_false(reported("<unknown policy key>: listed"))
    end)

    it(
      "warns when provider, completion.provider or the auto order fall outside the list",
      function()
        require("ai.config").setup({
          provider = "gemini",
          provider_order = { "gemini" },
          completion = { provider = "ollama" },
          policy = { allowed = { "claude", "copilot" } },
        })
        package.loaded["ai.health"] = nil
        require("ai.health").check()
        assert.is_true(reported('provider = "gemini" is not on the allow-list'))
        assert.is_true(reported('completion.provider = "ollama" is not on the allow-list'))
        assert.is_true(reported("provider_order shares no entry with the allow-list"))
        assert.is_true(reported("copilot: listed, but no provider with that id is registered"))
      end
    )
  end)
end)
