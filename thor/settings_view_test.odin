package thor

import "core:testing"

import "../lang/lsp"

// A Thor with what the Settings populate reads. No server starts: a client
// launches one only on a document event.
@(private = "file")
settings_test_thor :: proc() -> ^Thor {
    thor := new(Thor)
    thor.lsp_client = lsp.client_create("", false)
    thor_settings_init(thor)
    return thor
}

@(private = "file")
settings_test_destroy :: proc(thor: ^Thor) {
    thor_settings_destroy(thor)
    thor_lsp_probes_destroy(thor)
    backend := lsp.client_backend(thor.lsp_client)
    backend.destroy(backend.data)
    free(thor)
}

// An open after the modal was left on the Workspace tab of a folder with no
// .thor/ still lands on General with its categories.
@(test)
test_settings_open_resets_scope_before_populate :: proc(t: ^testing.T) {
    thor := settings_test_thor()
    defer settings_test_destroy(thor)

    thor.settings.scope = .Workspace
    thor.workspace_initialized = false
    thor_open_settings_view(thor)

    testing.expect_value(t, thor.settings.scope, Settings_Scope.General)
    testing.expect(t, thor.settings_open)
    testing.expect(t, len(thor.settings.categories) > 0)
    testing.expect(t, len(thor.settings.rows) > 0)
}

// A named category is selected after the rows exist; an unknown id keeps the first.
@(test)
test_settings_open_selects_named_category :: proc(t: ^testing.T) {
    thor := settings_test_thor()
    defer settings_test_destroy(thor)

    thor_open_settings_view(thor, "keybindings")
    s := &thor.settings
    testing.expect(t, s.selected_category > 0)
    if s.selected_category < len(s.categories) {
        testing.expect_value(t, s.categories[s.selected_category].id, "keybindings")
    }

    thor_open_settings_view(thor, "no-such-category")
    testing.expect_value(t, s.selected_category, 0)
}
