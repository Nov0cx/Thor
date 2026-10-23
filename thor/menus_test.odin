package thor

import "core:testing"

import "../lang"
import "../textedit"

@(private = "file")
MENU_STUB_KINDS :: bit_set[lang.Request_Kind]{.Definition, .References, .Format}

@(private = "file")
menu_stub_handles :: proc(data: rawptr, ext: string) -> bool {
    return ext == ".stub"
}

@(private = "file")
menu_stub_supports :: proc(data: rawptr, ext: string, kind: lang.Request_Kind) -> bool {
    return kind in MENU_STUB_KINDS
}

@(private = "file")
menu_stub_resolve :: proc(data: rawptr, req: ^lang.Request, res: ^lang.Result) {
    res.ok = true
}

// Reports the enabled flag of the menu item titled `title`.
@(private = "file")
menu_item_enabled :: proc(thor: ^Thor, title: string) -> (enabled, found: bool) {
    for item in thor.menu.items {
        if item.title == title {
            return item.enabled, true
        }
    }
    return false, false
}

@(private = "file")
menu_expect :: proc(t: ^testing.T, thor: ^Thor, title: string, want: bool, loc := #caller_location) {
    enabled, found := menu_item_enabled(thor, title)
    testing.expectf(t, found, "menu has no %q item", title, loc = loc)
    testing.expectf(t, enabled == want, "%q enabled = %v, want %v", title, enabled, want, loc = loc)
}

// The editor menu lists every language item and enables only those the file's backend serves.
@(test)
test_editor_menu_language_items :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    lang.manager_init(&thor.lang_manager)
    defer lang.manager_destroy(&thor.lang_manager)
    lang.manager_register(
        &thor.lang_manager,
        lang.Backend {
            name = "stub",
            handles = menu_stub_handles,
            resolve = menu_stub_resolve,
            supports = menu_stub_supports,
        },
    )
    thor.open_files = make([dynamic]^Open_File)
    defer delete(thor.open_files)
    defer delete(thor.menu.items)
    thor.active_file = make_signal(-1)

    file := new(Open_File)
    defer free(file)
    file.name = "a.stub"
    file.path = "a.stub"
    file.loaded = true
    textedit.init(&file.state)
    defer textedit.destroy(&file.state)
    textedit.set_text(&file.state, "alpha beta\n")
    append(&thor.open_files, file)
    signal_set(&thor.active_file, 0)

    thor_editor_context_menu(thor, {10, 10})
    testing.expect(t, thor.menu_open, "the menu opened")
    menu_expect(t, thor, "Go to Definition", true)
    menu_expect(t, thor, "Find References", true)
    menu_expect(t, thor, "Rename Symbol", false)
    menu_expect(t, thor, "Code Actions", false)
    menu_expect(t, thor, "Signature Help", false)
    menu_expect(t, thor, "Format Document", true)
    menu_expect(t, thor, "Format Selection", true)
    menu_expect(t, thor, "Go to Symbol in File", false)
    menu_expect(t, thor, "Package Documentation", false)
    menu_expect(t, thor, "Copy", true)

    // With a selection, Format Selection needs Format_Range, which the stub does not serve.
    textedit.select_range(&file.state, 0, 5)
    thor_editor_context_menu(thor, {10, 10})
    menu_expect(t, thor, "Format Selection", false)

    // No backend claims a .txt file.
    file.name = "notes.txt"
    file.path = "notes.txt"
    thor_editor_context_menu(thor, {10, 10})
    menu_expect(t, thor, "Go to Definition", false)
    menu_expect(t, thor, "Find References", false)
    menu_expect(t, thor, "Format Document", false)
    menu_expect(t, thor, "Format Selection", false)
    menu_expect(t, thor, "Select All", true)

    // No file open: every language item is disabled.
    signal_set(&thor.active_file, -1)
    thor_editor_context_menu(thor, {10, 10})
    menu_expect(t, thor, "Go to Definition", false)
    menu_expect(t, thor, "Select All", false)
}
