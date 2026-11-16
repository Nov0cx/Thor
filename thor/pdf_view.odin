// The PDF preview of a LaTeX document, in the pane the source is not in. Pages
// render to PNG through pdftoppm or mutool on a worker, only near the view, at
// the resolution the zoom asks for.
package thor

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "../platform"
import "../render"
import "../setting"
import ui "../vendor/loom/loom"

// How often the view looks at the PDF's modification time.
@(private = "file")
PDF_CHECK_SECS :: 0.5

// Pages in flight at once.
@(private = "file")
PDF_MAX_RENDERS :: 2

// A texture this far off the wanted resolution renders again.
@(private = "file")
PDF_DPI_SLACK :: 0.15

// Pages kept as textures beyond the visible ones, on each side.
@(private = "file")
PDF_KEEP_PAGES :: 3

@(private = "file")
PDF_ZOOM_MIN :: f32(0.25)

@(private = "file")
PDF_ZOOM_MAX :: f32(5)

@(private = "file")
PDF_ZOOM_STEP :: f32(1.1)

@(private = "file")
PDF_WHEEL_PX :: f32(60)

@(private = "file")
PDF_FLASH_SECS :: 1.5

@(private = "file")
PDF_PAPER :: ui.Color{255, 255, 255, 255}

@(private = "file")
PDF_CACHE_DIR :: "user/cache/pdf"

Pdf_Renderer :: enum {
    None,
    Poppler, // pdftoppm + pdfinfo
    Mutool,
}

Pdf_Page :: struct {
    size:       [2]f32,           // points
    texture:    platform.Texture, // owned while `loaded`
    loaded:     bool,
    loading:    bool,
    dpi:        f32, // what the texture, or the last failed render, was made at
    generation: u64, // the PDF generation of that render
}

Pdf_View :: struct {
    source:       rawptr, // borrowed identity of the buffer `pdf` was found from
    source_rev:   u64,
    pdf:          string, // owned; "" when the active file names none
    mtime:        time.Time,
    exists:       bool,
    generation:   u64, // bumps on each change of the PDF
    info_loading: bool,
    info_failed:  bool,
    pages:        [dynamic]Pdf_Page, // owned
    scroll:       f32,
    pan_x:        f32,
    zoom:         f32, // 1 fits the widest page to the pane
    next_check:   f64,
    renderer:     Pdf_Renderer,
    resolved:     bool,
    render_exe:   string,      // owned
    info_exe:     string,      // owned
    cache_dir:    string,      // owned, absolute
    seq:          u64,         // names each render's output file
    target:       Synctex_Box, // a forward search the next layout scrolls to
    has_target:   bool,
    flash:        Synctex_Box,
    flash_until:  f64,
}

@(private = "file")
thor_pdf_unload_page :: proc(thor: ^Thor, page: ^Pdf_Page) {
    if page.loaded {
        render.forget_texture(&thor.backend, page.texture)
        platform.texture_free(page.texture)
        page.texture = {}
        page.loaded = false
    }
}

@(private = "file")
thor_pdf_clear_pages :: proc(thor: ^Thor, view: ^Pdf_View) {
    for &page in view.pages {
        thor_pdf_unload_page(thor, &page)
    }
    clear(&view.pages)
}

thor_pdf_view_destroy :: proc(thor: ^Thor, view: ^Pdf_View) {
    thor_pdf_clear_pages(thor, view)
    delete(view.pages)
    delete(view.pdf)
    delete(view.render_exe)
    delete(view.info_exe)
    delete(view.cache_dir)
    view^ = {}
}

// Makes the view look at `pdf` again at once: a build wrote it.
thor_pdf_view_poke :: proc(view: ^Pdf_View, pdf: string) {
    if view.pdf == pdf {
        view.mtime = {}
        view.next_check = 0
    }
}

// Finds the renderer the latex_pdf_renderer setting names, once.
@(private = "file")
thor_pdf_resolve :: proc(thor: ^Thor, view: ^Pdf_View) {
    if view.resolved {
        return
    }
    view.resolved = true
    want := setting.latex_pdf_renderer(&thor.config)
    if want != "mutool" {
        render_exe, render_ok := thor_latex_tool("pdftoppm")
        info_exe, info_ok     := thor_latex_tool("pdfinfo")
        if render_ok && info_ok {
            view.renderer = .Poppler
            view.render_exe = strings.clone(render_exe)
            view.info_exe = strings.clone(info_exe)
        }
    }
    if view.renderer == .None && want != "pdftoppm" {
        if exe, ok := thor_latex_tool("mutool"); ok {
            view.renderer = .Mutool
            view.render_exe = strings.clone(exe)
            view.info_exe = strings.clone(exe)
        }
    }
    view.cache_dir = strings.clone(thor_abs_path(PDF_CACHE_DIR))
    if err := os.make_directory_all(view.cache_dir); err != nil && !os.exists(view.cache_dir) {
        log.warnf("Could not create %q: %v", view.cache_dir, err)
    }
}

