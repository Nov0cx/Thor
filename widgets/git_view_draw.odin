package widgets

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

import "../ui"

// Drawing for Git_View, split from git_view.odin for size only. The chrome
// (scrim, shadow, box, sidebar, footer) copies the settings view stroke for
// stroke, so the two modals read as one family.

@(private = "file")
GIT_SCROLLBAR_STYLE :: ui.Scrollbar_Style {width = 6, min_thumb = 24, inset = 4}

@(private = "file")
git_view_tint :: proc(base: rl.Color, alpha: u8) -> rl.Color {
    return rl.Color {base.r, base.g, base.b, alpha}
}

@(private = "file")
git_view_corner_radius :: proc(view: ^Git_View) -> f32 {
    return SETTINGS_ROUNDNESS * min(view.box.width, view.box.height) * 0.5
}

@(private = "file")
git_view_kind_label :: proc(kind: Git_View_Kind) -> string {
    switch kind {
    case .Changes:  return "Changes"
    case .History:  return "History"
    case .Branches: return "Branches"
    case .Settings: return "Settings"
    case .Hosting:  return "Hosting"
    }
    return ""
}

@(private = "file")
git_view_kind_icon :: proc(kind: Git_View_Kind) -> string {
    switch kind {
    case .Changes:  return "git-commit"
    case .History:  return "history"
    case .Branches: return "git-branch"
    case .Settings: return "settings"
    case .Hosting:  return "world-www"
    }
    return ""
}

@(private = "file")
git_view_status_name :: proc(status: Git_Status) -> string {
    switch status {
    case .None:      return ""
    case .Modified:  return "Modified"
    case .Renamed:   return "Renamed"
    case .Added:     return "Added"
    case .Untracked: return "Untracked"
    case .Deleted:   return "Deleted"
    case .Conflict:  return "Conflict"
    case .Submodule: return "Submodule"
    }
    return ""
}

@(private = "file")
git_view_status_color :: proc(view: ^Git_View, status: Git_Status) -> rl.Color {
    switch status {
    case .None:                return view.text_color
    case .Modified, .Renamed:  return view.warning_color
    case .Added, .Untracked:   return view.added_color
    case .Deleted:             return view.removed_color
    case .Conflict:            return view.conflict_color
    case .Submodule:           return view.muted_color
    }
    return view.text_color
}

// Head-truncates `text` to fit `max_width`: the tail carries the file name,
// so the front is what goes.
@(private = "file")
git_view_fit_tail :: proc(text: string, font_size: i32, max_width: f32) -> string {
    if cast(f32) ui.measure_text(text, font_size) <= max_width {
        return text
    }
    rest := text
    for len(rest) > 0 {
        rest = rest[input_next_rune(rest, 0):]
        candidate := strings.concatenate({"...", rest}, context.temp_allocator)
        if cast(f32) ui.measure_text(candidate, font_size) <= max_width {
            return candidate
        }
    }
    return "..."
}

git_view_draw :: proc(widget: ^ui.Widget, ctx: ^ui.Context) {
    view := cast(^Git_View) widget
    if !view.visible {
        return
    }
    mouse := rl.GetMousePosition()

    rl.DrawRectangleRec(view.bounds, rl.Color {0, 0, 0, 150})
    git_view_draw_shadow(view)
    rl.DrawRectangleRounded(view.box, SETTINGS_ROUNDNESS, 8, view.background_color)
    rl.DrawRectangleRoundedLinesEx(view.box, SETTINGS_ROUNDNESS, 8, 1, view.border_color)

    // The sidebar comes first: the header divider lies on its top edge.
    git_view_draw_sidebar(view, mouse)
    git_view_draw_header(view, ctx, mouse)

    switch view.kind {
    case .Changes:
        git_view_draw_changes(view, ctx, mouse)
    case .History:
        git_view_draw_history(view, ctx, mouse)
    case .Branches:
        git_view_draw_branches(view, ctx, mouse)
    case .Settings:
        git_view_draw_settings(view, ctx, mouse)
    case .Hosting:
        git_view_draw_hosting(view, mouse)
    }
    git_view_draw_footer(view)
}

// Asks for a hover hint over `rect` while the view is the hot widget.
@(private = "file")
git_view_tip :: proc(view: ^Git_View, ctx: ^ui.Context, rect: rl.Rectangle, text: string, mouse: rl.Vector2) {
    if ctx != nil && ctx.hot == &view.widget && rl.CheckCollisionPointRec(mouse, rect) {
        ui.tooltip_request(ctx, rect, text)
    }
}

// Three fading outlines under the box; there is no blur, so the steps stand
// in for one.
@(private = "file")
git_view_draw_shadow :: proc(view: ^Git_View) {
    for step := 3; step >= 1; step -= 1 {
        grow := cast(f32) step * 3
        rect := rl.Rectangle {
            view.box.x - grow,
            view.box.y - grow + 2,
            view.box.width + grow * 2,
            view.box.height + grow * 2,
        }
        rl.DrawRectangleRounded(rect, SETTINGS_ROUNDNESS, 8, rl.Color {0, 0, 0, 30})
    }
}

@(private = "file")
git_view_draw_header :: proc(view: ^Git_View, ctx: ^ui.Context, mouse: rl.Vector2) {
    x := view.box.x + 20
    title_y := cast(i32) (view.box.y + (view.header_height - cast(f32) view.font_title) * 0.5)
    ui.draw_text("Git", cast(i32) x, title_y, view.font_title, view.text_color)
    x += cast(f32) ui.measure_text("Git", view.font_title) + 14

    if view.branch != "" {
        icon_y := cast(i32) (view.box.y + (view.header_height - 16) * 0.5)
        ui.draw_icon("git-branch", cast(i32) x, icon_y, 16, view.accent_color)
        x += 20
        branch_y := cast(i32) (view.box.y + (view.header_height - cast(f32) view.font_primary) * 0.5)
        ui.draw_text(view.branch, cast(i32) x, branch_y, view.font_primary, view.accent_color)
        x += cast(f32) ui.measure_text(view.branch, view.font_primary) + 12

        if view.has_upstream && (view.ahead > 0 || view.behind > 0) {
            counts := fmt.tprintf("%d ahead · %d behind", view.ahead, view.behind)
            counts_y := view.box.y + (view.header_height - cast(f32) view.font_small) * 0.5
            ui.draw_text(counts, cast(i32) x, cast(i32) counts_y, view.font_small, view.muted_color)
            counts_rect := rl.Rectangle {x, counts_y, cast(f32) ui.measure_text(counts, view.font_small), cast(f32) view.font_small}
            git_view_tip(view, ctx, counts_rect, "Commits ahead and behind the upstream branch", mouse)
        }
    }

    fetch, pull, push := git_view_sync_rects(view)
    git_view_draw_sync_button(view, ctx, fetch, "cloud-down", "Fetch", mouse)
    git_view_draw_sync_button(view, ctx, pull, "arrow-down", "Pull", mouse)
    git_view_draw_sync_button(view, ctx, push, "arrow-up", "Push", mouse)
    git_view_draw_icon_button(view, git_view_close_rect(view), "x", 16, mouse)
    git_view_tip(view, ctx, git_view_close_rect(view), "Close", mouse)

    rl.DrawRectangleRec(
        rl.Rectangle {view.box.x + 1, view.box.y + view.header_height, view.box.width - 2, 1},
        git_view_tint(view.muted_color, 45),
    )
}

