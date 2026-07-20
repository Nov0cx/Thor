package thor

import "core:strings"

import "../plugin"
import "../textedit"
import "../ui"
import "../widgets"

// Reparses `file` and rebuilds its highlight spans (resolved to theme colors).
// Only the files shown in a pane are highlighted, so this runs when their
// buffers change.
thor_update_highlights :: proc(thor: ^Thor, file: ^Open_File) {
    ext := thor_file_ext(file.name)

    clear(&file.highlights)
    clear(&file.folds)
    if plugin.supports(&thor.plugins, ext) {
        source := textedit.text(&file.state)
        for span in plugin.highlight(&thor.plugins, source, ext, context.temp_allocator) {
            color := ui.theme_role_color(thor.theme, span.role)
            append(&file.highlights, widgets.Highlight_Span{span.start, span.end, color})
        }
        for r in plugin.fold_ranges(&thor.plugins, source, ext, context.temp_allocator) {
            append(&file.folds, widgets.Fold_Range{r.start_line, r.end_line})
        }
    }

    file.highlighted = true
    file.highlight_revision = file.state.revision
    thor_apply_file_highlights(thor, file)
}

// File extension including the dot (".odin"), or "" when there is none.
thor_file_ext :: proc(name: string) -> string {
    dot := strings.last_index_byte(name, '.')
    if dot < 0 {
        return ""
    }
    return name[dot:]
}