// Points the view at the PDF of the active LaTeX buffer.
@(private = "file")
thor_pdf_bind :: proc(thor: ^Thor, view: ^Pdf_View, file: ^Open_File) {
    if file == nil || !file.loaded {
        return
    }
    if view.source == rawptr(file) && view.source_rev == file.state.revision {
        return
    }
    view.source = rawptr(file)
    view.source_rev = file.state.revision
    pdf := latex_pdf_path(thor_latex_root(file), context.temp_allocator)
    if pdf == view.pdf {
        return
    }
    thor_pdf_clear_pages(thor, view)
    delete(view.pdf)
    view.pdf = strings.clone(pdf)
    view.mtime = {}
    view.exists = false
    view.generation += 1
    view.info_loading = false
    view.info_failed = false
    view.scroll = 0
    view.pan_x = 0
    view.next_check = 0
}

// Looks at the PDF's modification time and reads its pages again when it changed.
@(private = "file")
thor_pdf_check :: proc(thor: ^Thor, view: ^Pdf_View) {
    now := platform.time()
    if view.pdf == "" || now < view.next_check {
        return
    }
    view.next_check = now + PDF_CHECK_SECS
    info, err := os.stat(view.pdf, context.temp_allocator)
    if err != nil {
        view.exists = false
        return
    }
    view.exists = true
    if info.modification_time == view.mtime || view.renderer == .None {
        return
    }
    view.mtime = info.modification_time
    view.generation += 1
    view.info_failed = false
    view.info_loading = true

    job := thor_latex_job(thor, .Info, filepath.dir(view.pdf))
    job.exe = strings.clone(view.info_exe)
    job.pdf = strings.clone(view.pdf)
    job.generation = view.generation
    if view.renderer == .Poppler {
        thor_latex_arg(job, "-f", "1", "-l", "100000", view.pdf)
    } else {
        thor_latex_arg(job, "pages", view.pdf)
    }
    thor_latex_run(thor, job)
}

@(private = "file")
thor_pdf_start_page :: proc(thor: ^Thor, view: ^Pdf_View, index: int, dpi: f32) {
    view.seq += 1
    root := fmt.tprintf("%s/%d-%d", view.cache_dir, view.seq, index + 1)
    job  := thor_latex_job(thor, .Page, filepath.dir(view.pdf))
    job.exe = strings.clone(view.render_exe)
    job.pdf = strings.clone(view.pdf)
    job.page = index
    job.dpi = dpi
    job.generation = view.generation
    job.out_png = strings.concatenate({root, ".png"})
    dpi_text := fmt.tprintf("%d", int(dpi + 0.5))
    page     := fmt.tprintf("%d", index + 1)
    if view.renderer == .Poppler {
        thor_latex_arg(job, "-png", "-r", dpi_text, "-f", page, "-l", page, "-singlefile", view.pdf, root)
    } else {
        thor_latex_arg(job, "draw", "-r", dpi_text, "-o", job.out_png, view.pdf, page)
    }
    view.pages[index].loading = true
    thor_latex_run(thor, job)
}

