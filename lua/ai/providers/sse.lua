---@module 'ai.providers.sse'
--- Shared helpers for the SSE-based providers (`claude`, `openai`) --
--- `ollama` is NDJSON, a different line shape, and does not use this module.
---
--- Both SSE providers independently hit the same real quirk: a fatal
--- auth/validation failure on a streaming request does not come back as an
--- SSE event -- it is a plain, pretty-printed (multi-line!) JSON body, and
--- curl itself still exits 0. Individual lines like `{` or `  "error": {`
--- are not valid JSON on their own, so a caller collects every non-`data:`
--- line and only tries to parse the joined block once the stream ends. This
--- module is the one place that dance lives, instead of two near-identical
--- copies drifting apart.

local M = {}

---Extract the payload from an SSE `data: ...` line, if it is one.
---@param line string
---@return string|nil payload nil if `line` does not start with `data:`
function M.data_payload(line)
  return line:match("^data:%s*(.*)$")
end

---Try to recover a fatal error response that arrived as a plain,
---pretty-printed JSON body instead of an SSE event (see module doc). Callers
---still decide what counts as an error shape for their own API (Anthropic's
---`{type="error", error={message=...}}` vs. OpenAI's `{error={message=...}}`)
----- this only does the shared "safely decode the joined lines" part.
---@param non_data_lines string[]
---@return table|nil decoded nil if there were no lines, or they were not
---valid JSON, or decoding didn't produce a table
function M.recover_error_body(non_data_lines)
  if #non_data_lines == 0 then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(non_data_lines, "\n"))
  if ok and type(decoded) == "table" then
    return decoded
  end
  return nil
end

return M
