// The release notes of the running version: a short summary and the full
// changelog section, both built into the binary. The card opens once after an
// update and again from Help > What's New.
package thor

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"

import "../atomicfile"
import "../font"
import "../markdown"
import "../theme"
import ui "../vendor/loom/loom"

// The summary of each release, newest first, in the changelog shape.
WHATS_NEW_SOURCE :: #load("../WHATS_NEW.md", string)
CHANGELOG_SOURCE :: #load("../CHANGELOG.md", string)

// The version the card last opened for.
@(private = "file")
WHATS_NEW_FILE :: "sessions/whats-new.txt"

@(private = "file")
WHATS_NEW_WIDTH :: TK_W_FORM
@(private = "file")
WHATS_NEW_WHEEL_LINES :: f32(3)

Whats_New :: struct {
    open:          bool,
    full:          bool, // shows the changelog section, not the summary
    focus_pending: bool,
    return_focus:  string,        // borrowed focus owner when it opened
    view:          Markdown_View, // owned
}

// The text under the `# <version>` heading of a changelog-shaped text, up to
// the next `# ` heading. Borrows from `text`.
whats_new_section :: proc(text, version: string) -> (body: string, ok: bool) {
    start := -1
    pos   := 0
    for pos < len(text) {
        end  := strings.index_byte(text[pos:], '\n')
        next := end < 0 ? len(text) : pos + end + 1
        line := strings.trim_right(text[pos:next], " \t\r\n")
        if strings.has_prefix(line, "# ") {
            if start >= 0 {
                return strings.trim_space(text[start:pos]), true
            }
            if strings.trim_space(line[2:]) == version {
                start = next
            }
        }
        pos = next
    }
    if start < 0 {
        return "", false
    }
    return strings.trim_space(text[start:]), true
}

// The summary, or the changelog section when `full` is set or no summary was
// written. In the temp allocator, with CR removed.
@(private = "file")
thor_whats_new_text :: proc(full: bool) -> (text: string, ok: bool) {
    body: string
    if !full {
        body, ok = whats_new_section(WHATS_NEW_SOURCE, VERSION)
    }
    if !ok {
        body, ok = whats_new_section(CHANGELOG_SOURCE, VERSION)
    }
    if !ok {
        return "", false
    }
    text, _ = strings.replace_all(body, "\r", "", context.temp_allocator)
    return text, true
}

// Opens the card when this version is newer than the one it last opened for.
// A first start records the version and opens nothing: that is no update.
thor_whats_new_check :: proc(thor: ^Thor) {
    fresh     := !os.exists("sessions")
    data, err := os.read_entire_file(WHATS_NEW_FILE, context.temp_allocator)
    if err == nil && strings.trim_space(string(data)) == VERSION {
        return
    }
    thor_whats_new_record()
    if fresh {
        return
    }
    if _, ok := thor_whats_new_text(false); ok {
        thor_whats_new_show(thor, false)
    }
}

@(private = "file")
thor_whats_new_record :: proc() {
    if !os.is_dir("sessions") {
        if err := os.make_directory("sessions"); err != nil {
            log.errorf("Could not create sessions dir: %v", err)
            return
        }
    }
    if err := atomicfile.write(WHATS_NEW_FILE, transmute([]u8)string(VERSION)); err != nil {
        log.errorf("Could not write %q: %v", WHATS_NEW_FILE, err)
    }
}

@(private = "file")
thor_whats_new_show :: proc(thor: ^Thor, full: bool) {
    w := &thor.whats_new
    w.open = true
    w.full = full
    w.focus_pending = true
    w.return_focus = thor.focus_owner
    w.view.scroll = 0
}

// Closes the card and gives the focus back to where it was.
@(private = "file")
thor_whats_new_close :: proc(thor: ^Thor) {
    w := &thor.whats_new
    w.open = false
    if w.return_focus != "" {
        thor.focus_request = w.return_focus
    }
}

thor_cmd_whats_new :: proc(data: rawptr) {
    thor := cast(^Thor)data
    if _, ok := thor_whats_new_text(false); !ok {
        thor_flash_status(thor, fmt.tprintf("No release notes for %s", VERSION), true)
        return
    }
    thor_whats_new_show(thor, false)
}

thor_whats_new_destroy :: proc(thor: ^Thor) {
    thor_markdown_view_destroy(thor, &thor.whats_new.view)
}

