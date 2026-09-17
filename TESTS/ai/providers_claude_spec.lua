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
    -- `ai.providers.transport` sits between this provider and
    -- `lib.nvim.net.curl` and captures `curl` as its own require-time
    -- upvalue too, so it has to be dropped alongside the provider --
    -- otherwise the second test in this file runs against the first's stub.
    package.loaded["ai.providers.transport"] = nil
  end)

  after_each(function()
    vim.env.ANTHROPIC_API_KEY = original_key
    package.loaded["lib.nvim.net.curl"] = nil
    package.loaded["ai.providers.claude"] = nil
    package.loaded["ai.providers.transport"] = nil
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
  describe("attachments", function()
    local page = { kind = "image", media_type = "image/png", data = "AAA" }
    local pdf = { kind = "document", media_type = "application/pdf", data = "BBB" }

    ---Decode the JSON body the provider handed to curl.
    ---@param req table
    ---@return table
    local function body_for(req)
      local seen
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, opts, cb)
          seen = opts.body
          cb(true, { content = {} }, { code = 0 })
        end,
      }
      local claude = require("ai.providers.claude")
      claude.ask(req, function() end)
      return vim.json.decode(seen)
    end

    it("keeps content a plain string when there is nothing but the prompt", function()
      local body = body_for({ prompt = "hi" })
      assert.are.equal("hi", body.messages[1].content)
    end)

    it("sends an image as a base64 source block before the prompt", function()
      local body = body_for({ prompt = "read this", attachments = { page } })
      local content = body.messages[1].content
      assert.are.equal(2, #content)
      assert.are.equal("image", content[1].type)
      assert.are.equal("base64", content[1].source.type)
      assert.are.equal("image/png", content[1].source.media_type)
      assert.are.equal("AAA", content[1].source.data)
      -- Prompt last: Anthropic documents that ordering for document/image
      -- questions, and pdfport.nvim's own backend already sent it that way.
      assert.are.equal("text", content[2].type)
      assert.are.equal("read this", content[2].text)
    end)

    it("sends a PDF as a document block, not a rasterized image", function()
      local body = body_for({ prompt = "extract", attachments = { pdf } })
      local content = body.messages[1].content
      assert.are.equal("document", content[1].type)
      assert.are.equal("application/pdf", content[1].source.media_type)
    end)

    it("keeps several attachments in the order they were given", function()
      local body = body_for({ prompt = "p", attachments = { pdf, page } })
      local content = body.messages[1].content
      assert.are.equal("document", content[1].type)
      assert.are.equal("image", content[2].type)
      assert.are.equal("text", content[3].type)
    end)

    it("fails a malformed attachment without calling curl", function()
      local called = false
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function()
          called = true
        end,
      }
      local claude = require("ai.providers.claude")
      local ok, err
      claude.ask({ prompt = "hi", attachments = { { kind = "image" } } }, function(a, b)
        ok, err = a, b
      end)
      assert.is_false(ok)
      assert.is_false(called)
      assert.are.equal("invalid_request", err.kind)
    end)
  end)

  describe("api_key override", function()
    it("uses req.api_key in place of the environment variable", function()
      local seen
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, opts, cb)
          seen = opts.secret_headers["x-api-key"]
          cb(true, { content = {} }, { code = 0 })
        end,
      }
      local claude = require("ai.providers.claude")
      claude.ask({ prompt = "hi", api_key = "from-caller" }, function() end)
      assert.are.equal("from-caller", seen)
    end)

    it("lets a caller work without ANTHROPIC_API_KEY set at all", function()
      -- The case pdfport.nvim's own `claude_api_key` config option needs:
      -- it must not have to write the key into the user's environment.
      vim.env.ANTHROPIC_API_KEY = nil
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, _, cb)
          cb(true, { content = { { type = "text", text = "ok" } } }, { code = 0 })
        end,
      }
      local claude = require("ai.providers.claude")
      local ok, res
      claude.ask({ prompt = "hi", api_key = "from-caller" }, function(a, b)
        ok, res = a, b
      end)
      assert.is_true(ok)
      assert.are.equal("ok", res.text)
    end)
  end)

  describe("timeouts", function()
    it("reports curl's own exit 28 as a timeout, not a generic network error", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, _, cb)
          cb(false, "curl exited 28", { code = 28, stderr = "" })
        end,
      }
      local claude = require("ai.providers.claude")
      local ok, err
      claude.ask({ prompt = "hi", timeout_ms = 5000 }, function(a, b)
        ok, err = a, b
      end)
      assert.is_false(ok)
      assert.are.equal("timeout", err.kind)
      assert.is_true(err.message:find("5000 ms", 1, true) ~= nil)
    end)

    it("still reports any other non-zero exit as a network error", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, _, cb)
          cb(false, "connection refused", { code = 7, stderr = "connection refused" })
        end,
      }
      local claude = require("ai.providers.claude")
      local ok, err
      claude.ask({ prompt = "hi" }, function(a, b)
        ok, err = a, b
      end)
      assert.is_false(ok)
      assert.are.equal("network_error", err.kind)
    end)
  end)
  describe("available", function()
    it("is false with neither an env var nor a request key", function()
      vim.env.ANTHROPIC_API_KEY = nil
      local claude = require("ai.providers.claude")
      assert.is_false(claude.available())
    end)

    it("counts a request's own api_key towards availability", function()
      -- Otherwise `ai.providers.resolve` rejects the provider before
      -- `ask()` ever sees the key, and `req.api_key` is unreachable for the
      -- caller it exists for -- an embedding plugin holding the key in its
      -- own config rather than in the environment.
      vim.env.ANTHROPIC_API_KEY = nil
      local claude = require("ai.providers.claude")
      assert.is_true(claude.available({ prompt = "hi", api_key = "from-caller" }))
    end)
  end)
end)
