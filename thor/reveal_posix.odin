#+build !windows
package thor

import "core:os"
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

// Opens `target` -- a URL or a file path -- in the default browser. $BROWSER
// names it when the user sets it; otherwise the desktop's opener picks the
// program for the type, which is the browser for a URL and for HTML.
// Backgrounded like the file manager: it outlives the call and must not hold
// the pipe open.
thor_open_in_browser :: proc(target: string) {
    if target == "" {
        return
    }

    if browser := os.get_env("BROWSER", context.temp_allocator); browser != "" {
        command := strings.concatenate(
            {browser, " ", thor_shell_quote(target), " </dev/null >/dev/null 2>&1 &"},
            context.temp_allocator,
        )
        output := shell.run(command, ".")
        delete(output)
        return
    }

    opener: string
    when ODIN_OS == .Darwin {
        opener = "open "
    } else {
        opener = "xdg-open "
    }

    command := strings.concatenate(
        {opener, thor_shell_quote(target), " </dev/null >/dev/null 2>&1 &"},
        context.temp_allocator,
    )
    output := shell.run(command, ".")
    delete(output)
}
