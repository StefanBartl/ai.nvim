-- Same `package.loaded` stubbing approach as providers_claude_spec.lua --
-- see that file's module doc for why the stub must land before each fresh
-- `require("ai.providers.ai_desktop")`.
--
-- Same need-check-nil suppression reasoning as that file: the test body
-- itself is the guard.
---@diagnostic disable: need-check-nil
describe("ai.providers.ai_desktop", function()
  local original_host

  before_each(function()
    original_host = vim.env.AI_DESKTOP_HOST
    vim.env.AI_DESKTOP_HOST = nil
    package.loaded["ai.providers.ai_desktop"] = nil
    -- `ai.providers.transport` sits between this provider and
    -- `lib.nvim.net.curl` and captures `curl` as its own require-time
    -- upvalue too, so it has to be dropped alongside the provider --
    -- otherwise the second test in this file runs against the first's stub.
    package.loaded["ai.providers.transport"] = nil
  end)

  after_each(function()
    vim.env.AI_DESKTOP_HOST = original_host
    package.loaded["lib.nvim.net.curl"] = nil
    package.loaded["ai.providers.ai_desktop"] = nil
    package.loaded["ai.providers.transport"] = nil
  end)

  describe("ask", function()
    it("maps a successful /ask response to Ai.Response", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, _, cb)
          cb(true, { text = "hello", usage = { total_tokens = 3 }, stop_reason = "end" })
        end,
      }
      local ai_desktop = require("ai.providers.ai_desktop")
      local ok, res
      ai_desktop.ask({ prompt = "hi" }, function(a, b)
        ok, res = a, b
      end)
      assert.is_true(ok)
      assert.are.equal("hello", res.text)
      assert.are.equal("ai_desktop", res.provider)
      assert.are.equal("end", res.stop_reason)
    end)

    it("reports a table {message=...} error as a failure", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, _, cb)
          cb(true, { error = { message = "queue full" } })
        end,
      }
      local ai_desktop = require("ai.providers.ai_desktop")
      local ok, err
      ai_desktop.ask({ prompt = "hi" }, function(a, b)
        ok, err = a, b
      end)
      assert.is_false(ok)
      assert.are.equal("api_error", err.kind)
      assert.is_true(err.message:find("queue full", 1, true) ~= nil)
    end)

    it("reports a bare string error as a failure too", function()
      -- ai_desktop.lua's own `data.error` check accepts either shape -- see the
      -- `type(data.error) == "table" and data.error.message or data.error`
      -- fallback in the source.
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, _, cb)
          cb(true, { error = "malformed request" })
        end,
      }
      local ai_desktop = require("ai.providers.ai_desktop")
      local ok, err
      ai_desktop.ask({ prompt = "hi" }, function(a, b)
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
      local ai_desktop = require("ai.providers.ai_desktop")
      local ok, err
      local raised = not pcall(function()
        ai_desktop.ask({ prompt = "hi" }, function(a, b)
          ok, err = a, b
        end)
      end)
      assert.is_false(raised)
      assert.is_false(ok)
      assert.are.equal("invalid_response", err.kind)
    end)

    it(
      "rejects any attachment -- ai-desktop's /ask contract has no payload field for one",
      function()
        local called = false
        package.loaded["lib.nvim.net.curl"] = {
          fetch_json = function()
            called = true
          end,
        }
        local ai_desktop = require("ai.providers.ai_desktop")
        local ok, err
        ai_desktop.ask({
          prompt = "hi",
          attachments = { { kind = "image", media_type = "image/png", data = "AAA" } },
        }, function(a, b)
          ok, err = a, b
        end)
        assert.is_false(ok)
        assert.is_false(called)
        assert.are.equal("invalid_request", err.kind)
      end
    )
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
      local ai_desktop = require("ai.providers.ai_desktop")
      local chunks, done_res = {}, nil
      ai_desktop.stream({ prompt = "hi" }, {
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
      local ai_desktop = require("ai.providers.ai_desktop")
      local err
      ai_desktop.stream({ prompt = "hi" }, {
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
      local ai_desktop = require("ai.providers.ai_desktop")
      local err
      ai_desktop.stream({ prompt = "hi" }, {
        on_error = function(e)
          err = e
        end,
      })
      assert.are.equal("network_error", err.kind)
    end)

    it("a refused connection for a request that goes to Ollama says so", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_stream = function(_, _, handlers)
          handlers.on_done({ code = 7, signal = 0, stdout = "", stderr = "connection refused" })
        end,
      }
      local ai_desktop = require("ai.providers.ai_desktop")
      local err
      ai_desktop.stream({ prompt = "hi" }, {
        on_error = function(e)
          err = e
        end,
      })
      assert.is_truthy(err.message:find("sends this to Ollama", 1, true))
      assert.is_truthy(err.message:find("no model", 1, true))
      ai_desktop.stream({ prompt = "hi", model = "llama3" }, {
        on_error = function(e)
          err = e
        end,
      })
      assert.is_truthy(err.message:find("model 'llama3'", 1, true))
    end)

    it("a refused connection for a cloud model does not blame Ollama", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_stream = function(_, _, handlers)
          handlers.on_done({ code = 7, signal = 0, stdout = "", stderr = "connection refused" })
        end,
      }
      local ai_desktop = require("ai.providers.ai_desktop")
      local err
      ai_desktop.stream({ prompt = "hi", model = "claude-sonnet-5-5" }, {
        on_error = function(e)
          err = e
        end,
      })
      assert.are.equal("network_error", err.kind)
      assert.is_nil(err.message:find("Ollama", 1, true))
    end)

    it("backend_of() follows ai-desktop's routing by model prefix", function()
      local ai_desktop = require("ai.providers.ai_desktop")
      assert.are.equal("ollama", ai_desktop.backend_of(nil))
      assert.are.equal("ollama", ai_desktop.backend_of("llama3"))
      assert.are.equal("claude", ai_desktop.backend_of("claude-opus-5-5"))
      assert.are.equal("gpt", ai_desktop.backend_of("gpt-5"))
      assert.are.equal("gemini", ai_desktop.backend_of("gemini-2"))
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
      local ai_desktop = require("ai.providers.ai_desktop")
      local err_count, done_count = 0, 0
      ai_desktop.stream({ prompt = "hi" }, {
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
      local ai_desktop = require("ai.providers.ai_desktop")
      local chunks = {}
      ai_desktop.stream({ prompt = "hi" }, {
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
      local ai_desktop = require("ai.providers.ai_desktop")
      ai_desktop.ask({ prompt = "hi" }, function() end)
      assert.are.equal("http://127.0.0.1:8080/ask", seen_url)
    end)

    it("still honors the old variable LOOMAI_HOST, and AI_DESKTOP_HOST wins over it", function()
      local original = vim.env.LOOMAI_HOST
      vim.env.LOOMAI_HOST = "http://old.internal:9001"
      local seen_url
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(url, _, cb)
          seen_url = url
          cb(true, { text = "" }, { code = 0 })
        end,
      }
      local ai_desktop = require("ai.providers.ai_desktop")
      ai_desktop.ask({ prompt = "hi" }, function() end)
      assert.are.equal("http://old.internal:9001/ask", seen_url)
      vim.env.AI_DESKTOP_HOST = "http://new.internal:9002"
      ai_desktop.ask({ prompt = "hi" }, function() end)
      assert.are.equal("http://new.internal:9002/ask", seen_url)
      vim.env.LOOMAI_HOST = original
    end)

    it("honors AI_DESKTOP_HOST over the default", function()
      vim.env.AI_DESKTOP_HOST = "http://example.internal:9000"
      local seen_url
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(url, _, cb)
          seen_url = url
          cb(true, { text = "" }, { code = 0 })
        end,
      }
      local ai_desktop = require("ai.providers.ai_desktop")
      ai_desktop.ask({ prompt = "hi" }, function() end)
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
      local ai_desktop = require("ai.providers.ai_desktop")
      ai_desktop.stream({ prompt = "hi" }, {})
      assert.are.equal("http://127.0.0.1:8080/ask/stream", seen_url)
    end)
  end)

  describe("available", function()
    -- ai-desktop has no daemon-installed proxy the way ollama.lua checks for the
    -- `ollama` binary -- see the source's own comment: it only checks curl.
    it("is true when curl is on PATH, without checking for anything else", function()
      local ai_desktop = require("ai.providers.ai_desktop")
      assert.is_true(ai_desktop.available())
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
      local ai_desktop = require("ai.providers.ai_desktop")
      ai_desktop.ask(
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
