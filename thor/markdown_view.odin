// The markdown preview: the active file rendered as a page, in the pane the
// source is not in. The parse lives in the `markdown` package; this is the
// declaration of what it produced, plus the cache that decides when to re-parse.
package thor

import "core:path/filepath"
import "core:strings"
import "core:time"

import "../font"
import "../markdown"
import "../plugin"
import "../render"
import "../textedit"
import "../theme"
import ui "../vendor/loom/loom"

@(private = "file")
MD_WHEEL_LINES :: f32(3)

// How long the copy button reads "Copied" after a click.
@(private = "file")
MD_COPIED_FOR :: time.Second * 2

Markdown_View :: struct {
    page:         markdown.Page,
    // Owned copy of the source. Every item text borrows from it, so it outlives
    // the page; textedit.text dies at the first read after an edit.
    source:       string, // owned
    source_rev:   u64,
    source_owner: rawptr, // the buffer the revision belongs to
    scroll:       f32,
    // What the current page was built from.
    built:        bool,
    built_rev:    u64,
    built_width:  f32,
    built_font:   i32,
    hovered:      int,
    // The folder of the document, which a relative image source is read against.
    dir:          string, // owned
    images:       map[string]Md_Image, // owned, with its keys; by absolute path
    // The selection, as source byte offsets. Empty when anchor == cursor.
    sel_anchor:   int,
    sel_cursor:   int,
    selecting:    bool,
    copied:       int, // the code block item whose copy button reads "Copied", -1 for none
    copied_at:    time.Tick,
    thor:         ^Thor,
}

thor_markdown_view_destroy :: proc(thor: ^Thor, view: ^Markdown_View) {
    markdown.page_destroy(&view.page)
    delete(view.source)
    view.source = ""
    delete(view.dir)
    view.dir = ""
    for path, &image in view.images {
        thor_md_image_unload(thor, &image)
        delete(path)
    }
    delete(view.images)
    view.images = nil
}

// The file an image source names: a path as it is, or one beside the document.
// "" for a URL, which the preview does not fetch. In the temp allocator.
@(private = "file")
thor_markdown_image_path :: proc(view: ^Markdown_View, src: string) -> string {
    if src == "" || strings.contains(src, "://") || strings.has_prefix(src, "data:") {
        return ""
    }
    rel := src
    if cut := strings.index_any(rel, "#?"); cut >= 0 {
        rel = rel[:cut]
    }
    if rel == "" {
        return ""
    }
    if filepath.is_abs(rel) {
        return filepath.clean(rel, context.temp_allocator) or_else ""
    }
    if view.dir == "" {
        return ""
    }
    path, err := filepath.join({view.dir, rel}, context.temp_allocator)
    return err == nil ? path : ""
}

// The pixel size of an image the page names. The first ask starts its load;
// the page is laid out again when the pixels land. Only the preview loads
// images, since the load job reports back to it.
@(private = "file")
thor_markdown_image_size :: proc(src: string, user: rawptr) -> (w, h: f32, ok: bool) {
    view := cast(^Markdown_View)user
    thor := view.thor
    if thor == nil || view != &thor.markdown_view {
        return
    }
    path := thor_markdown_image_path(view, src)
    if path == "" {
        return
    }
    image, found := &view.images[path]
    if !found {
        view.images[strings.clone(path)] = Md_Image{loading = true, used = true}
        thor_md_image_start(thor, path)
        return
    }
    image.used = true
    if !image.loaded {
        return
    }
    return f32(image.texture.width), f32(image.texture.height), true
}

// Points the view at the document text. (owner, revision) identifies the
// content, so a static frame costs no compare. Revision 0 is not an identity —
// a freshly opened buffer starts there — so that case compares the bytes.
thor_markdown_set_source :: proc(view: ^Markdown_View, text: string, revision: u64, owner: rawptr) {
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
    view.sel_anchor, view.sel_cursor = 0, 0
    view.copied = -1
}

@(private = "file")
thor_markdown_palette :: proc(thor: ^Thor) -> markdown.Palette {
    return markdown.Palette {
        text = thor.theme.foreground,
        strong = thor.theme.primary_text_color,
        heading = thor.theme.primary_text_color,
        code = thor.theme.strings_color,
        code_bg = thor.theme.contrast,
        link = thor.theme.links_color,
        quote = thor.theme.muted_color,
        rule = thor.theme.highlight,
        accent = thor.theme.accent_color,
        alert = {
            .Note = thor.theme.info_color,
            .Tip = thor.theme.success_color,
            .Important = thor.theme.accent_secondary_color,
            .Warning = thor.theme.warning_color,
            .Caution = thor.theme.danger_color,
        },
    }
}

