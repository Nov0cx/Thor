package thor

import "core:strings"

import "../plugin"
import "../textedit"
import "../ui"
import "../widgets"

// Reparses `file` and rebuilds its highlight spans (resolved to theme colors).
// Only the active file is highlighted, so this runs when its buffer changes.
thor_update_highlights :: proc(thor: ^Thor, file: ^Open_File) {
    active := file == thor_active_open_file(thor)
    ext := thor_file_ext(file.name)

    clear(&file.highlights)
    if plugin.supports(&thor.plugins, ext) {
        source := textedit.text(&file.state)
        for span in plugin.highlight(&thor.plugins, source, ext, context.temp_allocator) {
            color := ui.theme_role_color(thor.theme, span.role)
            append(&file.highlights, widgets.Highlight_Span{span.start, span.end, color})
        }
    }

    file.highlighted = true
    file.highlight_revision = file.state.revision
    if active {
        widgets.editor_set_highlights(thor.editor, file.highlights[:])
    }
}

// File extension including the dot (".odin"), or "" when there is none.
thor_file_ext :: proc(name: string) -> string {
    dot := strings.last_index_byte(name, '.')
    if dot < 0 {
        return ""
    }
    return name[dot:]
}
