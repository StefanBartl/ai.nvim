-- Same `package.loaded` stubbing approach as providers_claude_spec.lua --
-- see that file's module doc for why the stub must land before each fresh
-- `require("ai.providers.ollama")`.
--
-- Same need-check-nil suppression reasoning as that file: the test body
-- itself is the guard.
---@diagnostic disable: need-check-nil
describe("ai.providers.ollama", function()
  local original_host

  before_each(function()
    original_host = vim.env.AI_OLLAMA_HOST
    vim.env.AI_OLLAMA_HOST = nil
    package.loaded["ai.providers.ollama"] = nil
    -- `ai.providers.transport` sits between this provider and
    -- `lib.nvim.net.curl` and captures `curl` as its own require-time
    -- upvalue too, so it has to be dropped alongside the provider --
    -- otherwise the second test in this file runs against the first's stub.
    package.loaded["ai.providers.transport"] = nil
  end)

  after_each(function()
    vim.env.AI_OLLAMA_HOST = original_host
    package.loaded["lib.nvim.net.curl"] = nil
    package.loaded["ai.providers.ollama"] = nil
    package.loaded["ai.providers.transport"] = nil
  end)

  describe("ask", function()
    it("maps a successful /api/chat response to Ai.Response", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, _, cb)
          cb(true, { message = { content = "hello" }, done_reason = "stop" })
        end,
      }
      local ollama = require("ai.providers.ollama")
      local ok, res
      ollama.ask({ prompt = "hi" }, function(a, b)
        ok, res = a, b
      end)
      assert.is_true(ok)
      assert.are.equal("hello", res.text)
      assert.are.equal("ollama", res.provider)
      assert.are.equal("stop", res.stop_reason)
    end)

    it("reports a string `error` field as a failure", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, _, cb)
          cb(true, { error = 'model "x" not found' })
        end,
      }
      local ollama = require("ai.providers.ollama")
      local ok, err
      ollama.ask({ prompt = "hi" }, function(a, b)
        ok, err = a, b
      end)
      assert.is_false(ok)
      assert.are.equal("api_error", err.kind)
      assert.is_true(err.message:find("not found", 1, true) ~= nil)
    end)

    it("fails with invalid_response rather than raising on a non-object 200", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, _, cb)
          cb(true, 42, { code = 0 })
        end,
      }
      local ollama = require("ai.providers.ollama")
      local ok, err
      local raised = not pcall(function()
        ollama.ask({ prompt = "hi" }, function(a, b)
          ok, err = a, b
        end)
      end)
      assert.is_false(raised)
      assert.is_false(ok)
      assert.are.equal("invalid_response", err.kind)
    end)

    it("reports curl's own exit 28 as a timeout", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, _, cb)
          cb(false, "curl exited 28", { code = 28, stderr = "" })
        end,
      }
      local ollama = require("ai.providers.ollama")
      local ok, err
      ollama.ask({ prompt = "hi", timeout_ms = 3000 }, function(a, b)
        ok, err = a, b
      end)
      assert.is_false(ok)
      assert.are.equal("timeout", err.kind)
    end)
  end)

  describe("stream", function()
    it("accumulates NDJSON message.content deltas and reports done_reason on_done", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_stream = function(_, _, handlers)
          handlers.on_chunk('{"message":{"content":"He"},"done":false}')
          handlers.on_chunk('{"message":{"content":"llo"},"done":false}')
          handlers.on_chunk('{"done":true,"done_reason":"stop"}')
          handlers.on_done({ code = 0, signal = 0, stdout = "", stderr = "" })
        end,
      }
      local ollama = require("ai.providers.ollama")
      local chunks, done_res = {}, nil
      ollama.stream({ prompt = "hi" }, {
        on_chunk = function(d)
          chunks[#chunks + 1] = d
        end,
        on_done = function(r)
          done_res = r
        end,
      })
      assert.are.same({ "He", "llo" }, chunks)
      assert.are.equal("Hello", done_res.text)
      assert.are.equal("stop", done_res.stop_reason)
    end)

    it("reports a mid-stream `error` line as on_error", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_stream = function(_, _, handlers)
          handlers.on_chunk('{"error":"daemon unreachable"}')
          handlers.on_done({ code = 0, signal = 0, stdout = "", stderr = "" })
        end,
      }
      local ollama = require("ai.providers.ollama")
      local err
      ollama.stream({ prompt = "hi" }, {
        on_error = function(e)
          err = e
        end,
      })
      assert.are.equal("api_error", err.kind)
      assert.is_true(err.message:find("daemon unreachable", 1, true) ~= nil)
    end)

    it("reports a non-zero curl exit as on_error", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_stream = function(_, _, handlers)
          handlers.on_done({ code = 7, signal = 0, stdout = "", stderr = "connection refused" })
        end,
      }
      local ollama = require("ai.providers.ollama")
      local err
      ollama.stream({ prompt = "hi" }, {
        on_error = function(e)
          err = e
        end,
      })
      assert.are.equal("network_error", err.kind)
      assert.is_true(err.message:find("curl exited 7", 1, true) ~= nil)
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
      local ollama = require("ai.providers.ollama")
      local err_count, done_count = 0, 0
      ollama.stream({ prompt = "hi" }, {
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

    it("ignores a line that is not valid JSON instead of raising", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_stream = function(_, _, handlers)
          handlers.on_chunk("not json")
          handlers.on_chunk('{"message":{"content":"ok"},"done":true,"done_reason":"stop"}')
          handlers.on_done({ code = 0, signal = 0, stdout = "", stderr = "" })
        end,
      }
      local ollama = require("ai.providers.ollama")
      local done_res
      ollama.stream({ prompt = "hi" }, {
        on_done = function(r)
          done_res = r
        end,
      })
      assert.are.equal("ok", done_res.text)
    end)
  end)

  describe("attachments", function()
    local pic = { kind = "image", media_type = "image/png", data = "AAA" }
    local pdf = { kind = "document", media_type = "application/pdf", data = "BBB" }

    ---Decode the JSON body the provider handed to curl.
    ---@param req table
    ---@return table
    local function body_for(req)
      local seen
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, opts, cb)
          seen = opts.body
          cb(true, { message = { content = "" } }, { code = 0 })
        end,
      }
      local ollama = require("ai.providers.ollama")
      ollama.ask(req, function() end)
      return vim.json.decode(seen)
    end

    it("sends an image's base64 data as a bare string in the `images` array", function()
      local body = body_for({ prompt = "read this", attachments = { pic } })
      local user = body.messages[#body.messages]
      assert.are.same({ "AAA" }, user.images)
    end)

    it("omits `images` entirely when there is no attachment", function()
      local body = body_for({ prompt = "hi" })
      local user = body.messages[#body.messages]
      assert.is_nil(user.images)
    end)

    it(
      "rejects a document attachment without calling curl -- Ollama's chat API has no document slot",
      function()
        local called = false
        package.loaded["lib.nvim.net.curl"] = {
          fetch_json = function()
            called = true
          end,
        }
        local ollama = require("ai.providers.ollama")
        local ok, err
        ollama.ask({ prompt = "hi", attachments = { pdf } }, function(a, b)
          ok, err = a, b
        end)
        assert.is_false(ok)
        assert.is_false(called)
        assert.are.equal("invalid_request", err.kind)
      end
    )

    it("puts req.system first as a system-role message", function()
      -- One `body_for` per test, not two: `ai.providers.transport` captures
      -- `curl` as a require-time upvalue (see the module doc at the top of
      -- this file), so a second `body_for` call in the same test would
      -- silently reuse the first call's stub instead of the second one.
      local with_system = body_for({ prompt = "hi", system = "be terse" })
      assert.are.equal("system", with_system.messages[1].role)
      assert.are.equal("be terse", with_system.messages[1].content)
    end)

    it("starts with a user-role message when req.system is absent", function()
      local without_system = body_for({ prompt = "hi" })
      assert.are.equal("user", without_system.messages[1].role)
    end)
  end)

  describe("host resolution", function()
    it("defaults to http://127.0.0.1:11434", function()
      local seen_url
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(url, _, cb)
          seen_url = url
          cb(true, { message = { content = "" } }, { code = 0 })
        end,
      }
      local ollama = require("ai.providers.ollama")
      ollama.ask({ prompt = "hi" }, function() end)
      assert.are.equal("http://127.0.0.1:11434/api/chat", seen_url)
    end)

    it("honors AI_OLLAMA_HOST over the default", function()
      vim.env.AI_OLLAMA_HOST = "http://example.internal:9999"
      local seen_url
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(url, _, cb)
          seen_url = url
          cb(true, { message = { content = "" } }, { code = 0 })
        end,
      }
      local ollama = require("ai.providers.ollama")
      ollama.ask({ prompt = "hi" }, function() end)
      assert.are.equal("http://example.internal:9999/api/chat", seen_url)
    end)

    it("honors req.host over AI_OLLAMA_HOST", function()
      vim.env.AI_OLLAMA_HOST = "http://example.internal:9999"
      local seen_url
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(url, _, cb)
          seen_url = url
          cb(true, { message = { content = "" } }, { code = 0 })
        end,
      }
      local ollama = require("ai.providers.ollama")
      ollama.ask({ prompt = "hi", host = "http://caller-supplied:1234" }, function() end)
      assert.are.equal("http://caller-supplied:1234/api/chat", seen_url)
    end)
  end)

  describe("available", function()
    -- `ai.providers.util.executable` caches by binary name for the module's
    -- lifetime, so `ai.providers.util` itself (not just ollama.lua) has to be
    -- dropped for a fresh, controllable cache -- otherwise a real `curl`/
    -- `ollama` probe from an earlier test (or an earlier spec file in the
    -- same headless run) wins regardless of what `vim.fn.executable` is
    -- stubbed to return here.
    local original_executable

    before_each(function()
      package.loaded["ai.providers.util"] = nil
      original_executable = vim.fn.executable
    end)

    after_each(function()
      vim.fn.executable = original_executable
      package.loaded["ai.providers.util"] = nil
    end)

    it("is true when both curl and ollama are on PATH", function()
      vim.fn.executable = function()
        return 1
      end
      local ollama = require("ai.providers.ollama")
      assert.is_true(ollama.available())
    end)

    it("is false when the ollama binary is missing, even with curl present", function()
      vim.fn.executable = function(name)
        return name == "curl" and 1 or 0
      end
      local ollama = require("ai.providers.ollama")
      assert.is_false(ollama.available())
    end)

    it("is false when curl itself is missing", function()
      vim.fn.executable = function()
        return 0
      end
      local ollama = require("ai.providers.ollama")
      assert.is_false(ollama.available())
    end)
  end)
end)