// A framed toolbar button, dimmed while a command runs.
@(private = "file")
git_view_draw_sync_button :: proc(view: ^Git_View, ctx: ^ui.Context, rect: rl.Rectangle, icon, tip: string, mouse: rl.Vector2) {
    hover := !view.busy && rl.CheckCollisionPointRec(mouse, rect)
    git_view_tip(view, ctx, rect, tip, mouse)
    rl.DrawRectangleRounded(rect, 0.35, 6, hover ? git_view_tint(view.accent_color, 25) : view.field_color)
    rl.DrawRectangleRoundedLinesEx(
        rect, 0.35, 6, 1, hover ? view.accent_color : git_view_tint(view.muted_color, 60),
    )
    color := view.text_color
    if view.busy {
        color = git_view_tint(view.muted_color, 90)
    } else if hover {
        color = view.accent_color
    }
    ui.draw_icon(
        icon,
        cast(i32) (rect.x + (rect.width - 16) * 0.5),
        cast(i32) (rect.y + (rect.height - 16) * 0.5),
        16,
        color,
    )
}

@(private = "file")
git_view_draw_icon_button :: proc(view: ^Git_View, rect: rl.Rectangle, icon: string, size: i32, mouse: rl.Vector2) {
    hover := rl.CheckCollisionPointRec(mouse, rect)
    if hover {
        rl.DrawRectangleRounded(rect, 0.35, 6, git_view_tint(view.accent_color, 25))
    }
    ui.draw_icon(
        icon,
        cast(i32) (rect.x + (rect.width - cast(f32) size) * 0.5),
        cast(i32) (rect.y + (rect.height - cast(f32) size) * 0.5),
        size,
        hover ? view.accent_color : view.muted_color,
    )
}

@(private = "file")
git_view_draw_sidebar :: proc(view: ^Git_View, mouse: rl.Vector2) {
    // An oversized rounded rect clipped to the sidebar: only the bottom-left
    // corner keeps its rounding, so the fill follows the box's corner.
    radius := git_view_corner_radius(view)
    fill := rl.Rectangle {
        view.sidebar.x,
        view.sidebar.y - radius,
        view.sidebar.width + radius,
        view.sidebar.height + radius,
    }
    ui.begin_clip(view.sidebar)
    rl.DrawRectangleRounded(fill, 2 * radius / min(fill.width, fill.height), 8, view.header_color)
    ui.end_clip()

    kinds := make([dynamic]Git_View_Kind, context.temp_allocator)
    git_view_categories(view, &kinds)
    for kind, i in kinds {
        rect := git_view_category_rect(view, i)
        selected := kind == view.kind
        if selected {
            rl.DrawRectangleRounded(rect, 0.35, 6, git_view_tint(view.accent_color, 32))
        } else if rl.CheckCollisionPointRec(mouse, rect) {
            rl.DrawRectangleRounded(rect, 0.35, 6, git_view_tint(view.text_color, 12))
        }
        icon_color := selected ? view.accent_color : view.muted_color
        text_color := selected ? view.text_color : view.muted_color
        ui.draw_icon(git_view_kind_icon(kind), cast(i32) (rect.x + 12), cast(i32) (rect.y + (rect.height - 16) * 0.5), 16, icon_color)
        ui.draw_text(git_view_kind_label(kind), cast(i32) (rect.x + 38), cast(i32) (rect.y + (rect.height - cast(f32) view.font_primary) * 0.5), view.font_primary, text_color)

        // Change count on the Changes entry, as a small pill.
        if kind == .Changes {
            count := len(view.unstaged) + len(view.staged)
            if count > 0 {
                label := fmt.tprintf("%d", count)
                tw := cast(f32) ui.measure_text(label, view.font_small)
                pill_h := cast(f32) view.font_small + 5
                pill := rl.Rectangle {rect.x + rect.width - 12 - tw - 12, rect.y + (rect.height - pill_h) * 0.5, tw + 12, pill_h}
                rl.DrawRectangleRounded(pill, 0.5, 8, git_view_tint(view.accent_color, 32))
                ui.draw_text(label, cast(i32) (pill.x + 6), cast(i32) (pill.y + (pill_h - cast(f32) view.font_small) * 0.5), view.font_small, view.accent_color)
            }
        }
    }

    rl.DrawRectangleRec(
        rl.Rectangle {view.sidebar.x + view.sidebar.width - 1, view.sidebar.y, 1, view.sidebar.height},
        git_view_tint(view.muted_color, 45),
    )
}

// The footer carries the last command's report when there is one, the key
// hints otherwise.
@(private = "file")
git_view_draw_footer :: proc(view: ^Git_View) {
    rect := git_view_footer_rect(view)
    rl.DrawRectangleRec(
        rl.Rectangle {rect.x, rect.y, rect.width, 1}, git_view_tint(view.muted_color, 45),
    )
    text := view.status_line
    color := view.status_is_error ? view.removed_color : git_view_tint(view.muted_color, 200)
    if view.busy {
        text = "Working..."
        color = git_view_tint(view.muted_color, 200)
    } else if text == "" {
        // The UI font carries no arrow glyphs, so the hint names the keys.
        switch view.kind {
        case .Changes:
            text = "Tab focus  ·  Space stage/unstage  ·  Ctrl+Enter commit  ·  Esc close"
        case .History:
            text = "Up/Down commits  ·  Esc close"
        case .Branches:
            text = "Up/Down navigate  ·  Enter check out  ·  Esc close"
        case .Settings, .Hosting:
            text = "Esc close"
        }
    }
    text = git_view_fit_tail(text, view.font_small, rect.width - 32)
    tw := ui.measure_text(text, view.font_small)
    ui.draw_text(
        text,
        cast(i32) (rect.x + (rect.width - cast(f32) tw) * 0.5),
        cast(i32) (rect.y + (rect.height - cast(f32) view.font_small) * 0.5),
        view.font_small,
        color,
    )
}

