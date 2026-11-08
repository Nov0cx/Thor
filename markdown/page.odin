// Markdown laid out as a flat list of positioned primitives. No UI, no raylib:
// the host answers the measuring questions and draws what comes back.
package markdown

import "core:strings"
import "core:unicode/utf8"

import ui "../vendor/loom/loom"

Item_Kind :: enum {
    Text,
    Rect,
    Image,
    Copy, // a code block: `text` is its code, `url` its language
    Toggle, // a `<details>` summary row: `ref` is the block, `size` 1 when open
}

// A synthetic face variant the host draws a text item in.
Style_Flag :: enum u8 {
    Bold,
    Italic,
}

Style :: bit_set[Style_Flag;u8]

// One laid-out primitive, relative to the content origin. `text` and `url`
// borrow from the source `layout` was given or from the page, so that source
// must outlive the page. An image has its source in `url` and its alternative
// text in `text`.
Item :: struct {
    kind:  Item_Kind,
    x, y:  f32,
    w, h:  f32,
    text:  string,
    size:  i32,
    color: ui.Color,
    url:   string, // link target, "" when the item is not a link
    style: Style,
    src:   int, // the byte offset of `text` in the source, -1 when it is not a slice of it
    ref:   int,
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
    alert:   [Alert_Kind]ui.Color,
}

// A colored byte range of a code block, as the host's highlighter answers.
Color_Span :: struct {
    start, end: int,
    color:      ui.Color,
}

// How the host measures the face the page draws in, and the images it can
// show. `image_size` gives the pixel size of an image by its source as written;
// nil, or false for a source the host cannot show, leaves the alternative text.
// `highlight` colors a code block by its language tag; nil leaves it plain.
Metrics :: struct {
    measure:     proc(text: string, size: i32, style: Style, user: rawptr) -> f32,
    line_height: proc(size: i32, user: rawptr) -> f32,
    image_size:  proc(src: string, user: rawptr) -> (w, h: f32, ok: bool),
    highlight:   proc(lang, code: string, user: rawptr) -> []Color_Span,
    user:        rawptr,
}

Page :: struct {
    items:          [dynamic]Item, // owned
    owned:          [dynamic]string, // strings the items borrow that are not slices of the source
    anchors:        map[string]f32, // owned keys; heading slug or `^label` to its y
    open:           map[int]bool, // the `<details>` blocks the reader opened; kept across layouts
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
    delete(page.anchors)
    delete(page.open)
    page.items = nil
    page.owned = nil
    page.anchors = nil
    page.open = nil
}

page_clear :: proc(page: ^Page) {
    for s in page.owned {
        delete(s)
    }
    clear(&page.owned)
    for key in page.anchors {
        delete(key)
    }
    clear(&page.anchors)
    clear(&page.items)
    page.content_height = 0
}

