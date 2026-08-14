# Configuration

Configuration is layered, each layer overlaying the one before it per key:

| Layer | Where | Written by |
| --- | --- | --- |
| Shipped defaults | `settings/*.json` beside the binary | Thor's releases and builds — replaced wholesale by an update |
| Your settings | `user/*.json` beside the binary | The Settings view and the command palette |
| Workspace | `<project>/.thor/*.json` | You, per project; usually checked in |

Both files of a layer above may name only the keys they change. Nothing Thor
writes ever lands in `settings/`, so an update or a rebuild cannot lose your
settings; keep your own edits in `user/` for the same reason. `user/` is created
on the first change and needs no `settings/` counterpart.

Most of it is reachable without editing JSON by hand, through the in-editor
**Settings** view and the command palette (`ctrl + .`). The Settings view's
**General** tab writes `user/`, its **Workspace** tab writes `.thor/`. The
palette's "Open Settings (JSON)" and its keybinds and comments counterparts open
whichever of the two a change would go to, creating the file when it is not
there yet.

## `settings.json`

General editor preferences.

| Key | Meaning | Default |
| --- | --- | --- |
| `font_size` | Editor font size, in points | `18` |
| `tab_width` | Spaces per indent level, and the width of a rendered tab stop | `4` |
| `autosave_delay_ms` | Delay after the last edit before autosave | `1500` |
| `ligatures` | Draw programming ligatures (`->` as one glyph) | `true` |
| `tooltips` | Explain a control when the cursor rests on it — title bar buttons, tabs, status bar segments, explorer rows | `true` |
| `tip_of_the_day` | Show the tip of the day: the card on the welcome page, and the card that opens over the editor on the first start of a day | `true` |
| `format_on_save` | Format the active buffer before an explicit save (`ctrl + s`, Save All, the palette) — never before an autosave | `false` |
| `format_on_type` | Dispatch on-type formatting as a trigger character is typed — `}` for Odin, a language server's own choice otherwise | `false` |
| `theme` | Active color theme, a name under `assets/themes/` with no extension (e.g. `"mjolnir"`) | built-in default |
| `font` | Text font family, a name in `assets/fonts/fonts.json` | built-in default |
| `icon_pack` | Primary icon pack, a family in `assets/icons/icons.json` | built-in default |
| `file_icon_pack` | File-icon pack, same set as `icon_pack` | built-in default |
| `check_for_updates` | Ask GitHub for a newer release shortly after start, at most once a day. **Help > Check for Updates** asks whatever this holds | `true` |
| `open_folder_in` | What opening a folder does: `"ask"`, `"same"` (replace this window's workspace), or `"new"` (open a window) | `"ask"` |
| `default_shell` | Shell new terminals start with, by profile id (`"pwsh"`, `"git-bash"`, `"msvc"`, ...); empty picks the best one installed | `""` |
| `language_intelligence` | Master switch for language features (hover, goto, completion, ...), both the built-in Odin support and any configured language server; either a plain boolean or an object with an `"enabled"` key plus per-feature toggles | `true` |
| `language_backends` | Per-backend switch, one level more precise than `language_intelligence`: an object keyed by backend id (`"odin"` for the built-in support, or an `lsp.json` server's own `id`) whose value is the same shape as `language_intelligence` itself — a plain boolean, or an object with `"enabled"` plus per-feature toggles — scoped to that one backend | `{}` (every backend fully enabled) |

An unset key falls back to its default, so a `settings.json` only needs the
keys you want to change. Every key applies as soon as the file is written,
whether from the Settings view or by hand — the files of all three layers are
watched.

## `keybinds.json`

Maps an action name to a key chord. See [Keybindings](keybindings.md) for the
shipped bindings; rebind by editing this file (Settings has no key-remap UI
yet), or open it directly via the command palette or **Tasks** dropdown's
"Edit Tasks (JSON)"-style actions.

A chord is modifiers and one key, joined with `+`, in any order — for example
`ctrl+shift+k` or `alt+page_up`. The modifier tokens are:

| Token | Key |
| --- | --- |
| `ctrl`, `control` | Control |
| `shift` | Shift |
| `alt`, `option` | Alt / Option |
| `cmd`, `command`, `super`, `meta`, `win` | Command on macOS, the Windows key elsewhere |

The shipped bindings all use `ctrl`; bind `cmd` here to reach the Command key on
macOS. An empty string unbinds an action.

## `lsp.json`

The language servers Thor may start. Odin is served in the editor itself and
needs no server; every other language gets its features — hover, go to
definition, find references, document symbols, workspace symbols, signature
help, completion, diagnostics, semantic colors, rename, code actions, and
document/selection/on-type formatting — from the server named here.

A server is started the first time you open a file it claims, never before, and
is stopped when Thor exits. A server that is not installed simply never starts
and the language stays a plain text file. Each server below has its own
bundled **`<name>` Setup** top-bar menu that checks whether it is on `PATH`
and, if not, adds a workspace task that installs it — see
[`plugins/clangd-setup`](../plugins/clangd-setup/plugin.lua),
[`plugins/rust-analyzer-setup`](../plugins/rust-analyzer-setup/plugin.lua),
[`plugins/gopls-setup`](../plugins/gopls-setup/plugin.lua),
[`plugins/basedpyright-setup`](../plugins/basedpyright-setup/plugin.lua),
[`plugins/typescript-setup`](../plugins/typescript-setup/plugin.lua),
[`plugins/lua-language-server-setup`](../plugins/lua-language-server-setup/plugin.lua) and
[`plugins/zls-setup`](../plugins/zls-setup/plugin.lua).

`clangd-setup` additionally has a **Configure compile_commands.json…** command
that detects the project's build system and helps produce the compilation
database clangd needs: it adds a workspace task for CMake
(`-DCMAKE_EXPORT_COMPILE_COMMANDS=ON`) or Make (`bear` on Linux/macOS,
`compiledb` on Windows), and for Bazel it can wire up [hedron's
bazel-compile-commands-extractor](https://github.com/hedronvision/bazel-compile-commands-extractor)
into `MODULE.bazel` (bzlmod only) before adding the task that runs it. A bare
build script with no recognized build system only gets a hint, since running
an arbitrary script is not something this plugin does on its own. See
[`plugins/clangd-setup/buildsystem.lua`](../plugins/clangd-setup/buildsystem.lua)
for the exact detection order.

Entries shipped by default: `clangd`, `rust-analyzer`, `gopls`, `basedpyright`,
`typescript`, `lua-language-server` and `zls`.

| Key | Meaning |
| --- | --- |
| `id` | Name for this entry; a workspace file overlays an entry by its `id` |
| `extensions` | File extensions it claims, each with its leading dot |
| `command` | Program and arguments; the program is looked up on `PATH` when not an absolute path |
| `root_markers` | Files that mark the project root, looked for at and above the opened file; the workspace root is used when none is found |
| `enabled` | `false` starts the entry switched off: it stops claiming its extensions, so another entry can take the language over, and it still lists in Settings where it can be switched back on |
| `cwd` | Working directory; empty is the project root |
| `env` | `"KEY=VALUE"` entries added to the environment |
| `init_options`, `settings` | JSON passed to the server as its initialization options and its configuration |
| `features` | Which features to ask this server for, by the `language_intelligence` names. Like `enabled`, this states where the switches start, and `language_backends` overrides whichever of them it names |
| `override` | `true` puts this server ahead of the built-in Odin support for `.odin` |

A server claims an extension all-or-nothing, so overriding `.odin` also gives up
what only the built-in support has: `Package_Doc` (`f3`) has no LSP equivalent,
and the `.thor/odin-analyzer.json` collection mechanism goes with it.

Known limitations: formatting follows the same `override` precedence as every
other feature — a server given `.odin` outright formats it too, in place of
the native printer below. Selection and on-type formatting are LSP-only; the
native Odin printer answers whole-document formatting alone. A server's own
config file (`.clang-format`, `rustfmt.toml`, ...) governs how it formats,
same as it would from any other editor. This table is also read when a workspace opens — including switching to a different folder, which
restarts the servers for the new root — so editing any `lsp.json` for the
workspace you already have open still needs it reopened to take effect. Turning
a server (or the built-in Odin support) on or off, or gating one of its
features, does not have that limitation: the Settings view's **Language**
category lists every configured server (plus Odin) under **Language Servers**,
each with its own on/off switch and, once enabled, a foldable **Features** group
of per-kind toggles — both take effect on the next request, the same as
`language_intelligence` itself, via the `language_backends` key above. Those
switches start where `lsp.json` puts them and are stored under
`language_backends`, so a server the file turns off is still listed and can be
switched back on without editing JSON. Turning a server off leaves an
already-running process idle rather than stopping it outright; it only stops
when the workspace reopens or Thor exits.

## `comments.json`

Maps a language id to its line-comment marker and the file extensions that use
it, driving `ctrl + k` (toggle line comment). Add an entry here to teach Thor a
new language's comment syntax.

## `tips.json`

The tips Thor shows, one a day. This file is the one exception to the layering
above: layers **append** rather than overlay, so a `user/tips.json` or a
workspace `.thor/tips.json` adds tips instead of hiding the shipped ones.

```json
{
    "tips": [
        {
            "title": "The command palette runs everything",
            "body": "Every action in Thor is in the palette, with the chord it is bound to beside it.",
            "action": "command_palette"
        }
    ]
}
```

| Key | Meaning |
| --- | --- |
| `title` | The headline. Required; an entry without one is skipped |
| `body` | The paragraph under it. Required |
| `action` | The `keybinds.json` action the tip is about, never a chord. Thor resolves it against the bindings in force, so a rebind shows the new chord. Omit it, or leave it empty, for a tip with no action of its own |

The card shows the tip of the current day and the arrows step through the rest.
It sits on the welcome page, and with a folder open it floats in the corner of
the editor on the first start of each day — `✕` closes it, and the line under it
turns tips off for good (the `tip_of_the_day` setting). Which tip, which day,
and the day the floating card last opened are remembered in `sessions/tips.json`
beside the binary, not in your settings.

## Per-workspace: `.thor/`

An opened folder can carry its own configuration in a `.thor/` directory at
its root, layered on top of the global settings above. This repository's own
`.thor/` is a working example.

- **`tasks.json`** — named shell commands, surfaced by the task buttons left
  of the window controls and under "Tasks:" in the command palette:

  ```json
  {
      "tasks": [
          { "name": "build", "command": "odin run build.odin -file" },
          { "name": "test",  "command": "odin test thor" }
      ]
  }
  ```

  Tasks run in the console panel, exactly like typing the command at the
  prompt. The dropdown next to the run button lists them, and can add, remove
  or open this file for editing.

- **`odin-analyzer.json`** — per-workspace settings for the Odin language
  intelligence: which analyzer collections to load and which features
  (`enable_hover`, `enable_document_symbols`, `enable_references`, ...) are on
  for this workspace. This is Thor's own file, not `ols.json`.

- **`odin-formatter.json`** — per-workspace options for formatting `.odin`
  files — "Edit: Format Document", "Edit: Format Selection", `format_on_save`
  and `format_on_type` all read it — mirroring the odinfmt (OLS) schema. An
  absent file, or an absent key, uses the default shown:

  | Key | Meaning | Default |
  | --- | --- | --- |
  | `character_width` | Column a call, parameter list or composite literal wraps at | `100` |
  | `spaces` | Spaces per indent level (when `tabs` is `false`) | `4` |
  | `newline_limit` | Most blank lines kept between statements/declarations | `2` |
  | `tabs` | Indent with tabs instead of spaces | `true` |
  | `tabs_width` | Columns one tab counts as, for `character_width` | `4` |
  | `convert_do` | Rewrite `if x do y()` to a braced block | `false` |
  | `exp_multiline_composite_literals` | Keep a composite literal that already spanned multiple lines from being collapsed onto one | `false` |
  | `brace_style` | `"_1TBS"`, `"Allman"`, `"Stroustrup"`, or `"K_And_R"` | `"_1TBS"` |
  | `indent_cases` | Indent a `switch`'s `case` bodies one level deeper than the label | `false` |
  | `newline_style` | `"LF"` or `"CRLF"` | unset (the file's own line ending is left alone) |
  | `inline_single_stmt_case` | Put a `case`'s body on the same line when it is one statement | `false` |
  | `spaces_around_colons` | `x : int` instead of `x: int` | `false` |
  | `sort_imports` | Sort each contiguous run of `import` declarations, `base:`/`core:`/`vendor:` paths first | `true` |
  | `space_single_line_blocks` | `{ stmt }` for a one-statement block the source already wrote on one line | `false` |
  | `align_struct_fields` | Align a struct's field types into one column | `true` |
  | `align_struct_values` | Align the `=` of enum members and multi-line composite literals, and a bit field's `\|` | `true` |
  | `align_struct_declarations` | Align consecutive `Name :: struct` / `union` / `enum` / `bit_field` declarations' `::` | `false` |
  | `align_constant_definitions` | Align consecutive `NAME :: value` declarations' `::` | `false` |

  The formatter never guesses at broken code — a file with a syntax error is
  left untouched. An import run with a comment in it is left in the order it
  was written, since moving an import would re-attach the comment beside it to
  a different one. Format Selection and format-on-type reformat only inside the
  lines they were given: a change that reaches past them is dropped rather than
  half-applied. `newline_style` only takes effect when the key is present:
  an absent key never flips a file's line ending, since the odinfmt schema's
  own default (`CRLF`) would otherwise silently rewrite every LF file's
  endings on its first format. Setting it applies once a format actually
  changes the buffer, by marking the file's line ending the same way the
  status-bar toggle does — the next save re-expands accordingly.

- **`lsp.json`** — language servers for this project, in the shape described
  above. An entry is merged onto the shipped one with the same `id`, so a
  project can change one server's command or arguments without repeating the
  rest of the table; `"enabled": false` switches a shipped server off here —
  which is how a project hands a language to a different server — and an `id`
  nothing ships adds one.

- **`tips.json`** — tips of this project's own, in the shape described above.
  They are added to the shipped ones, not put in their place.

- **`plugins/`** — the workspace's own Lua plugins, in addition to the bundled
  ones under the Thor install. See [Plugins](plugins.md).

## Themes, fonts and icons

- Themes live in `assets/themes/*.json`, one file per theme; pick one by name
  (no extension) in `theme`, or through Settings, which lists every theme
  found.
- Fonts and icon packs are named in `assets/fonts/fonts.json` and
  `assets/icons/icons.json`; Settings lists the available names for `font`,
  `icon_pack` and `file_icon_pack`.
