#+build !windows
package thor

import "core:os"
import "core:path/filepath"
import "core:strings"

import "../shell"

// Opens the OS file manager with `path` selected. macOS uses `open -R`, the
// other systems the org.freedesktop.FileManager1 D-Bus interface.
// Always backgrounded (see below), so a true return only means the launcher
// shell itself started, not that a file manager window actually appeared —
// there is no portable way to learn that without blocking the frame on it.
thor_reveal_path :: proc(path: string) -> bool {
    if path == "" {
        return false
    }
    dir := filepath.dir(path) // a slice of path, no allocation

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
            {"( ", reveal_command(path, dir), " ) </dev/null >/dev/null 2>&1 &"},
            context.temp_allocator,
        )
    }

    output := shell.run(command, dir)
    delete(output)
    return true
}

// The reveal command for the systems without `open`: the two D-Bus clients that
// reach org.freedesktop.FileManager1, then xdg-open on `dir` when neither does.
// ShowItems is the one selection interface the file managers share (Nautilus,
// Dolphin, Nemo, Thunar, PCManFM-Qt, Caja) and it is D-Bus activatable, so it
// also starts a manager that does not run. gdbus comes with glib, dbus-send with
// dbus; dbus-send needs --print-reply, or it reports success with no file manager
// on the bus and the fallback never runs. Temporary memory.
@(private)
reveal_command :: proc(path, dir: string) -> string {
    fallback := strings.concatenate({"xdg-open ", thor_shell_quote(dir)}, context.temp_allocator)
    // A file URI must be absolute, and the working directory is the binary's,
    // not the one the editor started in, so a relative path stays unresolved.
    if !filepath.is_abs(path) {
        return fallback
    }

    uri := reveal_file_uri(path)
    return strings.concatenate(
        {
            "gdbus call --session --dest org.freedesktop.FileManager1",
            " --object-path /org/freedesktop/FileManager1",
            " --method org.freedesktop.FileManager1.ShowItems \"['", uri, "']\" \"\"",
            " || dbus-send --session --print-reply --dest=org.freedesktop.FileManager1",
            " /org/freedesktop/FileManager1 org.freedesktop.FileManager1.ShowItems",
            " array:string:", uri, " string:''",
            " || ", fallback,
        },
        context.temp_allocator,
    )
}

// The file:// URI of `path`, percent-encoded down to the unreserved set of
// RFC 3986 with the separator kept. The result holds no quote and no shell
// metacharacter, which is what lets it stand unquoted in a command line and
// inside a GVariant literal. Temporary memory.
@(private)
reveal_file_uri :: proc(path: string) -> string {
    hex := "0123456789ABCDEF" // a variable, since a constant takes no variable index

    b := strings.builder_make(context.temp_allocator)
    strings.write_string(&b, "file://")
    for i in 0 ..< len(path) {
        c := path[i]
        switch {
        case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9',
             c == '-', c == '.', c == '_', c == '~', c == '/':
            strings.write_byte(&b, c)
        case:
            strings.write_byte(&b, '%')
            strings.write_byte(&b, hex[c >> 4])
            strings.write_byte(&b, hex[c & 0xf])
        }
    }
    return strings.to_string(b)
}

// Opens `target` -- a URL or a file path -- in the default browser. $BROWSER
// names it when the user sets it; otherwise the desktop's opener picks the
// program for the type, which is the browser for a URL and for HTML.
// Backgrounded like the file manager: it outlives the call and must not hold
// the pipe open, so a true return means only that the launcher shell started.
thor_open_in_browser :: proc(target: string) -> bool {
    if target == "" {
        return false
    }

    if browser := os.get_env("BROWSER", context.temp_allocator); browser != "" {
        command := strings.concatenate(
            {browser, " ", thor_shell_quote(target), " </dev/null >/dev/null 2>&1 &"},
            context.temp_allocator,
        )
        output := shell.run(command, ".")
        delete(output)
        return true
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
    return true
}