// ---- changes view ----

@(private = "file")
git_view_draw_changes :: proc(view: ^Git_View, ctx: ^ui.Context, mouse: rl.Vector2) {
    git_view_draw_file_section(view, ctx, false, mouse)
    git_view_draw_file_section(view, ctx, true, mouse)

    // Divider between the file column and the diff.
    right := git_view_right_rect(view)
    rl.DrawRectangleRec(
        rl.Rectangle {right.x, right.y, 1, right.height}, git_view_tint(view.muted_color, 45),
    )

    git_view_draw_diff(view, ctx)
    git_view_draw_commit_box(view, ctx, mouse)
}

@(private = "file")
git_view_draw_file_section :: proc(view: ^Git_View, ctx: ^ui.Context, staged: bool, mouse: rl.Vector2) {
    header, list := git_view_section_rects(view, staged)
    count := staged ? len(view.staged) : len(view.unstaged)

    title := fmt.tprintf(staged ? "STAGED (%d)" : "UNSTAGED (%d)", count)
    ui.draw_text(
        title,
        cast(i32) (header.x + SETTINGS_ITEM_INSET + 12),
        cast(i32) (header.y + (header.height - cast(f32) view.font_small) * 0.5),
        view.font_small,
        git_view_tint(view.muted_color, 200),
    )
    if staged {
        rl.DrawRectangleRec(
            rl.Rectangle {header.x, header.y, header.width, 1}, git_view_tint(view.muted_color, 45),
        )
    }

    if count > 0 && !view.busy {
        label := staged ? "Unstage All" : "Stage All"
        action := git_view_section_action_rect(view, header, label)
        hover := rl.CheckCollisionPointRec(mouse, action)
        if hover {
            rl.DrawRectangleRounded(action, 0.35, 6, git_view_tint(view.accent_color, 25))
        }
        ui.draw_text(
            label,
            cast(i32) (action.x + 8),
            cast(i32) (action.y + (action.height - cast(f32) view.font_small) * 0.5),
            view.font_small,
            hover ? view.accent_color : view.muted_color,
        )
    }

    if count == 0 {
        message := staged ? "Nothing staged" : "No changes"
        ui.draw_text(
            message,
            cast(i32) (list.x + SETTINGS_ITEM_INSET + 12),
            cast(i32) (list.y + 8),
            view.font_body,
            git_view_tint(view.muted_color, 120),
        )
        return
    }

    files := staged ? &view.staged : &view.unstaged
    ui.begin_clip(list)
    for file, index in files {
        rect := git_view_file_row_rect(view, staged, index)
        if rect.y + rect.height < list.y || rect.y > list.y + list.height {
            continue // fully scrolled out
        }
        band := rl.Rectangle {
            rect.x + SETTINGS_ITEM_INSET, rect.y + 1, rect.width - SETTINGS_ITEM_INSET * 2, rect.height - 2,
        }
        hovered := rl.CheckCollisionPointRec(mouse, rect)
        if view.sel_staged == staged && view.sel_index == index {
            rl.DrawRectangleRounded(band, 0.35, 6, view.selected_color)
        } else if hovered {
            rl.DrawRectangleRounded(band, 0.35, 6, git_view_tint(view.text_color, 10))
        }

        // Status letter chip.
        status_color := git_view_status_color(view, file.status)
        chip_size := cast(f32) view.font_badge + 4
        chip := rl.Rectangle {rect.x + SETTINGS_ITEM_INSET + 8, rect.y + (rect.height - chip_size) * 0.5, chip_size, chip_size}
        rl.DrawRectangleRounded(chip, 0.35, 6, git_view_tint(status_color, 40))
        letter := tree_status_letter(file.status)
        lw := ui.measure_text(letter, view.font_badge)
        ui.draw_text(
            letter,
            cast(i32) (chip.x + (chip.width - cast(f32) lw) * 0.5),
            cast(i32) (chip.y + (chip.height - cast(f32) view.font_badge) * 0.5),
            view.font_badge,
            status_color,
        )
        git_view_tip(view, ctx, chip, git_view_status_name(file.status), mouse)

        // Name, leaving room for the hover action boxes.
        name_x := chip.x + chip.width + 8
        max_w := rect.x + rect.width - SETTINGS_ROW_PAD - name_x
        if hovered {
            max_w -= staged ? 24 : 48
        }
        if file.is_lfs {
            max_w -= cast(f32) ui.measure_text("LFS", view.font_badge) + 16
        }
        name := git_view_fit_tail(file.display, view.font_body, max_w)
        ui.draw_text(name, cast(i32) name_x, cast(i32) (rect.y + (rect.height - cast(f32) view.font_body) * 0.5), view.font_body, view.text_color)

        if file.is_lfs {
            pill_w := cast(f32) ui.measure_text("LFS", view.font_badge) + 8
            pill_h := cast(f32) view.font_badge + 4
            pill := rl.Rectangle {
                name_x + cast(f32) ui.measure_text(name, view.font_body) + 8,
                rect.y + (rect.height - pill_h) * 0.5,
                pill_w, pill_h,
            }
            rl.DrawRectangleRounded(pill, 0.5, 8, git_view_tint(view.accent_color, 32))
            ui.draw_text("LFS", cast(i32) (pill.x + 4), cast(i32) (pill.y + (pill_h - cast(f32) view.font_badge) * 0.5), view.font_badge, view.accent_color)
            git_view_tip(view, ctx, pill, "Tracked by Git LFS", mouse)
        }

        if hovered && !view.busy {
            action := git_view_file_action_rect(rect)
            git_view_draw_icon_button(view, action, staged ? "minus" : "plus", 14, mouse)
            git_view_tip(view, ctx, action, staged ? "Unstage" : "Stage", mouse)
            if !staged {
                discard := git_view_file_discard_rect(rect)
                git_view_draw_icon_button(view, discard, "trash", 14, mouse)
                git_view_tip(view, ctx, discard, "Discard changes", mouse)
            }
        }
    }
    ui.end_clip()

    content := cast(f32) count * view.row_file
    if track, thumb, ok := ui.scrollbar_rects(list, content, staged ? view.staged_scroll : view.unstaged_scroll, GIT_SCROLLBAR_STYLE); ok {
        rl.DrawRectangleRounded(track, 0.5, 4, git_view_tint(view.muted_color, 15))
        rl.DrawRectangleRounded(thumb, 0.5, 4, git_view_tint(view.muted_color, 120))
    }
}

