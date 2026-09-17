-- Test doubles below deliberately implement only the `Ai.Provider` fields
-- each test actually exercises (usually just `id`/`available`) -- the
-- registry itself never calls `ask`/`stream`, so completing them would only
-- add noise, not coverage. need-check-nil is suppressed too: the test body
-- itself is the guard against a nil field.
---@diagnostic disable: missing-fields, need-check-nil

describe("ai.providers", function()
  local lib_error = require("lib.lua.error")

  before_each(function()
    -- Every test gets a fresh registry (module-local `registered` table),
    -- so a fake provider registered in one test never leaks into the next.
    package.loaded["ai.providers"] = nil
  end)

  it("register/get round-trip a custom provider", function()
    local providers = require("ai.providers")
    providers.register({
      id = "fake",
      available = function()
        return true
      end,
    })
    assert.are.equal("fake", providers.get("fake").id)
  end)

  it("register overrides a previous registration under the same id", function()
    local providers = require("ai.providers")
    providers.register({ id = "fake", name = "first" })
    providers.register({ id = "fake", name = "second" })
    assert.are.equal("second", providers.get("fake").name)
  end)

  it("register rejects a provider with no string id", function()
    local providers = require("ai.providers")
    assert.has_error(function()
      providers.register({})
    end)
  end)

  it("ids() lists every registered provider, sorted", function()
    local providers = require("ai.providers")
    providers.register({ id = "zeta" })
    providers.register({ id = "alpha" })
    assert.are.same({ "alpha", "zeta" }, providers.ids())
  end)

  it("resolve('auto', order) returns the first available provider in order", function()
    local providers = require("ai.providers")
    providers.register({
      id = "unavailable",
      available = function()
        return false
      end,
    })
    providers.register({
      id = "available",
      available = function()
        return true
      end,
    })
    local p, err = providers.resolve("auto", { "unavailable", "available" })
    assert.is_nil(err)
    assert.are.equal("available", p.id)
  end)

  it("resolve('auto', order) errors when nothing in order is available", function()
    local providers = require("ai.providers")
    providers.register({
      id = "nope",
      available = function()
        return false
      end,
    })
    local p, err = providers.resolve("auto", { "nope" })
    assert.is_nil(p)
    assert.is_true(lib_error.is(err))
    assert.are.equal("provider_resolution", err.kind)
  end)

  it("resolve(explicit_id, order) checks that provider directly, ignoring order", function()
    local providers = require("ai.providers")
    providers.register({
      id = "direct",
      available = function()
        return true
      end,
    })
    local p, err = providers.resolve("direct", {})
    assert.is_nil(err)
    assert.are.equal("direct", p.id)
  end)

  it("resolve(explicit_id) errors for an unregistered id", function()
    local providers = require("ai.providers")
    local p, err = providers.resolve("does-not-exist", {})
    assert.is_nil(p)
    assert.is_true(lib_error.is(err))
    assert.are.equal("provider_resolution", err.kind)
  end)

  it("resolve(explicit_id) errors when that provider is registered but unavailable", function()
    local providers = require("ai.providers")
    providers.register({
      id = "down",
      available = function()
        return false
      end,
    })
    local p, err = providers.resolve("down", {})
    assert.is_nil(p)
    assert.is_true(lib_error.is(err))
    assert.are.equal("provider_resolution", err.kind)
  end)

  it(
    "resolve(explicit_id) treats a provider with no .available field as unavailable, not a crash",
    function()
      -- Stands in for a lazy proxy whose module failed to require(): every
      -- field, including `available`, comes back nil (see providers/init.lua's
      -- `make_lazy`). resolve() must not call a nil field.
      local providers = require("ai.providers")
      providers.register({ id = "broken" })
      local p, err = providers.resolve("broken", {})
      assert.is_nil(p)
      assert.is_true(lib_error.is(err))
      assert.are.equal("provider_resolution", err.kind)
    end
  )

  it(
    "resolve('auto', order) skips a provider with no .available field instead of crashing",
    function()
      local providers = require("ai.providers")
      providers.register({ id = "broken" })
      providers.register({
        id = "fine",
        available = function()
          return true
        end,
      })
      local p, err = providers.resolve("auto", { "broken", "fine" })
      assert.is_nil(err)
      assert.are.equal("fine", p.id)
    end
  )

  it("load_builtin() registers all five built-ins, including gemini and loomai", function()
    local providers = require("ai.providers")
    providers.load_builtin()
    assert.are.same({ "claude", "gemini", "loomai", "ollama", "openai" }, providers.ids())
  end)

  it("'auto' never reaches a provider absent from order, even if registered", function()
    local providers = require("ai.providers")
    -- A provider present in the registry but never listed in provider_order
    -- (a custom one a caller registers, or a built-in before it is added to
    -- DEFAULTS.lua) -- ai.providers's whole point is that "auto" cannot
    -- reach it by accident.
    providers.register({
      id = "sidelined",
      available = function()
        return true
      end,
    })
    local p, err = providers.resolve("auto", { "does-not-exist-either" })
    assert.is_nil(p)
    assert.is_true(lib_error.is(err))
    assert.are.equal("provider_resolution", err.kind)
  end)
  describe("bootstrapping the built-ins", function()
    it("registers them on the first resolve, without setup() having run", function()
      -- `load_builtin()` normally runs from `ai.setup()`. ai.nvim is also a
      -- library another plugin calls into -- pdfport.nvim's claude/ollama
      -- extraction backends go through `require("ai").ask()` -- and that
      -- plugin cannot require its users to have called `ai.setup()` first.
      local providers = require("ai.providers")
      assert.are.same({}, providers.ids())

      local _, err = providers.resolve("claude", {})
      -- Whether claude is *available* depends on the machine; what matters
      -- is that it is no longer an unknown id.
      if err then
        assert.is_true(err.message:find("not available", 1, true) ~= nil)
        assert.is_true(err.message:find("unknown provider", 1, true) == nil)
      end
      assert.is_not_nil(providers.get("claude"))
      assert.is_not_nil(providers.get("ollama"))
    end)

    it("does not re-register once a custom provider is present", function()
      -- An empty registry is the only signal "setup() never ran"; a registry
      -- holding a caller's own provider must be left exactly as it is.
      local providers = require("ai.providers")
      providers.register({
        id = "fake",
        available = function()
          return true
        end,
      })
      providers.resolve("fake", {})
      assert.are.same({ "fake" }, providers.ids())
    end)
  end)
  it("passes the request being resolved to each candidate's available()", function()
    -- `Ai.Provider.available` takes the request so a provider whose
    -- availability depends on a credential can see `req.api_key`, not only
    -- its own env var.
    local providers = require("ai.providers")
    local seen
    providers.register({
      id = "fake",
      available = function(req)
        seen = req
        return true
      end,
    })
    local req = { prompt = "hi", api_key = "k" }
    providers.resolve("fake", {}, req)
    assert.are.equal(req, seen)
  end)

  it("still works for a provider whose available() ignores the argument", function()
    -- Every pre-existing implementation is `function() ... end`; passing an
    -- argument to it must stay harmless.
    local providers = require("ai.providers")
    providers.register({
      id = "fake",
      available = function()
        return true
      end,
    })
    local p = providers.resolve("fake", {}, { prompt = "hi" })
    assert.are.equal("fake", p.id)
  end)
end)