@(private = "file")
thor_font_style :: proc(style: markdown.Style) -> font.Style {
    out: font.Style
    if .Bold in style {
        out += {.Bold}
    }
    if .Italic in style {
        out += {.Italic}
    }
    return out
}

// The font handle a page item in `style` draws with: the default family, in
// the synthetic style.
@(private = "file")
thor_markdown_font :: proc(thor: ^Thor, style: markdown.Style) -> ui.Font {
    if style == {} {
        return render.DEFAULT_FONT
    }
    return render.register_family(&thor.backend, "", thor_font_style(style))
}

// The extension a fence's language tag names: the plugin language of that
// name, an alias, or the tag as an extension. "" when no plugin colors it.
@(private = "file")
thor_markdown_lang_key :: proc(thor: ^Thor, tag: string) -> string {
    if tag == "" {
        return ""
    }
    if key := plugin.language_key(&thor.plugins, tag); key != "" {
        return key
    }
    lower := strings.to_lower(tag, context.temp_allocator)
    alias := lower
    switch lower {
    case "sh", "bash", "shell", "zsh", "console", "shellsession":
        alias = "sh"
    case "js", "javascript", "node":
        alias = "js"
    case "ts", "typescript":
        alias = "ts"
    case "py", "python":
        alias = "py"
    case "rs", "rust":
        alias = "rs"
    case "ps", "ps1", "powershell", "pwsh":
        alias = "ps1"
    case "c++", "cpp":
        alias = "cpp"
    case "yml", "yaml":
        alias = "yaml"
    case "jsonc", "json5":
        alias = "json"
    case "md", "markdown":
        alias = "md"
    }
    key := strings.concatenate({".", alias}, context.temp_allocator)
    return plugin.supports(&thor.plugins, key) ? key : ""
}

// Colors a fenced code block through the plugin of its language. Spans in
// the temp allocator.
@(private = "file")
thor_markdown_highlight :: proc(lang, code: string, user: rawptr) -> []markdown.Color_Span {
    view := cast(^Markdown_View)user
    thor := view.thor
    if thor == nil {
        return nil
    }
    key := thor_markdown_lang_key(thor, lang)
    if key == "" {
        return nil
    }
    spans := plugin.highlight(&thor.plugins, "", code, key, context.temp_allocator)
    out := make([]markdown.Color_Span, len(spans), context.temp_allocator)
    for span, i in spans {
        out[i] = {start = span.start, end = span.end, color = theme.role_color(thor.theme, span.role)}
    }
    return out
}

// The face the page draws in, answered for the parser.
thor_markdown_metrics :: proc(view: ^Markdown_View) -> markdown.Metrics {
    return markdown.Metrics {
        measure = proc(text: string, size: i32, style: markdown.Style, user: rawptr) -> f32 {
            return f32(font.measure(text, size, "", 0, thor_font_style(style)))
        },
        line_height = proc(size: i32, user: rawptr) -> f32 {
            return f32(font.line_height(size))
        },
        image_size = thor_markdown_image_size,
        highlight = thor_markdown_highlight,
        user = view,
    }
}

// Rebuilds the page when the source, the column, the font size or the theme has
// moved since the last build.
thor_markdown_ensure :: proc(thor: ^Thor, view: ^Markdown_View, avail: f32, base: i32) {
    view.thor = thor
    if view.built &&
       view.built_rev == view.source_rev &&
       view.built_font == base &&
       abs(view.built_width - avail) < 0.5 {
        return
    }
    for _, &image in view.images {
        image.used = false
    }
    markdown.layout(&view.page, view.source, avail, base, thor_markdown_palette(thor), thor_markdown_metrics(view))
    // An image the page no longer names is freed. One still loading is kept
    // for its job to find.
    stale := make([dynamic]string, context.temp_allocator)
    for path, image in view.images {
        if !image.used && !image.loading {
            append(&stale, path)
        }
    }
    for path in stale {
        thor_md_image_unload(thor, &view.images[path])
        delete_key(&view.images, path)
        delete(path)
    }
    view.built = true
    view.built_rev = view.source_rev
    view.built_width = avail
    view.built_font = base
}

// A recolour has to re-parse: the palette is baked into every item.
thor_markdown_recolor :: proc(view: ^Markdown_View) {
    view.built = false
}

// The page's body font size, from the editor's.
thor_markdown_base :: proc(thor: ^Thor) -> i32 {
    return i32(clamp(thor.config.general.font_size, 11, 40))
}

