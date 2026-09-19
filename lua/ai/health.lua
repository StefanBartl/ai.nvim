---@module 'ai.health'
--- `:checkhealth ai` -- Neovim version, lib.nvim dependencies (including the
--- `fetch_stream` extension ai.nvim needs specifically), curl, per-provider
--- availability (never a key's value, only whether one is set), configured
--- model ids checked against `ai.providers.models`'s per-provider registry,
--- and the `:Ai` composer route pre-flight.

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
  lib_health.check_require(
    "lib.nvim.bindings.usercmd.composer",
    "usercmd.composer (:Ai)",
    "error",
    advice
  )
  lib_health.check_require("lib.nvim.bindings.keymap", "bindings.keymap (keymaps)", "error", advice)

  -- ── ui.nvim dependency ────────────────────────────────────────────────
  -- Moved out of the lib.nvim section above: ui.kit lives in ui.nvim now,
  -- not lib.nvim -- a stale "Update lib.nvim" hint here would point at the
  -- wrong repo for anyone missing it. No fallback anywhere it is used
  -- (ask/stream/explain/info all render through kit.popup/kit.surface), so
  -- it stays error-level like the lib.nvim submodules above.
  vim.health.start("ai.nvim: ui.nvim")
  lib_health.check_require(
    "ui.kit",
    "ui.kit (answer panel + badge)",
    "error",
    { 'Install "StefanBartl/ui.nvim"' }
  )

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
      -- Which attachment kinds this provider's API has a slot for. Reported
      -- only for an available provider, and as a plain fact rather than a
      -- warning: "no attachments" is a correct state for a text-only
      -- backend, not a defect. Worth surfacing because the failure it
      -- explains happens at request time and names the provider, not the
      -- config -- someone whose PDF request fails with "this provider's API
      -- takes no document payload" should be able to find out here which
      -- provider would have taken it.
      local caps = p and p.capabilities or {}
      local kinds = {}
      if caps.vision then
        kinds[#kinds + 1] = "image"
      end
      if caps.documents then
        kinds[#kinds + 1] = "document"
      end
      vim.health.info(
        ("  %s: attachments = %s"):format(
          id,
          #kinds > 0 and table.concat(kinds, ", ") or "none (text only)"
        )
      )
    else
      -- "ℹ️ INFO " prefix: this is a real adapter/backend status list, the
      -- case UI-61 calls out where the prefix earns its place (vs. a bare
      -- info() for a plain fact like a version or a path).
      vim.health.info("ℹ️ INFO " .. id .. ": not available (missing binary and/or API key)")
    end
  end

  -- ── Configuration ──────────────────────────────────────────────────────
  vim.health.start("ai.nvim: configuration")
  local cfg = require("ai").config()
  vim.health.info("provider = " .. cfg.provider)
  vim.health.info("provider_order = " .. table.concat(cfg.provider_order, ", "))
  for _, issue in ipairs(require("ai.config").issues()) do
    vim.health.warn("invalid config value, using the default -- " .. issue)
  end
  -- A model id is never rejected at request time (see
  -- `ai.providers.models`'s module doc) -- this is the surface the roadmap
  -- item asked for: report it here instead, against each provider's own
  -- known-model catalogue, with no fixed catalogue at all for a local
  -- provider like ollama/loomai (there is nothing to validate a
  -- self-hosted model name against).
  for _, issue in ipairs(require("ai.providers.models").check_config(cfg)) do
    vim.health.warn(issue, { "Check the provider's current docs for supported model ids" })
  end

  -- ── Completion ──────────────────────────────────────────────────────────
  vim.health.start("ai.nvim: completion")
  if not cfg.completion or not cfg.completion.enable then
    vim.health.info("disabled (config.completion.enable = false)")
  else
    vim.health.info("trigger = " .. tostring(cfg.completion.trigger))
    local resolved_provider = cfg.completion.provider or cfg.provider
    vim.health.info(
      "provider = "
        .. tostring(resolved_provider)
        .. " (completion.provider, falling back to provider)"
    )
    if cfg.completion.trigger == "auto" then
      vim.health.warn(
        "auto-trigger fires a request on every idle pause while typing, "
          .. "not just on deliberate action -- if `completion.provider` "
          .. "resolves to a paid cloud provider, this has a real cost",
        {
          'Set completion.provider = "ollama" (or similar) for auto mode, or use trigger = "manual"',
        }
      )
    end
  end

  -- ── Optional integrations ────────────────────────────────────────────────
  vim.health.start("ai.nvim: optional integrations")
  if pcall(require, "data.detect") then
    vim.health.ok("data.nvim detected -- context.structured_data available")
  else
    vim.health.info(
      "data.nvim not found (optional) -- context.structured_data is unavailable; every other context flag still works"
    )
  end

  -- ── composer route pre-flight ────────────────────────────────────────────
  require("lib.nvim.bindings.usercmd.composer").checkhealth("Ai")
end

return M
