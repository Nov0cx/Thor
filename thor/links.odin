// Document links: the spans a backend names as a URL or a file, underlined and opened by ctrl + click.
package thor

import "core:os"
import "core:strings"

import ui "../vendor/loom/loom"

import "../editview"
import "../lang"
import "../textedit"

// The links of one file, at the revision they were computed for.
File_Links :: struct {
    items:       [dynamic]lang.Document_Link_Item, // owned targets
    revision:    u64,
    ready:       bool,
    asked:       u64, // the revision last requested
    asked_valid: bool,
}

// Asks for the links of `file` once its text settled at a new revision.
@(private = "package")
thor_request_links :: proc(thor: ^Thor, file: ^Open_File) {
    nav   := &thor.nav
    links := &file.links
    if nav.link_request_id != 0 || thor_big_file(file) || (links.asked_valid && links.asked == file.state.revision) {
        return
    }
    ext := thor_lang_key(thor, file.name)
    if !lang.manager_allows(&thor.lang_manager, ext, .Document_Link) {
        return
    }
    id := lang.manager_request_debounced(
        &thor.lang_manager,
        .Document_Link,
        file.path,
        ext,
        textedit.text(&file.state),
        0,
        file.state.revision,
        thor.workspace_dir,
        delay = lang.DEBOUNCE_CHECK,
    )
    if id == 0 {
        return
    }
    links.asked = file.state.revision
    links.asked_valid = true
    nav.link_request_id = id
    nav.link_revision = file.state.revision
    delete(nav.link_path)
    nav.link_path = strings.clone(file.path)
}

// Stores the links of a landed Document_Link request. Looked up by path, since the tab may have closed.
thor_on_links :: proc(thor: ^Thor, res: ^lang.Result) {
    nav := &thor.nav
    if res.id != nav.link_request_id {
        return
    }
    nav.link_request_id = 0
    file := thor_open_file_at(thor, nav.link_path)
    delete(nav.link_path)
    nav.link_path = ""
    if file == nil || res.undispatched {
        return
    }
    thor_clear_file_links(file)
    for l in res.links {
        append(&file.links.items, lang.Document_Link_Item{start = l.start, end = l.end, target = strings.clone(l.target)})
    }
    file.links.revision = nav.link_revision
    file.links.ready = true
}

// Drops the slot of a link request that will never land.
thor_recover_link_slot :: proc(thor: ^Thor) {
    nav := &thor.nav
    if nav.link_request_id != 0 && !lang.manager_has_request(&thor.lang_manager, nav.link_request_id) {
        nav.link_request_id = 0
        delete(nav.link_path)
        nav.link_path = ""
    }
}

// Drops the links of a file.
thor_clear_file_links :: proc(file: ^Open_File) {
    for item in file.links.items {
        delete(item.target)
    }
    clear(&file.links.items)
    file.links.ready = false
    file.links.asked_valid = false
}

// Frees the links of a closing file.
thor_destroy_file_links :: proc(file: ^Open_File) {
    thor_clear_file_links(file)
    delete(file.links.items)
}

// The target of the link at `offset`, when the links are of the live text.
thor_link_at :: proc(file: ^Open_File, offset: int) -> (string, bool) {
    links := &file.links
    if !links.ready || links.revision != file.state.revision {
        return "", false
    }
    for item in links.items {
        if offset >= item.start && offset < item.end {
            return item.target, true
        }
    }
    return "", false
}

// Opens a link target: a URL in the browser, a folder in the file manager, a file in a tab.
thor_open_link :: proc(thor: ^Thor, target: string) {
    switch {
    case strings.has_prefix(target, "http://") || strings.has_prefix(target, "https://"):
        if !thor_open_in_browser(target) {
            thor_flash_status(thor, "Could not open the browser", is_error = true)
        }
    case os.is_dir(target):
        if !thor_reveal_path(target) {
            thor_flash_status(thor, "Could not open the folder", is_error = true)
        }
    case os.is_file(target):
        thor_open_file(thor, target)
    case:
        thor_flash_status(thor, "The link target does not exist", is_error = true)
    }
}

// Underlines the links of the file `editor` shows, while they are of its text.
@(private = "package")
thor_paint_links :: proc(thor: ^Thor, editor: ^editview.Editor, text: string, rows: []editview.Visual_Row, first, last: int, line_h, text_x: f32) {
    if editor.state == nil || first >= last {
        return
    }
    file: ^Open_File
    for f in thor.open_files {
        if &f.state == editor.state {
            file = f
            break
        }
    }
    if file == nil || !file.links.ready || file.links.revision != editor.state.revision || len(file.links.items) == 0 {
        return
    }
    lo_byte, hi_byte := rows[first].start, rows[last - 1].end
    for link in file.links.items {
        if link.end < lo_byte || link.start > hi_byte {
            continue
        }
        for index in first ..< last {
            if rows[index].spacer {
                continue
            }
            row := rows[index]
            a   := max(link.start, row.start)
            b   := min(link.end, row.end)
            if b <= a {
                continue
            }
            x0 := thor_row_x(editor, text, row.start, row.end, a)
            x1 := thor_row_x(editor, text, row.start, row.end, b)
            y  := f32(index) * line_h - editor.scroll_y
            ui.paint_rect({text_x + x0, y + line_h - 2, max(x1 - x0, 2), 1}, thor.theme.accent_color)
        }
    }
}
