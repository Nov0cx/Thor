# Configuration

Configuration is layered: global `settings/*.json` beside the binary,
overlaid by a workspace's `.thor/` directory. Most of it is also reachable
without editing JSON by hand, through the in-editor **Settings** view and the
command palette (`ctrl + .`).

## `settings/settings.json`

General editor preferences.

| Key | Meaning | Default |
| --- | --- | --- |
| `font_size` | Editor font size, in points | `18` |
| `tab_width` | Spaces per indent level | `4` |
| `autosave_delay_ms` | Delay after the last edit before autosave | `1500` |
| `ligatures` | Draw programming ligatures (`->` as one glyph) | `true` |
| `theme` | Active color theme, a name under `assets/themes/` with no extension (e.g. `"mjolnir"`) | built-in default |
| `font` | Text font family, a name in `assets/fonts/fonts.json` | built-in default |
| `icon_pack` | Primary icon pack, a family in `assets/icons/icons.json` | built-in default |
| `file_icon_pack` | File-icon pack, same set as `icon_pack` | built-in default |
| `open_folder_in` | What opening a folder does: `"ask"`, `"same"` (replace this window's workspace), or `"new"` (open a window) | `"ask"` |
| `default_shell` | Shell new terminals start with, by profile id (`"pwsh"`, `"git-bash"`, `"msvc"`, ...); empty picks the best one installed | `""` |
| `language_intelligence` | Master switch for language features (hover, goto, completion, ...), both the built-in Odin support and any configured language server; either a plain boolean or an object with an `"enabled"` key plus per-feature toggles | `true` |
| `language_backends` | Per-backend switch, one level more precise than `language_intelligence`: an object keyed by backend id (`"odin"` for the built-in support, or an `lsp.json` server's own `id`) whose value is the same shape as `language_intelligence` itself — a plain boolean, or an object with `"enabled"` plus per-feature toggles — scoped to that one backend | `{}` (every backend fully enabled) |

An unset key falls back to its default, so a `settings.json` only needs the
keys you want to change. Changing `theme`, `font` or an icon pack from
Settings applies immediately; hand-editing the file needs a restart.
`language_intelligence` and `language_backends` both apply immediately too,
whether changed from the Settings view's **Language** category or by hand.

## `settings/keybinds.json`

Maps an action name to a key chord. See [Keybindings](keybindings.md) for the
shipped bindings; rebind by editing this file (Settings has no key-remap UI
yet), or open it directly via the command palette or **Tasks** dropdown's
"Edit Tasks (JSON)"-style actions.

## `settings/lsp.json`

The language servers Thor may start. Odin is served in the editor itself and
needs no server; every other language gets its features — hover, go to
definition, find references, document symbols, workspace symbols, signature
help, completion, diagnostics, semantic colors, rename and code actions —
from the server named here.

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
| `enabled` | `false` removes the entry |
| `cwd` | Working directory; empty is the project root |
| `env` | `"KEY=VALUE"` entries added to the environment |
| `init_options`, `settings` | JSON passed to the server as its initialization options and its configuration |
| `features` | Which features to ask this server for, by the `language_intelligence` names |
| `override` | `true` puts this server ahead of the built-in Odin support for `.odin` |

A server claims an extension all-or-nothing, so overriding `.odin` also gives up
what only the built-in support has: `Package_Doc` (`f3`) has no LSP equivalent,
and the `.thor/odin-analyzer.json` collection mechanism goes with it.

Known limitations: there is no formatting support, and this table is read
when a workspace opens — including switching to a different folder, which
restarts the servers for the new root — so editing `settings/lsp.json` or
`.thor/lsp.json` for the workspace you already have open still needs it
reopened to take effect. Turning a server (or the built-in Odin support) on or
off, or gating one of its features, does not have that limitation: the
Settings view's **Language** category lists every configured server (plus
Odin) under **Language Servers**, each with its own on/off switch and, once
enabled, a foldable **Features** group of per-kind toggles — both take effect
on the next request, the same as `language_intelligence` itself, via the
`language_backends` key above. Turning a server off there leaves an
already-running process idle rather than stopping it outright; it only stops
when the workspace reopens or Thor exits.

## `settings/comments.json`

Maps a language id to its line-comment marker and the file extensions that use
it, driving `ctrl + k` (toggle line comment). Add an entry here to teach Thor a
new language's comment syntax.

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

- **`lsp.json`** — language servers for this project, in the shape described
  above. An entry is merged onto the shipped one with the same `id`, so a
  project can change one server's command or arguments without repeating the
  rest of the table; `"enabled": false` removes a shipped server here, and an
  `id` nothing ships adds one.

- **`plugins/`** — the workspace's own Lua plugins, in addition to the bundled
  ones under the Thor install. See [Plugins](plugins.md).

## Themes, fonts and icons

- Themes live in `assets/themes/*.json`, one file per theme; pick one by name
  (no extension) in `theme`, or through Settings, which lists every theme
  found.
- Fonts and icon packs are named in `assets/fonts/fonts.json` and
  `assets/icons/icons.json`; Settings lists the available names for `font`,
  `icon_pack` and `file_icon_pack`.