// Applies an .Info or .Page job of the view's PDF.
thor_pdf_apply_job :: proc(thor: ^Thor, view: ^Pdf_View, job: ^Latex_Job) {
    if job.pdf != view.pdf {
        return
    }
    thor.redraw = true
    if job.kind == .Info {
        if job.generation != view.generation {
            return
        }
        view.info_loading = false
        sizes := view.renderer == .Poppler ? pdfinfo_parse_sizes(job.output, context.temp_allocator) : mutool_parse_sizes(job.output, context.temp_allocator)
        if !job.ok || len(sizes) == 0 {
            // A build may still be writing the file; its next change reads it again.
            view.info_failed = true
            return
        }
        for i := len(sizes); i < len(view.pages); i += 1 {
            thor_pdf_unload_page(thor, &view.pages[i])
        }
        old := len(view.pages)
        resize(&view.pages, len(sizes))
        for i in 0 ..< len(sizes) {
            if i >= old {
                view.pages[i] = {}
            }
            view.pages[i].size = sizes[i]
            view.pages[i].loading = false
        }
        return
    }

    if job.page >= len(view.pages) {
        return
    }
    page := &view.pages[job.page]
    page.loading = false
    page.dpi = job.dpi
    page.generation = job.generation
    if !job.ok {
        return
    }
    texture, uploaded := platform.texture_from_image(job.decoded)
    if !uploaded {
        log.warnf("Failed to upload page %d of %q", job.page + 1, job.pdf)
        return
    }
    platform.texture_set_filter(texture, .Bilinear)
    thor_pdf_unload_page(thor, page)
    page.texture = texture
    page.loaded = true
}

// Applies a forward search: the next layout scrolls to the box and flashes it.
thor_pdf_apply_sync_view :: proc(thor: ^Thor, view: ^Pdf_View, job: ^Latex_Job) {
    box, ok := synctex_parse_view(job.output)
    if !job.ok || !ok {
        thor_flash_status(thor, "SyncTeX found no place in the PDF for this line. Build with -synctex=1.", is_error = true)
        return
    }
    view.target = box
    view.has_target = true
    view.flash = box
    view.flash_until = platform.time() + PDF_FLASH_SECS
    thor.redraw = true
}

// The pane: the pages of the active document's PDF, stacked.
thor_pdf_pane :: proc(thor: ^Thor, file: ^Open_File, key: string) {
    view := &thor.latex.view
    thor_pdf_resolve(thor, view)
    thor_pdf_bind(thor, view, file)
    thor_pdf_check(thor, view)

    pane := ui.begin(
        {
            key = key,
            flags = {.Clip, .Clickable, .Draggable, .Wheel},
            props = {position = .Relative, w = ui.Grow(1), h = ui.Grow(1), bg = thor.theme.second_background, cursor = .Grab},
        },
    )
    defer ui.end()

    if pane.rect.w <= 0 || pane.rect.h <= 0 {
        return
    }
    if message := thor_pdf_empty_message(view); message != "" {
        thor_pdf_empty(thor, message)
        return
    }

    margin := tk_sp(.M)
    gap    := tk_sp(.M)
    widest := f32(1)
    for page in view.pages {
        widest = max(widest, page.size[0])
    }
    if view.zoom <= 0 {
        view.zoom = 1
    }
    scale := max(pane.rect.w - 2 * margin, 1) / widest * view.zoom

    // Zoom keeps the point under the cursor in place; a plain wheel scrolls.
    if pane.wheel.y != 0 {
        if .Ctrl in ui.mods() {
            factor := pane.wheel.y < 0 ? PDF_ZOOM_STEP : 1 / PDF_ZOOM_STEP
            zoom   := clamp(view.zoom * factor, PDF_ZOOM_MIN, PDF_ZOOM_MAX)
            ratio  := zoom / view.zoom
            pivot  := ui.mouse_pos() - {pane.rect.x, pane.rect.y}
            view.scroll = (view.scroll + pivot.y) * ratio - pivot.y
            // pan_x is the left edge of the widest page once it overflows the pane.
            old_w := widest * scale
            left  := old_w <= pane.rect.w ? (pane.rect.w - old_w) * 0.5 : view.pan_x
            view.pan_x = pivot.x - (pivot.x - left) * ratio
            view.zoom = zoom
            scale *= ratio
        } else {
            view.scroll += pane.wheel.y * PDF_WHEEL_PX
        }
    }
    if pane.dragging && .Ctrl not_in ui.mods() {
        view.scroll -= pane.drag_delta.y
        view.pan_x += pane.drag_delta.x
    }

    content := margin
    for page, i in view.pages {
        content += page.size[1] * scale + (i + 1 < len(view.pages) ? gap : 0)
    }
    content += margin

    if view.has_target && view.target.page >= 1 && view.target.page <= len(view.pages) {
        top := margin
        for i in 0 ..< view.target.page - 1 {
            top += view.pages[i].size[1] * scale + gap
        }
        view.scroll = top + (view.target.v - view.target.height) * scale - pane.rect.h / 3
        view.has_target = false
    }
    view.scroll = clamp(view.scroll, 0, max(0, content - pane.rect.h))
    page_w := widest * scale
    slack  := pane.rect.w - page_w
    if slack >= 0 {
        view.pan_x = 0
    } else {
        view.pan_x = clamp(view.pan_x, slack - margin, margin)
    }

    want_dpi  := clamp(scale * 72 * max(thor.backend.dpi, 1), 30, 600)
    in_flight := 0
    for page in view.pages {
        in_flight += page.loading ? 1 : 0
    }

    first, last := -1, -1
    y := margin - view.scroll
    for &page, i in view.pages {
        w := page.size[0] * scale
        h := page.size[1] * scale
        x := slack >= 0 ? (pane.rect.w - w) * 0.5 : view.pan_x + (page_w - w) * 0.5
        if y + h >= 0 && y <= pane.rect.h {
            if first < 0 {
                first = i
            }
            last = i
            thor_pdf_draw_page(thor, view, &page, i, {x, y, w, h}, scale)
            if pane.pressed && .Ctrl in ui.mods() {
                mouse := ui.mouse_pos() - {pane.rect.x, pane.rect.y}
                if mouse.x >= x && mouse.x < x + w && mouse.y >= y && mouse.y < y + h {
                    thor_latex_inverse_search(thor, view.pdf, i + 1, (mouse.x - x) / scale, (mouse.y - y) / scale)
                }
            }
        }
        y += h + gap
    }

    if first < 0 || view.renderer == .None {
        return
    }
    lo := max(first - 1, 0)
    hi := min(last + 1, len(view.pages) - 1)
    for i in lo ..= hi {
        if in_flight >= PDF_MAX_RENDERS {
            break
        }
        page := &view.pages[i]
        if page.loading {
            continue
        }
        stale := !page.loaded && page.generation != view.generation
        stale ||= page.loaded && page.generation != view.generation
        stale ||= abs(page.dpi - want_dpi) > want_dpi * PDF_DPI_SLACK
        if stale {
            thor_pdf_start_page(thor, view, i, want_dpi)
            in_flight += 1
        }
    }
    for &page, i in view.pages {
        if i < first - PDF_KEEP_PAGES || i > last + PDF_KEEP_PAGES {
            thor_pdf_unload_page(thor, &page)
            page.dpi = 0
        }
    }
}