@(private = "file")
git_view_draw_diff :: proc(view: ^Git_View, ctx: ^ui.Context) {
    diff := git_view_diff_rect(view)
    list := git_view_diff_list_rect(view)

    if view.diff_title != "" {
        title := git_view_fit_tail(view.diff_title, view.font_meta, diff.width - 32)
        ui.draw_text(
            title,
            cast(i32) (diff.x + 16),
            cast(i32) (diff.y + (view.row_diff_title - cast(f32) view.font_meta) * 0.5),
            view.font_meta,
            git_view_tint(view.muted_color, 200),
        )
        rl.DrawRectangleRec(
            rl.Rectangle {diff.x + 1, diff.y + view.row_diff_title - 1, diff.width - 2, 1},
            git_view_tint(view.muted_color, 30),
        )
        // Head-truncated: the hint carries the full title.
        if title != view.diff_title {
            strip := rl.Rectangle {diff.x, diff.y, diff.width, view.row_diff_title}
            git_view_tip(view, ctx, strip, view.diff_title, rl.GetMousePosition())
        }
    }

    if len(view.diff_rows) == 0 {
        message := view.diff_title == "" ? "Select a file to see its diff" : "No changes to show"
        tw := ui.measure_text(message, view.font_primary)
        ui.draw_text(
            message,
            cast(i32) (list.x + (list.width - cast(f32) tw) * 0.5),
            cast(i32) (list.y + list.height * 0.4),
            view.font_primary,
            view.muted_color,
        )
        return
    }

    gutter: f32 = 44
    text_x := list.x + gutter * 2 + 10

    ui.begin_clip(list)
    for row, index in view.diff_rows {
        top := list.y + cast(f32) index * view.row_diff - view.diff_scroll
        if top + view.row_diff < list.y || top > list.y + list.height {
            continue
        }
        rect := rl.Rectangle {list.x, top, list.width, view.row_diff}
        text_y := cast(i32) (top + (view.row_diff - cast(f32) view.font_body) * 0.5)

        color := view.text_color
        switch row.kind {
        case .Hunk:
            rl.DrawRectangleRec(rect, git_view_tint(view.accent_color, 14))
            ui.draw_text(git_view_fit_tail(row.text, view.font_meta, rect.width - 24), cast(i32) (list.x + 12), text_y, view.font_meta, view.accent_color)
            continue
        case .Meta:
            ui.draw_text(git_view_fit_tail(row.text, view.font_meta, rect.width - 24), cast(i32) (list.x + 12), text_y, view.font_meta, view.muted_color)
            continue
        case .Added:
            rl.DrawRectangleRec(rect, git_view_tint(view.added_color, 26))
        case .Removed:
            rl.DrawRectangleRec(rect, git_view_tint(view.removed_color, 26))
        case .Context:
        }

        // Line numbers: old left, new right of it; a side without a line on
        // this row stays empty.
        number_color := git_view_tint(view.muted_color, 200)
        if row.kind == .Added {
            number_color = view.added_color
        } else if row.kind == .Removed {
            number_color = view.removed_color
        }
        if row.old_line > 0 {
            n := fmt.tprintf("%d", row.old_line)
            nw := ui.measure_text(n, view.font_small)
            ui.draw_text(n, cast(i32) (list.x + gutter - cast(f32) nw), text_y, view.font_small, number_color)
        }
        if row.new_line > 0 {
            n := fmt.tprintf("%d", row.new_line)
            nw := ui.measure_text(n, view.font_small)
            ui.draw_text(n, cast(i32) (list.x + gutter * 2 - cast(f32) nw), text_y, view.font_small, number_color)
        }

        if row.text != "" {
            ui.draw_text(row.text, cast(i32) text_x, text_y, view.font_body, color)
        }
    }
    ui.end_clip()

    // Gutter divider.
    rl.DrawRectangleRec(
        rl.Rectangle {list.x + gutter * 2 + 5, list.y, 1, list.height}, git_view_tint(view.muted_color, 30),
    )

    content := cast(f32) len(view.diff_rows) * view.row_diff
    if track, thumb, ok := ui.scrollbar_rects(list, content, view.diff_scroll, GIT_SCROLLBAR_STYLE); ok {
        rl.DrawRectangleRounded(track, 0.5, 4, git_view_tint(view.muted_color, 15))
        rl.DrawRectangleRounded(thumb, 0.5, 4, git_view_tint(view.muted_color, 120))
    }
}

@(private = "file")
git_view_draw_commit_box :: proc(view: ^Git_View, ctx: ^ui.Context, mouse: rl.Vector2) {
    box := git_view_commit_rect(view)
    rl.DrawRectangleRec(
        rl.Rectangle {box.x, box.y, box.width, 1}, git_view_tint(view.muted_color, 45),
    )

    git_view_draw_field(view, git_view_subject_rect(view), &view.subject, view.focus == .Subject, "Commit subject", false)
    git_view_draw_field(view, git_view_description_rect(view), &view.description, view.focus == .Description, "Description", true)

    // Amend checkbox.
    amend := git_view_amend_rect(view)
    check := rl.Rectangle {amend.x, amend.y + 1, 16, 16}
    rl.DrawRectangleRounded(check, 0.35, 6, view.amend ? git_view_tint(view.accent_color, 40) : view.field_color)
    rl.DrawRectangleRoundedLinesEx(
        check, 0.35, 6, 1, view.amend ? view.accent_color : git_view_tint(view.muted_color, 60),
    )
    if view.amend {
        ui.draw_icon("check", cast(i32) (check.x + 1), cast(i32) (check.y + 1), 14, view.accent_color)
    }
    ui.draw_text("Amend", cast(i32) (check.x + 22), cast(i32) (amend.y + 2), view.font_body, view.text_color)
    git_view_tip(view, ctx, amend, "Rewrite the last commit instead of adding a new one", mouse)

    // Commit button.
    button := git_view_commit_button_rect(view)
    enabled := git_view_can_commit(view)
    hover := enabled && rl.CheckCollisionPointRec(mouse, button)
    fill := view.field_color
    border := git_view_tint(view.muted_color, 60)
    label_color := git_view_tint(view.muted_color, 120)
    if enabled {
        fill = hover ? git_view_tint(view.accent_color, 45) : git_view_tint(view.accent_color, 25)
        border = view.accent_color
        label_color = hover ? view.accent_color : view.text_color
    }
    rl.DrawRectangleRounded(button, 0.35, 6, fill)
    rl.DrawRectangleRoundedLinesEx(button, 0.35, 6, 1, border)
    label := view.amend ? "Amend" : "Commit"
    lw := ui.measure_text(label, view.font_body)
    ui.draw_text(
        label,
        cast(i32) (button.x + (button.width - cast(f32) lw) * 0.5),
        cast(i32) (button.y + (button.height - cast(f32) view.font_body) * 0.5),
        view.font_body,
        label_color,
    )
}

