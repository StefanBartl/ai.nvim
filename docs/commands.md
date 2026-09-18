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
