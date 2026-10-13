// The markdown preview: the active file rendered as a page, in the pane the
// source is not in. The parse lives in the `markdown` package; this is the
// declaration of what it produced, plus the cache that decides when to re-parse.
package thor

import "core:path/filepath"
import "core:strings"

import "../font"
import "../markdown"
import "../render"
import "../textedit"
import ui "../vendor/loom/loom"

@(private = "file")
MD_WHEEL_LINES :: f32(3)

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
// the page is laid out again when the pixels land.
@(private = "file")
thor_markdown_image_size :: proc(src: string, user: rawptr) -> (w, h: f32, ok: bool) {
    thor := cast(^Thor) user
    view := &thor.markdown_view
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
@(private = "file")
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
    }
}

// The one face the page draws in, answered for the parser.
@(private = "file")
thor_markdown_metrics :: proc(thor: ^Thor) -> markdown.Metrics {
    return markdown.Metrics {
        measure = proc(text: string, size: i32, user: rawptr) -> f32 {
            return f32(font.measure(text, size))
        },
        line_height = proc(size: i32, user: rawptr) -> f32 {
            return f32(font.line_height(size))
        },
        image_size = thor_markdown_image_size,
        user = thor,
    }
}

// Rebuilds the page when the source, the column, the font size or the theme has
// moved since the last build.
@(private = "file")
thor_markdown_ensure :: proc(thor: ^Thor, view: ^Markdown_View, avail: f32) {
    base := i32(clamp(thor.config.general.font_size, 11, 40))
    if view.built &&
       view.built_rev == view.source_rev &&
       view.built_font == base &&
       abs(view.built_width - avail) < 0.5 {
        return
    }
    for _, &image in view.images {
        image.used = false
    }
    markdown.layout(
        &view.page,
        view.source,
        avail,
        base,
        thor_markdown_palette(thor),
        thor_markdown_metrics(thor),
    )
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

// One pane of the workspace, beside the source.
thor_markdown_pane :: proc(thor: ^Thor, file: ^Open_File, key: string) {
    view := &thor.markdown_view
    if file != nil && file.loaded {
        if dir := filepath.dir(file.path); dir != view.dir {
            delete(view.dir)
            view.dir = strings.clone(dir)
            view.built = false
        }
        thor_markdown_set_source(
            view,
            textedit.text(&file.state),
            file.state.revision,
            rawptr(file),
        )
    }

    // .Scroll_Y is for the bar alone; .Wheel hands over the raw delta, since the
    // items are absolute and the view moves them itself.
    pane := ui.begin(
        {
            key = key,
            flags = {.Clip, .Clickable, .Scroll_Y, .Wheel},
            props = {
                position = .Relative,
                w = ui.Grow(1),
                h = ui.Grow(1),
                bg = thor.theme.background,
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
    thor_markdown_ensure(thor, view, avail)

    if pane.wheel.y != 0 {
        view.scroll += pane.wheel.y * MD_WHEEL_LINES * f32(font.line_height(view.built_font))
    }
    view.scroll = clamp(view.scroll, 0, max(0, view.page.content_height - pane.rect.h))

    // The items are absolute and out of flow, so this states the page height for
    // Loom: it is what the bar and the scroll clamp are sized from.
    ui.leaf({key = "content", props = {w = ui.Px(0), h = ui.Px(view.page.content_height)}})

    left := markdown.content_left(pane.rect.w, avail)
    top := markdown.PAD_TOP - view.scroll

    thor_markdown_hover(view, pane, left, top)
    thor_markdown_items(thor, view, pane, left, top)
}

// The link under the cursor, so it lights up instead of changing the cursor.
// markdown.layout appends a link's underline right after its text, so the two
// light together.
@(private = "file")
thor_markdown_hover :: proc(view: ^Markdown_View, pane: ui.Interaction, left, top: f32) {
    view.hovered = -1
    if !pane.hovered {
        return
    }
    mouse := ui.mouse_pos()
    view.hovered = markdown.link_at(
        &view.page,
        mouse.x - pane.rect.x - left,
        mouse.y - pane.rect.y - top,
    )
}

@(private = "file")
thor_markdown_items :: proc(
    thor: ^Thor,
    view: ^Markdown_View,
    pane: ui.Interaction,
    left, top: f32,
) {
    // Clicked, not pressed: a drag that scrolled the page is not a link.
    clicked := view.hovered >= 0 && pane.clicked

    for item, index in view.page.items {
        y := top + item.y
        if y + item.h < 0 || y > pane.rect.h {
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
        }
    }

    if clicked {
        url := view.page.items[view.hovered].url
        if url != "" {
            thor_markdown_open_link(thor, url)
        }
    }
}
