package thor

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"

import "../editview"
import "../lang"
import ui "../vendor/loom/loom"

// The Problems panel: the diagnostics of the open files and of the other files of the checked packages, grouped by file.

PROBLEMS_WIDTH  :: 760
PROBLEMS_HEIGHT :: 520

// State of the Problems panel.
Problems_View :: struct {
    return_focus:  string, // focus owner when it opened
    focus_pending: bool,
}

// One diagnostic row of the panel.
Problem :: struct {
    offset:   int, // byte offset in the file; -1 for a file that is not open
    col:      int, // 1-based; used when `offset` is -1
    line:     int, // 0-based
    severity: editview.Diagnostic_Severity,
    message:  string, // borrowed from the file
    code:     string,
}

// A diagnostic of a file that is not open.
Package_Problem :: struct {
    path:     string, // owned, absolute
    line:     int,    // 1-based
    col:      int,    // 1-based
    severity: editview.Diagnostic_Severity,
    message:  string, // owned
    code:     string, // static
}

// The problems of one file, in line order.
Problem_Group :: struct {
    path:     string, // borrowed from the file
    problems: []Problem,
}

// The groups of all open files that have diagnostics, sorted by path. Scratch-allocated.
thor_problem_groups :: proc(thor: ^Thor, allocator := context.temp_allocator) -> []Problem_Group {
    groups := make([dynamic]Problem_Group, allocator)
    for file in thor.open_files {
        if file.closed {
            continue
        }
        diags := thor_file_live_diagnostics(file)
        if len(diags) == 0 {
            continue
        }
        rows := make([]Problem, len(diags), allocator)
        for d, i in diags {
            rows[i] = Problem{offset = d.start, line = d.line, severity = d.severity, message = d.message, code = d.code}
        }
        slice.stable_sort_by(rows, proc(a, b: Problem) -> bool {
            return a.line < b.line
        })
        append(&groups, Problem_Group{path = file.path, problems = rows})
    }
    problems_add_closed(thor, &groups, allocator)
    slice.sort_by(groups[:], proc(a, b: Problem_Group) -> bool {
        return a.path < b.path
    })
    return groups[:]
}

// Adds a group for each file that is not open and has stored problems.
@(private = "file")
problems_add_closed :: proc(thor: ^Thor, groups: ^[dynamic]Problem_Group, allocator: runtime.Allocator) {
    first := len(groups)
    for &pp in thor.package_problems {
        if file, _ := thor_find_open_file(thor, pp.path); file != nil && !file.closed {
            continue
        }
        at := -1
        for g, i in groups[first:] {
            if g.path == pp.path {
                at = first + i
                break
            }
        }
        if at < 0 {
            append(groups, Problem_Group{path = pp.path})
            at = len(groups) - 1
        }
        rows := make([dynamic]Problem, 0, len(groups[at].problems) + 1, allocator)
        append(&rows, ..groups[at].problems)
        append(&rows, Problem{offset = -1, col = pp.col, line = pp.line - 1, severity = pp.severity, message = pp.message, code = pp.code})
        groups[at].problems = rows[:]
    }
    for g in groups[first:] {
        slice.stable_sort_by(g.problems, proc(a, b: Problem) -> bool {
            return a.line < b.line
        })
    }
}

// Replaces the stored problems of the files `res.report.scope` covers with those of the
// report, keeping only files that are not open.
thor_package_problems_store :: proc(thor: ^Thor, res: ^lang.Result) {
    kept := 0
    for pp in thor.package_problems {
        if scope_covers(pp.path, res.report.scope) {
            delete(pp.path)
            delete(pp.message)
            continue
        }
        thor.package_problems[kept] = pp
        kept += 1
    }
    resize(&thor.package_problems, kept)
    for d in res.report.items {
        if file, _ := thor_find_open_file(thor, d.path); file != nil && !file.closed {
            continue
        }
        pp := Package_Problem{
            path = strings.clone(d.path),
            line = d.line,
            col = d.col,
            severity = editor_severity(d.severity),
            message = strings.clone(d.message),
            code = d.code,
        }
        if _, err := append(&thor.package_problems, pp); err != nil {
            delete(pp.path)
            delete(pp.message)
            return
        }
    }
}