// One pane of the workspace, beside the source.
thor_markdown_pane :: proc(thor: ^Thor, file: ^Open_File, key: string) {
    view := &thor.markdown_view
    if file != nil && file.loaded {
        if dir := filepath.dir(file.path); dir != view.dir {
            delete(view.dir)
            view.dir = strings.clone(dir)
            view.built = false
        }
        thor_markdown_set_source(view, textedit.text(&file.state), file.state.revision, rawptr(file))
    }

    // .Scroll_Y is for the bar alone; .Wheel hands over the raw delta, since the
    // items are absolute and the view moves them itself.
    pane := ui.begin(
        {
            key = key,
            flags = {.Clip, .Clickable, .Focusable, .Draggable, .Scroll_Y, .Wheel},
            props = {
                position = .Relative,
                w = ui.Grow(1),
                h = ui.Grow(1),
                bg = thor.theme.background,
                cursor = .Text,
            },
        },
    )
    defer ui.end()

    // A scroll the view did not push is a drag of the thumb or a click on the
    // track; adopt it before the offset is read again.
    if pane.node.scroll.y != view.scroll {
        view.scroll = pane.node.scroll.y
    }
    defer ui.set_scroll(pane.node, .Y, view.scroll)

    if pane.rect.w <= 0 || pane.rect.h <= 0 {
        return
    }

    avail := markdown.content_width(pane.rect.w)
    thor_markdown_ensure(thor, view, avail, thor_markdown_base(thor))

    if pane.wheel.y != 0 {
        view.scroll += pane.wheel.y * MD_WHEEL_LINES * f32(font.line_height(view.built_font))
    }
    view.scroll = clamp(view.scroll, 0, max(0, view.page.content_height - pane.rect.h))

    // The items are absolute and out of flow, so this states the page height for
    // Loom: it is what the bar and the scroll clamp are sized from.
    ui.leaf({key = "content", props = {w = ui.Px(0), h = ui.Px(view.page.content_height)}})

    left := markdown.content_left(pane.rect.w, avail)
    top := markdown.PAD_TOP - view.scroll

    thor_markdown_interact(thor, view, pane, left, top)
    thor_markdown_draw(thor, view, {pane.rect.x, pane.rect.y, pane.rect.w, pane.rect.h}, left, top, true)
}

// The mouse and the keys over the page: link hover and click, the details
// toggles, the copy buttons, and the text selection.
@(private = "file")
thor_markdown_interact :: proc(thor: ^Thor, view: ^Markdown_View, pane: ui.Interaction, left, top: f32) {
    view.hovered = -1
    mouse := ui.mouse_pos()
    mx := mouse.x - pane.rect.x - left
    my := mouse.y - pane.rect.y - top
    metrics := thor_markdown_metrics(view)

    // A label over the page takes the hover from the pane, so the pointer is
    // tested against the pane's box.
    r := pane.rect
    if mouse.x >= r.x && mouse.x < r.x + r.w && mouse.y >= r.y && mouse.y < r.y + r.h {
        view.hovered = markdown.link_at(&view.page, mx, my)
    }

    if pane.pressed {
        ui.set_focus(pane.id)
        // A press on a control is the control's, not the start of a selection.
        on_control := markdown.item_at(&view.page, .Toggle, mx, my) >= 0 || thor_markdown_copy_button_at(view, mx, my) >= 0
        if !on_control {
            at := markdown.offset_at(&view.page, metrics, mx, my)
            if pane.press_count >= 2 && at >= 0 {
                view.sel_anchor, view.sel_cursor = markdown.word_range(view.source, at)
                view.selecting = false
            } else if at >= 0 {
                view.sel_anchor, view.sel_cursor = at, at
                view.selecting = true
            } else {
                view.sel_anchor, view.sel_cursor = 0, 0
                view.selecting = false
            }
        }
    }
    if view.selecting && pane.dragging {
        if at := markdown.offset_at(&view.page, metrics, mx, my); at >= 0 {
            view.sel_cursor = at
        }
    }
    if pane.released {
        view.selecting = false
    }

    // Clicked, not pressed, and not dragged: a drag that selected is not a link.
    if pane.clicked && view.sel_anchor == view.sel_cursor {
        if toggle := markdown.item_at(&view.page, .Toggle, mx, my); toggle >= 0 {
            markdown.page_toggle(&view.page, view.page.items[toggle].ref)
            view.built = false
        } else if copy := thor_markdown_copy_button_at(view, mx, my); copy >= 0 {
            thor_markdown_copy(thor, view.page.items[copy].text)
            view.copied = copy
            view.copied_at = time.tick_now()
        } else if view.hovered >= 0 {
            if url := view.page.items[view.hovered].url; url != "" {
                thor_markdown_follow(thor, view, url)
            }
        }
    }

    if ui.focus_within(pane.node) {
        if ui.take_key(.C, {.Ctrl}) {
            lo, hi := min(view.sel_anchor, view.sel_cursor), max(view.sel_anchor, view.sel_cursor)
            if lo < hi {
                text := markdown.selection_text(&view.page, lo, hi, context.temp_allocator)
                thor_markdown_copy(thor, text)
            }
        }
        if ui.take_key(.A, {.Ctrl}) {
            view.sel_anchor, view.sel_cursor = markdown.source_extent(&view.page)
        }
        if ui.take_key(.Escape) {
            view.sel_anchor, view.sel_cursor = 0, 0
        }
    }
}

