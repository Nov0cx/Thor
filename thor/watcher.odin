package thor

import "../watch"
import "../widgets"

// Workspace file watcher wiring. The generic watcher (../watch) reports disk
// changes under the workspace root; here two subscribers consume them — the
// explorer (tree + git refresh) and the open buffers (reload on external edits).
// A third consumer, the language backend's resident index, can subscribe the same
// way as it grows.

// Starts the watcher over the workspace and registers its subscribers. A watcher
// that fails to start (e.g. the workspace is not a real directory) leaves the
// editor fully functional, just without live disk updates.
thor_init_watcher :: proc(thor: ^Thor) {
    if !watch.watcher_init(&thor.watcher, thor.workspace_dir) {
        return
    }
    watch.watcher_subscribe(&thor.watcher, thor_watch_explorer, thor)
    watch.watcher_subscribe(&thor.watcher, thor_watch_content, thor)
}

// Run-loop tick: dispatch the buffered changes to the subscribers (which set the
// coalescing flags and kick reloads), then apply the batched explorer refresh at
// most once — a save or a `git` command can fire a burst of events.
thor_poll_watcher :: proc(thor: ^Thor) {
    watch.watcher_poll(&thor.watcher)

    if thor.watch_tree_dirty {
        thor.watch_tree_dirty = false
        widgets.tree_refresh(thor.tree)
    }
    if thor.watch_git_dirty {
        thor.watch_git_dirty = false
        thor_refresh_git_status(thor)
    }
}

thor_shutdown_watcher :: proc(thor: ^Thor) {
    watch.watcher_destroy(&thor.watcher)
}

// Explorer subscriber: a created/deleted path changes the tree shape; any change
// (content included) can change git status. Both are coalesced to one refresh per
// poll via the dirty flags.
@(private = "file")
thor_watch_explorer :: proc(data: rawptr, change: watch.Change) {
    thor := cast(^Thor) data
    if change.kind != .Modified {
        thor.watch_tree_dirty = true
    }
    thor.watch_git_dirty = true
}

// Open-buffer subscriber: when a file open in a tab changes on disk, reload it.
// thor_reload_file guards the cases that must not reload (unsaved edits, our own
// save landing, an in-flight reload), so this just routes the path to its file.
@(private = "file")
thor_watch_content :: proc(data: rawptr, change: watch.Change) {
    thor := cast(^Thor) data
    if change.kind == .Deleted {
        return // a vanished file keeps its buffer so unsaved work can be re-saved
    }
    for file in thor.open_files {
        if thor_same_path(file.path, change.path) {
            thor_reload_file(thor, file)
            return
        }
    }
}
