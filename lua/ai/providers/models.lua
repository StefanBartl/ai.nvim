---@module 'ai.providers.models'
--- Known-model registry per provider -- lets `:checkhealth ai` report a
--- configured model id that a provider's fixed catalogue does not
--- recognize (see ROADMAP.md, "Modell-Registry pro Provider"). This is a
--- reporting aid only: it never blocks a request. `opts.model`/`req.model`
--- still flow to the wire completely unvalidated, exactly as before (see
--- `ai/init.lua`'s `resolve()`, which reads `cfg.model[provider.id]`
--- straight into `Ai.Request.model`) -- the roadmap item asked for
--- something a health check can *report*, not a new failure mode at
--- request time.
---
--- Local/self-hosted providers (`ollama`, `loomai`) run whatever model the
--- user has pulled or already has loaded on their own machine -- there is
--- no fixed catalogue to check that against, so both are deliberately left
--- out of `M.KNOWN` and treated as always-valid (see `M.is_known`) rather
--- than forced into a fixed list that would flag a perfectly legitimate
--- local model name as "unknown".
---
--- Catalogues below are a snapshot, kept in sync by hand with each
--- provider's own `DEFAULT_MODEL` constant -- there is no live
--- discovery/list-models endpoint call here on purpose: that would turn a
--- cheap, offline health check into a network request (and, for
--- claude.lua/openai.lua, one that needs the same API key `available()`
--- already gates on). Treat an "unknown model" report as a prompt to go
--- check the provider's current docs, not as ground truth.

local M = {}

---@type table<string, string[]>
M.KNOWN = {
  claude = {
    "claude-opus-4-5",
    "claude-sonnet-4-5",
    "claude-haiku-4-5",
    "claude-opus-4-1",
    "claude-sonnet-4-0",
    "claude-3-7-sonnet-latest",
    "claude-3-5-haiku-latest",
  },
  gemini = {
    "gemini-2.5-pro",
    "gemini-2.5-flash",
    "gemini-2.5-flash-lite",
    "gemini-2.0-flash",
    "gemini-2.0-flash-lite",
  },
  openai = {
    "gpt-5",
    "gpt-5-mini",
    "gpt-4.1",
    "gpt-4.1-mini",
    "gpt-4.1-nano",
    "gpt-4o",
    "gpt-4o-mini",
    "o3",
    "o4-mini",
  },
}

---Providers deliberately excluded from `M.KNOWN` because they run
---arbitrary, user-supplied local models rather than a fixed cloud
---catalogue -- see the module doc. Kept as an explicit set (not just "any
---id absent from `M.KNOWN`") so a future provider that *should* get a real
---catalogue but hasn't been filled in yet fails loudly in review/tests
---instead of silently behaving like `ollama`/`loomai`.
---@type table<string, true>
M.OPEN_ENDED = { ollama = true, loomai = true }

---Whether `provider_id` has a fixed catalogue at all in this registry.
---False for an open-ended (local) provider, and false for any id this
---registry has no entry for -- including a custom provider a caller
---registered at runtime via `ai.providers.register`, which this module
---knows nothing about and must not flag as invalid.
---@param provider_id string
---@return boolean
function M.is_validated(provider_id)
  return M.KNOWN[provider_id] ~= nil
end

---Whether `model` is a known id for `provider_id`. Always `true` when
---`provider_id` has no fixed catalogue (`is_validated` false) -- with
---nothing to compare against, "unknown" would be a false positive rather
---than useful information.
---@param provider_id string
---@param model string
---@return boolean
function M.is_known(provider_id, model)
  local list = M.KNOWN[provider_id]
  if not list then
    return true
  end
  for _, known in ipairs(list) do
    if known == model then
      return true
    end
  end
  return false
end

---Check the configured per-provider default models (`cfg.model`, see
---`ai.config.DEFAULTS`) and the completion override (`cfg.completion.model`)
---against this registry, and return one human-readable issue string per
---model this registry does not recognize for its provider -- the same
---shape `ai.config.issues()` already produces for `:checkhealth` to render
---as warnings (see `health.lua`).
---@param cfg Ai.Config
---@return string[]
function M.check_config(cfg)
  local issues = {}

  for provider_id, model in pairs(cfg.model or {}) do
    if type(model) == "string" and not M.is_known(provider_id, model) then
      issues[#issues + 1] = ("model %q is not a known model for provider %q"):format(
        model,
        provider_id
      )
    end
  end

  local completion = cfg.completion
  local completion_model = completion and completion.model
  if type(completion_model) == "string" then
    local provider_id = (completion and completion.provider) or cfg.provider
    if type(provider_id) == "string" and not M.is_known(provider_id, completion_model) then
      issues[#issues + 1] = ("completion.model %q is not a known model for provider %q"):format(
        completion_model,
        provider_id
      )
    end
  end

  return issues
end

return M
