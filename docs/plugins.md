# Plugins

Every language Thor highlights is a Lua plugin (`plugins/<id>/plugin.lua`),
backed either by a tree-sitter grammar or, for simpler formats, a pure-Lua
lexer. Plugins can also add commands, panels and key bindings — this page
covers using them; see [`plugins/README.md`](../plugins/README.md) for
writing one.

## Syntax highlighting

Thor ships plugins for Odin, Lua, C, C++, Go, Jai, JavaScript/JSX, TypeScript,
TSX, Rust, Python, Ruby, Java, Kotlin, Zig, C#, PHP, Haskell, OCaml, and
config/markup formats such as JSON, Markdown, shell and batch. Nothing to
configure — a file's extension (or, for extensionless names like `Makefile`,
its basename) picks the plugin.

## Permissions and the trust prompt

A plugin only gets capabilities it declares (`exec`, `read`, `write`, `ui`,
`keys`, `tick`) and only after you allow it. Plugins asking for nothing —
every syntax plugin — load silently. A plugin that asks for something holds
until you answer a prompt Thor shows once per session, batching every waiting
plugin into it. The prompt lists one row per plugin — its id and what it asks
for — and scrolls when there are more than fit. **Allow** (or Enter) runs all of
them; **Not now** (or Escape) leaves them all unloaded and asks again next
start.

Your answers are remembered (in `sessions/plugin-grants.json`), so the prompt
does not repeat unless a plugin starts asking for more. **Settings > Plugin
Permissions** lists every installed plugin, what it wants, and whether it is
allowed or blocked — allow one there and it loads immediately; block a running
one and the change takes effect on the next start.

## Workspace plugins

A folder Thor opens can carry its own plugins in `<workspace>/.thor/plugins/`,
laid out the same way as the bundled ones. They are for something that
belongs to one project — a lexer for a repo-specific format, a panel over its
build output. Two differences from bundled plugins:

- **The prompt is never skipped**, even for a plugin that asks for no
  permissions — it is code the opened folder carries, so Thor asks before
  running it regardless.
- **The answer is per folder.** Allowing a workspace plugin in one repository
  says nothing about a plugin of the same name in another.

A workspace plugin whose id matches a bundled one replaces it for that
workspace.

## Adding your own

See [`plugins/README.md`](../plugins/README.md) for the sandbox rules, the
permission table, and how to write a plugin — either a `<workspace>/.thor/plugins/`
folder for one project, or a bundled `plugins/<id>/` folder for everyone using
that Thor install.
