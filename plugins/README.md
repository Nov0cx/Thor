# Plugins

Editor plugins written in Lua live here, one folder per plugin
(`plugins/<name>/plugin.lua`). The host that loads and runs them is the Odin
`plugin` package (`../plugin`).

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
  fails with `plugin exceeded its time budget` and the editor keeps running.
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

No manifest grants nothing, which is all a syntax-only plugin needs. A denied
entry point is absent rather than present-and-refusing, so calling it raises
`attempt to call a nil value`. `thor.permissions()` returns what was granted, so
a plugin can degrade instead of erroring.

A plugin that asks for a permission does not run until the user allows it. Thor
asks once, for every waiting plugin in one prompt, and remembers the answer in
`<exe>/sessions/plugin-grants.json`; a plugin that later asks for more is asked
again. Plugins asking for nothing — every language plugin — load without a
prompt. Dismissing the prompt leaves those plugins unloaded for the session.

Always available: `thor.register_language`, `thor.print`, `thor.keybind`,
`thor.on_command`, `thor.workspace`, `thor.active_path`, `thor.refresh_git`,
`thor.theme` and `thor.ts`.

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

`highlights` replaces the grammar's compiled-in highlights query. A name ending
in `.scm` is read from the plugin's folder; anything else is the query itself. A
query that does not compile is reported on the console with its byte offset and
reason, and the language keeps the built-in query.

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
- `thor.ts.parse(source, grammar)` — a tree, or `nil, message`.
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