// Opens or closes the `<details>` block `ref`. The host lays the page out again.
page_toggle :: proc(page: ^Page, ref: int) {
    page.open[ref] = !page.open[ref]
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

@(private)
item_hit :: proc(item: Item, x, y: f32) -> bool {
    return x >= item.x && x < item.x + item.w && y >= item.y && y < item.y + item.h
}

// The index of the link item at a content-relative point, or -1. A link word
// also takes the space its underline runs on under, up to the next word.
link_at :: proc(page: ^Page, x, y: f32) -> int {
    for item, index in page.items {
        if item.url == "" || (item.kind != .Text && item.kind != .Image) {
            continue
        }
        box := item
        if item.kind == .Text && index + 1 < len(page.items) {
            if under := page.items[index + 1]; under.kind == .Rect && under.h <= 2 && under.x == item.x {
                box.w = max(box.w, under.w)
            }
        }
        if item_hit(box, x, y) {
            return index
        }
    }
    return -1
}

// The index of the item of `kind` at a content-relative point, or -1.
item_at :: proc(page: ^Page, kind: Item_Kind, x, y: f32) -> int {
    for item, index in page.items {
        if item.kind == kind && item_hit(item, x, y) {
            return index
        }
    }
    return -1
}

// The source offset nearest a content-relative point: in the text item under
// it, else at the end of the nearest item on that row, else -1.
offset_at :: proc(page: ^Page, m: Metrics, x, y: f32) -> int {
    best := -1
    best_dx := max(f32)
    for item in page.items {
        if item.kind != .Text || item.src < 0 || y < item.y || y >= item.y + item.h {
            continue
        }
        if x < item.x {
            if dx := item.x - x; dx < best_dx {
                best, best_dx = item.src, dx
            }
            continue
        }
        if x >= item.x + item.w {
            if dx := x - (item.x + item.w); dx < best_dx {
                best, best_dx = item.src + len(item.text), dx
            }
            continue
        }
        return item.src + byte_at(m, item, x - item.x)
    }
    return best
}

// The rune boundary in a text item nearest `x` pixels from its left edge.
@(private = "file")
byte_at :: proc(m: Metrics, item: Item, x: f32) -> int {
    prev, prev_w := 0, f32(0)
    for i := 0; i < len(item.text); {
        _, n := utf8.decode_rune_in_string(item.text[i:])
        i += max(n, 1)
        w := measure(m, item.text[:i], item.size, item.style)
        if w >= x {
            return x - prev_w > w - x ? i : prev
        }
        prev, prev_w = i, w
    }
    return len(item.text)
}

// The source range of the word around `offset`, for a double click.
word_range :: proc(source: string, offset: int) -> (lo, hi: int) {
    lo, hi = clamp(offset, 0, len(source)), clamp(offset, 0, len(source))
    for lo > 0 && word_byte(source[lo - 1]) {
        lo -= 1
    }
    for hi < len(source) && word_byte(source[hi]) {
        hi += 1
    }
    return
}

@(private = "file")
word_byte :: proc(c: u8) -> bool {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c >= 0x80
}

// The part of text item `item` that lies in the source range [lo, hi), as byte
// offsets into its text. ok is false when none of it does.
item_selection :: proc(item: Item, lo, hi: int) -> (from, to: int, ok: bool) {
    if item.kind != .Text || item.src < 0 || lo >= hi {
        return
    }
    from = clamp(lo - item.src, 0, len(item.text))
    to = clamp(hi - item.src, 0, len(item.text))
    return from, to, from < to
}

// The text a reader selected over [lo, hi) as it reads on the page: a row
// change is a line break and a gap between two items is a space. In
// `allocator`.
selection_text :: proc(page: ^Page, lo, hi: int, allocator := context.allocator) -> string {
    sb := strings.builder_make(allocator)
    have := false
    last: Item
    for item in page.items {
        from, to, ok := item_selection(item, lo, hi)
        if !ok {
            continue
        }
        if have {
            switch {
            case item.y != last.y:
                strings.write_byte(&sb, '\n')
            case item.x > last.x + last.w + 0.5:
                strings.write_byte(&sb, ' ')
            }
        }
        strings.write_string(&sb, item.text[from:to])
        last = item
        have = true
    }
    return strings.to_string(sb)
}

// The first and last source offsets any text item covers, for select all.
source_extent :: proc(page: ^Page) -> (lo, hi: int) {
    lo, hi = max(int), -1
    for item in page.items {
        if item.kind == .Text && item.src >= 0 {
            lo = min(lo, item.src)
            hi = max(hi, item.src + len(item.text))
        }
    }
    if hi < 0 {
        return 0, 0
    }
    return
}

@(private)
measure :: proc(m: Metrics, text: string, size: i32, style: Style = {}) -> f32 {
    return m.measure == nil ? 0 : m.measure(text, size, style, m.user)
}

@(private)
line_height :: proc(m: Metrics, size: i32) -> f32 {
    return m.line_height == nil ? f32(size) : m.line_height(size, m.user)
}