@(private = "file")
thor_pdf_draw_page :: proc(thor: ^Thor, view: ^Pdf_View, page: ^Pdf_Page, index: int, r: ui.Rect, scale: f32) {
    ui.paint_rect(r, PDF_PAPER)
    if page.loaded {
        ui.push_id_int(i64(index))
        ui.image(
            render.register_texture(&thor.backend, page.texture),
            {key = "pdf-page", props = {position = .Absolute, inset = {l = r.x, t = r.y}, w = ui.Px(r.w), h = ui.Px(r.h)}},
        )
        ui.pop_id()
    }
    if index + 1 == view.flash.page && platform.time() < view.flash_until {
        box   := view.flash
        band  := ui.Rect{r.x + box.h * scale, r.y + (box.v - box.height) * scale, max(box.width, 4) * scale, max(box.height, 4) * scale}
        color := thor.theme.accent_color
        color.a = 90
        ui.paint_rect(band, color, over = true)
        thor.redraw = true
    }
}

// What the pane says instead of pages, or "" when it has pages to show.
@(private = "file")
thor_pdf_empty_message :: proc(view: ^Pdf_View) -> string {
    switch {
    case view.pdf == "":
        return "Open a LaTeX file to see its PDF."
    case view.renderer == .None:
        return "No PDF renderer found. Install poppler (pdftoppm) or mupdf (mutool); see docs/latex.md."
    case !view.exists:
        return fmt.tprintf("%s does not exist yet. Save the document to build it.", filepath.base(view.pdf))
    case view.info_failed && len(view.pages) == 0:
        return fmt.tprintf("Could not read %s.", filepath.base(view.pdf))
    case len(view.pages) == 0:
        return "Reading the PDF..."
    }
    return ""
}

@(private = "file")
thor_pdf_empty :: proc(thor: ^Thor, message: string) {
    ui.label(
        message,
        {
            key = "pdf-empty",
            props = {
                position = .Absolute,
                inset = {l = tk_sp(.L), t = tk_sp(.L), r = tk_sp(.L)},
                color = thor.theme.foreground,
                font_size = f32(thor.config.general.font_size),
            },
        },
    )
}
