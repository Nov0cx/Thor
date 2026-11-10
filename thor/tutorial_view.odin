package thor

// The tutorial on screen: the coach card beside the region a step points at, the
// spotlight around that region, and the chapter list.

import "core:fmt"
import "core:strings"

import "../markdown"
import "../theme"
import ui "../vendor/loom/loom"

@(private = "file")
CARD_W :: f32(360)

@(private = "file")
CARD_PAD :: f32(14)

@(private = "file")
CARD_GAP :: f32(16)

@(private = "file")
SPOT_DIM :: ui.Color{0, 0, 0, 110}

// The smallest rect that holds both.
thor_rect_union :: proc(a, b: ui.Rect) -> ui.Rect {
    x0, y0 := min(a.x, b.x), min(a.y, b.y)
    x1, y1 := max(a.x + a.w, b.x + b.w), max(a.y + a.h, b.y + b.h)
    return {x0, y0, x1 - x0, y1 - y0}
}

// The card, the spotlight and the chapter list, over everything else.
thor_tutorial_view :: proc(thor: ^Thor) {
    thor_tutorial_poll(thor)
    if thor.tutorial.running {
        target, has_target := thor_tutorial_target(thor)
        if has_target {
            thor_tutorial_spotlight(thor, target)
        }
        thor_tutorial_card(thor, target, has_target)
    }
    thor_tutorial_chooser(thor)
}

// An overlay that owns the screen hides the spotlight, since the dim would cover it.
@(private = "file")
thor_tutorial_overlay_open :: proc(thor: ^Thor) -> bool {
    return thor_palette_is_open(thor) ||
        thor.find_open ||
        thor.settings_open ||
        thor.git_open ||
        thor.problems_open ||
        thor.undo_open ||
        thor.theme_editor_open ||
        thor.permission_open ||
        thor_select_is_open(thor) ||
        thor_menu_is_open(thor) ||
        thor.tutorial.chooser_open
}

// The rect the current step points at.
@(private = "file")
thor_tutorial_target :: proc(thor: ^Thor) -> (ui.Rect, bool) {
    step, ok := thor_tutorial_current(thor)
    if !ok || thor_tutorial_overlay_open(thor) {
        return {}, false
    }
    if task, is_lab := step.check.(Check_Lab); is_lab && int(task) == thor.tutorial.lab.show_task {
        if r, shown := thor_lab_show_rect(thor); shown {
            return r, true
        }
    }
    r: ui.Rect
    #partial switch step.region {
    case .None:
        return {}, false
    case .Editor:
        r = thor.pane_rect[clamp(thor.active_pane, 0, MAX_PANES - 1)]
    case:
        r = thor.region_rects[step.region]
    }
    return r, r.w > 0 && r.h > 0
}

// Four dim rects around the target and an accent outline on it. The UI under
// them stays usable.
@(private = "file")
thor_tutorial_spotlight :: proc(thor: ^Thor, r: ui.Rect) {
    v := ui.viewport()
    parts := [4]ui.Rect {
        {0, 0, v.x, r.y},
        {0, r.y + r.h, v.x, v.y - r.y - r.h},
        {0, r.y, r.x, r.h},
        {r.x + r.w, r.y, v.x - r.x - r.w, r.h},
    }
    for p, i in parts {
        if p.w <= 0 || p.h <= 0 {
            continue
        }
        ui.push_id_int(i64(i))
        ui.leaf(
            {
                key = "tutorial-dim",
                flags = {.Floating, .Pass_Through},
                props = {position = .Fixed, inset = {l = p.x, t = p.y}, w = ui.Px(p.w), h = ui.Px(p.h), z = 325, bg = SPOT_DIM},
            },
        )
        ui.pop_id()
    }
    ui.leaf(
        {
            key = "tutorial-ring",
            flags = {.Floating, .Pass_Through},
            props = {
                position = .Fixed,
                inset = {l = r.x, t = r.y},
                w = ui.Px(r.w),
                h = ui.Px(r.h),
                z = 326,
                radius = ui.rad(4),
                border = {width = ui.all(2), color = thor.theme.accent_color},
            },
        },
    )
}

