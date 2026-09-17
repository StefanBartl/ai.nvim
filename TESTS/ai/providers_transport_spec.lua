-- `lib.nvim.net.curl` is stubbed via `package.loaded` before each
-- `require("ai.providers.transport")` -- same pattern, and same reason, as
-- the provider specs: the module captures `curl` as a local upvalue at
-- require-time.
---@diagnostic disable: need-check-nil
describe("ai.providers.transport", function()
  local captured

  ---Stub curl, recording the opts each tier was called with.
  ---@param on_done? fun(handlers: table)
  local function stub_curl(on_done)
    captured = {}
    package.loaded["lib.nvim.net.curl"] = {
      fetch_json = function(url, opts, cb)
        captured = { url = url, opts = opts }
        cb(true, { ok = true }, { code = 0 })
      end,
      fetch_stream = function(url, opts, handlers)
        captured = { url = url, opts = opts, handlers = handlers }
        if on_done then
          on_done(handlers)
        end
        return { kill = function() end }
      end,
    }
  end

  before_each(function()
    package.loaded["ai.providers.transport"] = nil
  end)

  after_each(function()
    package.loaded["lib.nvim.net.curl"] = nil
    package.loaded["ai.providers.transport"] = nil
  end)

  ---@param extra? integer bytes past the inline ceiling
  ---@return string
  local function oversized_body(extra)
    local transport = require("ai.providers.transport")
    return string.rep("x", transport.MAX_INLINE_BODY_BYTES + (extra or 1))
  end

  ---The `@file` argument curl was told to read the body from, or nil.
  ---@return string|nil
  local function body_file_from(opts)
    local args = opts.raw_args or {}
    for i, arg in ipairs(args) do
      if arg == "--data-binary" then
        return (args[i + 1] or ""):sub(2) -- strip the leading "@"
      end
    end
    return nil
  end

  describe("body routing", function()
    it("leaves a small body inline, as curl's own -d argument", function()
      stub_curl()
      local transport = require("ai.providers.transport")
      transport.post_json("https://example.test", { body = '{"a":1}' }, function() end)
      assert.are.equal('{"a":1}', captured.opts.body)
      assert.is_nil(body_file_from(captured.opts))
    end)

    it("routes a body past the ceiling through a temp file instead", function()
      stub_curl()
      local transport = require("ai.providers.transport")
      local body = oversized_body()
      transport.post_json("https://example.test", { body = body }, function() end)

      assert.is_nil(captured.opts.body)
      local path = body_file_from(captured.opts)
      assert.is_not_nil(path)
      -- The callback already ran (the stub is synchronous), so the file is
      -- gone by now -- what matters is that curl was pointed at one.
      assert.is_true(path:find("%.json$") ~= nil)
    end)

    it("writes the exact body bytes to that file", function()
      local seen
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, opts, cb)
          local path = body_file_from(opts)
          local f = assert(io.open(path, "rb"))
          seen = f:read("*a")
          f:close()
          cb(true, {}, { code = 0 })
        end,
      }
      local transport = require("ai.providers.transport")
      local body = oversized_body()
      transport.post_json("https://example.test", { body = body }, function() end)
      assert.are.equal(body, seen)
    end)

    it("removes the temp file once the request is done", function()
      local path
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, opts, cb)
          path = body_file_from(opts)
          cb(true, {}, { code = 0 })
        end,
      }
      local transport = require("ai.providers.transport")
      transport.post_json("https://example.test", { body = oversized_body() }, function() end)
      assert.are.equal(0, vim.fn.filereadable(path))
    end)

    it("removes the temp file after a stream ends, too", function()
      local path
      stub_curl(function(handlers)
        path = body_file_from(captured.opts)
        handlers.on_done({ code = 0 })
      end)
      local transport = require("ai.providers.transport")
      transport.stream_json("https://example.test", { body = oversized_body() }, {
        on_done = function() end,
      })
      assert.are.equal(0, vim.fn.filereadable(path))
    end)

    it("survives a stream that reports both on_error and on_done", function()
      -- `fetch_stream` can reach both for one request; the second cleanup
      -- must be a no-op rather than deleting a since-reused temp name.
      local errors, dones = 0, 0
      stub_curl(function(handlers)
        handlers.on_error("read failed")
        handlers.on_done({ code = 1 })
      end)
      local transport = require("ai.providers.transport")
      transport.stream_json("https://example.test", { body = oversized_body() }, {
        on_error = function()
          errors = errors + 1
        end,
        on_done = function()
          dones = dones + 1
        end,
      })
      assert.are.equal(1, errors)
      assert.are.equal(1, dones)
    end)
  end)

  describe("--max-time", function()
    it("passes the request's own timeout to curl, in whole seconds", function()
      stub_curl()
      local transport = require("ai.providers.transport")
      transport.post_json(
        "https://example.test",
        { body = "{}", timeout_ms = 90000 },
        function() end
      )
      local args = captured.opts.raw_args
      assert.are.equal("--max-time", args[1])
      assert.are.equal("90", args[2])
    end)

    it("rounds a sub-second timeout up to 1, never down to 0", function()
      -- curl reads `--max-time 0` as "no limit", which would turn the
      -- shortest timeout into none at all.
      stub_curl()
      local transport = require("ai.providers.transport")
      transport.post_json("https://example.test", { body = "{}", timeout_ms = 200 }, function() end)
      assert.are.equal("1", captured.opts.raw_args[2])
    end)

    it("defaults to 60s when the caller set no timeout", function()
      stub_curl()
      local transport = require("ai.providers.transport")
      transport.post_json("https://example.test", { body = "{}" }, function() end)
      assert.are.equal("60", captured.opts.raw_args[2])
      assert.are.equal(60000, captured.opts.timeout_ms)
    end)

    it("keeps raw_args a caller already set", function()
      stub_curl()
      local transport = require("ai.providers.transport")
      transport.post_json(
        "https://example.test",
        { body = "{}", raw_args = { "--compressed" } },
        function() end
      )
      assert.are.equal("--compressed", captured.opts.raw_args[1])
      assert.are.equal("--max-time", captured.opts.raw_args[2])
    end)
  end)

  describe("callback contract", function()
    it("hands the raw process object through to the caller", function()
      package.loaded["lib.nvim.net.curl"] = {
        fetch_json = function(_, _, cb)
          cb(false, "curl exited 28", { code = 28, stderr = "" })
        end,
      }
      local transport = require("ai.providers.transport")
      local seen_obj
      transport.post_json("https://example.test", { body = "{}" }, function(_, _, obj)
        seen_obj = obj
      end)
      -- Without this the exit code never reaches the provider, and a timeout
      -- is indistinguishable from any other transport failure.
      assert.are.equal(28, seen_obj.code)
    end)
  end)
end)
