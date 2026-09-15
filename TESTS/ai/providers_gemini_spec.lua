-- Same `package.loaded` stubbing approach as providers_claude_spec.lua --
-- see that file's module doc for why the stub must land before each fresh
-- `require("ai.providers.gemini")`.
--
-- Same need-check-nil suppression reasoning as that file: the test body
-- itself is the guard.
---@diagnostic disable: need-check-nil
describe("ai.providers.gemini", function()
  local original_key

  before_each(function()
    original_key = vim.env.GEMINI_API_KEY
    vim.env.GEMINI_API_KEY = "test-key"
    package.loaded["ai.providers.gemini"] = nil
  end)

  after_each(function()
    vim.env.GEMINI_API_KEY = original_key
    package.loaded["lib.nvim.net.curl"] = nil
    package.loaded["ai.providers.gemini"] = nil
  end)

  describe("ask", function()
    it("rejects a model name outside the allowed charset without calling curl", function()
      -- MODEL_PATTERN guards against a `/` reaching the request URL's path
      -- (gemini.lua's own module doc: the model is interpolated straight
      -- into the URL, unlike claude.lua/openai.lua's JSON body field).
      local called = false
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function()
          called = true
        end,
      }
      local gemini = require("ai.providers.gemini")
      local ok, err
      gemini.ask({ prompt = "hi", model = "gemini-pro/../admin" }, function(a, b)
        ok, err = a, b
      end)
      assert.is_false(ok)
      assert.is_false(called)
      assert.are.equal("invalid_request", err.kind)
      assert.is_true(err.message:find("invalid model name", 1, true) ~= nil)
    end)

    it("maps a successful GenerateContentResponse to Ai.Response", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, _, cb)
          cb(true, {
            candidates = {
              {
                content = { parts = { { text = "hi " }, { text = "there" } } },
                finishReason = "STOP",
              },
            },
            usageMetadata = { totalTokenCount = 3 },
          })
        end,
      }
      local gemini = require("ai.providers.gemini")
      local res
      gemini.ask({ prompt = "hi" }, function(_, r)
        res = r
      end)
      assert.are.equal("hi there", res.text)
      assert.are.equal("STOP", res.stop_reason)
    end)

    it("reports a promptFeedback.blockReason with no candidates as a failure", function()
      -- Gemini's safety-block response is a normal 200 with no `error`
      -- field -- see gemini.lua's own module doc for why candidate_text()
      -- alone would silently look like an empty-but-successful answer here.
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, _, cb)
          cb(true, { promptFeedback = { blockReason = "SAFETY" } })
        end,
      }
      local gemini = require("ai.providers.gemini")
      local ok, err
      gemini.ask({ prompt = "hi" }, function(a, b)
        ok, err = a, b
      end)
      assert.is_false(ok)
      assert.are.equal("blocked", err.kind)
      assert.is_true(err.message:find("SAFETY", 1, true) ~= nil)
    end)

    it("reports an API error body as a failure", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, _, cb)
          cb(true, { error = { message = "quota exceeded" } })
        end,
      }
      local gemini = require("ai.providers.gemini")
      local ok, err
      gemini.ask({ prompt = "hi" }, function(a, b)
        ok, err = a, b
      end)
      assert.is_false(ok)
      assert.are.equal("api_error", err.kind)
      assert.is_true(err.message:find("quota exceeded", 1, true) ~= nil)
    end)
  end)

  describe("stream", function()
    it("accumulates candidate text deltas and reports the final response on_done", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_stream = function(_, _, handlers)
          handlers.on_chunk('data: {"candidates":[{"content":{"parts":[{"text":"He"}]}}]}')
          handlers.on_chunk(
            'data: {"candidates":[{"content":{"parts":[{"text":"llo"}]},"finishReason":"STOP"}]}'
          )
          handlers.on_done({ code = 0, signal = 0, stdout = "", stderr = "" })
        end,
      }
      local gemini = require("ai.providers.gemini")
      local chunks, done_res = {}, nil
      gemini.stream({ prompt = "hi" }, {
        on_chunk = function(d)
          chunks[#chunks + 1] = d
        end,
        on_done = function(r)
          done_res = r
        end,
      })
      assert.are.same({ "He", "llo" }, chunks)
      assert.are.equal("Hello", done_res.text)
      assert.are.equal("STOP", done_res.stop_reason)
    end)

    it("reports a mid-stream safety block and suppresses the later on_done", function()
      local done_called = false
      package.loaded["lib.nvim.net.curl"] = {
        fetch_stream = function(_, _, handlers)
          handlers.on_chunk('data: {"promptFeedback":{"blockReason":"SAFETY"}}')
          handlers.on_done({ code = 0, signal = 0, stdout = "", stderr = "" })
        end,
      }
      local gemini = require("ai.providers.gemini")
      local err
      gemini.stream({ prompt = "hi" }, {
        on_error = function(e)
          err = e
        end,
        on_done = function()
          done_called = true
        end,
      })
      assert.are.equal("blocked", err.kind)
      assert.is_true(err.message:find("SAFETY", 1, true) ~= nil)
      assert.is_false(done_called)
    end)
  end)
end)
