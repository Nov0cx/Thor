package thor

import "core:os"
import "core:strings"
import rl "vendor:raylib"

// Live settings reload. The config files live under settings/ (and, for an
// initialized workspace, its .thor/ overlay) rather than the workspace tree the
// file watcher covers, so they are polled here by modification time. An external
// edit — from another editor, or Thor's own Settings modal — reloads and
// re-applies them without a restart.

@(private = "file")
SETTINGS_POLL_INTERVAL :: 0.4

// Config files whose edits trigger a reload, appended to `out` (temp-allocated
// paths for the overlay). settings/ is relative to the exe dir (the CWD).
@(private = "file")
thor_settings_files :: proc(thor: ^Thor, out: ^[dynamic]string) {
    append(out, "settings/settings.json")
    append(out, "settings/keybinds.json")
    append(out, "settings/comments.json")
    if thor.workspace_initialized {
        dir := thor_workspace_config_dir(thor.workspace_dir)
        append(out, strings.concatenate({dir, "/settings.json"}, context.temp_allocator))
        append(out, strings.concatenate({dir, "/keybinds.json"}, context.temp_allocator))
        append(out, strings.concatenate({dir, "/comments.json"}, context.temp_allocator))
    }
}

// A cheap signature of the config files' size and modification time. It changes
// whenever any of them is written, so a mismatch against the stored value means
// an edit landed since the last (re)load.
@(private = "file")
thor_settings_signature :: proc(thor: ^Thor) -> i64 {
    files := make([dynamic]string, context.temp_allocator)
    thor_settings_files(thor, &files)
    sig: i64 = 0
    for path in files {
        if info, err := os.stat(path, context.temp_allocator); err == nil {
            sig = sig * 31 + info.modification_time._nsec
            sig = sig * 31 + info.size
        }
    }
    return sig
}

// Rebaselines the signature so the poll loop treats the current on-disk state as
// clean. Called after every (re)load, including Thor's own persisted changes.
thor_settings_mark_clean :: proc(thor: ^Thor) {
    thor.settings_sig = thor_settings_signature(thor)
}

// Run-loop tick: throttled check that reloads when the config files changed on
// disk since the last load. thor_reload_settings rebaselines, so this fires once
// per external edit.
thor_poll_settings :: proc(thor: ^Thor) {
    now := rl.GetTime()
    if now - thor.settings_poll_time < SETTINGS_POLL_INTERVAL {
        return
    }
    thor.settings_poll_time = now
    if thor_settings_signature(thor) != thor.settings_sig {
        thor_reload_settings(thor)
    }
}
