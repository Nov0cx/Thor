#+build !windows
package thor

import "core:path/filepath"
import "core:strings"

import "../shell"

// Opens the OS file manager on `path`. macOS selects the file; Linux only opens
// the containing folder, having no interface every file manager answers to.
thor_reveal_path :: proc(path: string) {
    if path == "" {
        return
    }
    dir := filepath.dir(path)

    // The file manager is backgrounded with its own streams: it outlives the
    // call and would otherwise hold the pipe open and block the frame.
    command: string
    when ODIN_OS == .Darwin {
        command = strings.concatenate(
            {"open -R ", thor_shell_quote(path), " </dev/null >/dev/null 2>&1 &"},
            context.temp_allocator,
        )
    } else {
        command = strings.concatenate(
            {"xdg-open ", thor_shell_quote(dir), " </dev/null >/dev/null 2>&1 &"},
            context.temp_allocator,
        )
    }

    output := shell.run(command, dir)
    delete(output)
}
