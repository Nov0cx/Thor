package thor

import "core:testing"

import "../plugin"

// A file_languages entry moves one file to another language; its neighbours
// keep the language their name gives, and an unknown name falls back to it.
@(test)
test_file_language_override_routes_highlighting :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    plugin.manager_init(&thor.plugins)
    defer plugin.manager_destroy(&thor.plugins)
    plugin.manager_load(&thor.plugins)
    thor.config.general.file_languages = make(map[string]string)
    defer delete(thor.config.general.file_languages)

    thor.workspace_dir = "thor_file_lang_ws.tmp"
    thor.config.general.file_languages["src/boot.asm"] = "FASM"
    thor.config.general.file_languages["src/odd.asm"] = "No Such Language"

    boot  := Open_File{path = "thor_file_lang_ws.tmp/src/boot.asm", name = "boot.asm"}
    other := Open_File{path = "thor_file_lang_ws.tmp/src/other.asm", name = "other.asm"}
    odd   := Open_File{path = "thor_file_lang_ws.tmp/src/odd.asm", name = "odd.asm"}

    testing.expect_value(t, thor_file_language_key(thor, boot.path), "src/boot.asm")
    testing.expect_value(t, thor_file_highlight_key(thor, &boot), plugin.language_key(&thor.plugins, "FASM"))
    testing.expect_value(t, thor_file_highlight_key(thor, &other), ".asm")
    testing.expect_value(t, thor_file_highlight_key(thor, &odd), ".asm")
}
