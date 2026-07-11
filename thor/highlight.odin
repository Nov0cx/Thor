package thor

import "core:strings"
import rl "vendor:raylib"

import "../syntax"
import "../textedit"
import "../widgets"

// Reparses `file` and rebuilds its highlight spans (resolved to theme colors).
// Only the active file is highlighted, so this runs when its buffer changes.
thor_update_highlights :: proc(thor: ^Thor, file: ^Open_File) {
    active := file == thor_active_open_file(thor)
    lang := thor_syntax_language(file.name)

    clear(&file.highlights)
    if syntax.supports(&thor.highlighter, lang) {
        source := textedit.text(&file.state)
        for span in syntax.highlight(&thor.highlighter, source, lang, context.temp_allocator) {
            color := thor_token_color(thor, span.kind)
            append(&file.highlights, widgets.Highlight_Span{span.start, span.end, color})
        }
    }

    file.highlighted = true
    file.highlight_revision = file.state.revision
    if active {
        widgets.editor_set_highlights(thor.editor, file.highlights[:])
    }
}

// syntax language id for a file name, or "" when unsupported.
thor_syntax_language :: proc(name: string) -> string {
    dot := strings.last_index_byte(name, '.')
    if dot < 0 {
        return ""
    }
    switch name[dot:] {
    case ".odin":
        return "odin"
    }
    return ""
}

thor_token_color :: proc(thor: ^Thor, kind: syntax.Token_Kind) -> rl.Color {
    t := thor.theme
    switch kind {
    case .Keyword:     return t.keywords_color
    case .Function:    return t.functions_color
    case .Type:        return t.orange_color
    case .Constant:    return t.orange_color
    case .Number:      return t.numbers_color
    case .String:      return t.strings_color
    case .Comment:     return t.comments_color
    case .Operator:    return t.operators_color
    case .Namespace:   return t.variables_color
    case .Parameter:   return t.parameters_color
    case .Field:       return t.variables_color
    case .Variable:    return t.variables_color
    case .Attribute:   return t.attributes_color
    case .Label:       return t.keywords_color
    case .Preproc:     return t.orange_color
    case .Punctuation, .Default:
        return t.foreground
    }
    return t.foreground
}
