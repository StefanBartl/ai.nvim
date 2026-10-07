-- doc/ai.txt (the `:help ai` file) is maintained by hand, and it drifts: on
-- 2026-10-01 it was found well behind docs/*.md. This spec diffs it against the
-- code and against docs/*.md, so the next drift fails here instead of waiting
-- for a reader of `:help ai`.
--
-- Checked: the help tags (via a real `:helptags` run) and every link, the
-- CONTENTS list against the section headings, the config block (must equal
-- DEFAULTS) and its provider-id comment, the `:Ai` subcommand tags, the keymap
-- tables (against BINDINGS.md), the provider list, `provider_order`, the
-- attachment capability list and extension list, the inline-body threshold, the
-- `ai.ask()` request fields, the context flags (twice), the stream handler names,
-- the error kinds (both ways), the Neovim version, and -- per provider -- its
-- environment variables and default base URL.
--
-- Not checked: prose, descriptions, and anything that is not a name, a default
-- or a list. A new fact in the vimdoc is only guarded once an extractor here
-- reads it; the extractors fail loudly (never go vacuous) when the layout they
-- rely on changes. Sections are found by their help tag, not by their number, so
-- inserting a section does not break the lookups.
---@diagnostic disable: need-check-nil

-- Self-contained: a spec must not depend on how it was started (a plain
-- :PlenaryBustedFile has no TESTS/minimal_init.lua behind it).
package.path = vim.fn.getcwd() .. "/TESTS/?.lua;" .. package.path
local S = require("docs_support")

local VIMDOC = S.ROOT .. "/doc/ai.txt"

---@type string[] doc/ai.txt, read in before_each so a missing file is a failing
---test and not an error while the spec loads (which would hang the runner)
local lines

---Lines of the numbered section whose heading carries the help tag `tag` (heading
---excluded), up to the next `====` rule.
---@param tag string e.g. "ai-config"
---@return string[]
local function section(tag)
  local out, inside = {}, false
  for _, line in ipairs(lines) do
    if inside then
      if line:match("^=+$") then
        break
      end
      out[#out + 1] = line
    elseif line:match("^%d+%. .*%*" .. vim.pesc(tag) .. "%*%s*$") then
      inside = true
    end
  end
  assert(#out > 0, ("doc/ai.txt: no section tagged *%s*"):format(tag))
  return out
end

---`id -> text` of an indented list: a line matching `item_pat` (first capture is
---the id) starts an item, following lines indented by 3+ spaces continue it.
---@param sec string[]
---@param item_pat string
---@return table<string, string>
local function items(sec, item_pat)
  local out, current = {}, nil
  for _, line in ipairs(sec) do
    local id = line:match(item_pat)
    if id then
      current = id
      out[id] = line
    elseif current and line:match("^%s%s%s+%S") then
      out[current] = out[current] .. "\n" .. line
    else
      current = nil
    end
  end
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
---@param expected table<string, true> the code side
---@param actual table<string, true> what doc/ai.txt says
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
  -- With the newline: `Ai.Request` must not match a longer `Ai.RequestFoo`.
  local at =
    assert(src:find("---@class " .. class .. "\n", 1, true), class .. " not found in @types")
  local block = src:sub(at):match("^(.-)\n\n") or src:sub(at)
  local fields = {}
  for name in block:gmatch("\n%-%-%-@field ([%w_]+)") do
    fields[name] = true
  end
  return fields
end

---Code lines of one file, comment lines removed: a name that only appears in a
---comment is not code.
---@param path string
---@return string[]
local function code_lines(path)
  local out = {}
  for _, line in ipairs(S.read_lines(path)) do
    if not line:match("^%s*%-%-") then
      out[#out + 1] = line
    end
  end
  return out
end

---Code of every `.lua` file under lua/ai/<subdir> (empty = all of lua/ai).
---@param subdir string
---@return string
local function code_of(subdir)
  local parts = {}
  local base = S.ROOT .. "/lua/ai/" .. subdir
  for name, kind in vim.fs.dir(base, { depth = 4 }) do
    if kind == "file" and name:match("%.lua$") then
      vim.list_extend(parts, code_lines(base .. "/" .. name))
    end
  end
  assert(#parts > 0, "no sources under " .. base)
  return table.concat(parts, "\n")
end

---Names a provider reads from the environment: `util.env_value("NAME"`.
---@param source string
---@return string[]
local function env_reads(source)
  local names = {}
  for name in source:gmatch('env_value%("([%u%d_]+)"') do
    names[#names + 1] = name
  end
  -- A provider whose key may come from a named profile asks `ai.keys`, passing
  -- its own variable as the default.
  for name in source:gmatch('keys"%)%.get%("[%w_%-]+", "([%u%d_]+)"') do
    names[#names + 1] = name
  end
  return names
end

describe("doc/ai.txt (:help ai) --", function()
  local tags -- every tag `:helptags` derives from the file

  S.isolate_install()

  before_each(function()
    lines = S.read_lines(VIMDOC)
    tags = nil
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

    it("every |link| resolves: to a tag of this file, or to Neovim's own help", function()
      local defined = help_tags()
      -- Neovim's own tags are only checkable where its help is installed.
      local core_help = #vim.fn.getcompletion("quickfix", "help") > 0
      local mine = 0
      local in_code = false
      for _, line in ipairs(lines) do
        -- A `>lua` ... `<` example is code, not prose: its `|` (a Lua alternation
        -- in a comment, say) is no link.
        if line:match(">%a*%s*$") and not in_code then
          in_code = true
        elseif in_code and line:match("^<%s*$") then
          in_code = false
        end
        for ref in (in_code and "" or line):gmatch("|([^|%s]+)|") do
          if defined[ref] then
            mine = mine + 1
          elseif ref:match("^ai") or ref:match("^:Ai") then
            error(("dangling help link |%s|"):format(ref)) -- ours by name: a typo must fail
          elseif core_help then
            assert.is_true(
              vim.tbl_contains(vim.fn.getcompletion(ref, "help"), ref),
              ("|%s| is neither a tag of doc/ai.txt nor of Neovim's help"):format(ref)
            )
          end
        end
      end
      assert.is_true(mine > 10, "found almost no links to this file -- extractor broken?")
    end)

    it("CONTENTS lists exactly the numbered sections, in order, with their tags", function()
      local headings, toc = {}, {}
      for _, line in ipairs(lines) do
        local num, title, tag = line:match("^(%d+)%. (%u.-)%s+%*([^*]+)%*$")
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

  describe("configuration", function()
    ---@return string code of the config block (the one calling setup())
    local function config_block()
      local blocks, current = {}, nil
      for _, line in ipairs(section("ai-config")) do
        if line:match(">lua%s*$") then
          current = {}
        elseif current and line:match("^<%s*$") then
          blocks[#blocks + 1] = table.concat(current, "\n")
          current = nil
        elseif current then
          current[#current + 1] = (line:gsub("^  ", ""))
        end
      end
      local hits = {}
      for _, code in ipairs(blocks) do
        if code:find('require("ai").setup(', 1, true) then
          hits[#hits + 1] = code
        end
      end
      assert.are.equal(1, #hits, "expected exactly one setup() block in the configuration section")
      return hits[1]
    end

    it("the config block is exactly DEFAULTS", function()
      local captured
      S.run_chunk(config_block(), "doc/ai.txt#config", {
        setup = function(opts)
          captured = opts
        end,
      })
      assert.is_table(captured)
      assert.are.same(require("ai.config.DEFAULTS"), captured)
    end)

    it("the provider-id comment of the config block lists the built-in providers", function()
      local comment = assert(
        config_block():match('provider = "auto",[^\n]-%-%-([^\n]*)'),
        "the `provider = ...` line lost its id comment"
      )
      local documented = {}
      for id in comment:gmatch('"([%w_%-]+)"') do
        if id ~= "auto" then
          documented[id] = true
        end
      end
      local providers = require("ai.providers")
      providers.load_builtin()
      assert_same_set(set_of(providers.ids()), documented, "provider ids in the config comment")
    end)

    it("provider_order in the scope section is the default one", function()
      local text = table.concat(section("ai-scope"), "\n")
      local list =
        assert(text:match('(%{%s*"[%w_]+"[^}]*%})'), "no provider_order list in the scope section")
      local order = {}
      for id in list:gmatch('"([%w_%-]+)"') do
        order[#order + 1] = id
      end
      assert.are.same(require("ai.config.DEFAULTS").provider_order, order)
    end)

    it("the documented completion idle default is DEFAULTS.completion.idle_ms", function()
      local text = table.concat(section("ai-completion"), " ")
      local ms = assert(
        text:match("`completion%.idle_ms` %(default%s+(%d+)%)"),
        "no idle_ms default in the prose"
      )
      assert.are.equal(require("ai.config.DEFAULTS").completion.idle_ms, tonumber(ms))
    end)
  end)

  describe("commands and bindings", function()
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
        local modes, lhs, id = line:match("^  (%a[%a, ]-)  +(<%S+)  +([%w_%-]+) ")
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

  describe("providers", function()
    local providers

    before_each(function()
      providers = require("ai.providers")
      providers.load_builtin()
    end)

    it("the provider list names exactly the built-in providers", function()
      local documented = {}
      for id in pairs(items(section("ai-providers"), "^  ([%w_%-]+)%s%s+%S")) do
        documented[id] = true
      end
      assert_same_set(set_of(providers.ids()), documented, "providers")
    end)

    it("the attachment capability list matches each provider's capabilities", function()
      local rows = {}
      local in_list = false
      for _, line in ipairs(section("ai-attachments")) do
        if line:match("^What each provider can carry") then
          in_list = true
        elseif in_list then
          local id, kinds = line:match("^  ([%w_%-]+)%s+(%S[^%s].-)%s%s+%S")
          if id then
            rows[id] = kinds
          end
        end
      end
      local documented_ids = {}
      for id, kinds in pairs(rows) do
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
      assert_same_set(set_of(providers.ids()), documented_ids, "attachment capability list")
    end)

    it("the recognized file extensions and the inline-body threshold match the code", function()
      local text = table.concat(section("ai-attachments"), "\n")
      local documented = {}
      local list = assert(text:match("Recognized extensions:([^\n]*)"), "no extension list")
      for ext in list:gmatch("%.(%w+)") do
        documented[ext] = true
      end
      local expected = {}
      for ext in code_of(""):gmatch('\n%s+(%l+) = "[%w]+/[%w%.%+%-]+",') do
        expected[ext] = true
      end
      assert_same_set(expected, documented, "recognized extensions")

      local kb = assert(text:match("A body over (%d+) KB"), "no inline-body threshold in the prose")
      assert.are.equal(
        require("ai.providers.transport").MAX_INLINE_BODY_BYTES,
        tonumber(kb) * 1024,
        "the documented threshold is not transport.MAX_INLINE_BODY_BYTES"
      )
    end)

    it("each provider's environment variables and default URL are documented under it", function()
      local requirements = items(section("ai-requirements"), "^  %- ([%w_%-]+):")
      local list = items(section("ai-providers"), "^  ([%w_%-]+)%s%s+%S")
      local checked = 0
      for _, id in ipairs(providers.ids()) do
        -- This provider's own file only: a name read by another provider must
        -- not satisfy it.
        local own = table.concat(
          code_lines(S.ROOT .. "/lua/ai/providers/" .. id:gsub("%-", "_") .. ".lua"),
          "\n"
        )
        local reads = env_reads(own)
        local host = own:match('DEFAULT_HOST = "([^"]+)"')
        local bullet = assert(requirements[id], id .. ": no bullet in the requirements section")
        for _, name in ipairs(reads) do
          checked = checked + 1
          assert.is_truthy(
            bullet:find(name, 1, true),
            id .. ": " .. name .. " is read but not named in its requirements bullet"
          )
        end
        -- ... and the other direction: every variable the bullet names is read by
        -- this provider (OLLAMA_HOST is mentioned on purpose as *not* read).
        for name in bullet:gmatch("%f[%w_](%u[%u%d]*_[%u%d_]+)%f[^%w_]") do
          assert.is_true(
            name == "OLLAMA_HOST" or vim.tbl_contains(reads, name),
            id .. ": its requirements bullet names " .. name .. ", which it does not read"
          )
        end
        for _, text in ipairs({ bullet, list[id] or "" }) do
          for url in text:gmatch("(http://127%.0%.0%.1:%d+)") do
            assert.are.equal(host, url, id .. ": a documented URL is not its DEFAULT_HOST")
          end
        end
        if host then
          checked = checked + 1
          assert.is_truthy(
            bullet:find(host, 1, true),
            id .. ": DEFAULT_HOST " .. host .. " is missing from its requirements bullet"
          )
        end
      end
      assert.is_true(checked >= 5, "checked almost nothing -- extractors broken?")
    end)

    it("every environment variable named anywhere in the help is one a provider reads", function()
      local reads = set_of(env_reads(code_of("providers")))
      local documented = {}
      for _, line in ipairs(lines) do
        for name in line:gmatch("%f[%w_](%u[%u%d]*_[%u%d_]+)%f[^%w_]") do
          -- Ollama's own variable, named on purpose as the one NOT read.
          if not (name == "OLLAMA_HOST" and line:find("not `OLLAMA_HOST`", 1, true)) then
            documented[name] = true
          end
        end
      end
      assert_same_set(reads, documented, "environment variables")
    end)
  end)

  describe("API surface", function()
    it("the ai.ask() request fields are the Ai.Request fields", function()
      local documented, in_list = {}, false
      for _, line in ipairs(section("ai-api")) do
        if line:match("{req} fields:") then
          in_list = true
        elseif in_list and line:match("^  {cb}") then
          break
        elseif in_list then
          local name = line:match("^    ([%w_]+)%s%s+%S")
          if name then
            documented[name] = true
          end
        end
      end
      assert_same_set(class_fields("Ai.Request"), documented, "ai.ask() request fields")
    end)

    it("the stream handlers are the Ai.StreamHandlers fields", function()
      local documented = {}
      for _, line in ipairs(section("ai-api")) do
        local name = line:match("^    (on_[%w_]+)%s%s+")
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
        for _, line in ipairs(section("ai-context")) do
          local name = line:match("^  ([%w_]+)%s%s+%S") or line:match("^  ([%w_]+)%s*$")
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

        -- The flag list in the ai.context.assemble() entry of the API section.
        local api = table.concat(section("ai-api"), " ")
        local list = assert(
          api:match("`Ai%.ContextDefaults`:%s*(.-), all%s+boolean"),
          "no flag list in the assemble() entry"
        )
        local in_api = {}
        for flag in list:gmatch("`([%w_]+)`") do
          in_api[flag] = true
        end
        assert_same_set(defaults, in_api, "context flags in the assemble() entry")
      end
    )

    it("the documented error kinds are exactly the ones the providers raise", function()
      local text = table.concat(section("ai-api"), " ")
      local list =
        assert(text:match("`kind` is one of ([^.]-)%."), "no error-kind list in the API section")
      local documented = {}
      for kind in list:gmatch("`([%w_]+)`") do
        documented[kind] = true
      end
      -- Raised = a `lib_error.new("<kind>", ...)` call in real code. Comment lines
      -- are stripped by code_of, so a kind that is only *mentioned* does not count.
      local raised = {}
      for kind in code_of(""):gmatch('lib_error%.new%(%s*"([%w_]+)"') do
        raised[kind] = true
      end
      assert_same_set(raised, documented, "error kinds")
    end)
  end)

  describe("requirements", function()
    it(
      "the minimum Neovim version agrees across doc/ai.txt, requirements.md and :checkhealth",
      function()
        local requirements = table.concat(section("ai-requirements"), "\n")
        local from_vimdoc = requirements:match("Neovim >= (%d+%.%d+)")
        local from_md = S.read(S.DOCS .. "requirements.md"):match("Neovim >= (%d+%.%d+)")
        -- The real threshold is the tuple handed to version_ok(), not the message.
        local major, minor = S.read(S.ROOT .. "/lua/ai/health.lua")
          :match("version_ok%(%s*{%s*(%d+)%s*,%s*(%d+)")
        assert.is_truthy(from_vimdoc, "no `Neovim >= x.y` in the requirements section")
        assert.is_truthy(major, "health.lua no longer calls version_ok({ major, minor, ... })")
        assert.are.equal(from_md, from_vimdoc)
        assert.are.equal(major .. "." .. minor, from_vimdoc)
      end
    )
  end)
end)
