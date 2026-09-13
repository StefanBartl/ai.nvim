---@module 'ai.health'
--- `:checkhealth ai` -- Neovim version, lib.nvim dependencies (including the
--- `fetch_stream` extension ai.nvim needs specifically), curl, per-provider
--- availability (never a key's value, only whether one is set), and the
--- `:Ai` composer route pre-flight.

local lib_health = require("lib.nvim.health")

local M = {}

---@return nil
function M.check()
  vim.health.start("ai.nvim: core")
  if lib_health.version_ok({ 0, 10, 0 }) then
    vim.health.ok("Neovim >= 0.10 (vim.system)")
  else
    vim.health.error("Neovim 0.10+ required -- lib.nvim.net.curl needs vim.system")
  end

  if vim.fn.executable("curl") == 1 then
    vim.health.ok("curl on PATH")
  else
    vim.health.error("curl not found on PATH -- every provider needs it", { "Install curl" })
  end

  -- ── lib.nvim dependency ────────────────────────────────────────────────
  vim.health.start("ai.nvim: lib.nvim")
  local advice = { 'Install "StefanBartl/lib.nvim"' }
  lib_health.check_require("lib.nvim.net.curl", "net.curl (transport)", "error", advice)
  lib_health.check_require("lib.nvim.harvest.scope", "harvest.scope (context)", "error", advice)
  lib_health.check_require(
    "lib.nvim.progress",
    "progress (thinking/streaming indicator)",
    "error",
    advice
  )
  lib_health.check_require("lib.nvim.ui.kit", "ui.kit (answer panel + badge)", "error", advice)
  lib_health.check_require("lib.nvim.usercmd.composer", "usercmd.composer (:Ai)", "error", advice)
  lib_health.check_require("lib.nvim.bindings.keymap", "bindings.keymap (keymaps)", "error", advice)

  local ok_curl, curl = pcall(require, "lib.nvim.net.curl")
  if ok_curl then
    if type(curl.fetch_stream) == "function" then
      vim.health.ok("lib.nvim.net.curl.fetch_stream present")
    else
      vim.health.error(
        "lib.nvim.net.curl.fetch_stream missing -- lib.nvim checkout is too old for ai.nvim",
        { "Update StefanBartl/lib.nvim" }
      )
    end
  end

  -- ── Providers ────────────────────────────────────────────────────────────
  vim.health.start("ai.nvim: providers")
  local providers = require("ai.providers")
  providers.load_builtin()
  for _, id in ipairs(providers.ids()) do
    local p = providers.get(id)
    local available = p and type(p.available) == "function" and p.available()
    if available then
      vim.health.ok(id .. ": available")
    else
      vim.health.info(id .. ": not available (missing binary and/or API key)")
    end
  end

  -- ── Configuration ──────────────────────────────────────────────────────
  vim.health.start("ai.nvim: configuration")
  local cfg = require("ai").config()
  vim.health.info("provider = " .. cfg.provider)
  vim.health.info("provider_order = " .. table.concat(cfg.provider_order, ", "))

  -- ── composer route pre-flight ────────────────────────────────────────────
  require("lib.nvim.usercmd.composer").checkhealth("Ai")
end

return M
