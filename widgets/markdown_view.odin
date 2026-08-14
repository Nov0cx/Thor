package widgets

import "core:strings"
import rl "vendor:raylib"

import "../ui"

// Renders a markdown document as a scrollable, laid-out page. Fed the file's
// text (borrowed each frame); it clones and re-parses only when the buffer
// revision, view width, or base font size changes, so drawing is just replaying
// a flat item list. The only font family is monospace, so emphasis is carried by
// color rather than by weight or slant.
Markdown_View :: struct {
    using widget:   ui.Widget,
    // Owned copy of the source, cloned when the fed revision changes. Every item
    // text slice borrows from this buffer, so it must outlive the item list.
    source:         string,
    source_rev:     u64,
    source_owner:   rawptr, // borrowed buffer identity, paired with source_rev
    items:          [dynamic]Md_Item,
    // Marker strings (ordered-list numbers) that are not slices of `source`.
    owned:          [dynamic]string,
    content_height: f32,
    scroll:         f32,
    base_font_size: i32,
    // Guards that record what the current item list was built from.
    built_rev:      u64,
    built_width:    f32,
    built_font:     i32,
    built:          bool,
    // Palette, pushed by the host from the active theme.
    background:     rl.Color,
    text_color:     rl.Color,
    strong_color:   rl.Color,
    heading_color:  rl.Color,
    code_color:     rl.Color,
    code_bg:        rl.Color,
    link_color:     rl.Color,
    quote_color:    rl.Color,
    rule_color:     rl.Color,
    accent_color:   rl.Color,
    scrollbar:      rl.Color,
    on_link:        Markdown_Link_Proc,
    link_data:      rawptr,
}

// Opens a link clicked in the rendered page. `url` is the target as the document
// wrote it -- a URL, or a path relative to the document -- so the owner decides
// what it means.
Markdown_Link_Proc :: #type proc(data: rawptr, url: string)

@(private)
Md_Item_Kind :: enum {
    Text,
    Rect,
}

// One laid-out primitive. Positions are relative to the content origin (top-left
// of the text column); the draw pass offsets by the margin and scroll.
@(private)
Md_Item :: struct {
    kind:  Md_Item_Kind,
    x, y:  f32,
    w, h:  f32,
    text:  string,
    size:  i32,
    color: rl.Color,
    url:   string, // link target, borrowed from `source`; "" when not a link
}

// A wrap unit produced by inline parsing. `code` tokens keep their spaces and
// draw on a chip background; the rest are single space-delimited words.
@(private)
Md_Token :: struct {
    text:  string,
    color: rl.Color,
    code:  bool,
    link:  bool,
    url:   string, // link target, borrowed from `source`; "" when not a link
}

PAD_X :: f32(28)
PAD_TOP :: f32(22)
PAD_BOTTOM :: f32(28)
MAX_WIDTH :: f32(860)
MD_SCROLL_STEP :: f32(60)

markdown_view_vtable := ui.Widget_VTable {
    layout       = markdown_view_layout,
    handle_event = markdown_view_handle_event,
    draw         = markdown_view_draw,
    destroy      = markdown_view_destroy,
}

markdown_view_create :: proc(id: string) -> ^Markdown_View {
    view := new(Markdown_View)
    ui.widget_init(&view.widget, id, markdown_view_vtable)
    view.items = make([dynamic]Md_Item)
    view.owned = make([dynamic]string)
    view.base_font_size = 16
    view.background = rl.Color {0x1A, 0x1C, 0x23, 0xFF}
    view.text_color = rl.Color {0xD0, 0xD4, 0xE0, 0xFF}
    view.strong_color = rl.Color {0xEC, 0xEF, 0xF1, 0xFF}
    view.heading_color = rl.Color {0xEC, 0xEF, 0xF1, 0xFF}
    view.code_color = rl.Color {0xFF, 0xCA, 0x28, 0xFF}
    view.code_bg = rl.Color {0x13, 0x15, 0x19, 0xFF}
    view.link_color = rl.Color {0x4F, 0xC3, 0xF7, 0xFF}
    view.quote_color = rl.Color {0x8B, 0x92, 0xA8, 0xFF}
    view.rule_color = rl.Color {0x33, 0x38, 0x46, 0xFF}
    view.accent_color = rl.Color {0x4F, 0xC3, 0xF7, 0xFF}
    view.scrollbar = rl.Color {0x33, 0x38, 0x46, 0xFF}
    return view
}

markdown_view_set_colors :: proc(view: ^Markdown_View, t: ui.Theme) {
    view.background = t.background
    view.text_color = t.foreground
    view.strong_color = t.primary_text_color
    view.heading_color = t.primary_text_color
    view.code_color = t.strings_color
    view.code_bg = t.contrast
    view.link_color = t.links_color
    view.quote_color = t.muted_color
    view.rule_color = t.highlight
    view.accent_color = t.accent_color
    view.scrollbar = t.highlight
    view.built = false // recolor forces a rebuild
}

markdown_view_set_font_size :: proc(view: ^Markdown_View, size: i32) {
    view.base_font_size = clamp(size, 11, 40)
}