// Opens a link: a `#slug` or a footnote scrolls the page, anything else goes
// to the docs link handler.
@(private = "file")
thor_markdown_follow :: proc(thor: ^Thor, view: ^Markdown_View, url: string) {
    key := ""
    switch {
    case strings.has_prefix(url, "#"):
        key = url[1:]
    case strings.has_prefix(url, "^"):
        key = url
    }
    if key != "" {
        // A slug is lower case; a footnote label is matched as written.
        y, found := view.page.anchors[strings.to_lower(key, context.temp_allocator)]
        if !found {
            y, found = view.page.anchors[key]
        }
        if found {
            view.scroll = max(0, y - markdown.PAD_TOP)
        }
        return
    }
    if strings.has_prefix(url, "www.") {
        thor_markdown_open_link(thor, strings.concatenate({"https://", url}, context.temp_allocator))
        return
    }
    thor_markdown_open_link(thor, url)
}

@(private = "file")
thor_markdown_copy :: proc(thor: ^Thor, text: string) {
    if text == "" {
        return
    }
    ui.set_clipboard_text(text)
    thor_clipboard_note(thor, text)
    thor_flash_status(thor, "Copied to the clipboard")
}

// The width and height of a code block's copy button.
@(private = "file")
MD_COPY_W :: f32(64)

@(private = "file")
MD_COPY_H :: f32(22)

// The box of a code block's copy button, at its top right.
@(private = "file")
thor_markdown_copy_box :: proc(item: markdown.Item) -> (x, y, w, h: f32) {
    return item.x + item.w - MD_COPY_W - 6, item.y + 6, MD_COPY_W, MD_COPY_H
}

// The code block item whose copy button is under a content point, or -1.
@(private = "file")
thor_markdown_copy_button_at :: proc(view: ^Markdown_View, mx, my: f32) -> int {
    for item, index in view.page.items {
        if item.kind != .Copy {
            continue
        }
        x, y, w, h := thor_markdown_copy_box(item)
        if mx >= x && mx < x + w && my >= y && my < y + h {
            return index
        }
    }
    return -1
}

