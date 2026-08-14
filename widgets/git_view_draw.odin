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

git_view_draw :: proc(widget: ^ui.Widget, _: ^ui.Context) {
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
    git_view_draw_header(view, mouse)

    if view.kind == .Changes {
        git_view_draw_changes(view, mouse)
    }
    git_view_draw_footer(view)
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
git_view_draw_header :: proc(view: ^Git_View, mouse: rl.Vector2) {
    x := view.box.x + 20
    title_y := cast(i32) (view.box.y + (view.header_height - 18) * 0.5)
    ui.draw_text("Git", cast(i32) x, title_y, 18, view.text_color)
    x += cast(f32) ui.measure_text("Git", 18) + 14

    if view.branch != "" {
        icon_y := cast(i32) (view.box.y + (view.header_height - 16) * 0.5)
        ui.draw_icon("git-branch", cast(i32) x, icon_y, 16, view.accent_color)
        x += 20
        branch_y := cast(i32) (view.box.y + (view.header_height - 15) * 0.5)
        ui.draw_text(view.branch, cast(i32) x, branch_y, 15, view.accent_color)
        x += cast(f32) ui.measure_text(view.branch, 15) + 12

        if view.has_upstream && (view.ahead > 0 || view.behind > 0) {
            counts := fmt.tprintf("%d ahead · %d behind", view.ahead, view.behind)
            ui.draw_text(counts, cast(i32) x, cast(i32) (view.box.y + (view.header_height - 12) * 0.5), 12, view.muted_color)
        }
    }

    fetch, pull, push := git_view_sync_rects(view)
    git_view_draw_sync_button(view, fetch, "cloud-down", mouse)
    git_view_draw_sync_button(view, pull, "arrow-down", mouse)
    git_view_draw_sync_button(view, push, "arrow-up", mouse)
    git_view_draw_icon_button(view, git_view_close_rect(view), "x", 16, mouse)

    rl.DrawRectangleRec(
        rl.Rectangle {view.box.x + 1, view.box.y + view.header_height, view.box.width - 2, 1},
        git_view_tint(view.muted_color, 45),
    )
}

// A framed toolbar button, dimmed while a command runs.
@(private = "file")
git_view_draw_sync_button :: proc(view: ^Git_View, rect: rl.Rectangle, icon: string, mouse: rl.Vector2) {
    hover := !view.busy && rl.CheckCollisionPointRec(mouse, rect)
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
        ui.draw_text(git_view_kind_label(kind), cast(i32) (rect.x + 38), cast(i32) (rect.y + (rect.height - 15) * 0.5), 15, text_color)

        // Change count on the Changes entry, as a small pill.
        if kind == .Changes {
            count := len(view.unstaged) + len(view.staged)
            if count > 0 {
                label := fmt.tprintf("%d", count)
                tw := cast(f32) ui.measure_text(label, 12)
                pill := rl.Rectangle {rect.x + rect.width - 12 - tw - 12, rect.y + (rect.height - 18) * 0.5, tw + 12, 18}
                rl.DrawRectangleRounded(pill, 0.5, 8, git_view_tint(view.accent_color, 32))
                ui.draw_text(label, cast(i32) (pill.x + 6), cast(i32) (pill.y + 3), 12, view.accent_color)
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
        text = "Tab focus  ·  Space stage/unstage  ·  Ctrl+Enter commit  ·  Esc close"
    }
    text = git_view_fit_tail(text, 12, rect.width - 32)
    tw := ui.measure_text(text, 12)
    ui.draw_text(
        text,
        cast(i32) (rect.x + (rect.width - cast(f32) tw) * 0.5),
        cast(i32) (rect.y + (rect.height - 12) * 0.5),
        12,
        color,
    )
}

// ---- changes view ----

@(private = "file")
git_view_draw_changes :: proc(view: ^Git_View, mouse: rl.Vector2) {
    git_view_draw_file_section(view, false, mouse)
    git_view_draw_file_section(view, true, mouse)

    // Divider between the file column and the diff.
    right := git_view_right_rect(view)
    rl.DrawRectangleRec(
        rl.Rectangle {right.x, right.y, 1, right.height}, git_view_tint(view.muted_color, 45),
    )

    git_view_draw_diff(view)
    git_view_draw_commit_box(view, mouse)
}

@(private = "file")
git_view_draw_file_section :: proc(view: ^Git_View, staged: bool, mouse: rl.Vector2) {
    header, list := git_view_section_rects(view, staged)
    count := staged ? len(view.staged) : len(view.unstaged)

    title := fmt.tprintf(staged ? "STAGED (%d)" : "UNSTAGED (%d)", count)
    ui.draw_text(
        title,
        cast(i32) (header.x + SETTINGS_ITEM_INSET + 12),
        cast(i32) (header.y + (header.height - 12) * 0.5),
        12,
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
            cast(i32) (action.y + (action.height - 12) * 0.5),
            12,
            hover ? view.accent_color : view.muted_color,
        )
    }

    if count == 0 {
        message := staged ? "Nothing staged" : "No changes"
        ui.draw_text(
            message,
            cast(i32) (list.x + SETTINGS_ITEM_INSET + 12),
            cast(i32) (list.y + 8),
            14,
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
        chip := rl.Rectangle {rect.x + SETTINGS_ITEM_INSET + 8, rect.y + (rect.height - 16) * 0.5, 16, 16}
        rl.DrawRectangleRounded(chip, 0.35, 6, git_view_tint(status_color, 40))
        letter := tree_status_letter(file.status)
        lw := ui.measure_text(letter, 11)
        ui.draw_text(
            letter,
            cast(i32) (chip.x + (chip.width - cast(f32) lw) * 0.5),
            cast(i32) (chip.y + 2),
            11,
            status_color,
        )

        // Name, leaving room for the hover action box.
        name_x := chip.x + chip.width + 8
        max_w := rect.x + rect.width - SETTINGS_ROW_PAD - name_x
        if hovered {
            max_w -= 24
        }
        name := git_view_fit_tail(file.display, 14, max_w)
        ui.draw_text(name, cast(i32) name_x, cast(i32) (rect.y + (rect.height - 14) * 0.5), 14, view.text_color)

        if hovered && !view.busy {
            git_view_draw_icon_button(view, git_view_file_action_rect(rect), staged ? "minus" : "plus", 14, mouse)
        }
    }
    ui.end_clip()

    content := cast(f32) count * GIT_FILE_ROW
    if track, thumb, ok := ui.scrollbar_rects(list, content, staged ? view.staged_scroll : view.unstaged_scroll, GIT_SCROLLBAR_STYLE); ok {
        rl.DrawRectangleRounded(track, 0.5, 4, git_view_tint(view.muted_color, 15))
        rl.DrawRectangleRounded(thumb, 0.5, 4, git_view_tint(view.muted_color, 120))
    }
}

@(private = "file")
git_view_draw_diff :: proc(view: ^Git_View, ) {
    diff := git_view_diff_rect(view)
    list := git_view_diff_list_rect(view)

    if view.diff_title != "" {
        title := git_view_fit_tail(view.diff_title, 13, diff.width - 32)
        ui.draw_text(
            title,
            cast(i32) (diff.x + 16),
            cast(i32) (diff.y + (GIT_DIFF_TITLE - 13) * 0.5),
            13,
            git_view_tint(view.muted_color, 200),
        )
        rl.DrawRectangleRec(
            rl.Rectangle {diff.x + 1, diff.y + GIT_DIFF_TITLE - 1, diff.width - 2, 1},
            git_view_tint(view.muted_color, 30),
        )
    }

    if len(view.diff_rows) == 0 {
        message := view.diff_title == "" ? "Select a file to see its diff" : "No changes to show"
        tw := ui.measure_text(message, 15)
        ui.draw_text(
            message,
            cast(i32) (list.x + (list.width - cast(f32) tw) * 0.5),
            cast(i32) (list.y + list.height * 0.4),
            15,
            view.muted_color,
        )
        return
    }

    gutter: f32 = 44
    text_x := list.x + gutter * 2 + 10

    ui.begin_clip(list)
    for row, index in view.diff_rows {
        top := list.y + cast(f32) index * GIT_DIFF_ROW - view.diff_scroll
        if top + GIT_DIFF_ROW < list.y || top > list.y + list.height {
            continue
        }
        rect := rl.Rectangle {list.x, top, list.width, GIT_DIFF_ROW}
        text_y := cast(i32) (top + (GIT_DIFF_ROW - 14) * 0.5)

        color := view.text_color
        switch row.kind {
        case .Hunk:
            rl.DrawRectangleRec(rect, git_view_tint(view.accent_color, 14))
            ui.draw_text(git_view_fit_tail(row.text, 13, rect.width - 24), cast(i32) (list.x + 12), text_y, 13, view.accent_color)
            continue
        case .Meta:
            ui.draw_text(git_view_fit_tail(row.text, 13, rect.width - 24), cast(i32) (list.x + 12), text_y, 13, view.muted_color)
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
            nw := ui.measure_text(n, 12)
            ui.draw_text(n, cast(i32) (list.x + gutter - cast(f32) nw), text_y, 12, number_color)
        }
        if row.new_line > 0 {
            n := fmt.tprintf("%d", row.new_line)
            nw := ui.measure_text(n, 12)
            ui.draw_text(n, cast(i32) (list.x + gutter * 2 - cast(f32) nw), text_y, 12, number_color)
        }

        if row.text != "" {
            ui.draw_text(row.text, cast(i32) text_x, text_y, 14, color)
        }
    }
    ui.end_clip()

    // Gutter divider.
    rl.DrawRectangleRec(
        rl.Rectangle {list.x + gutter * 2 + 5, list.y, 1, list.height}, git_view_tint(view.muted_color, 30),
    )

    content := cast(f32) len(view.diff_rows) * GIT_DIFF_ROW
    if track, thumb, ok := ui.scrollbar_rects(list, content, view.diff_scroll, GIT_SCROLLBAR_STYLE); ok {
        rl.DrawRectangleRounded(track, 0.5, 4, git_view_tint(view.muted_color, 15))
        rl.DrawRectangleRounded(thumb, 0.5, 4, git_view_tint(view.muted_color, 120))
    }
}

@(private = "file")
git_view_draw_commit_box :: proc(view: ^Git_View, mouse: rl.Vector2) {
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
    ui.draw_text("Amend", cast(i32) (check.x + 22), cast(i32) (amend.y + 2), 14, view.text_color)

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
    lw := ui.measure_text(label, 14)
    ui.draw_text(
        label,
        cast(i32) (button.x + (button.width - cast(f32) lw) * 0.5),
        cast(i32) (button.y + (button.height - 14) * 0.5),
        14,
        label_color,
    )
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
    line_height: f32 = 20
    text_x := cast(i32) (rect.x + 10)

    if text == "" && !focused {
        ui.draw_text(placeholder, text_x, cast(i32) (rect.y + (min(rect.height, 30) - 15) * 0.5), 15, git_view_tint(view.muted_color, 120))
        return
    }

    if !multiline {
        y := cast(i32) (rect.y + (rect.height - 15) * 0.5)
        ui.draw_text(text, text_x, y, 15, view.text_color)
        if focused {
            caret_x := text_x + cast(i32) ui.measure_text(text[:field.caret], 15) + 1
            rl.DrawRectangle(caret_x, y, 2, 15, view.accent_color)
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
            ui.draw_text(line, text_x, cast(i32) y, 15, view.text_color)
            if focused && field.caret >= offset && field.caret <= offset + len(line) {
                caret_x := text_x + cast(i32) ui.measure_text(line[:field.caret - offset], 15) + 1
                rl.DrawRectangle(caret_x, cast(i32) y, 2, 15, view.accent_color)
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