// The centred card over a dimmed window.
thor_whats_new_view :: proc(thor: ^Thor) {
    w := &thor.whats_new
    if !w.open {
        return
    }
    text, ok := thor_whats_new_text(w.full)
    if !ok {
        w.open = false
        return
    }

    backdrop := ui.scope(
        {
            key = "whats-new-backdrop",
            transition = TK_ENTER,
            enter = {opacity = 0},
            flags = {.Floating, .Clickable},
            props = {
                opacity = 1,
                position = .Fixed,
                inset = {0, 0, 0, 0},
                w = ui.Grow(1),
                h = ui.Grow(1),
                dir = .Column,
                justify = .Center,
                align = .Center,
                z = 470,
                bg = tk_scrim(.Card),
            },
        },
    )

    width := tk_modal_w(WHATS_NEW_WIDTH)
    box   := ui.scope(
        {
            key = "whats-new-box",
            transition = TK_ENTER,
            enter = {opacity = 0},
            focus_scope = true,
            flags = {.Clickable, .Focusable},
            props = {
                opacity = 1,
                w = ui.Px(width),
                h = ui.FIT,
                dir = .Column,
                gap = tk_gap(.None, .M),
                pad = ui.all(tk_sp(.XL)),
                bg = thor.theme.second_background,
                radius = tk_rad(.Card),
                border = {width = ui.all(1), color = thor.theme.border},
                shadow = tk_shadow(thor, .Card),
            },
        },
    )
    if w.focus_pending {
        ui.set_focus(box.id)
        w.focus_pending = false
    }

    {
        ui.scope({key = "head", props = {w = ui.Grow(1), h = ui.FIT, dir = .Row, align = .Center, gap = tk_gap(.M, .None)}})
        thor_icon_label(thor, "sparkles", thor.theme.accent_color)
        ui.label(
            fmt.tprintf("What's new in Thor %s", VERSION),
            {key = "title", props = {w = ui.Grow(1), color = thor.theme.foreground, font_size = tk_font(thor, .Title), text_wrap = .Ellipsis}},
        )
    }

    thor_whats_new_body(thor, text, width - 2 * tk_sp(.XL))

    {
        ui.scope({key = "foot", props = {w = ui.Grow(1), h = ui.FIT, dir = .Row, align = .Center, gap = tk_gap(.M, .None), margin = {t = tk_sp(.XS)}}})
        ui.spacer(ui.Grow(1), {key = "gap"})
        if whats_new_button(thor, "toggle", w.full ? "Summary" : "All changes", false) {
            w.full = !w.full
            w.view.scroll = 0
        }
        if whats_new_button(thor, "ok", "OK", true) {
            thor_whats_new_close(thor)
        }
    }

    if ui.take_key(.Escape) || ui.take_key(.Enter) || backdrop.clicked {
        thor_whats_new_close(thor)
    }
}

// The markdown of the notes, scrolled by the wheel when it is taller than half
// the window.
@(private = "file")
thor_whats_new_body :: proc(thor: ^Thor, text: string, avail: f32) {
    view := &thor.whats_new.view
    thor_markdown_set_source(view, text, 0, nil)
    thor_markdown_ensure(thor, view, avail, thor_markdown_base(thor))
    content := max(view.page.content_height - markdown.PAD_TOP - markdown.PAD_BOTTOM, 0)
    h       := min(content, max(ui.viewport().y * 0.6, 120))

    body := ui.begin({key = "body", flags = {.Clip, .Scroll_Y, .Wheel}, props = {position = .Relative, w = ui.Px(avail), h = ui.Px(h)}})
    defer ui.end()
    if body.node.scroll.y != view.scroll {
        view.scroll = body.node.scroll.y
    }
    defer ui.set_scroll(body.node, .Y, view.scroll)
    if body.wheel.y != 0 {
        view.scroll += body.wheel.y * WHATS_NEW_WHEEL_LINES * f32(font.line_height(view.built_font))
    }
    view.scroll = clamp(view.scroll, 0, max(0, content - h))

    ui.leaf({key = "content", props = {w = ui.Px(0), h = ui.Px(content)}})
    view.hovered = -1
    thor_markdown_draw(thor, view, {body.rect.x, body.rect.y, body.rect.w, body.rect.h}, 0, -markdown.PAD_TOP - view.scroll, false)
}

@(private = "file")
whats_new_button :: proc(thor: ^Thor, key, label: string, primary: bool) -> bool {
    bg := primary ? thor.theme.accent_color : thor.theme.buttons
    fg := primary ? theme.color_on(thor.theme.accent_color) : thor.theme.foreground
    it := ui.scope(
        thor_control(
            thor,
            {
                key = key,
                flags = {.Clickable},
                props = {
                    w = ui.FIT,
                    h = ui.Px(tk_h(.Control)),
                    dir = .Row,
                    align = .Center,
                    pad = tk_pad(.L, .None),
                    radius = tk_rad(.Popup),
                    bg = bg,
                    cursor = .Pointer,
                },
                hover = {bg = primary ? bg : thor.theme.active},
            },
        ),
    )
    ui.label(label, {key = "label", props = {color = fg, text_wrap = .None}})
    return it.clicked
}
