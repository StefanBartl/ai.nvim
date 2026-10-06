---@module 'ai.providers'
--- Provider registry. Built-in providers are lazy-loaded (the real module,
--- and whatever work its top-level `require` does, loads only the first
--- time one of its fields is actually touched) -- the same proxy pattern
--- `pdfport.nvim/lua/pdfport/backends/init.lua` uses for its extraction
--- backends.
---
--- `"loomai"` is in both `BUILTIN` and `DEFAULTS.lua`'s `provider_order`
--- (loomAI exposes `/ask`/`/ask/stream`, see `lua/ai/providers/loomai.lua`)
--- -- listed last, since it needs a local server the user must run
--- themselves and should not shadow a cloud/CLI provider that is already
--- configured and working. `resolve("auto", order)` only ever walks `order`,
--- so a *custom* provider a caller registers under its own id still stays
--- opt-in exactly the same way -- it has to be added to `provider_order`
--- explicitly to be reachable through `"auto"`.

require("ai.@types")

local lib_error = require("lib.lua.error")

local M = {}

---@type { id: string, module: string }[]
local BUILTIN = {
  { id = "claude", module = "ai.providers.claude" },
  { id = "ollama", module = "ai.providers.ollama" },
  { id = "openai", module = "ai.providers.openai" },
  { id = "gemini", module = "ai.providers.gemini" },
  { id = "loomai", module = "ai.providers.loomai" },
  { id = "claude-cli", module = "ai.providers.claude_cli" },
  { id = "copilot", module = "ai.providers.copilot" },
}

---@type table<string, Ai.Provider>
local registered = {}

---@internal
---@param entry { id: string, module: string }
---@return Ai.Provider
local function make_lazy(entry)
  ---@type Ai.Provider|nil
  local loaded = nil
  local load_failed = false

  local function load()
    if loaded or load_failed then
      return loaded
    end
    local ok, mod = pcall(require, entry.module)
    if ok and type(mod) == "table" then
      loaded = mod
    else
      load_failed = true
    end
    return loaded
  end

  return setmetatable({ id = entry.id }, {
    __index = function(_, key)
      local mod = load()
      -- Not `mod and mod[key] or nil`: that form would silently turn a
      -- legitimate `false` field value into `nil` (ERR-60's `a and b or c`
      -- trap) -- currently inert since no `Ai.Provider` field is ever
      -- boolean `false`, but there is no reason to keep the latent trap
      -- around for a field that becomes one later.
      if not mod then
        return nil
      end
      return mod[key]
    end,
  })
end

---Register every built-in provider as a lazy proxy. Idempotent: calling it
---again just rebuilds the same proxies, harmless since nothing has loaded
---yet at that point.
---@return nil
function M.load_builtin()
  for _, entry in ipairs(BUILTIN) do
    registered[entry.id] = make_lazy(entry)
  end
end

---Register a custom (or replacement) provider. Registering under an id that
---already exists -- built-in or previously custom -- replaces it: the last
---registration for a given id wins, so a user's own
---`require("ai.providers").register(...)` after `setup()` can override a
---built-in provider (e.g. to point "claude" at a proxy).
---@param provider Ai.Provider
---@return nil
function M.register(provider)
  assert(
    type(provider) == "table" and type(provider.id) == "string" and provider.id ~= "",
    "ai.providers.register: expects an Ai.Provider with a non-empty string id"
  )
  registered[provider.id] = provider
end

---@param id string
---@return Ai.Provider|nil
function M.get(id)
  return registered[id]
end

---@return string[] every registered provider id, built-in and custom, sorted
function M.ids()
  local ids = {}
  for id in pairs(registered) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  return ids
end

---@internal
---A lazy proxy's `__index` returns `nil` for every field once its module has
---failed to `require` (see `make_lazy`/`load_failed` above) -- including
---`available` itself, so calling `p.available()` unguarded would raise
---"attempt to call a nil value" instead of the intended "not available".
---@param p Ai.Provider
---@param req Ai.Request|nil the request being resolved, if any -- see `Ai.Provider`'s doc for why availability can depend on it
---@return boolean
local function is_available(p, req)
  return type(p.available) == "function" and p.available(req) or false
end

