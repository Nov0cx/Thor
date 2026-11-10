# 2026.11.2

- **Undo tree.** An edit after an undo starts a new branch and keeps the undone steps. `ctrl+z`, `ctrl+shift+z` and `ctrl+y` work as before.
- **Undo History.** Edit > Undo History (`undo_history`) shows the undo tree as a branch graph with a preview and a diff of each step. `enter` keeps the state, `escape` goes back.
- **Time-order undo.** `ctrl+alt+z` / `ctrl+alt+shift+z` step through every saved state across branches.
- **Formatter `case` labels.** `case` labels stay at the level of their `switch`; `indent_cases` moves them one level in.
- **Faster startup.** About 130 ms faster, and the console no longer stalls a frame when the shell starts.
- **Idle window.** An idle window no longer redraws 60 times a second.
- **Profiling.** `build.odin -- run -profile` builds an editor that writes a spall trace. See `docs/building.md`.
