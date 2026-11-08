package thor

import "core:fmt"
import "core:slice"
import "core:strings"

import "../editview"
import ui "../vendor/loom/loom"

// The Problems panel: the diagnostics of the open files, grouped by file.

PROBLEMS_WIDTH :: 760
PROBLEMS_HEIGHT :: 520

// State of the Problems panel.
Problems_View :: struct {
    return_focus:  string, // focus owner when it opened
    focus_pending: bool,
}

// One diagnostic row of the panel.
Problem :: struct {
    offset:   int, // byte offset in the file
    line:     int, // 0-based
    severity: editview.Diagnostic_Severity,
    message:  string, // borrowed from the file
    code:     string,
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
            rows[i] = Problem {
                offset   = d.start,
                line     = d.line,
                severity = d.severity,
                message  = d.message,
                code     = d.code,
            }
        }
        slice.stable_sort_by(rows, proc(a, b: Problem) -> bool {
            return a.line < b.line
        })
        append(&groups, Problem_Group {path = file.path, problems = rows})
    }
    slice.sort_by(groups[:], proc(a, b: Problem_Group) -> bool {
        return a.path < b.path
    })
    return groups[:]
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
    thor_goto_location(thor, path, p.offset)
}

@(private = "file")
problem_color :: proc(thor: ^Thor, severity: editview.Diagnostic_Severity) -> ui.Color {
    switch severity {
    case .Error:   return thor.theme.error_color
    case .Warning: return thor.theme.warning_color
    case .Hint:    return thor.theme.info_color
    }
    return thor.theme.muted_color
}

@(private = "file")
problem_label :: proc(severity: editview.Diagnostic_Severity) -> string {
    switch severity {
    case .Error:   return "error"
    case .Warning: return "warning"
    case .Hint:    return "hint"
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
    box := ui.scope(
        {
            key = "problems-box",
            flags = {.Clickable, .Focusable},
            props = {
                w = ui.Px(PROBLEMS_WIDTH),
                max_w = ui.viewport().x - 80,
                h = ui.Px(PROBLEMS_HEIGHT),
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

    groups := thor_problem_groups(thor)
    problems_header(thor, groups)

    ui.scope(
        {
            key = "list",
            flags = {.Clip, .Scroll_Y},
            props = {w = ui.Grow(1), h = ui.Grow(1), dir = .Column, pad = ui.xy(8, 8), gap = {0, 2}},
        },
    )
    if len(groups) == 0 {
        ui.label("No problems in the open files.", {key = "none", props = {color = thor.theme.muted_color, pad = ui.xy(8, 8)}})
        return
    }
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
            props = {
                w = ui.Grow(1),
                h = ui.FIT,
                dir = .Row,
                align = .Center,
                gap = {10, 0},
                pad = ui.xy(14, 12),
                bg = thor.theme.second_background,
            },
        },
    )
    thor_icon_label(thor, "alert-circle", thor.theme.error_color)
    ui.label("Problems", {key = "title", props = {color = thor.theme.foreground, text_wrap = .None}})
    ui.label(
        fmt.tprintf(
            "%d errors, %d warnings, %d hints",
            problem_count(groups, .Error),
            problem_count(groups, .Warning),
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
    row := ui.scope(
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
