// File-type icons: the glyph name and the vendor tint for a file, shared by
// the explorer tree, the tab strip and quick open. Both take a base name, so a
// caller with a path passes it through thor_file_base first.
package thor

import "core:strings"

import ui "../vendor/loom/loom"

// Vendor (brand) colour for a file's language, GitHub-linguist style, used to
// tint its row icon. `ok` is false for names with no known language, so the
// caller keeps its neutral fallback. Colours are lightened where the true brand
// tone would be too dark to read on a dark background.
@(private = "file")
file_vendor_color :: proc(name: string) -> (ui.Color, bool) {
    switch name {
    case "Dockerfile":
        return ui.Color{58, 137, 227, 255}, true
    case "CMakeLists.txt":
        return ui.Color{100, 130, 173, 255}, true
    }

    dot := strings.last_index_byte(name, '.')
    if dot < 0 {
        return {}, false
    }

    switch name[dot:] {
    case ".c", ".h":                           return ui.Color{90, 150, 214, 255}, true
    case ".cpp", ".hpp", ".cc", ".hh", ".cxx": return ui.Color{243, 75, 125, 255}, true
    case ".rs":                                return ui.Color{222, 165, 132, 255}, true
    case ".go":                                return ui.Color{0, 173, 216, 255}, true
    case ".py", ".pyw":                        return ui.Color{255, 212, 59, 255}, true
    case ".js", ".mjs", ".cjs":                return ui.Color{241, 224, 90, 255}, true
    case ".ts":                                return ui.Color{73, 143, 217, 255}, true
    case ".jsx", ".tsx":                       return ui.Color{97, 218, 251, 255}, true
    case ".zig":                               return ui.Color{236, 145, 92, 255}, true
    case ".glsl", ".vert", ".frag":            return ui.Color{90, 150, 214, 255}, true
    case ".md":                                return ui.Color{117, 143, 255, 255}, true
    case ".json":                              return ui.Color{203, 161, 53, 255}, true
    case ".yml", ".yaml":                      return ui.Color{203, 75, 80, 255}, true
    case ".xml":                               return ui.Color{150, 190, 90, 255}, true
    case ".html", ".htm":                      return ui.Color{227, 100, 60, 255}, true
    case ".css":                               return ui.Color{102, 129, 214, 255}, true
    case ".scss", ".sass":                     return ui.Color{207, 100, 154, 255}, true
    case ".lua":                               return ui.Color{80, 120, 255, 255}, true
    case ".java":                              return ui.Color{214, 143, 61, 255}, true
    case ".kt", ".kts":                        return ui.Color{169, 123, 255, 255}, true
    case ".cs":                                return ui.Color{104, 33, 122, 255}, true
    case ".fs":                                return ui.Color{55, 139, 186, 255}, true
    case ".swift":                             return ui.Color{240, 81, 56, 255}, true
    case ".rb":                                return ui.Color{204, 52, 45, 255}, true
    case ".php":                               return ui.Color{119, 123, 180, 255}, true
    case ".hs":                                return ui.Color{143, 78, 139, 255}, true
    case ".ex", ".exs":                        return ui.Color{150, 120, 180, 255}, true
    case ".jl":                                return ui.Color{150, 90, 165, 255}, true
    case ".pl", ".pm":                         return ui.Color{90, 130, 190, 255}, true
    case ".dart":                              return ui.Color{0, 180, 171, 255}, true
    case ".scala":                             return ui.Color{194, 65, 84, 255}, true
    case ".clj", ".cljs":                      return ui.Color{130, 190, 80, 255}, true
    case ".erl":                               return ui.Color{184, 57, 152, 255}, true
    case ".ml", ".mli":                        return ui.Color{232, 137, 62, 255}, true
    case ".nim":                               return ui.Color{240, 200, 80, 255}, true
    case ".sh", ".bash", ".zsh":               return ui.Color{137, 224, 81, 255}, true
    case ".ps1", ".psm1":                      return ui.Color{90, 145, 216, 255}, true
    case ".vim":                               return ui.Color{90, 175, 90, 255}, true
    case ".tex", ".bib":                       return ui.Color{120, 160, 200, 255}, true
    case ".cmake":                             return ui.Color{100, 130, 173, 255}, true
    case ".vue":                               return ui.Color{65, 184, 131, 255}, true
    case ".svelte":                            return ui.Color{255, 90, 45, 255}, true
    case ".graphql", ".gql":                   return ui.Color{229, 53, 171, 255}, true
    case ".gitignore", ".gitattributes", ".gitmodules":
        return ui.Color{240, 80, 50, 255}, true
    case ".odin":                              return ui.Color{104, 172, 227, 255}, true
    }
    return {}, false
}

