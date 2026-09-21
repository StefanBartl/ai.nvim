-- Same `package.loaded` stubbing approach as providers_claude_spec.lua --
-- see that file's module doc for why the stub must land before each fresh
-- `require("ai.providers.loomai")`.
--
-- Same need-check-nil suppression reasoning as that file: the test body
-- itself is the guard.
---@diagnostic disable: need-check-nil
describe("ai.providers.loomai", function()
  local original_host

  before_each(function()
    original_host = vim.env.LOOMAI_HOST
    vim.env.LOOMAI_HOST = nil
    package.loaded["ai.providers.loomai"] = nil
    -- `ai.providers.transport` sits between this provider and
    -- `lib.nvim.net.curl` and captures `curl` as its own require-time
    -- upvalue too, so it has to be dropped alongside the provider --
    -- otherwise the second test in this file runs against the first's stub.
    package.loaded["ai.providers.transport"] = nil
  end)

  after_each(function()
    vim.env.LOOMAI_HOST = original_host
    package.loaded["lib.nvim.net.curl"] = nil
    package.loaded["ai.providers.loomai"] = nil
    package.loaded["ai.providers.transport"] = nil
  end)

  describe("ask", function()
    it("maps a successful /ask response to Ai.Response", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, _, cb)
          cb(true, { text = "hello", usage = { total_tokens = 3 }, stop_reason = "end" })
        end,
      }
      local loomai = require("ai.providers.loomai")
      local ok, res
      loomai.ask({ prompt = "hi" }, function(a, b)
        ok, res = a, b
      end)
      assert.is_true(ok)
      assert.are.equal("hello", res.text)
      assert.are.equal("loomai", res.provider)
      assert.are.equal("end", res.stop_reason)
    end)

    it("reports a table {message=...} error as a failure", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, _, cb)
          cb(true, { error = { message = "queue full" } })
        end,
      }
      local loomai = require("ai.providers.loomai")
      local ok, err
      loomai.ask({ prompt = "hi" }, function(a, b)
        ok, err = a, b
      end)
      assert.is_false(ok)
      assert.are.equal("api_error", err.kind)
      assert.is_true(err.message:find("queue full", 1, true) ~= nil)
    end)

    it("reports a bare string error as a failure too", function()
      -- loomai.lua's own `data.error` check accepts either shape -- see the
      -- `type(data.error) == "table" and data.error.message or data.error`
      -- fallback in the source.
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, _, cb)
          cb(true, { error = "malformed request" })
        end,
      }
      local loomai = require("ai.providers.loomai")
      local ok, err
      loomai.ask({ prompt = "hi" }, function(a, b)
        ok, err = a, b
      end)
      assert.is_false(ok)
      assert.are.equal("api_error", err.kind)
      assert.is_true(err.message:find("malformed request", 1, true) ~= nil)
    end)

    it("fails with invalid_response rather than raising on a non-object 200", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, _, cb)
          cb(true, 42, { code = 0 })
        end,
      }
      local loomai = require("ai.providers.loomai")
      local ok, err
      local raised = not pcall(function()
        loomai.ask({ prompt = "hi" }, function(a, b)
          ok, err = a, b
        end)
      end)
      assert.is_false(raised)
      assert.is_false(ok)
      assert.are.equal("invalid_response", err.kind)
    end)

    it("rejects any attachment -- loomAI's /ask contract has no payload field for one", function()
      local called = false
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function()
          called = true
        end,
      }
      local loomai = require("ai.providers.loomai")
      local ok, err
      loomai.ask({
        prompt = "hi",
        attachments = { { kind = "image", media_type = "image/png", data = "AAA" } },
      }, function(a, b)
        ok, err = a, b
      end)
      assert.is_false(ok)
      assert.is_false(called)
      assert.are.equal("invalid_request", err.kind)
    end)
  end)

  describe("stream", function()
    it("accumulates delta text and reports the final response on_done", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_stream = function(_, _, handlers)
          handlers.on_chunk('data: {"delta":"He"}')
          handlers.on_chunk('data: {"delta":"llo"}')
          handlers.on_done({ code = 0, signal = 0, stdout = "", stderr = "" })
        end,
      }
      local loomai = require("ai.providers.loomai")
      local chunks, done_res = {}, nil
      loomai.stream({ prompt = "hi" }, {
        on_chunk = function(d)
          chunks[#chunks + 1] = d
        end,
        on_done = function(r)
          done_res = r
        end,
      })
      assert.are.same({ "He", "llo" }, chunks)
      assert.are.equal("Hello", done_res.text)
    end)

    it("reports a mid-stream error event as on_error", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_stream = function(_, _, handlers)
          handlers.on_chunk('data: {"error":{"message":"server crashed"}}')
          handlers.on_done({ code = 0, signal = 0, stdout = "", stderr = "" })
        end,
      }
      local loomai = require("ai.providers.loomai")
      local err
      loomai.stream({ prompt = "hi" }, {
        on_error = function(e)
          err = e
        end,
      })
      assert.are.equal("api_error", err.kind)
      assert.is_true(err.message:find("server crashed", 1, true) ~= nil)
    end)

    it("reports a non-zero curl exit as on_error", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_stream = function(_, _, handlers)
          handlers.on_done({ code = 7, signal = 0, stdout = "", stderr = "connection refused" })
        end,
      }
      local loomai = require("ai.providers.loomai")
      local err
      loomai.stream({ prompt = "hi" }, {
        on_error = function(e)
          err = e
        end,
      })
      assert.are.equal("network_error", err.kind)
    end)

    it("does not also call on_done after a transport-level on_error fires", function()
      -- See claude.lua's identical test: fetch_stream's on_error can fire
      -- independently of the process exit callback, and on_done must not
      -- then report a spurious success for the same request.
      package.loaded["lib.nvim.net.curl"] = {
        fetch_stream = function(_, _, handlers)
          handlers.on_error("read failed")
          handlers.on_done({ code = 0, signal = 0, stdout = "", stderr = "" })
        end,
      }
      local loomai = require("ai.providers.loomai")
      local err_count, done_count = 0, 0
      loomai.stream({ prompt = "hi" }, {
        on_error = function()
          err_count = err_count + 1
        end,
        on_done = function()
          done_count = done_count + 1
        end,
      })
      assert.are.equal(1, err_count)
      assert.are.equal(0, done_count)
    end)

    it("ignores [DONE]/empty payloads without emitting a chunk", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_stream = function(_, _, handlers)
          handlers.on_chunk("data: [DONE]")
          handlers.on_chunk('data: {"delta":"ok"}')
          handlers.on_done({ code = 0, signal = 0, stdout = "", stderr = "" })
        end,
      }
      local loomai = require("ai.providers.loomai")
      local chunks = {}
      loomai.stream({ prompt = "hi" }, {
        on_chunk = function(d)
          chunks[#chunks + 1] = d
        end,
      })
      assert.are.same({ "ok" }, chunks)
    end)
  end)

  describe("host resolution", function()
    it("defaults to http://127.0.0.1:8080", function()
      local seen_url
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(url, _, cb)
          seen_url = url
          cb(true, { text = "" }, { code = 0 })
        end,
      }
      local loomai = require("ai.providers.loomai")
      loomai.ask({ prompt = "hi" }, function() end)
      assert.are.equal("http://127.0.0.1:8080/ask", seen_url)
    end)

    it("honors LOOMAI_HOST over the default", function()
      vim.env.LOOMAI_HOST = "http://example.internal:9000"
      local seen_url
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(url, _, cb)
          seen_url = url
          cb(true, { text = "" }, { code = 0 })
        end,
      }
      local loomai = require("ai.providers.loomai")
      loomai.ask({ prompt = "hi" }, function() end)
      assert.are.equal("http://example.internal:9000/ask", seen_url)
    end)

    it("uses /ask/stream (not /ask) for the streaming endpoint", function()
      local seen_url
      package.loaded["lib.nvim.net.curl"] = {
        fetch_stream = function(url, _, handlers)
          seen_url = url
          handlers.on_done({ code = 0, signal = 0, stdout = "", stderr = "" })
        end,
      }
      local loomai = require("ai.providers.loomai")
      loomai.stream({ prompt = "hi" }, {})
      assert.are.equal("http://127.0.0.1:8080/ask/stream", seen_url)
    end)
  end)

  describe("available", function()
    -- loomAI has no daemon-installed proxy the way ollama.lua checks for the
    -- `ollama` binary -- see the source's own comment: it only checks curl.
    it("is true when curl is on PATH, without checking for anything else", function()
      local loomai = require("ai.providers.loomai")
      assert.is_true(loomai.available())
    end)
  end)

  describe("request body", function()
    it("sends prompt/system/model/timeout_ms as flat top-level fields", function()
      local seen
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, opts, cb)
          seen = opts.body
          cb(true, { text = "" }, { code = 0 })
        end,
      }
      local loomai = require("ai.providers.loomai")
      loomai.ask(
        { prompt = "hi", system = "be terse", model = "x", timeout_ms = 5000 },
        function() end
      )
      local body = vim.json.decode(seen)
      assert.are.equal("hi", body.prompt)
      assert.are.equal("be terse", body.system)
      assert.are.equal("x", body.model)
      assert.are.equal(5000, body.timeout_ms)
    end)
  end)
end)
