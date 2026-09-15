---@module 'scripts.gen_map'
--- CLI entry point for ai.nvim's own module map, via documentation.nvim.
---
---   nvim --headless -l scripts/gen_map.lua                    # regenerate
---   nvim --headless -l scripts/gen_map.lua --check            # verify, write nothing
---   nvim --headless -l scripts/gen_map.lua --check --lenient  # fail on staleness only
---   nvim --headless -l scripts/gen_map.lua --full             # + LuaLS enrichment
---
--- Copied from documentation.nvim's own scripts/gen_map.lua verbatim (see
--- its docs/reuse.md) except for the options table at the bottom, and minus
--- the BINDINGS.md-writing block that script also has -- that part is
--- specific to documentation.nvim self-documenting its own `:DocBrowse`
--- keys, not part of the generic reuse recipe. `docs/map/` itself is not
--- committed here (see NEW-20/CMT-16: this repo isn't documentation.nvim or
--- docmap-desktop, the two exceptions that do commit their own map).

local root = vim.uv.cwd():gsub("\\", "/"):gsub("/+$", "")
vim.opt.runtimepath:prepend(root)

--- Put a dependency on the runtimepath, if it is not already reachable.
---
--- A headless `nvim -l` run starts with no plugin manager, so nothing beyond
--- `root` is on the rtp -- `documentation` and `lib.nvim` both have to be
--- found by hand. Three candidates, in descending order of explicitness: an
--- environment variable (what CI sets), a `.deps/` checkout (what CI clones
--- into), and a sibling checkout (what a local development tree looks like).
---@param modname string A module the dependency provides, used as the probe.
---@param dirname string Repository directory name.
local function ensure(modname, dirname)
  if pcall(require, modname) then
    return
  end
  local candidates = {}
  local env_dir = vim.env[dirname:upper():gsub("[.-]", "_") .. "_DIR"]
  if env_dir and env_dir ~= "" then
    candidates[#candidates + 1] = env_dir
  end
  candidates[#candidates + 1] = root .. "/.deps/" .. dirname
  candidates[#candidates + 1] = vim.fs.dirname(root) .. "/" .. dirname
  for _, dir in ipairs(candidates) do
    if vim.fn.isdirectory(dir) == 1 then
      vim.opt.runtimepath:prepend(dir)
      if pcall(require, modname) then
        return
      end
    end
  end
  io.stderr:write(("gen_map: %s not found (probed require('%s')).\n"):format(dirname, modname))
  io.stderr:write(
    ("  Set %s_DIR, clone it to .deps/%s, or check it out beside this repo.\n"):format(
      dirname:upper():gsub("[.-]", "_"),
      dirname
    )
  )
  os.exit(1)
end

ensure("lib.nvim.fs.read", "lib.nvim")
ensure("documentation.core.cli", "documentation.nvim")

local opts = require("documentation.config").build(root, {
  source = "lua/ai",
  title = "ai.nvim",
  out_dir = "docs/map",
  repo_url = "https://github.com/StefanBartl/ai.nvim",
  branch = "main",
})

local code = require("documentation.core.cli").run(opts, _G.arg or {})
vim.cmd("cq " .. code)
