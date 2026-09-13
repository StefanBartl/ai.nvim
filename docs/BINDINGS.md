# Bindings cheatsheet

All keymaps sit under one configurable prefix (`config.keymaps.prefix`,
default `<leader>a`) and are individually overridable/disableable via
`config.keymaps[id]` -- see [configuration.md](configuration.md).

## Keymaps

| Mode | Default | Action id | Does |
| ---- | ------- | --------- | ---- |
| n, v | `<leader>aa` | `ask` | Ask once, non-streaming (prompts for text; v: about the selection) |
| n, v | `<leader>as` | `quick` | Send context + a typed task, stream the answer |
| n, v | `<leader>ae` | `explain` | Explain the current context in a small badge, no panel |

## Usercmds

| Command | Does |
| ------- | ---- |
| `:Ai ask [prompt?]` | Ask once, non-streaming |
| `:Ai stream [prompt?]` | Ask, streaming the answer into a panel |
| `:Ai provider <name>` | Switch the active provider |
| `:Ai info` | Show active provider + availability |

## Autocmds

| Event | Group | Does |
| ----- | ----- | ---- |
| `VimLeavePre` | `ai_nvim` | Kills every still-running stream, so quitting Neovim never leaves an orphaned curl process behind |