// Points the view at the document text. `owner` is the buffer the text belongs
// to: (owner, revision) identifies the content, so a static frame costs no
// compare. Revision 0 is not an identity — set_text resets it — so that case
// falls back to comparing the bytes, which is also what makes a reused owner
// address safe: a newly opened buffer starts at 0.
markdown_view_set_source :: proc(view: ^Markdown_View, text: string, revision: u64, owner: rawptr = nil) {
    same := view.source_owner == owner && view.source_rev == revision
    if same && (owner == nil || revision == 0) {
        same = view.source == text
    }
    if same {
        return
    }
    delete(view.source)
    view.source = strings.clone(text)
    view.source_rev = revision
    view.source_owner = owner
    view.built = false
}

markdown_view_set_on_link :: proc(view: ^Markdown_View, on_link: Markdown_Link_Proc, data: rawptr) {
    view.on_link = on_link
    view.link_data = data
}

markdown_view_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    view := cast(^Markdown_View) widget
    view.bounds = bounds
}

// Width of the readable text column: the pane inset, capped so long lines stay
// legible on a wide window.
@(private)
markdown_content_width :: proc(view: ^Markdown_View) -> f32 {
    return min(view.bounds.width - 2 * PAD_X, MAX_WIDTH)
}

// Index of the link item under `point` (screen space), or -1. Inverts the draw's
// margin and scroll transform, so it must stay in step with markdown_view_draw.
@(private)
markdown_link_index_at :: proc(view: ^Markdown_View, point: rl.Vector2) -> int {
    if !rl.CheckCollisionPointRec(point, view.bounds) {
        return -1
    }
    markdown_ensure_layout(view)
    markdown_clamp_scroll(view)

    avail := markdown_content_width(view)
    left := view.bounds.x + max(PAD_X, (view.bounds.width - avail) * 0.5)
    top := view.bounds.y + PAD_TOP - view.scroll
    for item, index in view.items {
        if item.url == "" {
            continue
        }
        if rl.CheckCollisionPointRec(point, rl.Rectangle {left + item.x, top + item.y, item.w, item.h}) {
            return index
        }
    }
    return -1
}

markdown_view_handle_event :: proc(widget: ^ui.Widget, _: ^ui.Context, event: ^ui.Event) -> bool {
    view := cast(^Markdown_View) widget
    #partial switch event.kind {
    case .Scroll:
        view.scroll -= event.wheel_delta * MD_SCROLL_STEP
        markdown_clamp_scroll(view)
        return true
    case .Click:
        // Click, not Mouse_Down: a drag that scrolled the page is not a link.
        if event.mouse_button == .LEFT && view.on_link != nil {
            if index := markdown_link_index_at(view, event.mouse_position); index >= 0 {
                view.on_link(view.link_data, view.items[index].url)
                return true
            }
        }
    case:
    }
    return false
}

@(private = "file")
markdown_clamp_scroll :: proc(view: ^Markdown_View) {
    max_scroll := max(0, view.content_height - view.bounds.height)
    view.scroll = clamp(view.scroll, 0, max_scroll)
}

markdown_view_draw :: proc(widget: ^ui.Widget, _: ^ui.Context) {
    view := cast(^Markdown_View) widget
    rl.DrawRectangleRec(view.bounds, view.background)

    markdown_ensure_layout(view)
    markdown_clamp_scroll(view)

    avail := markdown_content_width(view)
    left := view.bounds.x + max(PAD_X, (view.bounds.width - avail) * 0.5)
    top := view.bounds.y + PAD_TOP - view.scroll

    // A hovered link lights up instead of changing the cursor: `ui` owns no
    // cursor state, so a widget setting it would leave the hand shape behind.
    // markdown_wrap appends a link's underline right after its text, so the two
    // are hovered together.
    hovered := markdown_link_index_at(view, rl.GetMousePosition())

    ui.begin_clip(view.bounds)
    for item, index in view.items {
        ay := top + item.y
        if ay + item.h < view.bounds.y || ay > view.bounds.y + view.bounds.height {
            continue
        }
        ax := left + item.x
        lit := hovered >= 0 && (index == hovered || index == hovered + 1)
        color := lit ? view.accent_color : item.color
        switch item.kind {
        case .Rect:
            height := lit && item.h == 1 ? f32(2) : item.h // thicken the underline
            rl.DrawRectangleRec(rl.Rectangle {ax, ay, item.w, height}, color)
        case .Text:
            ui.draw_text(item.text, cast(i32) ax, cast(i32) ay, item.size, color)
        }
    }
    ui.end_clip()

    markdown_draw_scrollbar(view)
}

@(private = "file")
MARKDOWN_SCROLLBAR_STYLE :: ui.Scrollbar_Style {width = 4, min_thumb = 32, inset = 4}

@(private = "file")
markdown_draw_scrollbar :: proc(view: ^Markdown_View) {
    _, thumb, ok := ui.scrollbar_rects(view.bounds, view.content_height, view.scroll, MARKDOWN_SCROLLBAR_STYLE)
    if !ok {
        return
    }
    rl.DrawRectangleRec(thumb, view.scrollbar)
}

markdown_view_destroy :: proc(widget: ^ui.Widget) {
    view := cast(^Markdown_View) widget
    markdown_free_owned(view)
    delete(view.owned)
    delete(view.items)
    delete(view.source)
    free(view)
}

@(private)
markdown_free_owned :: proc(view: ^Markdown_View) {
    for s in view.owned {
        delete(s)
    }
    clear(&view.owned)
}
