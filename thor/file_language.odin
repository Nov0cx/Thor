// Per-file language overrides: the file_languages setting and the picker that
// writes it.
package thor

import "core:strings"

import "../plugin"
import "../setting"

// The file_languages key of `path`: relative to the workspace with `/`
// separators when the file is in it, else the absolute path.
thor_file_language_key :: proc(thor: ^Thor, path: string) -> string {
    full, _ := strings.replace_all(thor_canon_path(path), "\\", "/", context.temp_allocator)
    if thor.workspace_dir != "" && thor_path_within(path, thor.workspace_dir) {
        root := thor_canon_path(thor.workspace_dir)
        if len(full) > len(root) {
            return strings.trim_left(full[len(root):], "/")
        }
    }
    return full
}

// The language name the setting gives `path`, "" when the name decides.
thor_file_language_override :: proc(thor: ^Thor, path: string) -> string {
    if len(thor.config.general.file_languages) == 0 {
        return ""
    }
    return setting.file_language(&thor.config, thor_file_language_key(thor, path))
}

// The plugin key `file` highlights with: the override's language when one is
// set and registered, else the key its name gives.
thor_file_highlight_key :: proc(thor: ^Thor, file: ^Open_File) -> string {
    if name := thor_file_language_override(thor, file.path); name != "" {
        if key := plugin.language_key(&thor.plugins, name); key != "" {
            return key
        }
    }
    return thor_highlight_key(&thor.plugins, file.name)
}

// The settings file an override for `path` goes to: the workspace's .thor/
// for a file in the workspace, else the user layer.
@(private = "file")
thor_file_language_settings_path :: proc(thor: ^Thor, path: string) -> string {
    if thor.workspace_dir != "" && thor_path_within(path, thor.workspace_dir) {
        return strings.concatenate(
            {thor_workspace_config_dir(thor.workspace_dir), "/", setting.SETTINGS_FILE},
            context.temp_allocator,
        )
    }
    return setting.USER_SETTINGS
}

AUTO_DETECT_LANGUAGE :: "Auto Detect"

// Lists the languages for the active file. The choice is kept per file in the
// workspace's settings.
thor_cmd_change_language :: proc(data: rawptr) {
    thor := cast(^Thor) data
    file := thor_active_open_file(thor)
    if file == nil {
        thor_flash_status(thor, "Open a file to change its language")
        return
    }
    names := plugin.language_names(&thor.plugins, context.temp_allocator)
    labels := make([dynamic]string, 0, len(names) + 1, context.temp_allocator)
    values := make([dynamic]string, 0, len(names) + 1, context.temp_allocator)
    append(&labels, AUTO_DETECT_LANGUAGE)
    append(&values, "")
    for name in names {
        append(&labels, name)
        append(&values, name)
    }

    current := thor_file_language_override(thor, file.path)
    for name in names {
        if strings.equal_fold(name, current) {
            current = name
        }
    }
    thor_select_open(
        thor,
        "Language of the File",
        labels[:],
        current,
        thor_change_language_preview,
        thor_change_language_commit,
        thor,
        values = values[:],
    )
}

@(private = "file")
thor_change_language_preview :: proc(_: rawptr, _: string) {}

@(private = "file")
thor_change_language_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    file := thor_active_open_file(thor)
    if file == nil {
        return
    }
    if !thor_set_file_language(thor, file.path, choice) {
        return
    }
    if choice == "" {
        thor_flash_status(thor, "Language: detected from the file name")
    } else {
        thor_flash_status(thor, strings.concatenate({"Language: ", choice}, context.temp_allocator))
    }
}

// Writes `name` as the language of `path` and reloads the settings. An empty
// name removes the entry, and writes "" only when a glob or a lower layer would
// still set a language.
thor_set_file_language :: proc(thor: ^Thor, path, name: string) -> bool {
    key := thor_file_language_key(thor, path)
    target := thor_file_language_settings_path(thor, path)
    if name != "" {
        if err := setting.persist_file_language(target, key, name); err != .None {
            thor_settings_save_failed(thor, target, err)
            return false
        }
        thor_reload_settings(thor)
        return true
    }

    if err := setting.remove_file_language(target, key); err != .None {
        thor_settings_save_failed(thor, target, err)
        return false
    }
    thor_reload_settings(thor)
    if thor_file_language_override(thor, path) != "" {
        if err := setting.persist_file_language(target, key, ""); err != .None {
            thor_settings_save_failed(thor, target, err)
            return false
        }
        thor_reload_settings(thor)
    }
    return true
}
