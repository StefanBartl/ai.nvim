---@module 'ai.providers.aliases'
--- Old provider ids that still work. The provider for the native app was called `loomai` before it became
--- `ai_desktop`; a configuration, an allow-list or a request that names the old id keeps working, and the id the
--- rest of the code sees is always the new one.

local M = {}

---Old id -> current id.
---@type table<string, string>
M.ALIASES = { loomai = "ai_desktop" }

---The current id for `id`; any other value (an id that is not an alias, a non-string) is returned as it is.
---@generic T
---@param id T
---@return T|string
function M.canonical(id)
  if type(id) == "string" and M.ALIASES[id] then
    return M.ALIASES[id]
  end
  return id
end

---The list with every alias replaced by its current id, in place, without a duplicate where both spellings are listed.
---@param list any
---@return nil
function M.canonical_list(list)
  if type(list) ~= "table" then
    return
  end
  local seen, out = {}, {}
  for _, id in ipairs(list) do
    local current = M.canonical(id)
    if type(current) ~= "string" or not seen[current] then
      out[#out + 1] = current
      if type(current) == "string" then
        seen[current] = true
      end
    end
  end
  for i = 1, math.max(#list, #out) do
    list[i] = out[i]
  end
end

---The keys of the table that are aliases moved to their current id, in place; where the current id is there already,
---its value wins and the alias is dropped.
---@param tbl any
---@return nil
function M.canonical_keys(tbl)
  if type(tbl) ~= "table" then
    return
  end
  for old, current in pairs(M.ALIASES) do
    if tbl[old] ~= nil then
      if tbl[current] == nil then
        tbl[current] = tbl[old]
      end
      tbl[old] = nil
    end
  end
end

---Every place of a user's options that names a provider, with the alias replaced by the current id, in place: the
---default provider, the order of `"auto"`, the models per provider, the allow-list, the key profiles, an agent's and
---the completion's provider.
---@param opts any
---@return nil
function M.apply(opts)
  if type(opts) ~= "table" then
    return
  end
  opts.provider = M.canonical(opts.provider)
  M.canonical_list(opts.provider_order)
  M.canonical_keys(opts.model)
  M.canonical_keys(opts.keys)
  if type(opts.policy) == "table" then
    M.canonical_list(opts.policy.allowed)
  end
  if type(opts.agents) == "table" then
    for _, agent in pairs(opts.agents) do
      if type(agent) == "table" then
        agent.provider = M.canonical(agent.provider)
      end
    end
  end
  if type(opts.completion) == "table" then
    opts.completion.provider = M.canonical(opts.completion.provider)
  end
end

return M
