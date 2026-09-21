-- TESTS/minimal_init.lua — headless test bootstrap for ai.nvim.
--
-- Run from the repo root:
--   nvim --clean --headless -u TESTS/minimal_init.lua \
--     -c "PlenaryBustedDirectory TESTS/ai { minimal_init = 'TESTS/minimal_init.lua', sequential = true }"
--
-- (scripts/test.sh wraps exactly that.) `-u` (not `-c luafile` after startup)
-- matters: 'runtimepath' additions must land before Neovim's own plugin/
-- directory scan, which is what registers plenary's :PlenaryBusted* commands
-- in the first place -- appending rtp afterwards leaves those commands
-- undefined. `--clean` matters too: without it, 'runtimepath' still defaults
-- to stdpath('config')/stdpath('data') -- a real user's own Neovim config,
-- plugins and all -- which is not what a CI run (or anyone else's machine)
-- should be exercising.
vim.opt.rtp:append(vim.fn.getcwd())

--- lib.nvim is a runtime dependency (net.curl, harvest.scope, progress,
--- usercmd.composer, notify, ...), not an optional one -- ai.nvim's own
--- modules `require("lib.*")` directly, so the specs cannot run without it
--- on the rtp. plenary.nvim is the busted-compatible test harness the specs
--- under TESTS/ai are already written against (describe/it/before_each,
--- busted assertions).
---
--- ui.nvim (ui.kit) is NOT added here: none of the specs under TESTS/ai
--- touch ai.ui.panel/ai.ui.badge/ai.bindings.actions, the only modules that
--- require it, and every one of those requires is lazy (inside a handler
--- function, never at module load) -- so the suite genuinely does not need
--- it on the rtp. Add it the same way as lib.nvim above if a future spec
--- starts exercising one of those modules directly.
---
--- Three ways each can be found, in descending order of explicitness: an
--- explicit env var (`LIB_NVIM_DIR`/`PLENARY_DIR`), a `.deps/<name>` checkout
--- (what CI uses), or a sibling checkout next to this repo (`../lib.nvim`,
--- `../plenary.nvim`) for a local contributor who already has both cloned
--- that way.
---@param env_var string
---@param deps_name string
---@param marker string module `require()`d to confirm the directory is right
local function add_dep(env_var, deps_name, marker)
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
  io.stderr:write(("TESTS/minimal_init.lua: %s not found.\n"):format(deps_name))
  io.stderr:write(
    ("  Set %s, or clone it to .deps/%s, or place it beside this repo.\n"):format(
      env_var,
      deps_name
    )
  )
  os.exit(1)
end

add_dep("LIB_NVIM_DIR", "lib.nvim", "lib.nvim.notify")
add_dep("PLENARY_DIR", "plenary.nvim", "plenary")

--- data.nvim is an OPTIONAL soft dependency (`ai.context`'s
--- `structured_data` flag) -- unlike lib.nvim/plenary above, its absence
--- must never fail the run: the spec that needs it checks
--- `pcall(require, "data.detect")` itself and skips (registers zero `it`s)
--- when missing, same convention data.nvim's own optional-dep specs use.
--- Same search order as `add_dep`, just without the `os.exit(1)` on
--- failure.
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

-- Swap and shada stay off for the whole suite, including plenary's child
-- processes that reuse this file: stale swap files fail suites with E326.
vim.o.swapfile = false
vim.o.shadafile = "NONE"
