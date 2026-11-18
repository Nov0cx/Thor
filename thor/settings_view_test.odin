package thor

import "core:testing"

import "../lang/lsp"
import "../setting"

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
    thor_ext_clear(thor)
    thor_lsp_probes_destroy(thor)
    backend := lsp.client_backend(thor.lsp_client)
    backend.destroy(backend.data)
    free(thor)
}

// An open after the modal was left on the Project tab of a folder with no
// .thor/ still lands on General with its categories.
@(test)
test_settings_open_resets_scope_before_populate :: proc(t: ^testing.T) {
    thor := settings_test_thor()
    defer settings_test_destroy(thor)

    thor.settings.scope = .Project
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

// On/off settings are switches on the page they belong to, and a keybind row
// shows a readable name, not the action id.
@(test)
test_settings_rows_toggle_and_keybind_names :: proc(t: ^testing.T) {
    thor := settings_test_thor()
    defer settings_test_destroy(thor)

    thor_open_settings_view(thor)
    found_toggle, found_keybind := false, false
    for row in thor.settings.rows {
        switch row.id {
        case "format_on_save":
            found_toggle = true
            testing.expect_value(t, row.kind, Settings_Row_Kind.Toggle)
            testing.expect_value(t, row.category, "editor")
        case "add_cursor_above":
            found_keybind = true
            testing.expect_value(t, row.kind, Settings_Row_Kind.Keybind)
            testing.expect(t, row.label != row.id, "a keybind row shows its action id")
        }
    }
    testing.expect(t, found_toggle, "no Format on Save row")
    testing.expect(t, found_keybind, "no add_cursor_above row")
}

// The Project tab lists only the keys a .thor/ layer applies, and This folder
// lists the personal keys but no keybinds.
@(test)
test_settings_scope_rows :: proc(t: ^testing.T) {
    thor := settings_test_thor()
    defer settings_test_destroy(thor)
    thor.config = setting.load(setting.GLOBAL_DIR)
    defer setting.destroy(&thor.config)
    thor.workspace_initialized = true

    thor_open_settings_view(thor)
    thor.settings.scope = .Project
    thor_populate_settings_view(thor)
    for cat in thor.settings.categories {
        testing.expectf(t, cat.id == "editor" || cat.id == "language" || cat.id == "language_servers", "the Project tab shows category %q", cat.id)
    }
    for row in thor.settings.rows {
        if row.category == "editor" && row.kind != .Info {
            testing.expectf(t, setting.is_workspace_key(row.id), "the Project tab shows personal key %q", row.id)
        }
    }

    thor.settings.scope = .Folder
    thor_populate_settings_view(thor)
    has_theme := false
    for row in thor.settings.rows {
        testing.expectf(t, row.category != "keybindings" && row.id != "open_folder_in", "This folder shows %q", row.id)
        has_theme ||= row.id == "theme"
    }
    testing.expect(t, has_theme, "This folder has no theme row")
}

// A GUI write goes to the file of its scope tab, and outside the modal a
// personal key goes to user/ even when the folder has a .thor/.
@(test)
test_settings_write_routing :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    thor.workspace_dir = "proj"
    thor.workspace_initialized = true

    testing.expect_value(t, thor_active_settings_path(thor, "theme"), setting.USER_SETTINGS)
    testing.expect_value(t, thor_active_settings_path(thor, "tab_width"), "proj/.thor/settings.lua")
    testing.expect_value(t, thor_active_keybinds_path(thor), "user/keybinds.lua")

    thor.settings_open = true
    thor.settings.scope = .Folder
    testing.expect_value(t, thor_active_settings_path(thor, "tab_width"), thor_local_settings_path(thor.workspace_dir))
    thor.settings.scope = .Project
    testing.expect_value(t, thor_active_settings_path(thor, "theme"), "proj/.thor/settings.lua")
    thor.settings.scope = .General
    testing.expect_value(t, thor_active_settings_path(thor, "tab_width"), setting.USER_SETTINGS)
    thor.workspace_initialized = false
    thor.settings_open = false
    testing.expect_value(t, thor_active_settings_path(thor, "tab_width"), setting.USER_SETTINGS)
}

// With no folder open the "This folder" scope falls back to General.
@(test)
test_settings_folder_scope_needs_a_folder :: proc(t: ^testing.T) {
    thor := settings_test_thor()
    defer settings_test_destroy(thor)

    thor.workspace_dir = ""
    thor.settings.scope = .Folder
    thor_populate_settings_view(thor)

    testing.expect_value(t, thor.settings.scope, Settings_Scope.General)
}
