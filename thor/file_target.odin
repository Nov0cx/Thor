// Per-file build targets of the Odin analyzer: the file_targets setting, the status segment, the picker that
// writes the setting and the refresh after a change.
package thor

import "core:log"
import "core:strings"

import "../lang"
import "../lang/odin"
import "../setting"

WORKSPACE_DEFAULT_TARGET :: "Workspace Default"

// True when the Odin analyzer serves `file`.
thor_file_has_build_target :: proc(thor: ^Thor, file: ^Open_File) -> bool {
    return thor.odin_engine != nil && thor.odin_engine.admin_enabled && thor_lang_key(thor, file.name) == ".odin"
}

// The `-target:` value `file` is analyzed for, and true when the file has its own.
thor_file_build_target :: proc(thor: ^Thor, file: ^Open_File) -> (triple: string, own: bool) {
    if !thor_file_has_build_target(thor, file) {
        return "", false
    }
    return odin.engine_target_label(thor.odin_engine, thor.workspace_dir, file.path)
}

// The `-target:` value the file_targets setting gives `path`, "" when the workspace default holds.
thor_file_target_override :: proc(thor: ^Thor, path: string) -> string {
    if len(thor.config.general.file_targets) == 0 {
        return ""
    }
    return setting.file_target(&thor.config, thor_file_language_key(thor, path))
}

// Lists the build targets for the active Odin file. The choice is kept per file in the settings.
thor_cmd_select_build_target :: proc(data: rawptr) {
    thor := cast(^Thor)data
    file := thor_active_open_file(thor)
    if file == nil || !thor_file_has_build_target(thor, file) {
        thor_flash_status(thor, "Open an Odin file to select its build target")
        return
    }
    names  := odin.target_names()
    labels := make([dynamic]string, 0, len(names) + 1, context.temp_allocator)
    values := make([dynamic]string, 0, len(names) + 1, context.temp_allocator)
    append(&labels, WORKSPACE_DEFAULT_TARGET)
    append(&values, "")
    for name in names {
        append(&labels, name)
        append(&values, name)
    }
    triple, own := thor_file_build_target(thor, file)
    thor_select_open(
        thor,
        "Build Target of the File",
        labels[:],
        own ? triple : "",
        thor_build_target_preview,
        thor_build_target_commit,
        thor,
        values = values[:],
    )
}

@(private = "file")
thor_build_target_preview :: proc(_: rawptr, _: string) {}

@(private = "file")
thor_build_target_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor)data
    file := thor_active_open_file(thor)
    if file == nil {
        return
    }
    if !thor_set_file_target(thor, file.path, choice) {
        return
    }
    if choice == "" {
        thor_flash_status(thor, "Build target: workspace default")
    } else {
        thor_flash_status(thor, strings.concatenate({"Build target: ", choice}, context.temp_allocator))
    }
}

// Writes `triple` as the build target of `path` and reloads the settings; the engine takes it at the head of
// the next frame. An empty triple removes the entry, and writes "" only when a glob or a lower layer would
// still set a target.
thor_set_file_target :: proc(thor: ^Thor, path, triple: string) -> bool {
    if _, _, ok := odin.target_from_triple(triple); triple != "" && !ok {
        thor_flash_status(thor, "That build target is not a compiler target", is_error = true)
        return false
    }
    key    := thor_file_language_key(thor, path)
    target := thor_file_settings_path(thor, path)
    if triple != "" {
        if err := setting.persist_file_target(target, key, triple); err != .None {
            thor_settings_save_failed(thor, target, err)
            return false
        }
        thor_reload_settings(thor)
        return true
    }

    if err := setting.remove_file_target(target, key); err != .None {
        thor_settings_save_failed(thor, target, err)
        return false
    }
    thor_reload_settings(thor)
    if thor_file_target_override(thor, path) != "" {
        if err := setting.persist_file_target(target, key, ""); err != .None {
            thor_settings_save_failed(thor, target, err)
            return false
        }
        thor_reload_settings(thor)
    }
    return true
}

// Run-loop head: gives the engine the build target of every open Odin file after a settings reload, and asks
// again about each file whose target moved. Deferred so a reload inside an event changes no request state.
thor_poll_file_targets :: proc(thor: ^Thor) {
    if !thor.file_targets_pending {
        return
    }
    thor.file_targets_pending = false
    thor_apply_file_targets(thor)
}

// Gives the engine the build target the settings set for each open file. The targets of closed files are
// dropped; a file whose target moved is analyzed again.
thor_apply_file_targets :: proc(thor: ^Thor) {
    if thor.odin_engine == nil {
        return
    }
    changed := make([dynamic]^Open_File, context.temp_allocator)
    wanted  := make([dynamic]string, context.temp_allocator)
    for file in thor.open_files {
        if file.closed || thor_lang_key(thor, file.name) != ".odin" {
            continue
        }
        want         := thor_valid_target(thor_file_target_override(thor, file.path))
        current, own := odin.engine_target_label(thor.odin_engine, thor.workspace_dir, file.path)
        if !own {
            current = ""
        }
        if !strings.equal_fold(want, current) {
            append(&changed, file)
        }
        append(&wanted, want)
    }
    odin.engine_clear_targets(thor.odin_engine)
    i := 0
    for file in thor.open_files {
        if file.closed || thor_lang_key(thor, file.name) != ".odin" {
            continue
        }
        if wanted[i] != "" && !odin.engine_set_target(thor.odin_engine, file.path, wanted[i]) {
            log.warnf("Could not set the build target of %q", file.path)
        }
        i += 1
    }
    for file in changed {
        thor_refresh_file_analysis(thor, file)
    }
}

// Gives the engine the build target the settings set for `file`, before its first request.
thor_apply_file_target :: proc(thor: ^Thor, file: ^Open_File) {
    if thor.odin_engine == nil || thor_lang_key(thor, file.name) != ".odin" {
        return
    }
    want := thor_valid_target(thor_file_target_override(thor, file.path))
    if !odin.engine_set_target(thor.odin_engine, file.path, want) {
        log.warnf("Could not set the build target of %q", file.path)
    }
}

// `triple` when the compiler knows it, else "" with a warning.
@(private = "file")
thor_valid_target :: proc(triple: string) -> string {
    if triple == "" {
        return ""
    }
    if _, _, ok := odin.target_from_triple(triple); !ok {
        log.warnf("Settings %s: %q is not a compiler target and was ignored", setting.FILE_TARGETS_SETTING, triple)
        return ""
    }
    return triple
}

// Asks again for the diagnostics, semantic tokens and inlay hints of `file`. A request in flight is
// dropped, since it was made for the old target.
thor_refresh_file_analysis :: proc(thor: ^Thor, file: ^Open_File) {
    for id in ([]u64{thor.semantic_request_id, thor.inlay_request_id, thor.syntax_request_id}) {
        if id != 0 {
            lang.manager_cancel(&thor.lang_manager, id)
        }
    }
    file.semantic_ready = false
    file.highlighted = false
    file.inlay_ready = false
    file.syntax_ready = false
    if file.loaded {
        thor_request_diagnostics(thor, file)
    }
}
