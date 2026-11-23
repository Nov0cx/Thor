# 2026.11.8

- **Terminal.** The terminal rewraps its lines and its history when the panel gets wider or narrower.
- **Language servers.** Call and type hierarchy, expand selection, code lenses, folding ranges, document links and linked editing now reach the server. Diagnostics of several servers for one file show together.
- **Go to declaration.** The new `goto_declaration` action (unbound) jumps to a declaration where the language tells it apart from the definition.
- **Document links.** `ctrl + click` on an underlined link opens it: a web address in the browser, a file in a tab.
- **Linked editing.** Typing in one half of a pair, such as an HTML open and close tag, changes the other half too.
- **File watcher.** macOS and the BSDs use kqueue. Linux sees writes that do not close the file and shows a notice when the workspace folder is removed or moved.
- **Odin.** The save reports `-vet-style`, `-vet-semicolon` and `-vet-tabs` lines, a compiler "Did you mean?" gives a fix, and `transmute` between integers of one byte order is reported with a `cast` fix.
- **Plugins.** `thor.exec` returns the exit code as a second value. Tree-sitter injections color Lua `ffi.cdef` strings as C and Rust macro bodies as Rust, and a plugin can supply `injections`.
