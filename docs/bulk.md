# Bulk requests

A plugin that sends a whole document to a provider in many small requests --
a translation of a Markdown buffer, say -- is a different case from a person who
selected a region and pressed a key: nobody looks at each request, the text may be
long, and it leaves the machine. `req.bulk` is the leash for that case, kept in
one place instead of in every calling plugin.

ai.nvim adds **no task logic** here: the prompt, the splitting of the text and
the check of the answer stay with the caller. `bulk` only enforces limits.

## Calling it

```lua
local handle = require("ai").ask({
  prompt = chunk,
  system = "Translate to German. Keep the Markdown.",
  provider = "claude",             -- name it; see "Policy" below
  bulk = {
    label = "mdview:README.md",    -- names the run (required)
    max_chars = 4000,              -- largest request accepted (required)
    concurrency = 2,               -- in flight per label, the rest queue (default 1)
    max_total_chars = 200000,      -- cumulative cap of this label in this session
  },
}, function(ok, res)
  if ok then
    -- res.text, res.provider, and for the caller's cache key:
    -- res.bulk = { provider, model, label, temperature, deterministic, chars }
  else
    -- res.kind: bulk_limit | cancelled | provider_resolution | invalid_request | timeout | ...
  end
end)

handle:kill()  -- the callback runs once with kind "cancelled"
```

`ai.ask` returns the handle only for a bulk request (`nil` otherwise). It
understands `kill()` and `is_closing()`; it is not a real process, because the
non-streaming providers do not expose one (see "Cancel").

## What is enforced

| Option | Meaning |
| ------ | ------- |
| `label` | Names the run. Requests with the same label share the concurrency limit and the `max_total_chars` budget. Required. |
| `max_chars` | Largest request accepted, prompt plus system, in characters. A bigger one fails with `bulk_limit` and nothing is sent. Required. |
| `concurrency` | Requests of this label in flight at once (default 1). The rest wait in a FIFO queue and start as slots free up. |
| `max_total_chars` | Cumulative characters of this label in this session. A request that would pass it fails with `bulk_limit`. `require("ai.bulk").reset(label)` starts a fresh budget; a new label does too. |
| `allow_unlisted` | This one request may use a provider outside the allow-list. Set it only after asking the user. |
| `temperature` | Temperature to send (default `0`); `false` sends none. |

`config.bulk.max_session_chars` (default `false`, no cap) is the same cap over
every bulk request of the session. A request that is admitted reserves its
characters at once, so a burst of calls cannot overshoot; one that is cancelled
before it started gives them back. A request refused with `bulk_limit` costs
nothing.

Every refusal arrives as `cb(false, err)`, never as an exception, and never
inside `ask` itself: the callback is always asynchronous and runs exactly once
(also when `kill()` and an answer race). `err.data.reason` of a `bulk_limit`
is `max_chars`, `max_total_chars` or `max_session_chars`.

A bulk request gathers no editor context and carries no attachments: put the
text in `prompt`. It does not combine with the plain `allow_unlisted`, and
`ai.stream` refuses it (`invalid_request`).

## Policy

A bulk request is stricter than a chat request, on purpose. With
`policy.allowed` set, a provider outside the list is refused before anything is
sent, with a message that says what to do. Two explicit ways out, neither silent:

- Ask the user once that document text may go to that provider, then
  `require("ai.policy").grant_bulk("<id>")` -- valid for the Neovim session,
  nothing is written. `require("ai").policy().bulk_granted` lists them.
- `bulk.allow_unlisted = true` on one request, for a caller with its own
  confirmation.

The plain `allow_unlisted` of a request and a `:Ai provider <id>` confirmation
do **not** count for bulk: they were about a selection in a chat, not about a
whole document going out unattended. `provider = "auto"` walks only listed
providers, as everywhere else.

## Cancel

`handle:kill()` ends the call: the callback runs once with
`kind = "cancelled"`, a late answer is dropped, the slot is freed. A request
that had not started costs nothing. A request already sent **cannot be
aborted** (the non-streaming providers hand out no process), so its cost is
spent. `require("ai.bulk").cancel(label)` does this for every queued and
in-flight request of a label.

A provider that never answers does not hang the caller: after the request's
`timeout_ms` plus 5 s the call fails with `kind = "timeout"` and frees its slot.

## Repeatable answers and the cache key

Bulk sends `temperature = 0` to the providers that take one (`claude`, `openai`,
`gemini`, `ollama`: `capabilities.temperature`). `loomai` and `claude-cli` have
no such parameter, so their answers are not repeatable; `res.bulk.deterministic`
says which case applied. The result names what answered, for the caller's cache
key: `res.bulk.provider` and `res.bulk.model` (`req.model`, the configured model,
the provider's built-in default, or `"default"` when the provider chooses itself),
plus the `temperature` sent.

Some models accept only their default temperature (for example OpenAI's
o-series reasoning models) and answer a request with `temperature = 0` with an
API error. For those, set `bulk.temperature = false`: nothing is sent, and
`res.bulk.deterministic` is `false`. When a provider error mentions the
temperature, the error message of the bulk call carries this hint.

## Counters

```lua
local bulk = require("ai.bulk")
bulk.usage("mdview:README.md") -- { session_chars, label_chars, active, queued }
bulk.reset("mdview:README.md") -- forget that label's budget
bulk.reset()                   -- forget everything (also the session total)
```
