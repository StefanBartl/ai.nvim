-- Test doubles below deliberately implement only the `Ai.Provider` fields
-- each test actually exercises -- see providers_spec.lua's own module doc
-- for why need-check-nil is suppressed alongside it.
---@diagnostic disable: missing-fields, need-check-nil

describe("ai (init) -- context-error propagation into ask/stream (ERR-11)", function()
  local messages
  local original_notify

  before_each(function()
    package.loaded["ai"] = nil
    package.loaded["ai.config"] = nil
    package.loaded["ai.providers"] = nil
    package.loaded["ai.context"] = nil

    messages = {}
    original_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, _level, _opts)
      messages[#messages + 1] = msg
    end

    -- A fake provider, resolved by explicit id (bypasses provider_order,
    -- see providers_spec.lua's "resolve(explicit_id, order) checks that
    -- provider directly" test).
    require("ai.providers").register({
      id = "fake",
      available = function()
        return true
      end,
      ask = function(req, cb)
        cb(true, { text = "ok", provider = "fake", seen_prompt = req.prompt })
      end,
      stream = function(req, handlers)
        if handlers.on_done then
          handlers.on_done({ text = "ok", provider = "fake", seen_prompt = req.prompt })
        end
        return nil
      end,
    })
  end)

  after_each(function()
    package.loaded["lib.nvim.harvest.scope"] = nil
    vim.notify = original_notify
  end)

  ---@internal Force ai.context.assemble() to return an `errors` list, the
  ---same technique context_spec.lua's own "distinguishes a scope that
  ---raises" test uses.
  local function make_scope_raise()
    package.loaded["lib.nvim.harvest.scope"] = {
      resolve = function()
        error("boom: scope API drift")
      end,
    }
  end

  it("ask(): no context requested -- no warning, prompt passed through unchanged", function()
    local ok, res
    require("ai").ask({ prompt = "hi", provider = "fake" }, function(a, b)
      ok, res = a, b
    end)
    assert.is_true(ok)
    assert.are.equal("hi", res.seen_prompt)
    assert.are.equal(0, #messages)
  end)

  it("ask(): a context scope that legitimately resolves to nothing -- no warning", function()
    vim.cmd("enew")
    local ok, res
    require("ai").ask(
      { prompt = "hi", provider = "fake", context = { diagnostics = true } },
      function(a, b)
        ok, res = a, b
      end
    )
    assert.is_true(ok)
    assert.are.equal("hi", res.seen_prompt)
    assert.are.equal(0, #messages)
  end)

  it(
    "ask(): a context scope that raises -- warns distinctly, but still sends the request (ERR-11)",
    function()
      make_scope_raise()
      local ok, res
      require("ai").ask(
        { prompt = "hi", provider = "fake", context = { buffer = true } },
        function(a, b)
          ok, res = a, b
        end
      )
      -- The request itself must still succeed: a best-effort context
      -- section failing must not block it (see ai.completion's own
      -- "silent by design" note for the sibling case this mirrors).
      assert.is_true(ok)
      assert.are.equal("hi", res.seen_prompt)
      -- But the failure must be surfaced, distinctly from "nothing was
      -- there" (which asserts 0 messages above) and distinctly from a
      -- request failure (ok is still true here).
      assert.are.equal(1, #messages)
      assert.truthy(messages[1]:find("context", 1, true) ~= nil)
      assert.truthy(messages[1]:find("boom", 1, true) ~= nil)
    end
  )

  it("stream(): a context scope that raises -- warns, still streams (ERR-11)", function()
    make_scope_raise()
    local done_res
    require("ai").stream({ prompt = "hi", provider = "fake", context = { buffer = true } }, {
      on_done = function(res)
        done_res = res
      end,
    })
    assert.are.equal("hi", done_res.seen_prompt)
    assert.are.equal(1, #messages)
    assert.truthy(messages[1]:find("boom", 1, true) ~= nil)
  end)

  it("does not warn at all when provider resolution itself fails", function()
    local ok, err
    require("ai").ask({ prompt = "hi", provider = "does-not-exist" }, function(a, b)
      ok, err = a, b
    end)
    assert.is_false(ok)
    assert.are.equal("provider_resolution", err.kind)
    assert.are.equal(0, #messages)
  end)
end)
