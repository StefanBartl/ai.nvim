# Commands

```
:Ai ask [prompt?]          -- ask once, non-streaming; prompts for text if omitted
:Ai stream [prompt?]       -- like ask, but the panel opens and fills in live
:Ai provider <name>        -- switch the active provider (Tab-completes registered ids)
:Ai info                   -- active provider, resolution order, per-provider availability
```

Bare `:Ai [prompt?]` is the same as `:Ai ask [prompt?]`.

None of these build any context automatically -- they only send the literal
prompt text. The quick-action keymaps (`<leader>as`/`<leader>ae`, see
[BINDINGS.md](BINDINGS.md)) are what wire in the current
buffer/selection/diagnostics via `config.context`.
