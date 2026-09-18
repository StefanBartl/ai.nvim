# Commands

```
:Ai ask [prompt?]                 -- ask once, non-streaming; prompts for text if omitted
:Ai stream [prompt?]              -- like ask, but the panel opens and fills in live
:[range]Ai rewrite [prompt?]      -- replace the range with AI-generated code (default: current line)
:[range]Ai append [prompt?]       -- insert AI-generated code after the range (default: current line)
:[range]Ai prepend [prompt?]      -- insert AI-generated code before the range (default: current line)
:Ai provider <name>               -- switch the active provider (Tab-completes registered ids)
:Ai info                          -- active provider, resolution order, per-provider availability
```

Bare `:Ai [prompt?]` is the same as `:Ai ask [prompt?]`.

`:Ai` itself accepts a `-range` (needed for `rewrite`/`append`/`prepend`
below), so a stray range before `ask`/`stream`/`provider`/`info` -- a
leftover Visual selection, a typo -- no longer errors the way it used to;
it is now silently valid syntax that those four subcommands simply don't
use, and a warning says so rather than acting on it with no feedback at
all.

`ask`/`stream` build no context automatically -- they only send the literal
prompt text. The quick-action keymaps (`<leader>as`/`<leader>ae`, see
[BINDINGS.md](BINDINGS.md)) are what wire in the current
buffer/selection/diagnostics via `config.context`.

## In-place edits: rewrite/append/prepend

`rewrite`/`append`/`prepend` target a buffer range instead of assembling a
context block: a plain `:Ai rewrite fix the off-by-one` targets the current
line; `:'<,'>Ai rewrite add error handling` (or the `<leader>ar` Visual-mode
keymap) targets the selection. The task text is sent alongside a fenced copy
of that range; the model is instructed to answer with only the replacement/
insertion code (no explanation, no markdown fences) and the response
replaces (`rewrite`) or is inserted after/before (`append`/`prepend`) the
range in one buffer edit, so the whole thing is a single `u` (undo) step.
Non-streaming, same reasoning as `ask`: an in-place edit needs the complete
answer before it can write anything back.

Unlike `ask`/`stream`, which only ever render a model's answer in a popup or
a panel, these three write straight into the buffer with no preview or
confirmation step -- the code you selected (or the current line) is sent to
whichever provider is active, and its answer replaces/inserts around that
range as soon as it arrives. Treat the result the way you would any other
unreviewed paste: read it before you move on, especially in a file you did
not write yourself (a comment engineered to look like an instruction is
still just more text in the prompt to the model, not a command to this
plugin -- but a model that follows it anyway would write whatever it
produced straight into your buffer). `u` undoes the whole edit in one step;
there is no diff view.

A response that is empty, was cut off before finishing (a provider's token
limit), or arrives after the target buffer changed underneath it (closed, or
edited while the request was in flight) is discarded with a warning instead
of being applied.
