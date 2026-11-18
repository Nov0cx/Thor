# 2026.11.7

- **Two-step keybinds.** A `keybinds.lua` entry such as `"ctrl+m c"` runs after two presses. `"prefix c"` follows the new `chord_prefix` bind (`ctrl + m` by default). The status bar shows a pressed prefix, and `esc` cancels it.
- **Keybinding settings.** Settings > Keybindings records a two-step bind, and refuses a chord another action already uses.
- **Git window.** `up` and `down` pick a changed file, `space` stages or unstages it, and `esc` leaves a text field before it closes the window.
- **Odin analyzer.** Live diagnostics check only the changed declarations, so a large file takes about half the time. Rename refuses a name the scope already uses. Big integer constants fold in `when` conditions.
- **Plugins and config.** `latex_build_command` is now a personal setting that `.thor/settings.lua` cannot set. A Lua pattern that would backtrack without end is refused. Plugin update checks skip a folder plugin until you allow it.
- **Languages.** Shell here-documents and LaTeX verbatim text are coloured. `.env.local`, `Dockerfile.dev`, `.profile`, `.envrc`, `.gitmodules` and `.ignore` get highlighting.