// Where the card goes: beside the target on the side with the most room, inside
// its lower right corner when no side fits, or at the lower right of the window.
@(private = "file")
thor_tutorial_card_pos :: proc(target: ui.Rect, has_target: bool, w, h: f32) -> (x, y: f32) {
    v := ui.viewport()
    x, y = v.x - w - 24, v.y - h - 24 - STATUSBAR_HEIGHT
    if !has_target {
        return
    }
    r := target
    right := v.x - (r.x + r.w)
    left := r.x
    below := v.y - (r.y + r.h)
    above := r.y
    best := f32(-1)
    if right >= w + CARD_GAP * 2 && right > best {
        best = right
        x, y = r.x + r.w + CARD_GAP, r.y
    }
    if left >= w + CARD_GAP * 2 && left > best {
        best = left
        x, y = r.x - w - CARD_GAP, r.y
    }
    if below >= h + CARD_GAP * 2 && below > best {
        best = below
        x, y = r.x, r.y + r.h + CARD_GAP
    }
    if above >= h + CARD_GAP * 2 && above > best {
        best = above
        x, y = r.x, r.y - h - CARD_GAP
    }
    if best < 0 {
        x, y = r.x + r.w - w - 24, r.y + r.h - h - 24
    }
    x = clamp(x, 8, max(8, v.x - w - 8))
    y = clamp(y, 8, max(8, v.y - h - 8))
    return
}

// The card body: the step text, and for a lab task its checklist and the
// analyzer's message. In the temp allocator.
@(private = "file")
thor_tutorial_card_text :: proc(thor: ^Thor, step: Tutorial_Step, has_step: bool) -> string {
    t := &thor.tutorial
    if !has_step {
        chapter := TUTORIAL_CHAPTERS[t.chapter]
        if t.chapter + 1 < len(TUTORIAL_CHAPTERS) {
            return fmt.tprintf(
                "You finished **%s**. The next chapter is **%s**.",
                chapter.title,
                TUTORIAL_CHAPTERS[t.chapter + 1].title,
            )
        }
        return fmt.tprintf("You finished **%s**, the last chapter. Every key is in **All shortcuts**.", chapter.title)
    }
    task, is_lab := step.check.(Check_Lab)
    if !is_lab {
        return thor_tutorial_expand(thor, step.body)
    }
    st, open := thor_lab_state(thor)
    if !open {
        return "The playground is not open. Press **Show me** to open it again."
    }
    b := strings.builder_make(context.temp_allocator)
    strings.write_string(&b, lab_detail(&st, int(task)))
    if msg := thor_lab_diagnostic(thor, &st, int(task)); msg != "" {
        fmt.sbprintf(&b, "\n\n> The analyzer says: %s", msg)
    }
    strings.write_string(&b, "\n\n")
    for i in 0 ..< LAB_TASKS {
        fmt.sbprintf(&b, "- [%s] %s\n", lab_check(&st, i) ? "x" : " ", thor_lab_title(i))
    }
    return thor_tutorial_expand(thor, strings.to_string(b))
}

