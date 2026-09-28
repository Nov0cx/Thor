// Markdown laid out as a flat list of positioned primitives. No UI, no raylib:
// the host answers two measuring questions and draws what comes back.
package markdown

import ui "../vendor/loom/loom"

Item_Kind :: enum {
    Text,
    Rect,
}

// One laid-out primitive, relative to the content origin. `text` and `url`
// borrow from the source `layout` was given, so that source must outlive the page.
Item :: struct {
    kind:  Item_Kind,
    x, y:  f32,
    w, h:  f32,
    text:  string,
    size:  i32,
    color: ui.Color,
    url:   string, // link target, "" when the item is not a link
}

// The colors a page draws in, pushed by the host from the active theme.
Palette :: struct {
    text:    ui.Color,
    strong:  ui.Color,
    heading: ui.Color,
    code:    ui.Color,
    code_bg: ui.Color,
    link:    ui.Color,
    quote:   ui.Color,
    rule:    ui.Color,
    accent:  ui.Color,
}

// How the host measures the one face the page draws in.
Metrics :: struct {
    measure:     proc(text: string, size: i32, user: rawptr) -> f32,
    line_height: proc(size: i32, user: rawptr) -> f32,
    user:        rawptr,
}

Page :: struct {
    items:          [dynamic]Item,   // owned
    owned:          [dynamic]string, // list numbers, which are not slices of the source
    content_height: f32,
}

PAD_X :: f32(28)
PAD_TOP :: f32(22)
PAD_BOTTOM :: f32(28)
MAX_WIDTH :: f32(860)

page_destroy :: proc(page: ^Page) {
    page_clear(page)
    delete(page.items)
    delete(page.owned)
    page.items = nil
    page.owned = nil
}

page_clear :: proc(page: ^Page) {
    for s in page.owned {
        delete(s)
    }
    clear(&page.owned)
    clear(&page.items)
    page.content_height = 0
}

// Width of the readable text column: the pane inset, capped so a long line stays
// legible on a wide window.
content_width :: proc(pane_width: f32) -> f32 {
    return min(pane_width - 2 * PAD_X, MAX_WIDTH)
}

// The x a page of `avail` columns starts at inside a pane `pane_width` wide.
content_left :: proc(pane_width, avail: f32) -> f32 {
    return max(PAD_X, (pane_width - avail) * 0.5)
}

// The index of the link item at a content-relative point, or -1.
link_at :: proc(page: ^Page, x, y: f32) -> int {
    for item, index in page.items {
        if item.url == "" {
            continue
        }
        if x >= item.x && x < item.x + item.w && y >= item.y && y < item.y + item.h {
            return index
        }
    }
    return -1
}

@(private)
measure :: proc(m: Metrics, text: string, size: i32) -> f32 {
    return m.measure == nil ? 0 : m.measure(text, size, m.user)
}

@(private)
line_height :: proc(m: Metrics, size: i32) -> f32 {
    return m.line_height == nil ? f32(size) : m.line_height(size, m.user)
}