// ---- history view ----

@(private = "file")
git_view_draw_history :: proc(view: ^Git_View, ctx: ^ui.Context, mouse: rl.Vector2) {
    list := git_view_commits_list_rect(view)
    right := git_view_right_rect(view)
    rl.DrawRectangleRec(
        rl.Rectangle {right.x, right.y, 1, right.height}, git_view_tint(view.muted_color, 45),
    )

    if len(view.commits) == 0 {
        ui.draw_text(
            "No commits",
            cast(i32) (list.x + SETTINGS_ITEM_INSET + 12),
            cast(i32) (list.y + 8),
            view.font_body,
            git_view_tint(view.muted_color, 120),
        )
        git_view_draw_diff(view, ctx)
        return
    }

    ui.begin_clip(list)
    for commit, index in view.commits {
        rect := git_view_commit_row_rect(view, index)
        if rect.y + rect.height < list.y || rect.y > list.y + list.height {
            continue
        }
        band := rl.Rectangle {
            rect.x + SETTINGS_ITEM_INSET, rect.y + 2, rect.width - SETTINGS_ITEM_INSET * 2, rect.height - 4,
        }
        if index == view.commit_sel {
            rl.DrawRectangleRounded(band, 0.35, 6, view.selected_color)
        } else if rl.CheckCollisionPointRec(mouse, rect) {
            rl.DrawRectangleRounded(band, 0.35, 6, git_view_tint(view.text_color, 10))
        }

        text_x := rect.x + SETTINGS_ITEM_INSET + 12
        max_w := rect.width - SETTINGS_ITEM_INSET * 2 - 24

        // Ref decorations as a pill after the subject.
        subject_w := max_w
        pill_label := ""
        if commit.refs != "" {
            pill_label = git_view_fit_tail(commit.refs, view.font_badge, 160)
            subject_w -= cast(f32) ui.measure_text(pill_label, view.font_badge) + 24
        }
        subject := git_view_fit_tail(commit.subject, view.font_body, subject_w)
        ui.draw_text(subject, cast(i32) text_x, cast(i32) (rect.y + 7), view.font_body, view.text_color)
        if pill_label != "" {
            pw := cast(f32) ui.measure_text(pill_label, view.font_badge)
            pill_h := cast(f32) view.font_badge + 6
            pill := rl.Rectangle {text_x + cast(f32) ui.measure_text(subject, view.font_body) + 10, rect.y + 6, pw + 12, pill_h}
            rl.DrawRectangleRounded(pill, 0.5, 8, git_view_tint(view.accent_color, 32))
            ui.draw_text(pill_label, cast(i32) (pill.x + 6), cast(i32) (pill.y + (pill_h - cast(f32) view.font_badge) * 0.5), view.font_badge, view.accent_color)
            git_view_tip(view, ctx, pill, commit.refs, mouse)
        }

        meta := fmt.tprintf("%s · %s · %s", commit.short, commit.author, commit.date)
        ui.draw_text(git_view_fit_tail(meta, view.font_small, max_w), cast(i32) text_x, cast(i32) (rect.y + 10 + cast(f32) view.font_body), view.font_small, view.muted_color)
    }

    // The "Load more" row after the last commit.
    if view.commits_has_more {
        rect := git_view_commit_row_rect(view, len(view.commits))
        if rect.y <= list.y + list.height && rect.y + rect.height >= list.y {
            label := "Load more..."
            hover := rl.CheckCollisionPointRec(mouse, rect)
            tw := ui.measure_text(label, view.font_body)
            ui.draw_text(
                label,
                cast(i32) (rect.x + (rect.width - cast(f32) tw) * 0.5),
                cast(i32) (rect.y + (rect.height - cast(f32) view.font_body) * 0.5),
                view.font_body,
                hover ? view.accent_color : view.muted_color,
            )
        }
    }
    ui.end_clip()

    content := cast(f32) git_view_commit_row_count(view) * view.row_commit
    if track, thumb, ok := ui.scrollbar_rects(list, content, view.commits_scroll, GIT_SCROLLBAR_STYLE); ok {
        rl.DrawRectangleRounded(track, 0.5, 4, git_view_tint(view.muted_color, 15))
        rl.DrawRectangleRounded(thumb, 0.5, 4, git_view_tint(view.muted_color, 120))
    }

    git_view_draw_diff(view, ctx)
}

// ---- branches view ----

@(private = "file")
git_view_ref_kind_label :: proc(kind: Git_Ref_Kind) -> string {
    switch kind {
    case .Branch: return "BRANCHES"
    case .Remote: return "REMOTES"
    case .Tag:    return "TAGS"
    case .Stash:  return "STASHES"
    }
    return ""
}

@(private = "file")
git_view_ref_icon :: proc(kind: Git_Ref_Kind) -> string {
    switch kind {
    case .Branch, .Remote: return "git-branch"
    case .Tag:             return "point"
    case .Stash:           return "device-floppy"
    }
    return ""
}

