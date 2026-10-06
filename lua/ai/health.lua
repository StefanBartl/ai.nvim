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
  local cfg = require("ai").config()
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
    -- Under the entry it belongs to: what the CLI is told or finds that sends its
    -- requests elsewhere or under another account than its login. A warning only
    -- where the CLI can be run (it is installed, or it is the provider, in the order
    -- or the completion's): for someone who set the variable for other tools and
    -- never uses claude-cli it is a fact to know, not a defect, and must not nag on
    -- every :checkhealth.
    if id == "claude-cli" then
      local cli = require("ai.providers.claude_cli")
      local in_use = available
        or cfg.provider == id
        or vim.tbl_contains(cfg.provider_order, id)
        or (cfg.completion and cfg.completion.provider) == id
      ---@param text string
      ---@param hints string[]
      local function report(text, hints)
        if in_use then
          vim.health.warn(text, hints)
        else
          vim.health.info(text)
        end
      end
      -- The variable is passed on to the CLI on purpose, so say where it points.
      local gateway = cli.gateway_note()
      if gateway then
        report(table.concat(gateway, " "), {
          "Check that this is the endpoint you mean; unset ANTHROPIC_BASE_URL to reach Anthropic directly",
        })
      end
      -- A credential of the CLI's own settings (an apiKeyHelper, or an API key or
      -- token in the `env` block) ranks above its login and is not environment of
      -- the child, so it is not removed from it: say that the login may not be the
      -- account that is used. Only that the key exists, never its value.
      local found = cli.settings_credentials()
      if #found.api_key_helper > 0 then
        report(
          (
            "the claude CLI's %s settings define apiKeyHelper: that credential ranks above "
            .. "its login, so claude-cli may use another account than the one logged in"
          ):format(table.concat(found.api_key_helper, " and ")),
          {
            "In the claude CLI, /status shows the credential in use; remove apiKeyHelper "
              .. "from that settings file to use the login (a managed one is set by your organization)",
          }
        )
      end
      if #found.env > 0 then
        report(
          (
            "the claude CLI's %s settings set %s in their env block: such a credential may "
            .. "override its login, so claude-cli may use another account than the one logged in"
          ):format(table.concat(found.env, " and "), table.concat(found.env_names, ", ")),
          {
            "In the claude CLI, /status shows the credential in use; remove the variable from the "
              .. "env block of that settings file to use the login (a managed one is set by your organization)",
          }
        )
      end
    end
  end

  -- ── Configuration ──────────────────────────────────────────────────────
  vim.health.start("ai.nvim: configuration")
  vim.health.info("provider = " .. cfg.provider)
  vim.health.info("provider_order = " .. table.concat(cfg.provider_order, ", "))
  for _, issue in ipairs(require("ai.config").issues()) do
    -- The issue says by itself what became of the value (a default, or for
    -- policy.allowed a refusal) -- a fixed prefix would get one of them wrong.
    vim.health.warn(issue)
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

  -- ── Policy ──────────────────────────────────────────────────────────────
  vim.health.start("ai.nvim: provider policy")
  local policy = require("ai.policy")
  local marker = (policy.allowed() or {})[1]
  if not policy.restricted() then
    vim.health.info("no allow-list (config.policy.allowed is empty) -- every provider may be used")
  elseif marker == require("ai.config").INVALID_ALLOWED then
    vim.health.error(
      "config.policy.allowed is malformed -- every provider is refused until it is fixed",
      { 'Make it a list of provider ids, e.g. policy = { allowed = { "claude", "copilot" } }' }
    )
  elseif marker == require("ai.config").INVALID_POLICY then
    vim.health.error(
      "config.policy has a key ai.nvim does not know -- every provider is refused until it is fixed",
      {
        "The warning under configuration names the key; policy has only `allowed`, "
          .. 'a list of provider ids, e.g. policy = { allowed = { "claude", "copilot" } }',
      }
    )
  elseif marker == require("ai.config").MISSPELT_POLICY then
    vim.health.error(
      "the options have a key that looks like a misspelt `policy` -- every provider is refused until it is fixed",
      {
        "The warning under configuration names the key; the option is called `policy`, "
          .. 'e.g. policy = { allowed = { "claude", "copilot" } }',
      }
    )
  else
    local allowed = policy.allowed() or {}
    vim.health.info("allowed = " .. table.concat(allowed, ", "))
    for _, id in ipairs(allowed) do
      if not providers.get(id) then
        vim.health.info(id .. ": listed, but no provider with that id is registered (yet)")
      end
    end
    -- is_allowed, not is_listed: a session grant (`:Ai provider`) lets requests
    -- through, and those are reported as grants below, not as refused.
    if cfg.provider ~= "auto" and not policy.is_allowed(cfg.provider) then
      vim.health.warn(
        ("provider = %q is not on the allow-list -- requests that use it are refused"):format(
          cfg.provider
        ),
        { "Set provider to one of: " .. table.concat(allowed, ", ") }
      )
    end
    local completion_provider = cfg.completion and cfg.completion.provider
    if completion_provider and not policy.is_allowed(completion_provider) then
      vim.health.warn(
        ("completion.provider = %q is not on the allow-list -- completion requests are refused"):format(
          completion_provider
        ),
        { "Set completion.provider to one of: " .. table.concat(allowed, ", ") }
      )
    end
    if #policy.filter(cfg.provider_order) == 0 then
      vim.health.warn(
        'provider_order shares no entry with the allow-list -- provider = "auto" can never resolve',
        { "Add an allowed provider to provider_order" }
      )
    end
    for _, id in ipairs(policy.granted()) do
      vim.health.warn(
        id .. ": allowed for this session outside the allow-list (a confirmed :Ai provider)"
      )
    end
  end

  -- ── Keys ────────────────────────────────────────────────────────────────
  vim.health.start("ai.nvim: key profiles")
  local keys = require("ai.keys")
  local key_issues = keys.issues()
  if #key_issues == 0 and #keys.providers() == 0 then
    vim.health.info(
      "no key profiles (config.keys is empty) -- each provider reads its own variable"
    )
  end
  for _, issue in ipairs(key_issues) do
    vim.health.warn(issue)
  end
  for _, id in ipairs(keys.providers()) do
    local line = ("%s: %s"):format(id, keys.describe(id))
    if line:find("KEY MISSING", 1, true) then
      vim.health.warn(line, { "Set the variable or create the file the profile names" })
    else
      vim.health.ok(line)
    end
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
  if pcall(require, "gitsuite.features.conflict") then
    vim.health.ok("gitsuite.nvim detected -- context.conflict available")
  else
    vim.health.info(
      "gitsuite.nvim not found (optional) -- context.conflict is unavailable; every other context flag still works"
    )
  end

  -- The declared external tools (docs/install.json): a pointer to
  -- `:Lib deps show`, not a second report -- the checks above already say
  -- more per tool. Silent when lib.nvim.deps is absent (an older lib.nvim).
  local ok_deps, deps_health = pcall(require, "lib.nvim.deps.health")
  if ok_deps and type(deps_health.pointer_for) == "function" then
    vim.health.start("ai: declared tools (lib.nvim.deps)")
    deps_health.pointer_for("ai.nvim")
  end

  -- ── composer route pre-flight ────────────────────────────────────────────
  require("lib.nvim.bindings.usercmd.composer").checkhealth("Ai")
end

return M
