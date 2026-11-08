// Live diagnostics for the other files of the package of the request's buffer.
package odin

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import lang ".."

// Most sibling files one live pass reads.
PACKAGE_LIVE_MAX_FILES :: 64

// Most diagnostics the sibling files add to one report.
PACKAGE_LIVE_MAX_ITEMS :: 500

// Appends the live diagnostics of each other file of the package directory of the request's
// buffer to `report`, each item with the path of its own file. The files are read from disk.
// Stops at the limits and when the request is cancelled.
@(private)
package_live_items :: proc(rc: ^Request_Context, report: ^lang.Diagnostic_Report) {
    if rc.req.path == "" {
        return
    }
    dir := filepath.dir(rc.req.path)
    if dir == "" {
        return
    }
    infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
    if err != nil {
        return
    }
    names := make([dynamic]string, context.temp_allocator)
    for info in infos {
        if info.type == .Directory || !strings.has_suffix(info.name, ".odin") {
            continue
        }
        if strings.has_suffix(info.name, "_test.odin") && !rc.target.tests {
            continue
        }
        append(&names, info.name)
    }
    slice.sort(names[:])
    added := 0
    read := 0
    for name in names {
        full, jerr := filepath.join({dir, name}, context.temp_allocator)
        if jerr != nil || paths_equal(full, rc.req.path) {
            continue
        }
        if read >= PACKAGE_LIVE_MAX_FILES || added >= PACKAGE_LIVE_MAX_ITEMS || lang.request_cancelled(rc.req) {
            return
        }
        read += 1
        src, ok := lang.source_read(full, context.temp_allocator)
        if !ok {
            continue
        }
        added += sibling_items(rc, full, src, report)
    }
}

// Appends the live diagnostics of the file `path` holding `src`; the count added.
@(private = "file")
sibling_items :: proc(rc: ^Request_Context, path, src: string, report: ^lang.Diagnostic_Report) -> int {
    req := rc.req^
    req.path = path
    req.source = src
    req.offset = 0
    req.end = 0
    sub: Request_Context
    if !request_open(rc.e, &req, &sub) {
        request_close(&sub)
        return 0
    }
    defer request_close(&sub)
    if sub.live.path != "" && !sub.live.in_build {
        return 0
    }
    part: lang.Diagnostic_Report
    defer delete(part.items)
    if !live_report(&sub, &part) {
        for d in part.items {
            delete(d.path)
            delete(d.message)
        }
        return 0
    }
    for d in part.items {
        append(&report.items, d)
    }
    return len(part.items)
}

// True when two paths name the same file, ignoring the separator and the case on Windows.
@(private)
paths_equal :: proc(a, b: string) -> bool {
    when ODIN_OS == .Windows {
        return slashes_equal_fold(a, b)
    } else {
        return a == b
    }
}

@(private = "file")
slashes_equal_fold :: proc(a, b: string) -> bool {
    if len(a) != len(b) {
        return false
    }
    for i in 0 ..< len(a) {
        x, y := a[i], b[i]
        if x == '\\' {
            x = '/'
        }
        if y == '\\' {
            y = '/'
        }
        if x >= 'A' && x <= 'Z' {
            x += 32
        }
        if y >= 'A' && y <= 'Z' {
            y += 32
        }
        if x != y {
            return false
        }
    }
    return true
}
