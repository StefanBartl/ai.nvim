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
| `temperature` | Temperature to send (default `0`); `false` sends none. When set it wins over the request's own `temperature`, which stands when this is not set. |

`config.bulk.max_session_chars` (default `false`, no cap) is the same cap over
every bulk request of the session. A request that is admitted reserves its
characters at once, so a burst of calls cannot overshoot; one that is cancelled
before it started gives them back. A request refused with `bulk_limit` costs
nothing.

This is a cost guard, so it never fails open. `0` is a cap like any other: it
refuses every bulk request. A value that cannot be a cap -- a string such as
`"500000"`, a negative number, `true`, or a misspelt key under `bulk` -- is
reported when `setup()` runs and refuses every bulk request until it is fixed;
it does not turn into "no cap". Only `false` means none.

Every refusal arrives as `cb(false, err)`, never as an exception, and never
inside `ask` itself: the callback is always asynchronous and runs exactly once
(also when `kill()` and an answer race). That holds for input that is not what
it should be, too: a field of the wrong type (`system`, `timeout_ms`,
`temperature`, ...) is an `invalid_request`, and a NUL byte in the text counts
as one character like any other. `err.data.reason` of a `bulk_limit` is
`max_chars`, `max_total_chars` or `max_session_chars`.

A bulk request gathers no editor context and carries no attachments: put the
text in `prompt`. It does not combine with the plain `allow_unlisted`, and
`ai.stream` refuses it (`invalid_request`).

A long queue is fine: requests that wait are started one after the other without
growing the stack, also when the provider answers (or fails) at once, and
`usage().queued` is a counter, not a scan.

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

A request that is still waiting for a command-sourced key (`config.keys`,
see [Key profiles](configuration.md#key-profiles)) is not sent yet: if it is cancelled, or the watchdog
gives up on it, it is not sent when the key command finishes either -- the
document text does not leave the machine after the cancel.

A provider that never answers does not hang the caller: after the request's
`timeout_ms` plus 5 s the call fails with `kind = "timeout"` and frees its slot.

## A key that cannot be had

When a request fails with `missing_api_key` -- a locked vault, a cancelled
passphrase prompt, an unset variable -- the requests of the same label that
still wait for the same provider fail at once with that error, without being
sent and without running the key command again. Otherwise a document of 300
chunks would run the key command 300 times, unattended. The first callback is
the one of the request that hit the problem; the characters of the others are
given back. Other errors do not do this: the queue goes on.

## Repeatable answers and the cache key

Bulk sends `temperature = 0` to the providers that take one (`claude`, `openai`,
`gemini`, `ollama`: `capabilities.temperature`). `loomai`, `claude-cli` and `copilot` have
no such parameter, so their answers are not repeatable; `res.bulk.deterministic`
says which case applied. The result names what answered, for the caller's cache
key: `res.bulk.provider` and `res.bulk.model` (`req.model`, the configured model,
the provider's built-in default, or `"default"` when the provider chooses itself),
plus the `temperature` sent.

Some models accept only their default temperature (for example OpenAI's
o-series reasoning models) and answer a request with `temperature = 0` with an
API error. For those, set `bulk.temperature = false`: nothing is sent -- also
not a `temperature` the request itself carries -- and `res.bulk.deterministic`
is `false`. When a provider error mentions the temperature, the error message of
the bulk call carries this hint.

`res.bulk.temperature` and `res.bulk.deterministic` always say what was really
sent: `bulk.temperature` if set, else the request's own `temperature`, else `0`,
and none for a provider that has no such parameter.

## Counters

```lua
local bulk = require("ai.bulk")
bulk.usage("mdview:README.md") -- { session_chars, label_chars, active, queued }
bulk.reset("mdview:README.md") -- forget that label's budget
bulk.reset()                   -- forget everything (also the session total)
```

`:Ai info` and `:checkhealth ai` show the session cap and how much of it is used,
and list a provider that was confirmed for bulk requests with
`ai.policy.grant_bulk` (document text goes there without anyone looking at each
request).
