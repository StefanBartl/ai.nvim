-- REL-08: the code blocks and tables in docs/*.md actually work.
--
-- The examples are extracted from the markdown files themselves at run time
-- (not copied here), so a doc edit that stops matching the code -- or a code
-- change that silently invalidates a documented snippet -- fails this spec
-- instead of waiting for a reader to trip over it.
--
-- A block is located by a stable substring of its own text, never by index:
-- reordering the docs must not break the lookup, only removing the example
-- does (and that is worth a failure too).
--
-- Not covered (see TESTS/README.md): prose, the Action-id/description columns
-- and the Autocmds table of BINDINGS.md, the other docs' tables, README.md,
-- doc/ai.txt (the `:help ai` file, maintained by hand and not checked), and
-- keymaps the BINDINGS.md scan cannot see: buffer-local ones, and a key mapped
-- outside the registry that is neither under the prefix nor in
-- DEFAULTS.completion.keymap.
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

---Data rows (header and separator dropped) of every GFM table in `file` whose
---header starts with the cells `header`, each row as its trimmed cell strings.
---@param file string
---@param header string[]
---@return string[][]
local function table_rows(file, header)
  local rows = {}
  for _, tbl in ipairs(require("lib.nvim.markdown.table").parse(read_lines(DOCS .. file))) do
    local matches = true
    for i, cell in ipairs(header) do
      matches = matches and tbl.rows[1][i] == cell
    end
    if matches then
      for i = 2, #tbl.rows do
        rows[#rows + 1] = tbl.rows[i]
      end
    end
  end
  return rows
end

---Registry/lazy `mode` fields are `string|string[]`; normalize to a list.
---@param mode string|string[]|nil
---@return string[]
local function mode_list(mode)
  return type(mode) == "table" and mode or { mode or "n" }
end

---Run `code` as a chunk with `overrides` shadowing globals; `require` is
---replaced so a doc's `require("ai")` can be pointed at a capturing stub
---while every other module stays real. Only the setup() block uses the stub
---(a real setup() would install keymaps); the ask() examples run the real
---`ai.ask` against a stubbed provider instead.
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
  -- loadstring + setfenv is the Lua 5.1 API Nvim guarantees; the 4-argument
  -- load() is a 5.2/LuaJIT extension.
  local fn, err = loadstring(code, "=" .. name)
  assert(fn, err)
  setfenv(fn, env)
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

      assert.is_table(opts.completion)

      local cfg = require("ai.config").setup(opts)
      assert.are.same({}, notified)
      assert.are.same({}, require("ai.config").issues())
      -- DEFAULTS are `false`, so these also prove the documented value replaced
      -- the default; `model` has no VALUE_SCHEMA entry, hence the type check.
      assert.is_string(cfg.completion.model)
      require("ai.providers").load_builtin()
      assert.is_table(require("ai.providers").get(cfg.completion.provider))
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
      -- Through the public entry point, so the registered id is really reachable.
      local got
      require("ai").ask({ prompt = "ping", provider = "myproxy" }, function(ok, res)
        got = { ok, res.text }
      end)
      assert.are.same({ true, "pong" }, got)
    end)
  end)

  describe("attachments.md", function()
    local tmp_file

    after_each(function()
      if tmp_file then
        os.remove(tmp_file)
        tmp_file = nil
      end
    end)

    ---Replace EVERY built-in provider with a stub running `on_ask`, not just
    ---the id the example names today: a doc edit that picks another provider
    ---must still land on a stub (never on real curl and the developer's own
    ---API key) and fail on the id comparison instead.
    ---@param on_ask fun(req: Ai.Request, cb?: fun(ok: boolean, res: table))
    local function stub_all_providers(on_ask)
      local providers = require("ai.providers")
      providers.load_builtin()
      for _, id in ipairs(providers.ids()) do
        providers.register({
          id = id,
          available = function()
            return true
          end,
          ask = on_ask,
        })
      end
    end

    it("the from_file() + ask() example builds an attachment and passes it on", function()
      local code = block_with("attachments.md", "attachments.from_file(")
      local doc_path = assert(
        code:match('attachments%.from_file%("([^"]+)"'),
        "from_file() example no longer passes a string-literal path"
      )
      -- The temp file keeps the documented path's extension, so from_file()
      -- really derives the media type from what the doc names (a `.tiff` or
      -- extension-less doc path fails here, exactly as it would for a reader).
      local payload = "\137PNG\r\n\26\n-not-a-real-image-"
      tmp_file = vim.fn.tempname() .. (doc_path:match("%.[%w]+$") or "")
      local f = assert(io.open(tmp_file, "wb"))
      f:write(payload)
      f:close()
      -- A function replacement: a string one would treat a `%` in the temp
      -- dir as a capture escape.
      local real_path = tmp_file:gsub("\\", "/")
      code = code:gsub(vim.pesc(doc_path), function()
        return real_path
      end)

      -- The provider's own capabilities, read before the stubs replace it: the
      -- stub's ask() skips the capability check a real provider runs first.
      local providers = require("ai.providers")
      providers.load_builtin()
      local provider_id =
        assert(code:match('provider = "([^"]+)"'), "example has no provider literal")
      local real_provider = assert(providers.get(provider_id), "example names an unknown provider")
      local caps = real_provider.capabilities

      -- The real ai.ask() runs; only the providers are stubs, so
      -- the attachments pass-through in ai.ask is exercised too.
      local seen_req
      local printed
      stub_all_providers(function(req, cb)
        seen_req = req
        cb(true, { text = "| a | b |" })
      end)
      run_chunk(code, "attachments.md", nil, {
        vim = setmetatable({
          print = function(...)
            printed = ...
          end,
        }, { __index = vim }),
      })

      assert.is_not_nil(seen_req, "example did not reach a stubbed provider -- ask() call changed?")
      assert.are.equal(provider_id, seen_req.provider)
      assert.are.equal(1, #seen_req.attachments)
      local att = seen_req.attachments[1]
      -- Expectations derive from the documented path, not from the temp file.
      local A = require("ai.attachments")
      local doc_type =
        assert(A.media_type_for(doc_path), "the documented path's extension implies no media type")
      assert.are.equal(doc_type, att.media_type)
      assert.are.equal(A.kind_for(doc_type), att.kind)
      assert.are.equal(payload, vim.base64.decode(att.data))
      -- What the stubbed ask() skipped: would the real provider take this?
      local rejected = A.unsupported(provider_id, caps, seen_req.attachments)
      assert.is_nil(
        rejected,
        provider_id
          .. " cannot carry the example's attachment: "
          .. (rejected and rejected.message or "")
      )
      assert.are.equal("| a | b |", printed)
    end)

    it("the documented Ai.Attachment class lists exactly the fields @types declares", function()
      local code = block_with("attachments.md", "---@class Ai.Attachment")
      local types_src = table.concat(read_lines(vim.fn.getcwd() .. "/lua/ai/@types/init.lua"), "\n")
      local class_at = assert(types_src:find("---@class Ai.Attachment", 1, true))
      local class_src = types_src:sub(class_at):match("^(.-)\n\n") or types_src:sub(class_at)

      -- Per field: its name, the optional flag and the first type token are
      -- compared (trailing prose after the type is ignored).
      local doc_fields, src_fields = {}, {}
      for name, opt, ty in code:gmatch("---@field ([%w_]+)(%??)%s+(%S+)") do
        doc_fields[#doc_fields + 1] = name .. opt .. " " .. ty
      end
      for name, opt, ty in class_src:gmatch("---@field ([%w_]+)(%??)%s+(%S+)") do
        src_fields[#src_fields + 1] = name .. opt .. " " .. ty
      end
      table.sort(doc_fields)
      table.sort(src_fields)
      assert.are.same(src_fields, doc_fields)
    end)

    it("the host = ... example reaches a registered built-in provider", function()
      local code = block_with("attachments.md", "host = ")
      -- Real ai.ask(), stubbed providers: `host` has to survive resolve().
      local seen_req
      stub_all_providers(function(req)
        seen_req = req
      end)
      run_chunk(code, "attachments.md#host", nil, { cb = function() end })

      -- Both values are read from the doc, then compared with what reached the
      -- provider: a dropped, defaulted or rewritten host/provider fails here.
      local doc_host = assert(code:match('host = "([^"]+)"'), "example has no host literal")
      local doc_provider =
        assert(code:match('provider = "([^"]+)"'), "example has no provider literal")
      assert.is_not_nil(seen_req, "example did not reach a stubbed provider -- ask() call changed?")
      assert.are.equal(doc_host, seen_req.host)
      assert.are.equal(doc_provider, seen_req.provider)

      -- Runtime honoring of req.host stays with providers_ollama_spec; here
      -- the documented key has to be a real Ai.Request field.
      local types_src = table.concat(read_lines(vim.fn.getcwd() .. "/lua/ai/@types/init.lua"), "\n")
      local request_src = types_src:match("---@class Ai%.Request.-\n\n") or ""
      assert.is_truthy(request_src:find("---@field host%??%s"), "Ai.Request has no `host` field")
    end)

    it("the provider capability table matches each built-in provider's capabilities", function()
      local providers = require("ai.providers")
      providers.load_builtin()

      local rows = table_rows("attachments.md", { "Provider", "`image`", "`document`" })
      local listed = {}
      for _, row in ipairs(rows) do
        -- Any id charset: providers.get() below is the validator, so an
        -- unknown id fails as "lists unknown provider", not as a format error.
        local id = assert(
          row[1]:match("^`([%w_%-%.]+)`$"),
          "provider cell is not a backticked id: " .. row[1]
        )
        listed[#listed + 1] = id
        local p = assert(providers.get(id), "attachments.md lists unknown provider " .. id)
        assert.are.equal(
          row[2] == "yes",
          p.capabilities.vision == true,
          id .. ": image column disagrees with capabilities.vision"
        )
        assert.are.equal(
          row[3] == "yes",
          p.capabilities.documents == true,
          id .. ": document column disagrees with capabilities.documents"
        )
      end

      -- Both directions: an undocumented built-in fails here, and an empty
      -- parse (header drift) cannot go vacuous either.
      table.sort(listed)
      assert.are.same(
        providers.ids(),
        listed,
        "attachments.md provider table vs. built-in providers"
          .. " (or its `| Provider | `image` | `document` |` header changed)"
      )
    end)
  end)

  describe("installation.md", function()
    it("the lazy.nvim spec parses, and its cmd/keys/config match what setup() installs", function()
      local code = block_with("installation.md", '"StefanBartl/ai.nvim"')
      local spec = run_chunk("return " .. code:gsub(",%s*$", ""), "installation.md")

      assert.are.equal("StefanBartl/ai.nvim", spec[1])
      assert.is_function(spec.config)
      spec.config()
      assert.are.same({}, notified, "setup() emitted warnings")

      -- lazy.nvim accepts `cmd` as a string or a list, and a `keys` entry as a
      -- bare lhs string or a table; normalize both so a legitimate rewrite of
      -- the doc does not crash this test with an error that never names it.
      local cmds = type(spec.cmd) == "table" and spec.cmd or { spec.cmd }
      assert.is_true(#cmds > 0, "installation.md spec has no cmd")
      for _, c in ipairs(cmds) do
        assert.are.equal(
          2,
          vim.fn.exists(":" .. c),
          "documented cmd " .. c .. " is not defined after setup()"
        )
      end
      local ai_keys = require("lib.nvim.bindings.keymap").registered("Ai")
      local first_lhs
      assert.is_table(spec.keys, "installation.md spec has no keys")
      for _, key in ipairs(spec.keys) do
        local lhs = type(key) == "string" and key or key[1]
        assert(type(lhs) == "string", "installation.md keys entry has no lhs")
        first_lhs = first_lhs or lhs
        -- lazy.nvim's `mode` is a string or a list and defaults to "n".
        for _, mode in ipairs(mode_list(type(key) == "table" and key.mode or nil)) do
          -- The spec's lazy-load key is the bare prefix; the mappings live
          -- under it, so at least one registered `<prefix>...` must be
          -- really mapped per mode. maparg() is the judge, not the registry's
          -- mode label: ai.nvim registers `v`, which Neovim applies to x and
          -- s as well, so `mode = { "n", "x" }` is a valid spelling.
          local found = false
          for _, e in ipairs(ai_keys) do
            if e.lhs and vim.startswith(e.lhs, lhs) and vim.fn.maparg(e.lhs, mode) ~= "" then
              found = true
              break
            end
          end
          assert.is_true(found, ("no mapping under %s in mode %s"):format(lhs, mode))
        end
      end
      assert.are.equal(require("ai.config.DEFAULTS").keymaps.prefix, first_lhs)
    end)

    it("the documented dependencies are exactly the externally required modules", function()
      local code = block_with("installation.md", "dependencies")
      local documented = {}
      for dep in code:gmatch("[\"'](StefanBartl/[%w%.%-_]+)[\"']") do
        if dep ~= "StefanBartl/ai.nvim" then
          documented[dep] = true
        end
      end
      assert.is_true(next(documented) ~= nil, "parsed no dependency from the installation.md block")

      -- Hard `require("<root>.` calls only. The soft deps (data.nvim,
      -- gitsuite.nvim) are reached through `pcall(require, ...)`, which this
      -- pattern deliberately ignores: they are optional and belong in
      -- requirements.md, not in `dependencies`. Comment lines are skipped.
      local used = {}
      for _, dir in ipairs({ "lua", "plugin" }) do
        local base = vim.fn.getcwd() .. "/" .. dir
        for name, kind in vim.fs.dir(base, { depth = 8 }) do
          if kind == "file" and name:match("%.lua$") then
            for _, line in ipairs(read_lines(base .. "/" .. name)) do
              if not line:match("^%s*%-%-") then
                for root in line:gmatch('require%("([%w_]+)%.') do
                  if root ~= "ai" then
                    used["StefanBartl/" .. root .. ".nvim"] = true
                  end
                end
              end
            end
          end
        end
      end
      assert.is_true(next(used) ~= nil, "found no external require() under lua/ -- scan broken?")

      for dep in pairs(used) do
        assert.is_true(
          documented[dep] == true,
          dep .. " is required by the plugin source but missing from installation.md"
        )
      end
      for dep in pairs(documented) do
        assert.is_true(
          used[dep] == true,
          dep
            .. " is documented as a dependency but never required"
            .. " (optional soft deps belong in docs/requirements.md, not in `dependencies`)"
        )
      end
    end)
  end)

  describe("commands + keymap tables", function()
    local function setup_all()
      require("ai").setup()
      -- A failed setup step is only reported through vim.notify; assert it here
      -- so the failure names its cause instead of blaming the docs.
      assert.are.same({}, notified, "setup() emitted warnings")
    end

    ---Subcommand names mentioned as `:Ai <sub>` or `:[range]Ai <sub>` in text.
    ---The whole token is captured (digits, `_`, `-` included): a truncated
    ---`info2` would pass as `info`, and a real `code_review` would be blamed
    ---on the doc as `code`.
    ---@param text string
    ---@return table<string, true>
    local function documented_subcommands(text)
      local set = {}
      for sub in text:gmatch(":%[?r?a?n?g?e?%]?Ai (%l[%w_%-]*)") do
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
      assert.is_true(next(real) ~= nil, "no :Ai subcommands registered -- is :Ai defined?")
      for file, text in pairs(sources) do
        local subs = documented_subcommands(text)
        assert.is_true(
          next(subs) ~= nil,
          file .. ": found no ':Ai <sub>' mention -- extractor regex or doc format drifted"
        )
        for sub in pairs(subs) do
          assert.is_true(
            real[sub] == true,
            ("%s documents :Ai %s, which does not exist"):format(file, sub)
          )
        end
      end
    end)

    it("every real :Ai subcommand is documented in commands.md and BINDINGS.md", function()
      setup_all()
      local in_md = documented_subcommands(block_with("commands.md", ":Ai ask"))
      -- The BINDINGS.md Usercmds table: one command per row, in its first cell.
      local in_table = {}
      local rows = table_rows("BINDINGS.md", { "Command" })
      assert.is_true(#rows > 0, "BINDINGS.md: found no Usercmds rows -- table drifted?")
      for _, row in ipairs(rows) do
        for sub in pairs(documented_subcommands(row[1])) do
          in_table[sub] = true
        end
      end
      local real = vim.fn.getcompletion("Ai ", "cmdline")
      assert.is_true(#real > 0, "no :Ai subcommands registered -- is :Ai defined after setup()?")
      for _, c in ipairs(real) do
        assert.is_true(
          in_md[c] == true,
          (":Ai %s exists but is missing from commands.md"):format(c)
        )
        assert.is_true(
          in_table[c] == true,
          (":Ai %s exists but is missing from the BINDINGS.md Usercmds table"):format(c)
        )
      end
    end)

    it("the BINDINGS.md keymap tables equal the keymaps mapped after setup()", function()
      setup_all()

      -- Documented side: every `| Mode | Default | ...` table (the prefixed
      -- actions and the completion surface), as "<mode> <lhs>" keys.
      local documented = {}
      for _, row in ipairs(table_rows("BINDINGS.md", { "Mode", "Default" })) do
        local lhs =
          assert(row[2]:match("^`(.+)`$"), "BINDINGS.md: default not in backticks: " .. row[2])
        for mode in row[1]:gmatch("%a") do
          documented[mode .. " " .. lhs] = true
        end
      end
      assert.is_true(next(documented) ~= nil, "BINDINGS.md: found no keymap rows -- table drifted?")

      -- Code side: everything the "Ai" registry bound -- the prefixed surface
      -- plus the separate "Ai/completion" one -- and really mapped.
      local registered = {}
      for key, entries in pairs(require("lib.nvim.bindings.keymap").registered()) do
        if key == "Ai" or vim.startswith(key, "Ai/") then
          for _, e in ipairs(entries) do
            if e.lhs and e.bound then
              for _, m in ipairs(mode_list(e.mode)) do
                local id = m .. " " .. e.lhs
                assert.is_true(vim.fn.maparg(e.lhs, m) ~= "", id .. " is registered but not mapped")
                registered[id] = true
              end
            end
          end
        end
      end
      assert.is_true(next(registered) ~= nil, "no keymaps registered for Ai -- did setup() run?")

      for id in pairs(registered) do
        assert.is_true(
          documented[id] == true,
          (
            "%q is registered but not documented in any `| Mode | Default |` table of BINDINGS.md"
            .. " (row missing, or a table header was renamed)"
          ):format(id)
        )
      end
      for id in pairs(documented) do
        assert.is_true(
          registered[id] == true,
          ("BINDINGS.md lists %q, which is not registered"):format(id)
        )
      end

      -- Registry-independent scan: the loops above only see keymaps bound
      -- through keymap.register(), so a plain vim.keymap.set (or a lib
      -- `keymap()` call) under the prefix would stay invisible. Look at what
      -- is really mapped instead: every GLOBAL map in modes n/x/s/o/i/c/t/l
      -- (buffer-local maps are out of scope), keyed on the raw lhs and
      -- mode-agnostic -- the registry comparison above already covers the
      -- mode. nvim_get_keymap reports a literal space for a space leader, so
      -- both sides are compared as raw bytes via the translated `lhs`
      -- (`lhsraw` encodes Ctrl chords as modifier keys instead, which
      -- nvim_replace_termcodes does not).
      local DEFAULTS = require("ai.config.DEFAULTS")
      local function raw(lhs)
        return vim.api.nvim_replace_termcodes(lhs, true, true, true)
      end

      -- Self-check of that normalization on a Ctrl chord, so it cannot rot
      -- silently on another Neovim version.
      local probe = "<F20><C-j>"
      vim.keymap.set("n", probe, "<Nop>")
      local probe_seen = false
      for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
        probe_seen = probe_seen or raw(m.lhs) == raw(probe)
      end
      vim.keymap.del("n", probe)
      assert.is_true(
        probe_seen,
        "raw(nvim_get_keymap().lhs) no longer equals raw(lhs) for a Ctrl chord"
      )

      local doc_lhs = {}
      for id in pairs(documented) do
        doc_lhs[raw(id:match("^%a (.+)$"))] = true
      end
      local completion_lhs = {}
      for _, k in pairs(DEFAULTS.completion.keymap) do
        if type(k) == "string" then
          completion_lhs[raw(k)] = true
        end
      end
      local prefix = raw(DEFAULTS.keymaps.prefix)
      local scanned = 0
      for _, mode in ipairs({ "n", "x", "s", "o", "i", "c", "t", "l" }) do
        for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
          local lhs = raw(m.lhs)
          if vim.startswith(lhs, prefix) or completion_lhs[lhs] then
            scanned = scanned + 1
            assert.is_true(
              doc_lhs[lhs] == true,
              ("%s %s is mapped but missing from BINDINGS.md"):format(mode, m.lhs)
            )
          end
        end
      end
      assert.is_true(scanned > 0, "scan saw no mapped ai.nvim keymap -- lhs normalization broken?")
    end)
  end)

  describe("architecture.md", function()
    it("the lib.nvim.net.curl extension it describes exists", function()
      local code = block_with("architecture.md", "fetch_stream")
      local curl = require("lib.nvim.net.curl")
      assert.is_function(curl.fetch_stream)

      assert.is_truthy(code:find("secret_headers", 1, true))
      local found = false
      -- Code lines only: a doc comment alone must not count as "implemented".
      for _, f in ipairs(vim.api.nvim_get_runtime_file("lua/lib/nvim/net/curl/*.lua", true)) do
        for _, line in ipairs(read_lines(f)) do
          if not line:match("^%s*%-%-") and line:find("secret_headers", 1, true) then
            found = true
          end
        end
      end
      assert.is_true(found, "secret_headers is not implemented in lib.nvim.net.curl")
    end)
  end)
end)
