-- TESTS/minimal_init.lua -- puts this plugin and its dependencies on the runtimepath.
--
--   nvim -n -i NONE --headless -u TESTS/minimal_init.lua ...
--
-- It runs nothing itself. A dependency that cannot be found is FATAL (NEW-40): the message names
-- all four places that were searched and the process exits with code 1, so that a run which could
-- not load its dependency never looks green. Each dependency <name> is looked up in, in this order:
--   1. $<NAME>_DIR                  (lib.nvim -> $LIB_NVIM_DIR)
--   2. <repo>/.deps/<name>          (what CI checks out)
--   3. <repo>/../<name>             (a sibling checkout)
--   4. stdpath('data')/lazy/<name>  (what a plugin manager installed)
-- An override (1) that is set but wrong decides alone; it is never skipped.

local this = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(this)))

-- Hard dependencies only. data.nvim and gitsuite.nvim are optional (see below); ui.nvim is not
-- needed: none of the specs touch ai.ui.panel / ai.ui.badge / ai.bindings.actions, the only
-- modules that require it, and every one of those requires is lazy.
local DEPS = { "testing.nvim", "lib.nvim" }

---@type table<string, string>
local MARKERS = { ["lib.nvim"] = "lua/lib/nvim", ["testing.nvim"] = "lua/testing" }

---@param name string
---@return string
local function env_name(name)
  return (name:upper():gsub("[^%w]", "_")) .. "_DIR"
end

---@param dir string|nil
---@param marker string
---@return boolean
local function valid(dir, marker)
  return dir ~= nil and dir ~= "" and vim.fn.isdirectory(dir .. "/" .. marker) == 1
end

local found, failures = {}, {}
for _, name in ipairs(DEPS) do
  local marker = MARKERS[name] or "lua"
  local override = vim.env[env_name(name)]
  local places = {
    { "$" .. env_name(name), override },
    { (".deps/%s"):format(name), root .. "/.deps/" .. name },
    { ("../%s"):format(name), vim.fs.dirname(root) .. "/" .. name },
    {
      ("stdpath('data')/lazy/%s"):format(name),
      vim.fs.normalize(vim.fn.stdpath("data")) .. "/lazy/" .. name,
    },
  }
  local hit
  if override ~= nil and override ~= "" then
    if valid(override, marker) then
      hit = override
    end
  else
    for i = 2, #places do
      if valid(places[i][2], marker) then
        hit = places[i][2]
        break
      end
    end
  end
  if hit then
    found[name] = hit
  else
    local lines = { ("error: dependency '%s' not found. Searched, in this order:"):format(name) }
    for i, p in ipairs(places) do
      lines[#lines + 1] = ("  %d. %s (%s)"):format(i, p[1], p[2] or "unset")
    end
    lines[#lines + 1] = ("Set $%s, or clone it to .deps/%s, or place it beside this repo."):format(
      env_name(name),
      name
    )
    failures[#failures + 1] = table.concat(lines, "\n")
  end
end

if #failures > 0 then
  io.stderr:write(table.concat(failures, "\n"), "\n")
  os.exit(1)
end

vim.opt.rtp:prepend(root)
for _, name in ipairs(DEPS) do
  vim.opt.rtp:append(found[name])
end

-- Carried over from TESTS/minimal_init.lua (replaced by the migration): what the suite needs
-- besides the runtimepath. Review each block; the diff of the removed file shows all of it.

--- data.nvim is an OPTIONAL soft dependency (`ai.context`'s
--- `structured_data` flag) -- unlike lib.nvim above, its absence
--- must never fail the run: the spec that needs it checks
--- `pcall(require, "data.detect")` itself and skips (registers zero `it`s)
--- when missing, same convention data.nvim's own optional-dep specs use.
--- Search order: the env var, `.deps/<name>`, a sibling checkout; a miss is
--- silent (no `os.exit`).
---@param env_var string
---@param deps_name string
---@param marker string
local function add_optional_dep(env_var, deps_name, marker)
  if pcall(require, marker) then
    return
  end
  local candidates = {}
  local env_val = vim.env[env_var]
  if env_val and env_val ~= "" then
    candidates[#candidates + 1] = env_val
  end
  candidates[#candidates + 1] = vim.fn.getcwd() .. "/.deps/" .. deps_name
  candidates[#candidates + 1] = vim.fs.dirname(vim.fn.getcwd()) .. "/" .. deps_name
  for _, dir in ipairs(candidates) do
    if dir and vim.fn.isdirectory(dir) == 1 then
      vim.opt.rtp:append(dir)
      if pcall(require, marker) then
        return
      end
    end
  end
end

add_optional_dep("DATA_NVIM_DIR", "data.nvim", "data.detect")

--- gitsuite.nvim is an OPTIONAL soft dependency too (`ai.context`'s
--- `conflict` flag) -- same convention as data.nvim above: the spec checks
--- `pcall(require, "gitsuite.features.conflict")` itself and skips when
--- missing, plus a separate `package.loaded`-stubbed describe block gives
--- CI-guaranteed coverage regardless of whether a real checkout is found.
add_optional_dep("GITSUITE_NVIM_DIR", "gitsuite.nvim", "gitsuite.features.conflict")

-- No spec may read the claude CLI's real settings (they can hold credential
-- commands): the user settings location points at a directory that does not
-- exist. A spec that needs settings files passes fixtures of its own.
vim.env.CLAUDE_CONFIG_DIR = vim.fn.tempname()

-- Swap and shada stay off for the whole suite, including the child
-- editors that reuse this file: stale swap files fail suites with E326.
vim.o.swapfile = false
vim.o.shadafile = "NONE"

return { root = root, deps = found }
