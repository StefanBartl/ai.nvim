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

local M = {}

---@type { id: string, module: string }[]
local BUILTIN = {
  { id = "claude", module = "ai.providers.claude" },
  { id = "ollama", module = "ai.providers.ollama" },
  { id = "openai", module = "ai.providers.openai" },
  { id = "gemini", module = "ai.providers.gemini" },
  { id = "loomai", module = "ai.providers.loomai" },
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
      return mod and mod[key] or nil
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
---@return boolean
local function is_available(p)
  return type(p.available) == "function" and p.available() or false
end

---Resolve `id` to a concrete, available provider. `id == "auto"` walks
---`order` in sequence and returns the first entry whose `available()` is
---true; an explicit `id` is looked up directly and must itself be
---available. A provider absent from `order` is only ever reachable by
---naming it explicitly -- see the module doc for why that matters for
---`"loomai"`.
---@param id string
---@param order string[]
---@return Ai.Provider|nil provider
---@return string|nil err
function M.resolve(id, order)
  if id ~= "auto" then
    local p = registered[id]
    if not p then
      return nil, string.format("ai: unknown provider '%s'", id)
    end
    if not is_available(p) then
      return nil, string.format("ai: provider '%s' is not available", id)
    end
    return p, nil
  end

  for _, candidate_id in ipairs(order or {}) do
    local p = registered[candidate_id]
    if p and is_available(p) then
      return p, nil
    end
  end
  return nil, "ai: no provider available (checked: " .. table.concat(order or {}, ", ") .. ")"
end

return M
