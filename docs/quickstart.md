# Quickstart

Set an API key for at least one provider (or have Ollama running locally),
then:

```
:Ai ask
```

Type a prompt, hit enter -- the answer appears in a read-only popup.

For a longer answer that streams in as it is generated:

```
:Ai stream
```

Or use the default keymaps (all under `<leader>a`, see
[BINDINGS.md](BINDINGS.md)):

- `<leader>aa` -- ask (prompts for text)
- `<leader>as` -- send the current context + a typed task, stream the answer
- `<leader>ae` -- explain the current context in a small badge, no panel

`:Ai info` shows the active provider and which ones are available on this
machine -- never a key's actual value.
