package thor

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"

import "../setting"
import ui "../vendor/loom/loom"
import "../font"
import "../theme"
import "../editview"
// Built-in theme used when none is configured or the configured one fails to load.
DEFAULT_THEME :: "mjolnir"

// Shipped themes. Replaced wholesale by every build and by every update, so
// nothing Thor writes may land here.
SHIPPED_THEME_DIR :: "assets/themes"
// User themes: what the theme editor writes, beside setting.USER_DIR. Gitignored,
// never staged, never swapped by an update.
USER_THEME_DIR :: "user/themes"

// The file `name` resolves to: the user copy shadows the shipped one. Falls back
// to the shipped path when neither exists, so a failure names the shipped file.
thor_theme_path :: proc(name: string, allocator := context.temp_allocator) -> string {
    user := thor_user_theme_path(name, allocator)
    if os.exists(user) {
        return user
    }
    return strings.concatenate({SHIPPED_THEME_DIR, "/", name, ".json"}, allocator)
}

// Where an edit to `name` is written: always the user layer.
thor_user_theme_path :: proc(name: string, allocator := context.temp_allocator) -> string {
    return strings.concatenate({USER_THEME_DIR, "/", name, ".json"}, allocator)
}

// Loads the theme named in settings (falling back to the default) into
// thor.theme. Called once at startup, before the widgets are built.
thor_load_active_theme :: proc(thor: ^Thor) {
    name := setting.theme_name(&thor.config)
    if name == "" {
        name = DEFAULT_THEME
    }
    thor_load_theme_by_name(thor, name)
}

// Replaces thor.theme with the theme file `name` resolves to, freeing the
// previous one. Falls back to the built-in default when the file is unreadable.
thor_load_theme_by_name :: proc(thor: ^Thor, name: string) {
    loaded, ok := theme.load(thor_theme_path(name))
    if !ok && name != DEFAULT_THEME {
        log.warnf("Theme %q failed to load; using %q", name, DEFAULT_THEME)
        theme.destroy(&loaded)
        // theme.load returns the built-in palette and logs on failure, so the
        // fallback always lands on a complete palette.
        loaded, _ = theme.load(thor_theme_path(DEFAULT_THEME))
    }

    theme.destroy(&thor.theme)
    thor.theme = loaded
    // A palette read from disk, so any generated preview is gone.
    thor.theme_preview_generated = false
    log.infof("Loaded theme: %s", thor.theme.name)
}

// Theme names available in both theme directories (base names, no extension),
// sorted, each listed once — a user theme and a shipped one of the same name are
// one entry, the user's.
thor_available_themes :: proc(allocator := context.temp_allocator) -> []string {
    names := make([dynamic]string, allocator)
    seen := make(map[string]bool, 16, context.temp_allocator)
    for dir in ([]string {USER_THEME_DIR, SHIPPED_THEME_DIR}) {
        pattern := strings.concatenate({dir, "/*.json"}, context.temp_allocator)
        // A fresh install has no user/themes; that is not a failure of the listing.
        matches, err := filepath.glob(pattern, context.temp_allocator)
        if err != nil {
            continue
        }
        for path in matches {
            name := strings.trim_suffix(filepath.base(path), ".json")
            if name in seen {
                continue
            }
            seen[name] = true
            append(&names, strings.clone(name, allocator))
        }
    }
    slice.sort(names[:])
    return names[:]
}

// Installed themes as parallel (display name, file base) slices: `labels` are the
// human names from each theme's "name" field, `files` the base names used to load
// and persist them. Aligned by index, and owned by `thor` — borrowed until the
// next call.
//
// A display name costs a whole palette parse, so the pair is cached and rebuilt
// only when the set of theme files or the newest of their modification times
// moves. Both theme directories sit beside the binary, outside the watched
// workspace, so the stat is what notices an edit. It stats the resolved path, so
// adding or removing a user copy also moves the stamp.
thor_available_theme_choices :: proc(thor: ^Thor) -> (labels, files: []string) {
    names := thor_available_themes(context.temp_allocator)
    stamp := i64(0)
    for file in names {
        path := thor_theme_path(file)
        if info, err := os.stat(path, context.temp_allocator); err == nil {
            stamp = max(stamp, info.modification_time._nsec)
        }
    }
    if thor.theme_labels != nil && thor.theme_stamp == stamp && slice.equal(thor.theme_files, names) {
        return thor.theme_labels, thor.theme_files
    }

    thor_free_theme_choices(thor)
    labels_out := make([dynamic]string)
    files_out := make([dynamic]string)
    for file in names {
        path := thor_theme_path(file)
        loaded, _ := theme.load(path)
        append(&labels_out, strings.clone(loaded.name))
        append(&files_out, strings.clone(file))
        theme.destroy(&loaded)
    }
    thor.theme_labels = labels_out[:]
    thor.theme_files = files_out[:]
    thor.theme_stamp = stamp
    return thor.theme_labels, thor.theme_files
}

