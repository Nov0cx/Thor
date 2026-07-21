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
    key := thor_highlight_key(&thor.plugins, file.name)

    clear(&file.highlights)
    clear(&file.folds)
    if plugin.supports(&thor.plugins, key) {
        source := textedit.text(&file.state)
        for span in plugin.highlight(&thor.plugins, source, key, context.temp_allocator) {
            color := ui.theme_role_color(thor.theme, span.role)
            append(&file.highlights, widgets.Highlight_Span{span.start, span.end, color})
        }
        for r in plugin.fold_ranges(&thor.plugins, source, key, context.temp_allocator) {
            append(&file.folds, widgets.Fold_Range{r.start_line, r.end_line})
        }
    }

    file.highlighted = true
    file.highlight_revision = file.state.revision
    thor_apply_file_highlights(thor, file)
}

// The key a language plugin is looked up by: the file extension (".odin") when a
// plugin claims it, else the bare filename ("Dockerfile", "Makefile") so files
// with no extension can still map to a language. Falls back to the extension.
thor_highlight_key :: proc(plugins: ^plugin.Manager, name: string) -> string {
    if ext := thor_file_ext(name); ext != "" && plugin.supports(plugins, ext) {
        return ext
    }
    if base := thor_file_base(name); plugin.supports(plugins, base) {
        return base
    }
    return thor_file_ext(name)
}

// File extension including the dot (".odin"), or "" when there is none.
thor_file_ext :: proc(name: string) -> string {
    dot := strings.last_index_byte(name, '.')
    if dot < 0 {
        return ""
    }
    return name[dot:]
}

// The final path component ("Dockerfile" from "app/Dockerfile"), handling both
// path separators.
thor_file_base :: proc(name: string) -> string {
    slash := max(strings.last_index_byte(name, '/'), strings.last_index_byte(name, '\\'))
    return name[slash + 1:]
}