@(private = "file")
thor_tutorial_card :: proc(thor: ^Thor, target: ui.Rect, has_target: bool) {
    t := &thor.tutorial
    chapter := TUTORIAL_CHAPTERS[t.chapter]
    step, has_step := thor_tutorial_current(thor)
    h := t.card_h > 0 ? t.card_h : 220
    x, y := thor_tutorial_card_pos(target, has_target, CARD_W, h)

    card := ui.scope(
        {
            key = "tutorial-card",
            flags = {.Floating, .Clickable},
            props = {
                position = .Fixed,
                inset = {l = x, t = y},
                w = ui.Px(CARD_W),
                h = ui.FIT,
                dir = .Column,
                pad = ui.all(CARD_PAD),
                gap = {0, 8},
                z = 330,
                bg = thor.theme.second_background,
                radius = ui.rad(8),
                border = {width = ui.all(1), color = thor.theme.accent_color},
                shadow = {offset = {0, 6}, blur = 24, color = thor.theme.contrast},
            },
        },
    )
    t.card_h = card.rect.h

    {
        ui.scope({key = "head", props = {w = ui.Grow(1), h = ui.FIT, dir = .Row, align = .Center, gap = {8, 0}}})
        thor_icon_label(thor, "school", thor.theme.accent_color)
        ui.label(
            chapter.title,
            {key = "chapter", props = {w = ui.Grow(1), color = thor.theme.muted_color, text_wrap = .Ellipsis}},
        )
        if has_step {
            ui.label(
                fmt.tprintf("%d / %d", t.step + 1, len(chapter.steps)),
                {key = "pos", props = {color = thor.theme.disabled, text_wrap = .None}},
            )
        }
        close := ui.scope(
            {
                key = "close",
                flags = {.Clickable},
                props = {w = ui.Px(22), h = ui.Px(22), dir = .Row, justify = .Center, align = .Center, radius = ui.rad(4), cursor = .Pointer},
                hover = {bg = thor.theme.buttons},
            },
        )
        thor_icon_label(thor, "x", thor.theme.muted_color, 14)
        thor_tip(thor, close.id, "Close the tutorial")
        if close.clicked {
            thor_tutorial_stop(thor)
            return
        }
    }

    ui.label(
        has_step ? step.title : "Chapter done",
        {key = "title", props = {w = ui.Grow(1), color = thor.theme.foreground, font_size = f32(thor.config.general.font_size + 2), text_wrap = .Words}},
    )

    thor_tutorial_card_body(thor, thor_tutorial_card_text(thor, step, has_step))
    thor_tutorial_dots(thor, len(chapter.steps), t.step)

    ui.scope({key = "foot", props = {w = ui.Grow(1), h = ui.FIT, dir = .Row, align = .Center, gap = {6, 0}, margin = {t = 4}}})
    if tutorial_button(thor, "chapters", "Chapters", false) {
        t.chooser_open = true
    }
    ui.spacer(ui.Grow(1), {key = "gap"})
    if !has_step {
        if t.chapter + 1 < len(TUTORIAL_CHAPTERS) {
            if tutorial_button(thor, "next-chapter", "Next chapter", true) {
                thor_tutorial_start(thor, t.chapter + 1)
            }
        } else if tutorial_button(thor, "shortcuts", "All shortcuts", true) {
            thor_tutorial_stop(thor)
            thor_open_docs_page(thor, "keybindings.md")
        }
        return
    }
    if task, is_lab := step.check.(Check_Lab); is_lab {
        if tutorial_button(thor, "show", "Show me", false) {
            thor_lab_show(thor, int(task))
        }
    }
    if t.step > 0 && tutorial_button(thor, "back", "Back", false) {
        thor_tutorial_move(thor, -1)
    }
    _, is_next := step.check.(Check_Next)
    if tutorial_button(thor, "next", is_next ? "Next" : "Skip", is_next) {
        thor_tutorial_move(thor, 1)
    }
}

// The markdown of the card, laid out to the card width with no page padding.
@(private = "file")
thor_tutorial_card_body :: proc(thor: ^Thor, text: string) {
    view := &thor.tutorial.card
    thor_markdown_set_source(view, text, 0, nil)
    avail := CARD_W - 2 * CARD_PAD
    thor_markdown_ensure(thor, view, avail, thor_markdown_base(thor))
    h := max(view.page.content_height - markdown.PAD_TOP - markdown.PAD_BOTTOM, 0)
    body := ui.scope({key = "body", props = {position = .Relative, w = ui.Px(avail), h = ui.Px(h)}})
    view.hovered = -1
    thor_markdown_draw(thor, view, {body.rect.x, body.rect.y, body.rect.w, body.rect.h}, 0, -markdown.PAD_TOP, false)
}

@(private = "file")
thor_tutorial_dots :: proc(thor: ^Thor, count, at: int) {
    if count <= 1 {
        return
    }
    ui.scope({key = "dots", props = {w = ui.Grow(1), h = ui.FIT, dir = .Row, align = .Center, gap = {5, 0}}})
    for i in 0 ..< count {
        color := thor.theme.border
        if i < at {
            color = thor.theme.accent_secondary_color
        } else if i == at {
            color = thor.theme.accent_color
        }
        ui.push_id_int(i64(i))
        ui.leaf({key = "dot", props = {w = ui.Px(6), h = ui.Px(6), radius = ui.rad(3), bg = color}})
        ui.pop_id()
    }
}