// Frees the cached theme choices. Called before a rebuild and at shutdown.
thor_free_theme_choices :: proc(thor: ^Thor) {
    for label in thor.theme_labels {
        delete(label)
    }
    for file in thor.theme_files {
        delete(file)
    }
    delete(thor.theme_labels)
    delete(thor.theme_files)
    thor.theme_labels = nil
    thor.theme_files = nil
}

// Reapplies thor.theme. The tree reads it through thor_push_theme each frame, so
// only the syntax spans that bake a color in need work.
thor_apply_theme :: proc(thor: ^Thor) {
    // Syntax spans bake in theme colors, so every open file needs new ones. Only
    // mark them stale: the per-frame pane pass recolors the files on screen with
    // a window to scope to, and one off screen costs nothing until it is shown.
    for file in thor.open_files {
        file.highlighted = false
    }
}

// Preferences: Change Theme -> pick from the installed themes in a dialog that
// previews each one live as the selection moves.
thor_cmd_change_theme :: proc(data: rawptr) {
    thor := cast(^Thor) data
    labels, files := thor_available_theme_choices(thor)
    if len(files) == 0 {
        thor_plugin_print(thor, "\nNo themes are installed.\n")
        return
    }
    current := setting.theme_name(&thor.config)
    if current == "" {
        current = DEFAULT_THEME
    }
    thor_select_open(
        thor,
        "Change Theme",
        labels,
        current,
        thor_theme_preview,
        thor_theme_commit,
        thor,
        files,
    )
}

// Loads the theme and applies it live (no persistence): the dialog's preview.
thor_theme_preview :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    thor_load_theme_by_name(thor, choice)
    thor_apply_theme(thor)
}

// Applies the chosen theme and persists it as the new default.
thor_theme_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    thor_theme_preview(thor, choice)
    // The generator seeds follow the palette the user just chose.
    thor_reset_theme_seeds(thor)
    thor_persist_string_setting(thor, "theme", choice)
}

// Preferences: Change Font -> pick from the registered text families in a dialog
// that previews each one live as the selection moves.
thor_cmd_change_font :: proc(data: rawptr) {
    thor := cast(^Thor) data
    families := font.family_names()
    if len(families) == 0 {
        thor_plugin_print(thor, "\nNo font families are registered.\n")
        return
    }
    // Warm the unbaked families off-thread, so moving the selection previews
    // without a main-thread bake.
    sizes := [2]i32 {cast(i32) setting.font_size(&thor.config), WELCOME_TITLE_FONT_SIZE}
    font.prebake_async(families, sizes[:])
    thor_select_open(
        thor,
        "Change Font",
        families,
        font.default_family(),
        thor_font_preview,
        thor_font_commit,
        thor,
    )
}

// Switches the default text font live (no persistence): the dialog's preview.
// Text is drawn through the default family everywhere, so it shows next frame.
thor_font_preview :: proc(_: rawptr, choice: string) {
    font.set_default_family(choice)
}

// Applies the chosen font and persists it as the new default.
thor_font_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    if !font.set_default_family(choice) {
        thor_plugin_print(thor, strings.concatenate({"\nFont ", choice, " is not available.\n"}, context.temp_allocator))
        return
    }
    thor_persist_string_setting(thor, "font", choice)
}

// Picker rows for the ligatures setting.
@(private = "file")
LIGATURE_LABELS := [?]string {"On", "Off"}

// The ligatures setting as its picker row.
thor_ligatures_label :: proc(config: ^setting.Settings) -> string {
    return setting.ligatures(config) ? LIGATURE_LABELS[0] : LIGATURE_LABELS[1]
}

// Preferences: Ligatures -> draw the font's ligatures ("->" as one glyph), or
// the plain glyphs. Shaping runs per frame, so the choice shows at once.
thor_cmd_change_ligatures :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_select_open(
        thor,
        "Ligatures",
        LIGATURE_LABELS[:],
        thor_ligatures_label(&thor.config),
        thor_ligatures_preview,
        thor_ligatures_commit,
        thor,
    )
}

// Switches ligatures live (no persistence): the dialog's preview.
thor_ligatures_preview :: proc(_: rawptr, choice: string) {
    font.set_ligatures(choice == LIGATURE_LABELS[0])
}

// Applies the choice and persists it.
thor_ligatures_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    enabled := choice == LIGATURE_LABELS[0]
    font.set_ligatures(enabled)
    if !setting.persist_bool(thor_active_settings_path(thor), "ligatures", enabled) {
        thor_flash_status(thor, SETTINGS_SAVE_FAILED, is_error = true)
        return
    }
    thor_reload_settings(thor)
}

