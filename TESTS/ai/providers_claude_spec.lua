-- `lib.nvim.net.curl` is stubbed via `package.loaded` before each
-- `require("ai.providers.claude")` -- the module captures `curl` as a local
-- upvalue at require-time, so the stub must be in place first and the
-- module itself must be re-required fresh each time (see `before_each`).
--
-- The test body itself is the guard against a nil field (busted fails loudly
-- on an actual nil-index error), so per-line need-check-nil noise on the
-- stub tables/responses built above is suppressed file-wide.
---@diagnostic disable: need-check-nil
describe("ai.providers.claude", function()
  local original_key

  before_each(function()
    original_key = vim.env.ANTHROPIC_API_KEY
    vim.env.ANTHROPIC_API_KEY = "test-key"
    package.loaded["ai.providers.claude"] = nil
  end)

  after_each(function()
    vim.env.ANTHROPIC_API_KEY = original_key
    package.loaded["lib.nvim.net.curl"] = nil
    package.loaded["ai.providers.claude"] = nil
  end)

  describe("ask", function()
    it("maps a successful Messages API response to Ai.Response", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, _, cb)
          cb(true, {
            content = { { type = "text", text = "hello" } },
            usage = { input_tokens = 1, output_tokens = 2 },
            stop_reason = "end_turn",
          })
        end,
      }
      local claude = require("ai.providers.claude")
      local ok, res
      claude.ask({ prompt = "hi" }, function(a, b)
        ok, res = a, b
      end)
      assert.is_true(ok)
      assert.are.equal("hello", res.text)
      assert.are.equal("claude", res.provider)
      assert.are.equal("end_turn", res.stop_reason)
    end)

    it("concatenates multiple text content blocks", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, _, cb)
          cb(true, { content = { { type = "text", text = "a" }, { type = "text", text = "b" } } })
        end,
      }
      local claude = require("ai.providers.claude")
      local res
      claude.ask({ prompt = "hi" }, function(_, r)
        res = r
      end)
      assert.are.equal("ab", res.text)
    end)

    it("reports a Messages API error body as a failure", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, _, cb)
          cb(true, { type = "error", error = { message = "overloaded" } })
        end,
      }
      local claude = require("ai.providers.claude")
      local ok, err
      claude.ask({ prompt = "hi" }, function(a, b)
        ok, err = a, b
      end)
      assert.is_false(ok)
      assert.are.equal("api_error", err.kind)
      assert.is_true(err.message:find("overloaded", 1, true) ~= nil)
    end)

    it("fails without calling curl when ANTHROPIC_API_KEY is unset", function()
      vim.env.ANTHROPIC_API_KEY = nil
      local called = false
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function()
          called = true
        end,
      }
      local claude = require("ai.providers.claude")
      local ok, err
      claude.ask({ prompt = "hi" }, function(a, b)
        ok, err = a, b
      end)
      assert.is_false(ok)
      assert.is_false(called)
      assert.are.equal("missing_api_key", err.kind)
      assert.is_true(err.message:find("ANTHROPIC_API_KEY", 1, true) ~= nil)
    end)
  end)

  describe("stream", function()
    it("accumulates content_block_delta text and reports it on_done", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_stream = function(_, _, handlers)
          handlers.on_chunk(
            'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"He"}}'
          )
          handlers.on_chunk(
            'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"llo"}}'
          )
          handlers.on_chunk(
            'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}'
          )
          handlers.on_done({ code = 0, signal = 0, stdout = "", stderr = "" })
        end,
      }
      local claude = require("ai.providers.claude")
      local chunks, done_res = {}, nil
      claude.stream({ prompt = "hi" }, {
        on_chunk = function(d)
          chunks[#chunks + 1] = d
        end,
        on_done = function(r)
          done_res = r
        end,
      })
      assert.are.same({ "He", "llo" }, chunks)
      assert.are.equal("Hello", done_res.text)
      assert.are.equal("end_turn", done_res.stop_reason)
    end)

    it("recovers a fatal error that arrives as a plain, non-SSE JSON body", function()
      -- Anthropic prints a pretty-printed JSON error body one line at a
      -- time, with no `data:` prefix -- see ai.providers.sse's module doc.
      package.loaded["lib.nvim.net.curl"] = {
        fetch_stream = function(_, _, handlers)
          for _, line in ipairs({
            "{",
            '  "type": "error",',
            '  "error": {"message": "invalid x-api-key"}',
            "}",
          }) do
            handlers.on_chunk(line)
          end
          handlers.on_done({ code = 0, signal = 0, stdout = "", stderr = "" })
        end,
      }
      local claude = require("ai.providers.claude")
      local err
      claude.stream({ prompt = "hi" }, {
        on_error = function(e)
          err = e
        end,
      })
      assert.are.equal("api_error", err.kind)
      assert.is_true(err.message:find("invalid x%-api%-key") ~= nil)
    end)

    it("reports a non-zero curl exit as on_error", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_stream = function(_, _, handlers)
          handlers.on_done({ code = 7, signal = 0, stdout = "", stderr = "connection refused" })
        end,
      }
      local claude = require("ai.providers.claude")
      local err
      claude.stream({ prompt = "hi" }, {
        on_error = function(e)
          err = e
        end,
      })
      assert.are.equal("network_error", err.kind)
      assert.is_true(err.message:find("curl exited 7", 1, true) ~= nil)
    end)
  end)
end)
