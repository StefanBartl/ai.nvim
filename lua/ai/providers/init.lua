---@module 'ai.providers'
--- Provider registry. Built-in providers are lazy-loaded (the real module,
--- and whatever work its top-level `require` does, loads only the first
--- time one of its fields is actually touched) -- the same proxy pattern
--- `pdfport.nvim/lua/pdfport/backends/init.lua` uses for its extraction
--- backends.
---
--- `"loomai"` is deliberately NOT in `BUILTIN`: as of this writing, loomAI
--- (a separate, native multi-agent framework -- see the project's own notes)
--- exposes no ask/completion-shaped HTTP endpoint to build a provider
--- against. The `Ai.Provider` interface is cut so that adding it later is a
--- new file here, not a redesign -- and `resolve("auto", order)` only ever
--- walks `order`, so a future `loomai` entry stays opt-in even once
--- registered: it has to be added to `provider_order` explicitly to be
--- reachable through `"auto"`, exactly like a user's own custom provider.

require("ai.@types")

local M = {}

---@type { id: string, module: string }[]
local BUILTIN = {
  { id = "claude", module = "ai.providers.claude" },
  { id = "ollama", module = "ai.providers.ollama" },
  { id = "openai", module = "ai.providers.openai" },
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
    if not p.available() then
      return nil, string.format("ai: provider '%s' is not available", id)
    end
    return p, nil
  end

  for _, candidate_id in ipairs(order or {}) do
    local p = registered[candidate_id]
    if p and p.available() then
      return p, nil
    end
  end
  return nil, "ai: no provider available (checked: " .. table.concat(order or {}, ", ") .. ")"
end

return M
