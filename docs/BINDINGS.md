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

## Completion keymaps

A second, separate keymap surface (insert mode, no shared prefix --
individually overridable/disableable via `config.completion.keymap[id]`,
see [configuration.md](configuration.md)):

| Mode | Default | Action id | Does |
| ---- | ------- | --------- | ---- |
| i | `<C-\><C-a>` | `trigger` | Request a completion suggestion at the cursor (manual mode only) |
| i | `<Tab>` | `accept` | Insert the shown suggestion; falls through to normal `<Tab>` when nothing is shown or a completion-menu popup is open |
| i | `<C-]>` | `dismiss` | Clear the shown suggestion without inserting it |

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
| `TextChangedI`, `CursorMovedI` | `AiCompletion` | Dismisses a shown completion suggestion once the buffer/cursor moves past it (`completion.enable = true` only) |
| `InsertLeave` | `AiCompletion` | Clears completion state and stops a pending auto-trigger timer |
| `TextChangedI` | `AiCompletion` | Schedules an auto-trigger completion after an idle pause (`completion.trigger = "auto"` only) |
