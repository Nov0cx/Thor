#+build !windows
package thor

// POSIX pickers for Open File / Open Folder, drawn by a helper program:
// osascript on macOS, zenity or kdialog on Linux. Without one of them a pick
// reports a cancel. Modal like the Windows dialogs: the frame loop waits.

import "base:runtime"
import "core:log"
import "core:strings"

import "../shell"

@(private = "file")
Pick_Kind :: enum u8 {
    Folder,
    File,
}

// Printed when no picker is installed, which tells that case from a cancel.
@(private = "file")
NO_DIALOG :: "__no_dialog__"

// Opens the folder picker starting at `initial`. Returns the chosen directory
// (caller owns) and false when the user cancelled.
thor_pick_folder :: proc(title: string, initial: string, allocator := context.allocator) -> (string, bool) {
    return thor_run_picker(thor_pick_command(.Folder, title, initial), initial, allocator)
}

// Opens the file picker in `initial`. Returns the chosen file (caller owns) and
// false when the user cancelled.
thor_pick_file :: proc(title: string, initial: string, allocator := context.allocator) -> (string, bool) {
    return thor_run_picker(thor_pick_command(.File, title, initial), initial, allocator)
}

// Runs one picker command and reads the path back off its output.
@(private = "file")
thor_run_picker :: proc(command: string, cwd: string, allocator: runtime.Allocator) -> (string, bool) {
    output := shell.run(command, cwd != "" ? cwd : ".")
    defer delete(output)

    line := output
    if end := strings.index_byte(line, '\n'); end >= 0 {
        line = line[:end]
    }
    line = strings.trim_space(line)

    if line == NO_DIALOG {
        log.warn("No picker is installed; install zenity or kdialog to browse for a path")
        return "", false
    }
    // Every picker answers with an absolute path; a cancel writes nothing.
    if !strings.has_prefix(line, "/") {
        return "", false
    }
    // `choose folder` ends its answer with a separator that no path key expects.
    if len(line) > 1 && strings.has_suffix(line, "/") {
        line = line[:len(line) - 1]
    }
    return strings.clone(line, allocator), true
}

// Builds the shell command that draws the picker. The Linux one tries both
// desktops in turn, so one command covers either.
@(private = "file")
thor_pick_command :: proc(kind: Pick_Kind, title: string, initial: string) -> string {
    when ODIN_OS == .Darwin {
        script := strings.builder_make(context.temp_allocator)
        strings.write_string(&script, "POSIX path of (")
        strings.write_string(&script, kind == .Folder ? "choose folder" : "choose file")
        strings.write_string(&script, " with prompt ")
        applescript_write_string(&script, title)
        if initial != "" {
            strings.write_string(&script, " default location POSIX file ")
            applescript_write_string(&script, initial)
        }
        strings.write_string(&script, ")")
        return strings.concatenate(
            {"osascript -e ", thor_shell_quote(strings.to_string(script)), " 2>/dev/null"},
            context.temp_allocator,
        )
    } else {
        start := initial != "" ? initial : "."
        // zenity reads a starting directory as a file name that ends in a separator.
        zenity := strings.concatenate(
            {
                "zenity --file-selection",
                kind == .Folder ? " --directory" : "",
                " --title=",
                thor_shell_quote(title),
                " --filename=",
                thor_shell_quote(strings.concatenate({start, "/"}, context.temp_allocator)),
                " 2>/dev/null",
            },
            context.temp_allocator,
        )
        kdialog := strings.concatenate(
            {
                "kdialog --title ",
                thor_shell_quote(title),
                kind == .Folder ? " --getexistingdirectory " : " --getopenfilename ",
                thor_shell_quote(start),
                " 2>/dev/null",
            },
            context.temp_allocator,
        )
        return strings.concatenate(
            {
                "if command -v zenity >/dev/null 2>&1; then ",
                zenity,
                "; elif command -v kdialog >/dev/null 2>&1; then ",
                kdialog,
                "; else echo ",
                NO_DIALOG,
                "; fi",
            },
            context.temp_allocator,
        )
    }
}

// Wraps `s` for /bin/sh. Single quotes take everything literally, so only the
// quote itself has to break out of them. Shared with reveal_posix.odin.
@(private)
thor_shell_quote :: proc(s: string) -> string {
    escaped, _ := strings.replace_all(s, "'", "'\\''", context.temp_allocator)
    return strings.concatenate({"'", escaped, "'"}, context.temp_allocator)
}

// Writes `s` as an AppleScript string literal: backslash and quote are the two
// characters the language reads inside one.
@(private = "file")
applescript_write_string :: proc(b: ^strings.Builder, s: string) {
    strings.write_byte(b, '"')
    for i in 0 ..< len(s) {
        if s[i] == '\\' || s[i] == '"' {
            strings.write_byte(b, '\\')
        }
        strings.write_byte(b, s[i])
    }
    strings.write_byte(b, '"')
}
