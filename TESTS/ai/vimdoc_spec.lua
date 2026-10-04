-- doc/ai.txt (the `:help ai` file) is maintained by hand, and it drifts: on
-- 2026-10-01 it was found well behind docs/*.md. This spec diffs it against the
-- code and against docs/*.md, so the next drift fails here instead of waiting
-- for a reader of `:help ai`.
--
-- Checked: the help tags (via a real `:helptags` run) and every `|ai-...|` link,
-- the CONTENTS list against the section headings, the config block (must equal
-- DEFAULTS), the `:Ai` subcommand tags, the keymap tables (against the BINDINGS.md
-- tables), the provider list, `provider_order`, the attachment capability list,
-- the `ai.ask()` request fields, the context flags, the stream handler names, the
-- error kinds, the Neovim version, the environment variables and default hosts.
--
-- Not checked: prose, descriptions, and anything that is not a name, a default
-- or a list. A new fact in the vimdoc is only guarded once an extractor here
-- reads it -- the extractors fail loudly (never go vacuous) when the layout
-- they rely on changes.
---@diagnostic disable: need-check-nil

local S = require("docs_support")

local VIMDOC = S.ROOT .. "/doc/ai.txt"
local lines = S.read_lines(VIMDOC)

---Lines of numbered section `n` of the vimdoc (heading excluded), up to the next
---`====` rule.
---@param n integer
---@return string[]
local function section(n)
  local out, inside = {}, false
  for _, line in ipairs(lines) do
    if inside then
      if line:match("^=+$") then
        break
      end
      out[#out + 1] = line
    else
      local num = line:match("^(%d+)%. %u")
      inside = num ~= nil and tonumber(num) == n
    end
  end
  assert(#out > 0, ("doc/ai.txt: section %d not found"):format(n))
  return out
end

---@param list string[]
---@return table<string, true>
local function set_of(list)
  local set = {}
  for _, v in ipairs(list) do
    set[v] = true
  end
  return set
end

---Asserts two name sets are equal, naming the side each stray name is missing from.
---@param expected table<string, true>
---@param actual table<string, true>
---@param what string
local function assert_same_set(expected, actual, what)
  assert.is_true(next(expected) ~= nil, what .. ": the code side is empty -- extractor broken?")
  assert.is_true(next(actual) ~= nil, what .. ": parsed nothing from doc/ai.txt -- layout drifted?")
  for name in pairs(expected) do
    assert.is_true(actual[name] == true, ("%s: %q is missing from doc/ai.txt"):format(what, name))
  end
  for name in pairs(actual) do
    assert.is_true(
      expected[name] == true,
      ("%s: doc/ai.txt documents %q, which does not exist"):format(what, name)
    )
  end
end

---Field names of an `---@class <name>` block of lua/ai/@types/init.lua.
---@param class string
---@return table<string, true>
local function class_fields(class)
  local src = S.read(S.ROOT .. "/lua/ai/@types/init.lua")
  local at = assert(src:find("---@class " .. class, 1, true), class .. " not found in @types")
  local block = src:sub(at):match("^(.-)\n\n") or src:sub(at)
  local fields = {}
  for name in block:gmatch("\n%-%-%-@field ([%w_]+)") do
    fields[name] = true
  end
  return fields
end

---All source text under lua/ai/<subdir> (plain `.lua` files), comments included.
---@param subdir string
---@return string
local function source_of(subdir)
  local parts = {}
  local base = S.ROOT .. "/lua/ai/" .. subdir
  for name, kind in vim.fs.dir(base, { depth = 4 }) do
    if kind == "file" and name:match("%.lua$") then
      parts[#parts + 1] = S.read(base .. "/" .. name)
    end
  end
  assert(#parts > 0, "no sources under " .. base)
  return table.concat(parts, "\n")
end

describe("doc/ai.txt (:help ai) --", function()
  local tags -- every tag `:helptags` derives from the file

  before_each(function()
    for _, mod in ipairs({ "ai", "ai.config", "ai.providers" }) do
      package.loaded[mod] = nil
    end
  end)

  ---Tags as `:helptags` really sees them, from a scratch copy so the repo's
  ---doc/ directory is never written to. A duplicate tag is E154, a failure here.
  local function help_tags()
    if tags then
      return tags
    end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/doc", "p")
    vim.fn.writefile(lines, dir .. "/doc/ai.txt")
    local ok, err = pcall(vim.cmd, "helptags " .. vim.fn.fnameescape(dir .. "/doc"))
    assert(ok, "`:helptags` rejected doc/ai.txt: " .. tostring(err))
    tags = {}
    for _, line in ipairs(vim.fn.readfile(dir .. "/doc/tags")) do
      local tag = line:match("^([^\t]+)\t")
      if tag then
        tags[tag] = true
      end
    end
    vim.fn.delete(dir, "rf")
    return tags
  end

  describe("structure", function()
    it("is a well-formed help file: first-line tag, modeline, `:helptags` accepts it", function()
      assert.is_truthy(lines[1]:find("*ai.txt*", 1, true), "first line lost its *ai.txt* tag")
      local last
      for i = #lines, 1, -1 do
        if lines[i] ~= "" then
          last = lines[i]
          break
        end
      end
      assert.is_truthy(last:match("^vim:.*ft=help"), "the vim: modeline at the end is gone")
      assert.is_true(help_tags()["ai.txt"] == true)
    end)

    it("every |ai...| / |:Ai...| link resolves to a tag of this file", function()
      local defined = help_tags()
      local checked = 0
      for _, line in ipairs(lines) do
        for ref in line:gmatch("|([^|%s]+)|") do
          -- Links into Neovim's own help (|:checkhealth|, ...) are not ours to check.
          if ref:match("^ai") or ref:match("^:Ai") then
            checked = checked + 1
            assert.is_true(defined[ref] == true, ("dangling help link |%s|"):format(ref))
          end
        end
      end
      assert.is_true(checked > 10, "found almost no |ai...| links -- extractor broken?")
    end)

    it("CONTENTS lists exactly the numbered sections, in order, with their tags", function()
      local headings, toc = {}, {}
      for _, line in ipairs(lines) do
        local num, title, tag = line:match("^(%d+)%. (%u[%u%s]-)%s+%*([^*]+)%*$")
        if num then
          headings[#headings + 1] = { tonumber(num), title:lower(), tag }
        end
        local tnum, ttitle, ttag = line:match("^%s+(%d+)%. (%S.-)%s*%.%.+%s*|([^|]+)|$")
        if tnum then
          toc[#toc + 1] = { tonumber(tnum), ttitle:lower(), ttag }
        end
      end
      assert.is_true(#headings > 5, "found almost no section headings -- layout drifted?")
      assert.are.same(headings, toc)
      for i, h in ipairs(headings) do
        assert.are.equal(i, h[1], "section numbers are not consecutive")
        assert.is_true(help_tags()[h[3]] == true)
      end
    end)
  end)

  describe("configuration (section 4)", function()
    it("the config block is exactly DEFAULTS", function()
      local code, inside = {}, false
      for _, line in ipairs(section(4)) do
        if line:match(">lua%s*$") then
          inside = true
        elseif inside and line:match("^<%s*$") then
          break
        elseif inside then
          code[#code + 1] = (line:gsub("^  ", ""))
        end
      end
      assert.is_true(#code > 10, "found no config block in section 4")

      local captured
      S.run_chunk(table.concat(code, "\n"), "doc/ai.txt#config", {
        setup = function(opts)
          captured = opts
        end,
      })
      assert.is_table(captured)
      assert.are.same(require("ai.config.DEFAULTS"), captured)
    end)

    it("provider_order in the scope section is the default one", function()
      local text = table.concat(section(12), "\n")
      local list =
        assert(text:match('(%{%s*"[%w_]+"[^}]*%})'), "no provider_order list in section 12")
      local order = {}
      for id in list:gmatch('"([%w_%-]+)"') do
        order[#order + 1] = id
      end
      assert.are.same(require("ai.config.DEFAULTS").provider_order, order)
    end)
  end)

  describe("commands and bindings (sections 5-7)", function()
    it("every :Ai subcommand has its |:Ai-<sub>| tag, and no tag names a missing one", function()
      require("ai").setup()
      local real = {}
      for _, sub in ipairs(vim.fn.getcompletion("Ai ", "cmdline")) do
        real[sub] = true
      end
      local documented = {}
      for tag in pairs(help_tags()) do
        local sub = tag:match("^:Ai%-(.+)$")
        if sub then
          documented[sub] = true
        end
      end
      assert_same_set(real, documented, ":Ai subcommands")
    end)

    it("the keymap tables equal the BINDINGS.md tables (mode, lhs and action id)", function()
      ---@param modes string e.g. "n, v"
      ---@return string
      local function mode_key(modes)
        local letters = {}
        for letter in modes:gmatch("%a") do
          letters[#letters + 1] = letter
        end
        table.sort(letters)
        return table.concat(letters)
      end

      local documented = {}
      for _, line in ipairs(lines) do
        local modes, lhs, id = line:match("^  (%a[%a, ]-)  +(<%S+)  +(%l+) ")
        if modes then
          documented[mode_key(modes) .. " " .. lhs .. " " .. id] = true
        end
      end

      local expected = {}
      for _, row in ipairs(S.table_rows("BINDINGS.md", { "Mode", "Default", "Action id" })) do
        local lhs = assert(row[2]:match("^`(.+)`$"), "BINDINGS.md: default not in backticks")
        local id = assert(row[3]:match("^`(.+)`$"), "BINDINGS.md: action id not in backticks")
        expected[mode_key(row[1]) .. " " .. lhs .. " " .. id] = true
      end
      assert_same_set(expected, documented, "keymap tables")
    end)
  end)

  describe("providers (sections 9-10, 2)", function()
    local providers

    before_each(function()
      providers = require("ai.providers")
      providers.load_builtin()
    end)

    it("the provider list names exactly the built-in providers", function()
      local documented = {}
      for _, line in ipairs(section(9)) do
        local id = line:match("^  (%l+)%s%s+%S")
        if id then
          documented[id] = true
        end
      end
      assert_same_set(set_of(providers.ids()), documented, "providers")
    end)

    it("the attachment capability list matches each provider's capabilities", function()
      local documented = {}
      local in_list = false
      for _, line in ipairs(section(10)) do
        if line:match("^What each provider can carry") then
          in_list = true
        elseif in_list then
          local id, kinds = line:match("^  (%l+)%s+(%S[^%s].-)%s%s+%S")
          if id then
            documented[id] = kinds
          end
        end
      end
      local expected_ids = set_of(providers.ids())
      local documented_ids = {}
      for id, kinds in pairs(documented) do
        documented_ids[id] = true
        local caps =
          assert(providers.get(id), "doc/ai.txt lists unknown provider " .. id).capabilities
        local expected = {}
        if caps.vision then
          expected[#expected + 1] = "image"
        end
        if caps.documents then
          expected[#expected + 1] = "document"
        end
        assert.are.equal(
          #expected == 0 and "--" or table.concat(expected, ", "),
          kinds,
          id .. ": the attachment kinds disagree with its capabilities"
        )
      end
      assert_same_set(expected_ids, documented_ids, "attachment capability list")
    end)

    it("every API key / host variable a provider reads is documented, with its default", function()
      local help = table.concat(lines, "\n")
      local source = source_of("providers")
      local seen = 0
      for name in source:gmatch('"([A-Z][A-Z0-9_]*_API_KEY)"') do
        seen = seen + 1
        assert.is_truthy(
          help:find(name, 1, true),
          name .. " is read by a provider but not documented"
        )
      end
      for name in source:gmatch('"([A-Z][A-Z0-9_]*_HOST)"') do
        seen = seen + 1
        assert.is_truthy(
          help:find(name, 1, true),
          name .. " is read by a provider but not documented"
        )
      end
      assert.is_true(seen >= 4, "found almost no environment variable in lua/ai/providers")
      -- ... and the other direction: every UPPER_CASE_WITH_UNDERSCORE token of the
      -- help is an environment variable (nothing else in doc/ai.txt has that
      -- shape), so each one must be read by a provider. No suffix is assumed --
      -- a typo such as OPENAI_APIKEY or LOOMAI_HOSTT must not slip past. OLLAMA_HOST
      -- is the one name the help mentions on purpose as *not* read (it is Ollama's
      -- own variable, see AI_OLLAMA_HOST).
      local tokens = 0
      for name in help:gmatch("%f[%w_](%u[%u%d]*_[%u%d_]+)%f[^%w_]") do
        tokens = tokens + 1
        assert.is_true(
          name == "OLLAMA_HOST" or source:find('"' .. name .. '"', 1, true) ~= nil,
          name .. " is documented but no provider reads it"
        )
      end
      assert.is_true(tokens >= 6, "found almost no environment variable in doc/ai.txt")
      -- Default base URLs named in the help must be the ones in the code.
      local urls = 0
      for url in help:gmatch("(http://127%.0%.0%.1:%d+)") do
        urls = urls + 1
        assert.is_truthy(
          source:find(url, 1, true),
          url .. " is documented but is not a provider default"
        )
      end
      assert.is_true(urls > 0, "no default base URL found in doc/ai.txt")
    end)
  end)

  describe("API surface (section 8, 11)", function()
    it("the ai.ask() request fields are the Ai.Request fields", function()
      local documented, in_list = {}, false
      for _, line in ipairs(section(8)) do
        if line:match("{req} fields:") then
          in_list = true
        elseif in_list and line:match("^  {cb}") then
          break
        elseif in_list then
          local name = line:match("^    ([%l_]+)%s%s+%S")
          if name then
            documented[name] = true
          end
        end
      end
      assert_same_set(class_fields("Ai.Request"), documented, "ai.ask() request fields")
    end)

    it("the stream handlers are the Ai.StreamHandlers fields", function()
      local documented = {}
      for _, line in ipairs(section(8)) do
        local name = line:match("^    (on_[%l_]+)%s%s+")
        if name then
          documented[name] = true
        end
      end
      assert_same_set(class_fields("Ai.StreamHandlers"), documented, "stream handlers")
    end)

    it(
      "the context flags are the DEFAULTS.context keys and the Ai.ContextDefaults fields",
      function()
        local documented = {}
        for _, line in ipairs(section(11)) do
          local name = line:match("^  ([%l_]+)%s%s+%S") or line:match("^  ([%l_]+)%s*$")
          if name then
            documented[name] = true
          end
        end
        local defaults = {}
        for k in pairs(require("ai.config.DEFAULTS").context) do
          defaults[k] = true
        end
        assert_same_set(defaults, documented, "context flags (vs DEFAULTS.context)")
        assert_same_set(class_fields("Ai.ContextDefaults"), documented, "context flags (vs @types)")
      end
    )

    it("the error kinds are the ones the providers actually raise", function()
      local text = table.concat(section(8), " ")
      local list =
        assert(text:match("`kind` is one of ([^.]-)%."), "no error-kind list in section 8")
      local documented = {}
      for kind in list:gmatch("`([%l_]+)`") do
        documented[kind] = true
      end

      -- Raised: every kind named as a string literal in the sources (the @types
      -- file is excluded -- its comments are documentation, not code), and every
      -- `lib_error.new("<kind>", ...)` literal.
      local source = source_of("providers") .. source_of(""):gsub("%-%-%-@[^\n]*", "") -- annotation lines are docs, not code
      for kind in pairs(documented) do
        assert.is_truthy(
          source:find('"' .. kind .. '"', 1, true),
          ("doc/ai.txt documents error kind %q, which no source raises"):format(kind)
        )
      end
      local raised = 0
      for kind in source:gmatch('lib_error%.new%(%s*"([%l_]+)"') do
        raised = raised + 1
        assert.is_true(
          documented[kind] == true,
          ("error kind %q is raised but not documented"):format(kind)
        )
      end
      assert.is_true(raised > 0, "found no lib_error.new() call -- extractor broken?")
    end)
  end)

  describe("requirements (section 2)", function()
    it(
      "the minimum Neovim version agrees across doc/ai.txt, requirements.md and :checkhealth",
      function()
        local from_vimdoc = table.concat(section(2), "\n"):match("Neovim >= (%d+%.%d+)")
        local from_md = S.read(S.DOCS .. "requirements.md"):match("Neovim >= (%d+%.%d+)")
        local from_health = S.read(S.ROOT .. "/lua/ai/health.lua"):match("Neovim >= (%d+%.%d+)")
        assert.is_truthy(from_vimdoc, "no `Neovim >= x.y` in doc/ai.txt section 2")
        assert.are.equal(from_md, from_vimdoc)
        assert.are.equal(from_health, from_vimdoc)
      end
    )
  end)
end)
