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
| `language_intelligence` | Master switch for Odin language features (hover, goto, completion, ...); either a plain boolean or an object with an `"enabled"` key plus per-feature toggles | `true` |

An unset key falls back to its default, so a `settings.json` only needs the
keys you want to change. Changing `theme`, `font` or an icon pack from
Settings applies immediately; hand-editing the file needs a restart.

## `settings/keybinds.json`

Maps an action name to a key chord. See [Keybindings](keybindings.md) for the
shipped bindings; rebind by editing this file (Settings has no key-remap UI
yet), or open it directly via the command palette or **Tasks** dropdown's
"Edit Tasks (JSON)"-style actions.

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

- **`plugins/`** — the workspace's own Lua plugins, in addition to the bundled
  ones under the Thor install. See [Plugins](plugins.md).

## Themes, fonts and icons

- Themes live in `assets/themes/*.json`, one file per theme; pick one by name
  (no extension) in `theme`, or through Settings, which lists every theme
  found.
- Fonts and icon packs are named in `assets/fonts/fonts.json` and
  `assets/icons/icons.json`; Settings lists the available names for `font`,
  `icon_pack` and `file_icon_pack`.