@(private = "file")
git_view_draw_branches :: proc(view: ^Git_View, ctx: ^ui.Context, mouse: rl.Vector2) {
    list := git_view_refs_list_rect(view)
    rows := make([dynamic]Git_Ref_Row, context.temp_allocator)
    git_view_ref_rows(view, &rows)

    ui.begin_clip(list)
    for row, index in rows {
        rect := git_view_ref_row_rect(view, index)
        if rect.y + rect.height < list.y || rect.y > list.y + list.height {
            continue
        }
        hovered := rl.CheckCollisionPointRec(mouse, rect)

        if row.header {
            chevron := view.ref_collapsed[row.kind] ? "chevron-right" : "chevron-down"
            x := rect.x + SETTINGS_ITEM_INSET + 12
            ui.draw_icon(chevron, cast(i32) x, cast(i32) (rect.y + (rect.height - 16) * 0.5), 16, view.accent_color)
            ui.draw_text(
                git_view_ref_kind_label(row.kind),
                cast(i32) (x + 22),
                cast(i32) (rect.y + (rect.height - cast(f32) view.font_small) * 0.5),
                view.font_small,
                git_view_tint(view.muted_color, 200),
            )
            if row.kind == .Stash && !view.busy {
                action := git_view_section_action_rect(view, rect, "Stash changes")
                action_hover := rl.CheckCollisionPointRec(mouse, action)
                if action_hover {
                    rl.DrawRectangleRounded(action, 0.35, 6, git_view_tint(view.accent_color, 25))
                }
                ui.draw_text(
                    "Stash changes",
                    cast(i32) (action.x + 8),
                    cast(i32) (action.y + (action.height - cast(f32) view.font_small) * 0.5),
                    view.font_small,
                    action_hover ? view.accent_color : view.muted_color,
                )
            }
            continue
        }

        ref := view.refs[row.index]
        band := rl.Rectangle {
            rect.x + SETTINGS_ITEM_INSET, rect.y + 1, rect.width - SETTINGS_ITEM_INSET * 2, rect.height - 2,
        }
        if index == view.ref_sel {
            rl.DrawRectangleRounded(band, 0.35, 6, view.selected_color)
        } else if hovered {
            rl.DrawRectangleRounded(band, 0.35, 6, git_view_tint(view.text_color, 10))
        }

        x := rect.x + SETTINGS_ITEM_INSET + 12 + SETTINGS_GROUP_INDENT
        icon_color := ref.current ? view.accent_color : view.muted_color
        ui.draw_icon(git_view_ref_icon(ref.kind), cast(i32) x, cast(i32) (rect.y + (rect.height - 16) * 0.5), 16, icon_color)
        x += 22

        label := ref.name
        if ref.kind == .Stash && ref.subject != "" {
            label = fmt.tprintf("%s  %s", ref.name, ref.subject)
        }
        max_w := rect.x + rect.width - SETTINGS_ROW_PAD - x
        if ref.kind == .Stash && hovered {
            max_w -= 76
        }
        text_color := ref.current ? view.text_color : git_view_tint(view.text_color, 220)
        ui.draw_text(git_view_fit_tail(label, view.font_body, max_w), cast(i32) x, cast(i32) (rect.y + (rect.height - cast(f32) view.font_body) * 0.5), view.font_body, text_color)

        if ref.current {
            check_x := x + cast(f32) ui.measure_text(label, view.font_body) + 8
            ui.draw_icon("check", cast(i32) check_x, cast(i32) (rect.y + (rect.height - 14) * 0.5), 14, view.accent_color)
        }

        if ref.kind == .Stash && hovered && !view.busy {
            apply, pop, drop := git_view_stash_action_rects(rect)
            git_view_draw_icon_button(view, apply, "check", 14, mouse)
            git_view_draw_icon_button(view, pop, "arrow-up", 14, mouse)
            git_view_draw_icon_button(view, drop, "trash", 14, mouse)
            git_view_tip(view, ctx, apply, "Apply", mouse)
            git_view_tip(view, ctx, pop, "Pop", mouse)
            git_view_tip(view, ctx, drop, "Drop", mouse)
        }
    }
    ui.end_clip()

    content := cast(f32) len(rows) * view.row_ref
    if track, thumb, ok := ui.scrollbar_rects(list, content, view.refs_scroll, GIT_SCROLLBAR_STYLE); ok {
        rl.DrawRectangleRounded(track, 0.5, 4, git_view_tint(view.muted_color, 15))
        rl.DrawRectangleRounded(thumb, 0.5, 4, git_view_tint(view.muted_color, 120))
    }
}

// ---- settings view (git config) ----

@(private = "file")
git_view_draw_settings :: proc(view: ^Git_View, ctx: ^ui.Context, mouse: rl.Vector2) {
    list := git_view_refs_list_rect(view)
    rows := make([dynamic]Git_Config_Row, context.temp_allocator)
    git_view_config_rows(view, &rows)

    ui.begin_clip(list)
    for row, index in rows {
        rect := git_view_config_row_rect(view, index)
        if rect.y + rect.height < list.y || rect.y > list.y + list.height {
            continue
        }
        hovered := rl.CheckCollisionPointRec(mouse, rect)

        if row.lfs != .None {
            git_view_draw_lfs_row(view, ctx, row, rect, index, hovered, mouse)
            continue
        }

        if row.header {
            scope := row.global ? 1 : 0
            chevron := view.config_collapsed[scope] ? "chevron-right" : "chevron-down"
            x := rect.x + SETTINGS_ITEM_INSET + 12
            ui.draw_icon(chevron, cast(i32) x, cast(i32) (rect.y + (rect.height - 16) * 0.5), 16, view.accent_color)
            ui.draw_text(
                row.global ? "GLOBAL" : "LOCAL",
                cast(i32) (x + 22),
                cast(i32) (rect.y + (rect.height - cast(f32) view.font_small) * 0.5),
                view.font_small,
                git_view_tint(view.muted_color, 200),
            )
            continue
        }

        entry := view.config_rows[row.index]
        band := rl.Rectangle {
            rect.x + SETTINGS_ITEM_INSET, rect.y + 1, rect.width - SETTINGS_ITEM_INSET * 2, rect.height - 2,
        }
        if index == view.config_sel {
            rl.DrawRectangleRounded(band, 0.35, 6, view.selected_color)
        } else if hovered {
            rl.DrawRectangleRounded(band, 0.35, 6, git_view_tint(view.text_color, 10))
        }

        x := rect.x + SETTINGS_ITEM_INSET + 12 + SETTINGS_GROUP_INDENT
        ui.draw_text(entry.key, cast(i32) x, cast(i32) (rect.y + (rect.height - cast(f32) view.font_body) * 0.5), view.font_body, view.text_color)

        // The value, or the edit field over it.
        if view.config_edit_index == row.index {
            field := rl.Rectangle {rect.x + rect.width * 0.5, rect.y + 2, rect.width * 0.5 - SETTINGS_ROW_PAD, rect.height - 4}
            git_view_draw_field(view, field, &view.config_edit, view.focus == .Config_Edit, "value", false)
            continue
        }
        value := entry.value
        color := view.accent_color
        if !entry.is_set {
            value = "not set"
            color = git_view_tint(view.muted_color, 120)
        }
        value = git_view_fit_tail(value, view.font_body, rect.width * 0.5 - SETTINGS_ROW_PAD)
        vw := ui.measure_text(value, view.font_body)
        ui.draw_text(
            value,
            cast(i32) (rect.x + rect.width - SETTINGS_ROW_PAD - cast(f32) vw),
            cast(i32) (rect.y + (rect.height - cast(f32) view.font_body) * 0.5),
            view.font_body,
            color,
        )
    }
    ui.end_clip()

    content := cast(f32) len(rows) * view.row_ref
    if track, thumb, ok := ui.scrollbar_rects(list, content, view.config_scroll, GIT_SCROLLBAR_STYLE); ok {
        rl.DrawRectangleRounded(track, 0.5, 4, git_view_tint(view.muted_color, 15))
        rl.DrawRectangleRounded(thumb, 0.5, 4, git_view_tint(view.muted_color, 120))
    }
}