---The `missing_api_key` error for `id` when it is unavailable *because* its
---chosen key profile has no key (`ai.keys`), `nil` otherwise. Naming the
---profile is the point: a bare "not available" hides what to fix, and under
---`"auto"` skipping the provider would send the request on to another one.
---@param id string
---@return LibErrorValue|nil
local function profile_key_error(id)
  if require("ai.keys").blocked(id) then
    -- The variable name is only used without a profile, and `blocked` means one is active.
    return require("ai.providers.util").missing_key_error(id, "")
  end
  return nil
end

---Capability names a provider has, in a fixed order, for `:Ai info`. `vision`
---and `documents` are shown by the attachment kind they accept.
---@param p Ai.Provider|nil
---@return string[]
function M.capability_names(p)
  local caps = p and p.capabilities or {}
  local out = {}
  for _, pair in ipairs({
    { "streaming", "streaming" },
    { "vision", "image" },
    { "documents", "document" },
    { "web", "web" },
  }) do
    if caps[pair[1]] then
      out[#out + 1] = pair[2]
    end
  end
  return out
end

---Resolve `id` to a concrete, available provider. `id == "auto"` walks
---`order` in sequence and returns the first entry whose `available()` is
---true; an explicit `id` is looked up directly and must itself be
---available. A provider absent from `order` is only ever reachable by
---naming it explicitly -- see the module doc for why that matters for
---`"loomai"`. A provider that is unavailable only because its chosen key
---profile has no key fails the request with `missing_api_key` (explicit or
---`"auto"`): the walk never moves on to another provider from there.
---@param id string
---@param order string[]
---@param req? Ai.Request the request being resolved -- passed on to each candidate's `available()`, so a per-request `api_key` counts towards availability the same way the provider's own env var does
---@return Ai.Provider|nil provider
---@return LibErrorValue|nil err
function M.resolve(id, order, req)
  -- `load_builtin()` normally runs from `ai.setup()`, but ai.nvim is also a
  -- library another plugin calls into (`pdfport.nvim`'s claude/ollama
  -- extraction backends go through `require("ai").ask()`), and that plugin
  -- cannot require its users to have called `ai.setup()` first. An empty
  -- registry here means exactly that case -- not "the user deregistered
  -- everything", which nothing can do -- so registering the built-ins is
  -- right rather than reporting "unknown provider 'claude'" for a provider
  -- that ships in this repo.
  if next(registered) == nil then
    M.load_builtin()
  end

  local policy = require("ai.policy")

  if id ~= "auto" then
    local p = registered[id]
    if not p then
      return nil,
        lib_error.new(
          "provider_resolution",
          string.format("ai: unknown provider '%s'", id),
          { id = id }
        )
    end
    -- Before availability, so a refused provider says "not allowed" rather
    -- than "no key": the allow-list is the more useful thing to hear about.
    if not policy.is_allowed(id, req) then
      return nil,
        lib_error.new(
          "provider_resolution",
          string.format(
            "ai: provider '%s' is not on this machine's allow-list (%s)",
            id,
            policy.describe()
          ),
          { id = id, reason = "policy", allowed = policy.allowed() }
        )
    end
    if not is_available(p, req) then
      local key_err = profile_key_error(id)
      if key_err then
        return nil, key_err
      end
      return nil,
        lib_error.new(
          "provider_resolution",
          string.format("ai: provider '%s' is not available", id),
          { id = id }
        )
    end
    return p, nil
  end

  -- "auto" only ever walks `order` (see the module doc), and with an
  -- allow-list only the part of it the policy admits: a provider that happens
  -- to have a key set must not be picked when the machine does not list it.
  local walk = policy.filter(order or {}, req)
  for _, candidate_id in ipairs(walk) do
    local p = registered[candidate_id]
    if p and is_available(p, req) then
      return p, nil
    end
    -- A chosen key profile without a key ends the walk instead of being
    -- skipped, or the request would quietly go out under another provider.
    local key_err = p and profile_key_error(candidate_id)
    if key_err then
      return nil, key_err
    end
  end
  -- "policy" only when the allow-list actually removed something; a plain
  -- missing key or binary is not the policy's doing.
  local filtered = policy.restricted() and #walk < #(order or {})
  local message = "ai: no provider available (checked: " .. table.concat(walk, ", ") .. ")"
  if filtered then
    message = message .. "; " .. policy.describe()
  end
  return nil,
    lib_error.new(
      "provider_resolution",
      message,
      { order = order, checked = walk, reason = filtered and "policy" or nil }
    )
end

return M
