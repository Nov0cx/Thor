// Per-file build targets of the Odin analyzer: the status segment, the picker and the refresh after a change.
package thor

import "core:fmt"
import "core:strings"

import "../lang"
import "../lang/odin"

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

// Lists the build targets for the active Odin file.
thor_cmd_select_build_target :: proc(data: rawptr) {
    thor := cast(^Thor) data
    file := thor_active_open_file(thor)
    if file == nil || !thor_file_has_build_target(thor, file) {
        thor_flash_status(thor, "Open an Odin file to select its build target")
        return
    }
    names := odin.target_names()
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
    thor := cast(^Thor) data
    file := thor_active_open_file(thor)
    if file == nil {
        return
    }
    if !thor_set_file_target(thor, file, choice) {
        thor_flash_status(thor, "Could not set the build target", is_error = true)
        return
    }
    if choice == "" {
        triple, _ := thor_file_build_target(thor, file)
        thor_flash_status(thor, fmt.tprintf("Build target: workspace default (%s)", triple))
    } else {
        thor_flash_status(thor, strings.concatenate({"Build target: ", choice}, context.temp_allocator))
    }
}

// Sets the build target of `file` to `triple`; "" takes the workspace default.
thor_set_file_target :: proc(thor: ^Thor, file: ^Open_File, triple: string) -> bool {
    if thor.odin_engine == nil || !odin.engine_set_target(thor.odin_engine, file.path, triple) {
        return false
    }
    thor_refresh_file_analysis(thor, file)
    return true
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