@(private = "file")
tutorial_button :: proc(thor: ^Thor, key, label: string, primary: bool) -> bool {
    bg := primary ? thor.theme.accent_color : thor.theme.buttons
    fg := primary ? theme.color_on(thor.theme.accent_color) : thor.theme.foreground
    it := ui.scope(
        {
            key = key,
            flags = {.Clickable},
            props = {w = ui.FIT, h = ui.Px(26), dir = .Row, align = .Center, pad = ui.xy(10, 0), radius = ui.rad(6), bg = bg, cursor = .Pointer},
            hover = {bg = primary ? thor.theme.accent_secondary_color : thor.theme.active},
        },
    )
    ui.label(label, {key = "label", props = {color = fg, text_wrap = .None}})
    return it.clicked
}

// The chapter list: each chapter with its state, a click starts or resumes it.
@(private = "file")
thor_tutorial_chooser :: proc(thor: ^Thor) {
    t := &thor.tutorial
    if !t.chooser_open {
        return
    }
    backdrop := ui.scope(
        {
            key = "tutorial-chooser",
            flags = {.Floating, .Clickable},
            props = {
                position = .Fixed,
                inset = {0, 0, 0, 0},
                w = ui.Grow(1),
                h = ui.Grow(1),
                dir = .Column,
                justify = .Center,
                align = .Center,
                z = 340,
                bg = ui.Color{0, 0, 0, 120},
            },
        },
    )
    {
        ui.scope(
            {
                key = "box",
                flags = {.Clickable},
                props = {
                    w = ui.Px(420),
                    max_w = ui.viewport().x - 60,
                    h = ui.FIT,
                    dir = .Column,
                    gap = {0, 4},
                    pad = ui.all(16),
                    radius = ui.rad(8),
                    bg = thor.theme.second_background,
                    border = {width = ui.all(1), color = thor.theme.border},
                    shadow = {offset = {0, 6}, blur = 24, color = thor.theme.contrast},
                },
            },
        )
        {
            ui.scope({key = "head", props = {w = ui.Grow(1), h = ui.FIT, dir = .Row, align = .Center, gap = {8, 0}, margin = {b = 6}}})
            thor_icon_label(thor, "school", thor.theme.accent_color)
            ui.label("Tutorial", {key = "title", props = {w = ui.Grow(1), color = thor.theme.foreground, text_wrap = .None}})
        }
        for _, i in TUTORIAL_CHAPTERS {
            ui.push_id_int(i64(i))
            clicked := tutorial_chapter_row(thor, i)
            ui.pop_id()
            if clicked {
                thor_tutorial_start(thor, i)
            }
        }
        ui.scope({key = "foot", props = {w = ui.Grow(1), h = ui.FIT, dir = .Row, align = .Center, gap = {6, 0}, margin = {t = 10}}})
        if tutorial_button(thor, "shortcuts", "All shortcuts", false) {
            t.chooser_open = false
            thor_open_docs_page(thor, "keybindings.md")
        }
        ui.spacer(ui.Grow(1), {key = "gap"})
        if tutorial_button(thor, "close", "Close", true) {
            t.chooser_open = false
        }
    }
    if backdrop.clicked || ui.take_key(.Escape) {
        t.chooser_open = false
    }
}

// One row of the chapter list. True when it was clicked.
@(private = "file")
tutorial_chapter_row :: proc(thor: ^Thor, i: int) -> bool {
    c := TUTORIAL_CHAPTERS[i]
    mark := thor.tutorial.marks[i]
    row := ui.scope(
        {
            key = "chapter",
            flags = {.Clickable},
            props = {w = ui.Grow(1), h = ui.Px(30), dir = .Row, align = .Center, gap = {8, 0}, pad = ui.xy(8, 0), radius = ui.rad(4), cursor = .Pointer},
            hover = {bg = thor.theme.buttons},
        },
    )
    icon, color := "circle", thor.theme.disabled
    if mark.done {
        icon, color = "circle-check", thor.theme.success_color
    } else if mark.step > 0 {
        icon, color = "circle-half-2", thor.theme.accent_color
    }
    thor_icon_label(thor, icon, color, 14)
    ui.label(
        fmt.tprintf("%d. %s", i + 1, c.title),
        {key = "name", props = {w = ui.Grow(1), color = thor.theme.foreground, text_wrap = .Ellipsis}},
    )
    state := ""
    if mark.done {
        state = "done"
    } else if mark.step > 0 {
        state = fmt.tprintf("resume at %d / %d", mark.step + 1, len(c.steps))
    }
    ui.label(state, {key = "state", props = {color = thor.theme.disabled, text_wrap = .None}})
    return row.clicked
}