// Drops the stored problems.
thor_package_problems_clear :: proc(thor: ^Thor) {
    for pp in thor.package_problems {
        delete(pp.path)
        delete(pp.message)
    }
    clear(&thor.package_problems)
}

thor_package_problems_destroy :: proc(thor: ^Thor) {
    thor_package_problems_clear(thor)
    delete(thor.package_problems)
    thor.package_problems = nil
}

// The number of problems of `severity` over all `groups`.
problem_count :: proc(groups: []Problem_Group, severity: editview.Diagnostic_Severity) -> int {
    count := 0
    for g in groups {
        for p in g.problems {
            if p.severity == severity {
                count += 1
            }
        }
    }
    return count
}

thor_cmd_open_problems :: proc(data: rawptr) {
    thor := cast(^Thor)data
    if thor.problems_open {
        thor_problems_close(thor)
    } else {
        thor_problems_open(thor)
    }
}

thor_problems_open :: proc(thor: ^Thor) {
    if !thor.problems_open {
        thor.problems.return_focus = thor.focus_owner
        thor.problems.focus_pending = true
    }
    thor.problems_open = true
}

thor_problems_close :: proc(thor: ^Thor) {
    if !thor.problems_open {
        return
    }
    thor.problems_open = false
    if thor.problems.return_focus != "" {
        thor.focus_request = thor.problems.return_focus
    }
}

// The path shown for a group: relative to the workspace when inside it.
problem_display_path :: proc(thor: ^Thor, path: string) -> string {
    if thor.workspace_prefix != "" && strings.has_prefix(path, thor.workspace_prefix) {
        return path[len(thor.workspace_prefix):]
    }
    return path
}

// Opens the file of a problem at its location and closes the panel.
thor_problem_jump :: proc(thor: ^Thor, path: string, p: Problem) {
    thor_problems_close(thor)
    if p.offset < 0 {
        thor_goto_file_line_col(thor, path, p.line + 1, p.col)
        return
    }
    thor_goto_location(thor, path, p.offset)
}

@(private = "file")
problem_color :: proc(thor: ^Thor, severity: editview.Diagnostic_Severity) -> ui.Color {
    switch severity {
    case .Error:
        return thor.theme.error_color
    case .Warning:
        return thor.theme.warning_color
    case .Information, .Hint:
        return thor.theme.info_color
    }
    return thor.theme.muted_color
}

@(private = "file")
problem_label :: proc(severity: editview.Diagnostic_Severity) -> string {
    switch severity {
    case .Error:
        return "error"
    case .Warning:
        return "warning"
    case .Information:
        return "info"
    case .Hint:
        return "hint"
    }
    return ""
}

thor_problems_view :: proc(thor: ^Thor) {
    if !thor.problems_open {
        return
    }

    backdrop := ui.scope(
        {
            key = "problems-backdrop",
            flags = {.Floating, .Clickable},
            props = {
                position = .Fixed,
                inset = {0, 0, 0, 0},
                w = ui.Grow(1),
                h = ui.Grow(1),
                dir = .Column,
                justify = .Center,
                align = .Center,
                z = 410,
                bg = ui.Color{0, 0, 0, 140},
            },
        },
    )

    problems_box(thor)

    if backdrop.clicked || ui.take_key(.Escape) {
        thor_problems_close(thor)
    }
}

