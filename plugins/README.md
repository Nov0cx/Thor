# Plugins

Editor plugins written in Lua live here, one folder per plugin
(`plugins/<name>/plugin.lua`). The host that loads and runs them is the Odin
`plugin` package (`../plugin`).

An opened folder can carry plugins of its own in `<workspace>/.thor/plugins/`,
with the same layout. See [Workspace plugins](#workspace-plugins).

## The sandbox

Every plugin runs in its own environment inside one shared Lua state:

- Globals are per plugin. Two plugins never see each other's variables, and `_G`
  inside a plugin is that plugin's own environment.
- The standard library is trimmed to `table`, `string`, `math`, `utf8`,
  `coroutine` and the clock half of `os` (`clock`, `date`, `difftime`, `time`).
  `io`, `package` and `debug` are never loaded; `load`, `dofile`, `loadfile` and
  `collectgarbage` are removed. The string metatable is locked.
- `require "name"` loads `name.lua` from the plugin's own folder into the same
  environment. Plain names only — nothing outside the folder resolves.
- One call into a plugin may hold the frame for two seconds. Past that the call
  fails with `plugin exceeded its time budget` and the editor keeps running. The
  budget covers a coroutine too, and it is the call's budget: time a coroutine
  spends resumed counts against the call that resumed it.
- `thor.exec` blocks the frame while the command runs, and the budget above
  cannot stop it — it counts Lua instructions, and there are none to count while
  a command runs. So `thor.exec` stops the command itself once the call's budget
  is spent, and appends `[shell] command stopped after ...` to what it returns.
  A plugin that needs a long command must run it in pieces across `on_tick`.
- File paths a plugin passes to `thor.read`, `thor.write` and `thor.doc` resolve
  against the open workspace and must stay inside it or inside the plugin's own
  folder.

This contains buggy and rogue plugins. It is not a boundary against native code.

## Permissions

A plugin declares what it needs in `plugin.json` beside `plugin.lua`:

```json
{
    "name": "Git",
    "permissions": ["exec", "write", "ui"]
}
```

| Permission | Grants |
| ---------- | ------ |
| `exec`     | `thor.exec` |
| `read`     | `thor.read` |
| `write`    | `thor.write`, `thor.doc` |
| `ui`       | `thor.button`, `thor.menu`, `thor.panel`, `thor.prompt`, `thor.pick`, `thor.confirm` |
| `keys`     | `thor.on_key` |
| `tick`     | `thor.on_tick` |

No manifest grants nothing, which is all a syntax-only plugin needs. A denied
entry point is absent rather than present-and-refusing, so calling it raises
`attempt to call a nil value`. `thor.permissions()` returns what was granted, so
a plugin can degrade instead of erroring.

A plugin that asks for a permission does not run until the user allows it. Thor
asks once, for every waiting plugin in one prompt, and remembers the answer in
`<exe>/sessions/plugin-grants.json`; a plugin that later asks for more is asked
again. Plugins asking for nothing — every language plugin — load without a
prompt. Dismissing the prompt leaves those plugins unloaded for the session.

Settings has a **Plugin Permissions** section listing every installed plugin
that wants something, with what it wants and whether it is Allowed or Blocked.
Allowing one there runs it immediately; blocking one that is already running
takes effect on the next start, since a plugin cannot be taken back out of the
running VM.

## Workspace plugins

A folder Thor opens can hold its own plugins in `<workspace>/.thor/plugins/`,
one folder per plugin, exactly like this directory. They are for a plugin that
belongs to one project: a lexer for a format the repo invents, a panel over its
build output, a command that only makes sense there.

They differ from the bundled ones in three ways:

- **Consent is never skipped.** A bundled plugin that wants no permission loads
  silently; a workspace plugin never does. It is code the opened folder carries,
  so Thor asks before running it even when it asks for nothing. The two groups
  are asked separately, bundled first.
- **The answer is per folder.** A grant records the workspace path, the plugin
  id and the permissions allowed, so allowing `build-panel` in one repository
  says nothing about a plugin of that name in another. Grants live beside the
  bundled ones in `<exe>/sessions/plugin-grants.json`.
- **They override by id.** An allowed workspace plugin whose id matches a
  bundled one replaces it — the bundled plugin is not loaded. The override holds
  even if the workspace plugin then fails, so a broken override reports itself
  instead of quietly falling back.

Opening another folder reloads the whole plugin set: the outgoing workspace's
plugins stop, the new one's are scanned and asked for. Settings lists every
workspace plugin, marked `.thor/plugins`, whatever it asks for; changing an
answer there reloads on the next frame.

Grants key on the folder, the id and the permissions — not on the file
contents. Editing an allowed plugin's Lua does not ask again, which is what
makes a plugin editable in place, and what makes an allowed folder a folder you
trust. Thor asks again when the plugin widens what it wants.

Always available: `thor.register_language`, `thor.print`, `thor.keybind`,
`thor.on_command`, `thor.workspace`, `thor.active_path`, `thor.refresh_git`,
`thor.permissions`, `thor.theme` and `thor.ts`. Each one waits to be called, so a
plugin that asks for no permission runs only when the user does something.

## Following the editor

`thor.on_tick(fn)` (permission `tick`) runs `fn` from the frame loop, ten times a
second — for a plugin that must notice what the user did rather than wait to be
called. One handler per plugin, and it holds the frame while it runs, so keep it
short and do nothing when nothing changed:

```lua
local last = nil

thor.on_tick(function()
    local src = thor.read "notes.md"
    if src ~= last then
        last = src
        panel:render(outline_of(src))
    end
end)
```

`thor.on_key(fn)` (permission `keys`) sees every key press before the editor
does, so the buffer it reads is the one from *before* that key. A plugin that
watches what the user typed wants `on_tick`; one that watches which chord was
pressed wants `on_key`. `fn` gets one table: `chord` in the display form
`thor.keybind` returns, and the booleans `ctrl`, `shift`, `alt` and `cmd` — `cmd`
is the Command key on macOS and the Windows key elsewhere. Return `true` to
consume the press.

## Languages

```lua
thor.register_language {
    name = "odin",
    extensions = { ".odin" },
    grammar = "odin",                -- a tree-sitter grammar compiled into Thor
    highlights = "highlights.scm",   -- optional; a file here, or a query inline
    colors = { keyword = thor.theme.keywords, comment = thor.theme.comments },
}
```

`colors` maps tree-sitter capture names (or their head, so `type.builtin` falls
back to `type`) to theme roles. Without `grammar`, supply a `highlight` function
returning `{ start, end, role }` byte spans instead.

A `highlight` function is given the whole buffer. Add `line_based = true` when it
reads each line on its own, and it is given only the lines the pane shows, which
is what keeps a large file responsive:

```lua
thor.register_language {
    name       = "INI",
    extensions = { ".ini" },
    highlight  = lex,
    line_based = true,   -- no state carried from one line to the next
}
```

The spans are then relative to the lines passed in, so a lexer must not assume
it starts at byte 0 of the file. Leave the flag off for a lexer that carries
state across lines — a block comment, a fenced block, a multi-line string.

`highlights` replaces the grammar's compiled-in highlights query. A name ending
in `.scm` is read from the plugin's folder; anything else is the query itself. A
query that does not compile is reported on the console with its byte offset and
reason, and the language keeps the built-in query.

A query may filter a pattern with `#eq?`, `#any-of?`, `#match?` (a regular
expression), `#lua-match?` (a Lua pattern), `#has-parent?` and the `#not-` form
of each. Directives (`#set!` and friends) are ignored. A predicate Thor does not
evaluate never holds, which retires its whole pattern; the console names it once.

Grammars stay compiled into the editor. Adding one is a source change (see
`CLAUDE.md`); queries over an existing grammar are data.

## Tree-sitter

```lua
local tree, err = thor.ts.parse(source, "odin")
local root = tree:root()

for _, match in ipairs(tree:query "(comment) @c") do
    thor.print(match.c:text())
end
```

- `thor.ts.supports(grammar)` — whether the grammar is in this build.
- `thor.ts.parse(source, grammar)` — a tree, or `nil, message`. Parsing the same
  buffer again as it is edited costs the edit, not the file: the last tree the
  plugin parsed under that grammar seeds the next parse.
- `thor.ts.parse_active(grammar)` (permission `read`) — the same, for the buffer
  in the focused pane, sharing the tree the editor already colors it with.
- `tree:root()`, `tree:language()`, `tree:source()`.
- `tree:query(source)` — the query inline or as a `.scm` file in the plugin's
  folder. Returns an array of matches, each `{ pattern = n, [capture] = node }`,
  or `nil, message` when the query does not compile.
- Node fields: `start_byte`, `end_byte`, `start_row`, `start_column`, `end_row`,
  `end_column`, `named`, `missing`, `has_error`.
- Node methods: `type()`, `text()`, `child(i)`, `child_count()`,
  `named_child(i)`, `named_child_count()`, `children()`, `named_children()`,
  `field(name)`, `parent()`, `next()`, `prev()`, `descendant_at(byte)`.

Child indexes are 0-based, as in tree-sitter itself. A tree stays alive as long
as any node off it does.

## Panels

`thor.panel` creates a dockable panel; `:render` replaces its contents with a
list of nodes, `:show` reveals it and `:close` hides it. Re-render as often as
you like — the previous contents and their callbacks are released each time.

```lua
local p = thor.panel { id = "status", title = "Status", dock = "right" }

p:render {
    { kind = "label", text = "3 files changed", role = thor.theme.comments },
    { kind = "row", gap = 6, children = {
        { kind = "button", text = "Stage", on_click = function() stage() end },
        { kind = "button", text = "Commit", on_click = function() commit() end },
    }},
    { kind = "separator" },
    { kind = "list", items = paths, on_select = function(row, item) open(item) end },
    { kind = "canvas", height = 120, draw = function(ctx)
        ctx:rect(0, 0, ctx.w, ctx.h, thor.theme.background)
        ctx:text(4, 4, "hello", thor.theme.foreground)
    end },
}
p:show()
```

Node kinds: `label`, `button`, `row`, `column`, `list`, `separator`, `spacer`,
`canvas`. `role` is a theme role, `gap` the spacing inside a row or column, and
`height` fixes a canvas's or spacer's height. `dock` is `"right"` or `"bottom"`.
For text entry use `thor.prompt`.

A canvas draws in canvas coordinates, clipped to itself. Inside `draw`:
`ctx.w`, `ctx.h`, `ctx:rect(x, y, w, h, role)`, `ctx:outline(x, y, w, h, role)`,
`ctx:text(x, y, text, role)`, `ctx:line(x0, y0, x1, y1, role, thickness)` and
`ctx:measure(text)` returning width and height.