// Icon families sharing a pack group are alternatives for the same set of icon
// names. The primary group backs the unprefixed UI names (buttons, tabbar,
// statusbar, tree chevrons/folder); the file group backs the tree's `filetype-`
// names, one glyph per language.
PRIMARY_ICON_PACK_GROUP :: "primary"
FILE_ICON_PACK_GROUP :: "files"

// Pack each group falls back to when settings.json names none.
DEFAULT_ICON_PACK :: "material"
DEFAULT_FILE_ICON_PACK :: "mdi"

// Makes `configured` the active pack for `group`, falling back to `fallback`
// when it is unset or names a pack that did not register.
thor_activate_icon_pack :: proc(group, configured, fallback: string) {
    if configured != "" && font.icon_set_active_pack(group, configured) {
        return
    }
    if configured != "" {
        log.warnf("Configured icon pack %q is not available; using %q", configured, fallback)
    }
    if !font.icon_set_active_pack(group, fallback) {
        log.warnf("Default icon pack %q is not available for group %q", fallback, group)
    }
}

// Opens a live-preview picker over the packs installed in `group`. `current` is
// the configured pack, empty when unset — the active one is the default then.
@(private = "file")
thor_open_icon_pack_dialog :: proc(
    thor: ^Thor,
    group, title, current: string,
    preview, commit: Select_Choice_Proc,
) {
    labels, names := font.icon_pack_choices(group)
    if len(names) == 0 {
        thor_plugin_print(thor, "\nNo icon packs are installed.\n")
        return
    }
    // Warm the unbaked packs off-thread, so the preview switch draws at once.
    font.prebake_async(names)
    active := current
    if active == "" {
        active = font.icon_active_pack(group)
    }
    thor_select_open(
        thor,
        title,
        labels,
        active,
        preview,
        commit,
        thor,
        names,
    )
}

// Applies `choice` to `group` and persists it under `key`; the reload writes it
// back into the config and redraws the settings view.
@(private = "file")
thor_icon_pack_apply :: proc(thor: ^Thor, group, key, choice: string) {
    if !font.icon_set_active_pack(group, choice) {
        thor_plugin_print(thor, strings.concatenate({"\nIcon pack ", choice, " is not available.\n"}, context.temp_allocator))
        return
    }
    thor_persist_string_setting(thor, key, choice)
}

// Writes one string settings key to the active layer and reloads, which is what
// re-applies it and refreshes the modal. A write that did not land is reported
// and changes nothing, so the row keeps reading what is actually on disk.
@(private)
thor_persist_string_setting :: proc(thor: ^Thor, key, value: string) {
    if !setting.persist_string(thor_active_settings_path(thor), key, value) {
        thor_flash_status(thor, SETTINGS_SAVE_FAILED, is_error = true)
        return
    }
    thor_reload_settings(thor)
}

// Preferences: Change Icon Pack -> pick from the installed primary icon packs
// (e.g. Tabler Icons, Material Icons) in a dialog that previews each one live.
thor_cmd_change_icon_pack :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_open_icon_pack_dialog(
        thor, PRIMARY_ICON_PACK_GROUP, "Change Icon Pack", setting.icon_pack_name(&thor.config),
        thor_icon_pack_preview, thor_icon_pack_commit,
    )
}

// Switches the active icon pack live (no persistence): the dialog's preview.
// Icon names are resolved at draw time, so this shows next frame.
thor_icon_pack_preview :: proc(_: rawptr, choice: string) {
    font.icon_set_active_pack(PRIMARY_ICON_PACK_GROUP, choice)
}

// Applies the chosen icon pack and persists it as the new default.
thor_icon_pack_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    thor_icon_pack_apply(thor, PRIMARY_ICON_PACK_GROUP, "icon_pack", choice)
}

// Preferences: Change File Icon Pack -> pick which pack draws the file tree's
// per-language icons (e.g. Devicon brand logos, Material Design Icons).
thor_cmd_change_file_icon_pack :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_open_icon_pack_dialog(
        thor, FILE_ICON_PACK_GROUP, "Change File Icon Pack", setting.file_icon_pack_name(&thor.config),
        thor_file_icon_pack_preview, thor_file_icon_pack_commit,
    )
}

thor_file_icon_pack_preview :: proc(_: rawptr, choice: string) {
    font.icon_set_active_pack(FILE_ICON_PACK_GROUP, choice)
}

thor_file_icon_pack_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    thor_icon_pack_apply(thor, FILE_ICON_PACK_GROUP, "file_icon_pack", choice)
}