@(private = "file")
problems_box :: proc(thor: ^Thor) {
    groups := thor_problem_groups(thor)
    box    := ui.scope(
        {
            key = "problems-box",
            flags = {.Clickable, .Focusable},
            props = {
                w = ui.Px(PROBLEMS_WIDTH),
                max_w = ui.viewport().x - 80,
                h = len(groups) == 0 ? ui.FIT : ui.Px(PROBLEMS_HEIGHT),
                max_h = ui.viewport().y - 80,
                dir = .Column,
                bg = thor.theme.background,
                radius = ui.rad(10),
                border = {width = ui.all(1), color = thor.theme.border},
                shadow = {offset = {0, 8}, blur = 32, color = thor.theme.contrast},
            },
        },
    )
    if thor.problems.focus_pending {
        ui.set_focus(box.id)
        thor.problems.focus_pending = false
    }

    problems_header(thor, groups)

    if len(groups) == 0 {
        ui.label("No problems.", {key = "none", props = {color = thor.theme.muted_color, pad = ui.xy(16, 14)}})
        return
    }
    ui.scope({key = "list", flags = {.Clip, .Scroll_Y}, props = {w = ui.Grow(1), h = ui.Grow(1), dir = .Column, pad = ui.xy(8, 8), gap = {0, 2}}})
    for g, gi in groups {
        ui.push_id_int(i64(gi))
        defer ui.pop_id()
        ui.label(
            fmt.tprintf("%s (%d)", problem_display_path(thor, g.path), len(g.problems)),
            {key = "file", props = {color = thor.theme.foreground, pad = {l = 8, t = 8, b = 4}, text_wrap = .Ellipsis, w = ui.Grow(1)}},
        )
        for p, pi in g.problems {
            problem_row(thor, g.path, p, pi)
        }
    }
}

@(private = "file")
problems_header :: proc(thor: ^Thor, groups: []Problem_Group) {
    ui.scope(
        {
            key = "header",
            props = {w = ui.Grow(1), h = ui.FIT, dir = .Row, align = .Center, gap = {10, 0}, pad = ui.xy(14, 12), bg = thor.theme.second_background},
        },
    )
    icon, color := "circle-check", thor.theme.success_color
    for sev in editview.Diagnostic_Severity {
        if problem_count(groups, sev) > 0 {
            icon, color = "alert-circle", problem_color(thor, sev)
            break
        }
    }
    thor_icon_label(thor, icon, color)
    ui.label("Problems", {key = "title", props = {color = thor.theme.foreground, text_wrap = .None}})
    ui.label(
        fmt.tprintf(
            "%d errors, %d warnings, %d infos, %d hints",
            problem_count(groups, .Error),
            problem_count(groups, .Warning),
            problem_count(groups, .Information),
            problem_count(groups, .Hint),
        ),
        {key = "counts", props = {color = thor.theme.muted_color, text_wrap = .None}},
    )
    ui.leaf({key = "gap", props = {w = ui.Grow(1)}})
    close := ui.scope(
        {
            key = "close",
            flags = {.Clickable},
            props = {w = ui.Px(26), h = ui.Px(26), dir = .Row, justify = .Center, align = .Center, radius = ui.rad(4), cursor = .Pointer},
            hover = {bg = thor.theme.buttons},
        },
    )
    thor_icon_label(thor, "x", thor.theme.muted_color)
    thor_tip(thor, close.id, "Close", thor_action_shortcut(thor, "open_problems"))
    if close.clicked {
        thor_problems_close(thor)
    }
}

@(private = "file")
problem_row :: proc(thor: ^Thor, path: string, p: Problem, index: int) {
    ui.push_id_int(i64(index))
    defer ui.pop_id()
    color := problem_color(thor, p.severity)
    row   := ui.scope(
        {
            key = "row",
            flags = {.Clickable},
            props = {w = ui.Grow(1), h = ui.FIT, dir = .Row, align = .Center, gap = {10, 0}, pad = ui.xy(8, 4), radius = ui.rad(4), cursor = .Pointer},
            hover = {bg = thor.theme.buttons},
        },
    )
    ui.label(problem_label(p.severity), {key = "severity", props = {color = color, text_wrap = .None, min_w = 56}})
    ui.label(fmt.tprintf("%d", p.line + 1), {key = "line", props = {color = thor.theme.muted_color, text_wrap = .None, min_w = 40}})
    ui.label(p.message, {key = "message", props = {color = thor.theme.foreground, text_wrap = .Ellipsis, w = ui.Grow(1)}})
    if p.code != "" {
        ui.label(p.code, {key = "code", props = {color = thor.theme.muted_color, text_wrap = .None}})
    }
    if row.clicked {
        thor_problem_jump(thor, path, p)
    }
}