// Tint for a file's icon: the language's vendor colour, or `fallback` for a name
// with no known language.
thor_file_icon_tint :: proc(name: string, fallback: ui.Color) -> ui.Color {
    if vendor, ok := file_vendor_color(name); ok {
        return vendor
    }
    return fallback
}

// Language files get a `filetype-` glyph from the active file icon pack; `.odin`
// has no glyph in either pack, so it keeps its own family, and everything else
// falls back to the generic file icons of the primary pack.
thor_file_icon :: proc(name: string) -> string {
    switch name {
    case "Dockerfile":
        return "filetype-docker"
    case "CMakeLists.txt":
        return "filetype-cmake"
    }

    dot := strings.last_index_byte(name, '.')
    if dot < 0 {
        return "file"
    }

    switch name[dot:] {
    case ".c", ".h":                           return "filetype-c"
    case ".cpp", ".hpp", ".cc", ".hh", ".cxx": return "filetype-cpp"
    case ".rs":                                return "filetype-rust"
    case ".go":                                return "filetype-go"
    case ".py", ".pyw":                        return "filetype-python"
    case ".js", ".mjs", ".cjs":                return "filetype-javascript"
    case ".ts":                                return "filetype-typescript"
    case ".jsx", ".tsx":                       return "filetype-react"
    case ".zig":                               return "filetype-zig"
    case ".glsl", ".vert", ".frag":            return "filetype-glsl"
    case ".md":                                return "filetype-markdown"
    case ".json":                              return "filetype-json"
    case ".yml", ".yaml":                      return "filetype-yaml"
    case ".xml":                               return "filetype-xml"
    case ".html", ".htm":                      return "filetype-html"
    case ".css":                               return "filetype-css"
    case ".scss", ".sass":                     return "filetype-sass"
    case ".lua":                               return "filetype-lua"
    case ".java":                              return "filetype-java"
    case ".kt", ".kts":                        return "filetype-kotlin"
    case ".cs":                                return "filetype-csharp"
    case ".fs":                                return "filetype-fsharp"
    case ".swift":                             return "filetype-swift"
    case ".rb":                                return "filetype-ruby"
    case ".php":                               return "filetype-php"
    case ".hs":                                return "filetype-haskell"
    case ".ex", ".exs":                        return "filetype-elixir"
    case ".jl":                                return "filetype-julia"
    case ".pl", ".pm":                         return "filetype-perl"
    case ".dart":                              return "filetype-dart"
    case ".scala":                             return "filetype-scala"
    case ".clj", ".cljs":                      return "filetype-clojure"
    case ".erl":                               return "filetype-erlang"
    case ".ml", ".mli":                        return "filetype-ocaml"
    case ".nim":                               return "filetype-nim"
    case ".sh", ".bash", ".zsh":               return "filetype-shell"
    case ".ps1", ".psm1":                      return "filetype-powershell"
    case ".vim":                               return "filetype-vim"
    case ".tex", ".bib":                       return "filetype-latex"
    case ".cmake":                             return "filetype-cmake"
    case ".vue":                               return "filetype-vue"
    case ".svelte":                            return "filetype-svelte"
    case ".graphql", ".gql":                   return "filetype-graphql"
    case ".gitignore", ".gitattributes", ".gitmodules":
        return "filetype-git"
    case ".odin":                              return "odin"
    case ".asm", ".s", ".sql", ".bat", ".slang", ".slangh":
        return "file-code"
    case ".txt", ".toml", ".ini", ".cfg", ".log":
        return "file-text"
    }
    return "file"
}
