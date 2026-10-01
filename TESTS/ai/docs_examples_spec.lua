-- REL-08: the code blocks and tables in README.md / docs/*.md actually work.
--
-- The examples are extracted from the markdown files themselves at run time
-- (not copied here), so a doc edit that stops matching the code -- or a code
-- change that silently invalidates a documented snippet -- fails this spec
-- instead of waiting for a reader to trip over it.
--
-- A block is located by a stable substring of its own text, never by index:
-- reordering the docs must not break the lookup, only removing the example
-- does (and that is worth a failure too).
---@diagnostic disable: missing-fields, need-check-nil

local DOCS = vim.fn.getcwd() .. "/docs/"

---@param path string
---@return string[]
local function read_lines(path)
  local lines = {}
  for line in io.lines(path) do
    lines[#lines + 1] = line
  end
  return lines
end

---Every fenced block of `file` (relative to docs/), as `{ lang, code }`.
---@param file string
---@return { lang: string, code: string }[]
local function fenced_blocks(file)
  local blocks, cur = {}, nil
  for _, line in ipairs(read_lines(DOCS .. file)) do
    local fence = line:match("^```(%S*)%s*$")
    if fence ~= nil then
      if cur then
        cur.code = table.concat(cur.lines, "\n")
        blocks[#blocks + 1] = cur
        cur = nil
      else
        cur = { lang = fence, lines = {} }
      end
    elseif cur then
      cur.lines[#cur.lines + 1] = line
    end
  end
  return blocks
end

---The single block of `file` whose code contains `needle` (plain match).
---@param file string
---@param needle string
---@return string
local function block_with(file, needle)
  local hits = {}
  for _, b in ipairs(fenced_blocks(file)) do
    if b.code:find(needle, 1, true) then
      hits[#hits + 1] = b.code
    end
  end
  assert(
    #hits == 1,
    ("%s: expected exactly 1 block containing %q, found %d"):format(file, needle, #hits)
  )
  return hits[1]
end

---Run `code` as a chunk with `overrides` shadowing globals; `require` is
---replaced so a doc's `require("ai")` can be pointed at a capturing stub
---while every other module stays real.
---@param code string
---@param name string chunk name for error messages
---@param ai_stub? table what `require("ai")` returns instead of the real one
---@param extra? table additional globals for the chunk
---@return any
local function run_chunk(code, name, ai_stub, extra)
  local env = setmetatable({
    require = function(mod)
      if mod == "ai" and ai_stub then
        return ai_stub
      end
      return require(mod)
    end,
  }, { __index = _G })
  for k, v in pairs(extra or {}) do
    env[k] = v
  end
  local fn, err = load(code, "=" .. name, "t", env)
  assert(fn, err)
  return fn()
end

describe("docs examples (REL-08) --", function()
  local notified
  local original_notify

  before_each(function()
    notified = {}
    original_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg)
      notified[#notified + 1] = msg
    end
    for _, mod in ipairs({ "ai", "ai.config", "ai.providers", "ai.attachments" }) do
      package.loaded[mod] = nil
    end
  end)

  after_each(function()
    vim.notify = original_notify
  end)

  describe("configuration.md", function()
    it("the full setup() block is exactly DEFAULTS and is accepted without warnings", function()
      local code = block_with("configuration.md", 'require("ai").setup({')
      local captured
      run_chunk(code, "configuration.md", {
        setup = function(opts)
          captured = opts
        end,
      })

      assert.is_table(captured)
      assert.are.same(require("ai.config.DEFAULTS"), captured)

      require("ai.config").setup(vim.deepcopy(captured))
      assert.are.same({}, notified)
      assert.are.same({}, require("ai.config").issues())
    end)

    it("the completion = { provider, model } snippet is a valid config fragment", function()
      local code = block_with("configuration.md", 'completion = { provider = "ollama"')
      local opts = run_chunk("return { " .. code .. " }", "configuration.md#completion")

      local cfg = require("ai.config").setup(opts)
      assert.are.same({}, notified)
      assert.are.equal("ollama", cfg.completion.provider)
      assert.are.equal("qwen2.5-coder:7b-q5_K_M", cfg.completion.model)
    end)

    it("the custom-provider register() example registers a usable provider", function()
      local code = block_with("configuration.md", 'id = "myproxy"')
      -- The doc elides the callback body with `...`, which is not valid Lua
      -- outside a vararg function; fill it in so the rest runs for real.
      local body = "ask = function(req, cb) ... end"
      assert.is_truthy(code:find(body, 1, true), "register() example no longer elides the ask body")
      code = code:gsub(vim.pesc(body), "ask = function(req, cb) cb(true, { text = 'pong' }) end")

      run_chunk(code, "configuration.md#register")

      local provider = require("ai.providers").get("myproxy")
      assert.is_table(provider)
      assert.is_true(provider.available())
      local got
      provider.ask({ prompt = "ping" }, function(ok, res)
        got = { ok, res.text }
      end)
      assert.are.same({ true, "pong" }, got)
    end)
  end)

  describe("attachments.md", function()
    local tmp_png

    before_each(function()
      tmp_png = vim.fn.tempname() .. ".png"
      local f = assert(io.open(tmp_png, "wb"))
      f:write("\137PNG\r\n\26\n-not-a-real-image-")
      f:close()
    end)

    after_each(function()
      os.remove(tmp_png)
    end)

    it("the from_file() + ask() example builds an image attachment and passes it on", function()
      local code = block_with("attachments.md", "attachments.from_file(")
      local doc_path = "/tmp/invoice-page-1.png"
      assert.is_truthy(code:find(doc_path, 1, true))
      code = code:gsub(vim.pesc(doc_path), (tmp_png:gsub("\\", "/")))

      local seen_req
      local printed
      run_chunk(code, "attachments.md", {
        ask = function(req, cb)
          seen_req = req
          cb(true, { text = "| a | b |" })
        end,
      }, {
        vim = setmetatable({
          print = function(...)
            printed = ...
          end,
        }, { __index = vim }),
      })

      assert.are.equal("claude", seen_req.provider)
      assert.are.equal(1, #seen_req.attachments)
      local att = seen_req.attachments[1]
      assert.are.equal("image", att.kind)
      assert.are.equal("image/png", att.media_type)
      assert.are.equal("\137PNG\r\n\26\n-not-a-real-image-", vim.base64.decode(att.data))
      assert.are.equal("| a | b |", printed)
    end)

    it("the documented Ai.Attachment class lists exactly the fields @types declares", function()
      local code = block_with("attachments.md", "---@class Ai.Attachment")
      local types_src = table.concat(read_lines(vim.fn.getcwd() .. "/lua/ai/@types/init.lua"), "\n")
      local class_at = assert(types_src:find("---@class Ai.Attachment", 1, true))
      local class_src = types_src:sub(class_at):match("^(.-)\n\n") or types_src:sub(class_at)

      local doc_fields, src_fields = {}, {}
      for name in code:gmatch("---@field (%w+)%??") do
        doc_fields[#doc_fields + 1] = name
      end
      for name in class_src:gmatch("---@field (%w+)%??") do
        src_fields[#src_fields + 1] = name
      end
      table.sort(doc_fields)
      table.sort(src_fields)
      assert.are.same(src_fields, doc_fields)
    end)

    it("the host = ... example reaches a registered built-in provider", function()
      local code = block_with("attachments.md", "host = ")
      local seen_req
      run_chunk(code, "attachments.md#host", {
        ask = function(req)
          seen_req = req
        end,
      }, { cb = function() end })

      assert.are.equal("http://192.168.1.4:11434", seen_req.host)
      require("ai.providers").load_builtin()
      assert.is_table(require("ai.providers").get(seen_req.provider))
    end)
  end)

  describe("installation.md", function()
    it("the lazy.nvim spec parses, and its cmd/keys/config match what setup() installs", function()
      local code = block_with("installation.md", '"StefanBartl/ai.nvim"')
      local spec = run_chunk("return " .. code:gsub(",%s*$", ""), "installation.md")

      assert.are.equal("StefanBartl/ai.nvim", spec[1])
      assert.is_function(spec.config)
      spec.config()

      assert.are.equal(
        2,
        vim.fn.exists(":" .. spec.cmd),
        "documented cmd is not defined after setup()"
      )
      for _, key in ipairs(spec.keys) do
        for _, mode in ipairs(key.mode) do
          -- The spec's lazy-load key is the bare prefix; the mappings live
          -- under it, so at least one `<prefix>?` must exist per mode.
          local found = false
          for _, suffix in ipairs({ "a", "s", "r", "o", "O", "e" }) do
            if vim.fn.maparg(key[1] .. suffix, mode) ~= "" then
              found = true
            end
          end
          assert.is_true(found, ("no mapping under %s in mode %s"):format(key[1], mode))
        end
      end
      assert.are.equal(require("ai.config.DEFAULTS").keymaps.prefix, spec.keys[1][1])
    end)

    it("every dependency it lists is actually required by the plugin source", function()
      local code = block_with("installation.md", "dependencies")
      local expected = { ["StefanBartl/lib.nvim"] = "lib%.", ["StefanBartl/ui.nvim"] = "ui%.kit" }
      for dep in code:gmatch('"(StefanBartl/[%w%.%-_]+)"') do
        if dep ~= "StefanBartl/ai.nvim" then
          local pattern = assert(expected[dep], "unexpected dependency in the docs: " .. dep)
          local used = false
          for name, kind in vim.fs.dir(vim.fn.getcwd() .. "/lua", { depth = 4 }) do
            if kind == "file" and name:match("%.lua$") then
              local src = table.concat(read_lines(vim.fn.getcwd() .. "/lua/" .. name), "\n")
              if src:find('require%("' .. pattern) then
                used = true
                break
              end
            end
          end
          assert.is_true(used, dep .. " is documented as a dependency but never required")
        end
      end
    end)
  end)

  describe("commands + keymap tables", function()
    local function setup_all()
      require("ai").setup()
    end

    ---Subcommand names mentioned as `:Ai <sub>` or `:[range]Ai <sub>` in text.
    ---@param text string
    ---@return table<string, true>
    local function documented_subcommands(text)
      local set = {}
      for sub in text:gmatch(":%[?r?a?n?g?e?%]?Ai (%l+)") do
        set[sub] = true
      end
      return set
    end

    it("commands.md, BINDINGS.md and quickstart.md only name real :Ai subcommands", function()
      setup_all()
      local real = {}
      for _, c in ipairs(vim.fn.getcompletion("Ai ", "cmdline")) do
        real[c] = true
      end

      local sources = {
        ["commands.md"] = block_with("commands.md", ":Ai ask"),
        ["BINDINGS.md"] = table.concat(read_lines(DOCS .. "BINDINGS.md"), "\n"),
        ["quickstart.md"] = table.concat(read_lines(DOCS .. "quickstart.md"), "\n"),
      }
      for file, text in pairs(sources) do
        for sub in pairs(documented_subcommands(text)) do
          assert.is_true(
            real[sub] == true,
            ("%s documents :Ai %s, which does not exist"):format(file, sub)
          )
        end
      end
    end)

    it("every real :Ai subcommand is documented in commands.md", function()
      setup_all()
      local documented = documented_subcommands(block_with("commands.md", ":Ai ask"))
      for _, c in ipairs(vim.fn.getcompletion("Ai ", "cmdline")) do
        assert.is_true(
          documented[c] == true,
          (":Ai %s exists but is missing from commands.md"):format(c)
        )
      end
    end)

    it("every default keymap in the BINDINGS.md tables is really mapped after setup()", function()
      setup_all()
      local checked = 0
      for _, line in ipairs(read_lines(DOCS .. "BINDINGS.md")) do
        local modes, lhs = line:match("^| ([%w, ]+) | `(<[^`]+)` |")
        if modes and lhs then
          for mode in modes:gmatch("%a") do
            local mapped = vim.fn.maparg(lhs, mode)
            assert.is_true(
              mapped ~= "",
              ("BINDINGS.md lists %s in mode %s, but it is not mapped"):format(lhs, mode)
            )
            checked = checked + 1
          end
        end
      end
      -- 6 prefixed actions x (n, v) + 3 insert-mode completion keys.
      assert.are.equal(15, checked)
    end)
  end)

  describe("architecture.md", function()
    it("the lib.nvim.net.curl extension it describes exists", function()
      local code = block_with("architecture.md", "fetch_stream")
      local curl = require("lib.nvim.net.curl")
      assert.is_function(curl.fetch_stream)

      assert.is_truthy(code:find("secret_headers", 1, true))
      local found = false
      for _, f in ipairs(vim.api.nvim_get_runtime_file("lua/lib/nvim/net/curl/*.lua", true)) do
        if table.concat(read_lines(f), "\n"):find("secret_headers", 1, true) then
          found = true
        end
      end
      assert.is_true(found, "secret_headers is not implemented in lib.nvim.net.curl")
    end)
  end)
end)