// One row of the settings view's GIT LFS group.
@(private = "file")
git_view_draw_lfs_row :: proc(
    view: ^Git_View,
    ctx: ^ui.Context,
    row: Git_Config_Row,
    rect: rl.Rectangle,
    index: int,
    hovered: bool,
    mouse: rl.Vector2,
) {
    x := rect.x + SETTINGS_ITEM_INSET + 12
    switch row.lfs {
    case .None:
    case .Header:
        ui.draw_text(
            "GIT LFS",
            cast(i32) (x + 22),
            cast(i32) (rect.y + (rect.height - cast(f32) view.font_small) * 0.5),
            view.font_small,
            git_view_tint(view.muted_color, 200),
        )
    case .Status:
        text := view.lfs_available ? view.lfs_version : "Git LFS not installed"
        ui.draw_text(
            text,
            cast(i32) (x + SETTINGS_GROUP_INDENT),
            cast(i32) (rect.y + (rect.height - cast(f32) view.font_body) * 0.5),
            view.font_body,
            git_view_tint(view.muted_color, 150),
        )
    case .Pattern:
        if row.index < 0 || row.index >= len(view.lfs_patterns) {
            return
        }
        ui.draw_text(
            view.lfs_patterns[row.index],
            cast(i32) (x + SETTINGS_GROUP_INDENT),
            cast(i32) (rect.y + (rect.height - cast(f32) view.font_body) * 0.5),
            view.font_body,
            view.text_color,
        )
        git_view_tip(view, ctx, rect, "Pattern tracked by Git LFS", mouse)
    case .Pull, .Track:
        band := rl.Rectangle {
            rect.x + SETTINGS_ITEM_INSET, rect.y + 1, rect.width - SETTINGS_ITEM_INSET * 2, rect.height - 2,
        }
        if index == view.config_sel {
            rl.DrawRectangleRounded(band, 0.35, 6, view.selected_color)
        } else if hovered && !view.busy {
            rl.DrawRectangleRounded(band, 0.35, 6, git_view_tint(view.text_color, 10))
        }
        label := row.lfs == .Pull ? "Pull LFS files" : "Track pattern..."
        tip := row.lfs == .Pull ? "git lfs pull" : "git lfs track"
        ui.draw_text(
            label,
            cast(i32) (x + SETTINGS_GROUP_INDENT),
            cast(i32) (rect.y + (rect.height - cast(f32) view.font_body) * 0.5),
            view.font_body,
            view.busy ? git_view_tint(view.muted_color, 120) : view.text_color,
        )
        ui.draw_icon(
            "chevron-right",
            cast(i32) (rect.x + rect.width - SETTINGS_ROW_PAD - 16),
            cast(i32) (rect.y + (rect.height - 16) * 0.5),
            16,
            view.muted_color,
        )
        git_view_tip(view, ctx, rect, tip, mouse)
    }
}

// ---- hosting view ----