// Declares the page's items inside the current node. `rect` is that node's box
// on screen, `left`/`top` the page origin inside it. `controls` draws the
// selection, the toggles and the copy buttons.
thor_markdown_draw :: proc(thor: ^Thor, view: ^Markdown_View, rect: ui.Rect, left, top: f32, controls: bool) {
    lo, hi := min(view.sel_anchor, view.sel_cursor), max(view.sel_anchor, view.sel_cursor)
    metrics := thor_markdown_metrics(view)
    mouse := ui.mouse_pos()
    mx := mouse.x - rect.x - left
    my := mouse.y - rect.y - top

    for item, index in view.page.items {
        y := top + item.y
        if y + item.h < 0 || y > rect.h {
            continue
        }
        x := left + item.x
        // A link lights with the underline that follows its text.
        lit := view.hovered >= 0 &&
            (index == view.hovered || (index == view.hovered + 1 && view.page.items[view.hovered].kind == .Text))
        color := lit ? thor.theme.accent_color : item.color
        switch item.kind {
        case .Rect:
            // A lit underline thickens, which is the whole hover feedback.
            h := lit && item.h == 1 ? f32(2) : item.h
            ui.paint_rect({x, y, item.w, h}, color)
        case .Text:
            if controls {
                if from, to, ok := markdown.item_selection(item, lo, hi); ok {
                    sx := f32(0)
                    if from > 0 {
                        sx = markdown_prefix_width(metrics, item, from)
                    }
                    sw := markdown_prefix_width(metrics, item, to) - sx
                    // A selection that goes on in the next word on this row
                    // covers the space between the two.
                    if to == len(item.text) {
                        if next, more := thor_markdown_next_text(view, index); more && next.y == item.y && next.src >= 0 && next.src < hi && next.src > item.src {
                            sw = max(sw, next.x - item.x - sx)
                        }
                    }
                    ui.paint_rect({x + sx, y, max(sw, 2), item.h}, thor.theme.selection_background)
                }
            }
            ui.push_id_int(i64(index))
            ui.label(
                item.text,
                {
                    key = "md",
                    props = {
                        position = .Absolute,
                        inset = {l = x, t = y},
                        w = ui.FIT,
                        color = color,
                        font = thor_markdown_font(thor, item.style),
                        font_size = f32(item.size),
                        text_wrap = .None,
                    },
                },
            )
            ui.pop_id()
        case .Image:
            image, found := view.images[thor_markdown_image_path(view, item.url)]
            if !found || !image.loaded {
                continue
            }
            ui.push_id_int(i64(index))
            ui.image(
                render.register_texture(&thor.backend, image.texture),
                {
                    key = "md",
                    props = {
                        position = .Absolute,
                        inset = {l = x, t = y},
                        w = ui.Px(item.w),
                        h = ui.Px(item.h),
                    },
                },
            )
            ui.pop_id()
        case .Toggle:
            if !controls {
                continue
            }
            ui.push_id_int(i64(index))
            ui.begin({key = "md", props = {position = .Absolute, inset = {l = x, t = y}, w = ui.Px(16), h = ui.Px(item.h), align = .Center, justify = .Center}})
            thor_icon_label(thor, item.size == 1 ? "chevron-down" : "chevron-right", item.color, 14)
            ui.end()
            ui.pop_id()
        case .Copy:
            thor_markdown_code_chrome(thor, view, item, index, x, y, mx, my, controls)
        }
    }
}

// A code block's language tag and, while the mouse is over the block, its
// copy button.
@(private = "file")
thor_markdown_code_chrome :: proc(
    thor: ^Thor,
    view: ^Markdown_View,
    item: markdown.Item,
    index: int,
    x, y, mx, my: f32,
    controls: bool,
) {
    over := mx >= item.x && mx < item.x + item.w && my >= item.y && my < item.y + item.h
    size := f32(max(item.size - 3, 9))
    ui.push_id_int(i64(index))
    defer ui.pop_id()
    if controls && over {
        bx, by, bw, bh := thor_markdown_copy_box(item)
        hot := mx >= bx && mx < bx + bw && my >= by && my < by + bh
        copied := view.copied == index && time.tick_since(view.copied_at) < MD_COPIED_FOR
        ui.scope(
            {
                key = "copy",
                props = {
                    position = .Absolute,
                    inset = {l = x + (bx - item.x), t = y + (by - item.y)},
                    w = ui.Px(bw),
                    h = ui.Px(bh),
                    dir = .Row,
                    align = .Center,
                    justify = .Center,
                    gap = {4, 0},
                    radius = ui.rad(4),
                    bg = hot ? thor.theme.active : thor.theme.buttons,
                    border = {width = ui.all(1), color = thor.theme.border},
                },
            },
        )
        thor_icon_label(thor, copied ? "check" : "copy", copied ? thor.theme.success_color : thor.theme.muted_color, 12)
        ui.label(copied ? "Copied" : "Copy", {key = "text", props = {color = thor.theme.muted_color, font_size = size, text_wrap = .None}})
        return
    }
    if item.url == "" {
        return
    }
    tw := f32(font.measure(item.url, i32(size)))
    ui.label(
        item.url,
        {
            key = "lang",
            props = {
                position = .Absolute,
                inset = {l = x + item.w - tw - 10, t = y + 4},
                w = ui.FIT,
                color = thor.theme.disabled,
                font_size = size,
                text_wrap = .None,
            },
        },
    )
}

// The text item after item `index`, past its underline and chips.
@(private = "file")
thor_markdown_next_text :: proc(view: ^Markdown_View, index: int) -> (markdown.Item, bool) {
    for i in index + 1 ..< min(index + 6, len(view.page.items)) {
        if item := view.page.items[i]; item.kind == .Text {
            return item, true
        }
    }
    return {}, false
}

// The width of the first `n` bytes of a text item, in its size and style.
@(private = "file")
markdown_prefix_width :: proc(m: markdown.Metrics, item: markdown.Item, n: int) -> f32 {
    return m.measure(item.text[:n], item.size, item.style, m.user)
}
