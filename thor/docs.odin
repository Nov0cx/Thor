package thor

// The user manual: the Markdown pages shipped in docs/ beside the binary. Help
// opens a page in the rendered preview, or hands the documentation to the
// system browser -- the generated docs/html/ when it is present, the project
// page when it is not.

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "../widgets"

// Documentation folder beside the binary. Thor moves its working directory to
// the executable at startup, so the path is relative.
DOCS_DIR :: "docs"

// The page every other page is linked from.
DOCS_INDEX :: "index.md"

// Offline HTML made by docs/generate_html.py. Not committed, so it is present
// only when the user has generated it.
DOCS_HTML_INDEX :: "html/index.html"

// The pages on the project page, for a build with no local HTML.
DOCS_URL :: "https://github.com/Nov0cx/Thor/tree/master/docs"

// Path of a documentation page, from its name inside docs/.
@(private = "file")
thor_docs_path :: proc(name: string, allocator := context.temp_allocator) -> string {
    return strings.concatenate({DOCS_DIR, "/", name}, allocator)
}

// Opens the documentation index in the rendered Markdown preview.
thor_cmd_docs :: proc(data: rawptr) {
    thor_open_docs_page(cast(^Thor) data, DOCS_INDEX)
}

// Opens one page of the manual, turning the Markdown preview on so the page
// arrives rendered and not as its source.
@(private = "file")
thor_open_docs_page :: proc(thor: ^Thor, name: string) {
    path := thor_docs_path(name)
    if !os.exists(path) {
        thor_flash_status(thor, "No documentation is installed beside Thor", true)
        return
    }
    thor.markdown_preview = true
    thor_open_file(thor, path)
}

// The Markdown pages under docs/, the index first and the rest by name. Names
// are relative to docs/ and temp-allocated.
@(private = "file")
thor_docs_pages :: proc() -> []string {
    names := make([dynamic]string, context.temp_allocator)

    handle, open_err := os.open(DOCS_DIR)
    if open_err != nil {
        return names[:]
    }
    defer os.close(handle)

    infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil {
        return names[:]
    }

    for info in infos {
        if info.type == .Directory || info.name == DOCS_INDEX {
            continue
        }
        if strings.has_suffix(info.name, ".md") {
            append(&names, info.name)
        }
    }
    slice.sort(names[:])

    if os.exists(thor_docs_path(DOCS_INDEX)) {
        inject_at(&names, 0, DOCS_INDEX)
    }
    return names[:]
}

// Picks a page of the manual by name and opens it in the preview.
thor_cmd_docs_page :: proc(data: rawptr) {
    thor := cast(^Thor) data
    pages := thor_docs_pages()
    if len(pages) == 0 {
        thor_flash_status(thor, "No documentation is installed beside Thor", true)
        return
    }
    widgets.command_palette_pick(thor.command_palette, &thor.ui_context, "Documentation", pages, thor_pick_docs_page, thor)
}

@(private = "file")
thor_pick_docs_page :: proc(data: rawptr, name: string) {
    thor_open_docs_page(cast(^Thor) data, name)
}

// Opens the documentation in the system browser: the generated HTML when
// docs/generate_html.py has been run, the project page otherwise. The local
// path is made absolute because the browser does not inherit our working
// directory.
thor_cmd_docs_browser :: proc(data: rawptr) {
    thor := cast(^Thor) data
    local := thor_docs_path(DOCS_HTML_INDEX)
    if os.exists(local) {
        if abs, err := filepath.abs(local, context.temp_allocator); err == nil {
            if thor_open_in_browser(abs) {
                thor_flash_status(thor, "Documentation opened in the browser")
            } else {
                thor_flash_status(thor, "Could not open the browser", true)
            }
            return
        }
    }
    if thor_open_in_browser(DOCS_URL) {
        thor_flash_status(thor, "Documentation opened on the project page")
    } else {
        thor_flash_status(thor, "Could not open the browser", true)
    }
}