@(private = "file")
git_view_draw_hosting :: proc(view: ^Git_View, mouse: rl.Vector2) {
    list := git_view_refs_list_rect(view)
    items := make([dynamic]Git_Hosting_Item, context.temp_allocator)
    git_view_hosting_items(view, &items)

    ui.begin_clip(list)
    for item in items {
        rect := item.rect
        if rect.y + rect.height < list.y || rect.y > list.y + list.height {
            continue
        }
        hovered := rl.CheckCollisionPointRec(mouse, rect)

        switch item.kind {
        case .Card:
            rl.DrawRectangleRounded(rect, 0.35, 6, view.field_color)
            rl.DrawRectangleRoundedLinesEx(rect, 0.35, 6, 1, git_view_tint(view.muted_color, 60))
            icon := view.host_icon == "" ? "world-www" : view.host_icon
            ui.draw_icon(icon, cast(i32) (rect.x + 12), cast(i32) (rect.y + (rect.height - 18) * 0.5), 18, view.accent_color)
            label := view.host_label == "" ? "No remote detected" : view.host_label
            color := view.host_label == "" ? view.muted_color : view.text_color
            ui.draw_text(git_view_fit_tail(label, view.font_primary, rect.width - 52), cast(i32) (rect.x + 40), cast(i32) (rect.y + (rect.height - cast(f32) view.font_primary) * 0.5), view.font_primary, color)
        case .Action_Repo, .Action_File, .Action_Commit, .Action_Pr:
            label := "Open repository in browser"
            #partial switch item.kind {
            case .Action_File:   label = "Open current file in browser"
            case .Action_Commit: label = "Open last commit in browser"
            case .Action_Pr:     label = view.cli_name == "" ? "Create pull request (browser)" : "Create pull request"
            }
            band := rl.Rectangle {rect.x, rect.y + 1, rect.width, rect.height - 2}
            if hovered && !view.busy {
                rl.DrawRectangleRounded(band, 0.35, 6, git_view_tint(view.text_color, 10))
            }
            ui.draw_text(label, cast(i32) (rect.x + 8), cast(i32) (rect.y + (rect.height - cast(f32) view.font_body) * 0.5), view.font_body, view.text_color)
            ui.draw_icon(
                "chevron-right",
                cast(i32) (rect.x + rect.width - SETTINGS_ROW_PAD - 16),
                cast(i32) (rect.y + (rect.height - 16) * 0.5),
                16,
                view.muted_color,
            )
        case .Pr_Header:
            ui.draw_text("PULL REQUESTS", cast(i32) (rect.x + 4), cast(i32) (rect.y + (rect.height - cast(f32) view.font_small) * 0.5), view.font_small, git_view_tint(view.muted_color, 200))
        case .Pr:
            pr := view.prs[item.index]
            band := rl.Rectangle {rect.x, rect.y + 1, rect.width, rect.height - 2}
            if hovered {
                rl.DrawRectangleRounded(band, 0.35, 6, git_view_tint(view.text_color, 10))
            }
            label := fmt.tprintf("#%d  %s  (%s)", pr.number, pr.title, pr.branch)
            ui.draw_text(git_view_fit_tail(label, view.font_body, rect.width - 16), cast(i32) (rect.x + 8), cast(i32) (rect.y + (rect.height - cast(f32) view.font_body) * 0.5), view.font_body, view.text_color)
        case .Cli_Hint:
            hint := view.cli_name == "" ? "Install gh or glab to list pull requests" : "No open pull requests"
            ui.draw_text(hint, cast(i32) (rect.x + 8), cast(i32) (rect.y + (rect.height - cast(f32) view.font_meta) * 0.5), view.font_meta, git_view_tint(view.muted_color, 150))
        case .Clone_Header:
            ui.draw_text("CLONE REPOSITORY", cast(i32) (rect.x + 4), cast(i32) (rect.y + (rect.height - cast(f32) view.font_small) * 0.5), view.font_small, git_view_tint(view.muted_color, 200))
        case .Clone_Url_Field:
            git_view_draw_field(view, rect, &view.clone_url, view.focus == .Clone_Url, "Repository URL", false)
        case .Clone_Dir_Field:
            git_view_draw_field(view, rect, &view.clone_dir, view.focus == .Clone_Dir, "Destination folder", false)
        case .Clone_Button:
            enabled := !view.busy && len(view.clone_url.buf) > 0 && len(view.clone_dir.buf) > 0
            hover := enabled && hovered
            fill := view.field_color
            border := git_view_tint(view.muted_color, 60)
            label_color := git_view_tint(view.muted_color, 120)
            if enabled {
                fill = hover ? git_view_tint(view.accent_color, 45) : git_view_tint(view.accent_color, 25)
                border = view.accent_color
                label_color = hover ? view.accent_color : view.text_color
            }
            rl.DrawRectangleRounded(rect, 0.35, 6, fill)
            rl.DrawRectangleRoundedLinesEx(rect, 0.35, 6, 1, border)
            lw := ui.measure_text("Clone", view.font_body)
            ui.draw_text(
                "Clone",
                cast(i32) (rect.x + (rect.width - cast(f32) lw) * 0.5),
                cast(i32) (rect.y + (rect.height - cast(f32) view.font_body) * 0.5),
                view.font_body,
                label_color,
            )
        }
    }
    ui.end_clip()

    content := git_view_hosting_content_height(view)
    if track, thumb, ok := ui.scrollbar_rects(list, content, view.hosting_scroll, GIT_SCROLLBAR_STYLE); ok {
        rl.DrawRectangleRounded(track, 0.5, 4, git_view_tint(view.muted_color, 15))
        rl.DrawRectangleRounded(thumb, 0.5, 4, git_view_tint(view.muted_color, 120))
    }
}

// A text field in the search box's clothes: darker fill, accent border and a
// caret while focused, placeholder while empty.
@(private = "file")
git_view_draw_field :: proc(
    view: ^Git_View,
    rect: rl.Rectangle,
    field: ^Git_Text_Field,
    focused: bool,
    placeholder: string,
    multiline: bool,
) {
    rl.DrawRectangleRounded(rect, 0.4, 8, view.field_color)
    border := focused ? git_view_tint(view.accent_color, 70) : git_view_tint(view.muted_color, 45)
    rl.DrawRectangleRoundedLinesEx(rect, 0.4, 8, 1, border)

    text := string(field.buf[:])
    font := view.font_primary
    line_height := cast(f32) font + 5
    text_x := cast(i32) (rect.x + 10)

    if text == "" && !focused {
        ui.draw_text(placeholder, text_x, cast(i32) (rect.y + (min(rect.height, 30) - cast(f32) font) * 0.5), font, git_view_tint(view.muted_color, 120))
        return
    }

    if !multiline {
        y := cast(i32) (rect.y + (rect.height - cast(f32) font) * 0.5)
        ui.draw_text(text, text_x, y, font, view.text_color)
        if focused {
            caret_x := text_x + cast(i32) ui.measure_text(text[:field.caret], font) + 1
            rl.DrawRectangle(caret_x, y, 2, font, view.accent_color)
        }
        return
    }

    // Multiline: one draw per line, scrolled to keep the caret line visible.
    caret_line := strings.count(text[:field.caret], "\n")
    caret_top := cast(f32) caret_line * line_height
    if caret_top < view.desc_scroll {
        view.desc_scroll = caret_top
    } else if caret_top + line_height > view.desc_scroll + rect.height - 8 {
        view.desc_scroll = caret_top + line_height - (rect.height - 8)
    }

    ui.begin_clip(rect)
    line_index := 0
    it := text
    offset := 0
    for {
        line_end := strings.index_byte(it, '\n')
        line := line_end >= 0 ? it[:line_end] : it
        y := rect.y + 5 + cast(f32) line_index * line_height - view.desc_scroll
        if y + line_height >= rect.y && y <= rect.y + rect.height {
            ui.draw_text(line, text_x, cast(i32) y, font, view.text_color)
            if focused && field.caret >= offset && field.caret <= offset + len(line) {
                caret_x := text_x + cast(i32) ui.measure_text(line[:field.caret - offset], font) + 1
                rl.DrawRectangle(caret_x, cast(i32) y, 2, font, view.accent_color)
            }
        }
        if line_end < 0 {
            break
        }
        it = it[line_end + 1:]
        offset += line_end + 1
        line_index += 1
    }
    ui.end_clip()
}
