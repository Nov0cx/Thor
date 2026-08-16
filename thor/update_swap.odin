package thor

// Swapping a staged update into the install, then starting the new binary.
//
// The file mechanics live in update/swap.odin; this is the editor side — the
// order of the teardown, what a failure puts back, and the relaunch. A swap that
// dies part-way is recoverable because every replaced name is renamed aside
// rather than removed: update.install_restore puts the backups back, here on a
// failed swap and at the next start otherwise.

import "core:fmt"
import "core:log"
import "core:os"
import "core:time"

import "../setting"
import "../shell"
import "../update"

// How many times a refused start is retried. A freshly written executable can
// be held for a moment by a scanner, which is not a failure worth reporting.
@(private = "file")
SPAWN_ATTEMPTS :: 5

@(private = "file")
SPAWN_RETRY_DELAY :: 100 * time.Millisecond

// Swaps the staged tree in and starts the new binary. Runs on the main thread
// from thor_poll_update, with no job in flight and nothing else touching the
// install. Leaves should_close set on success, so the run loop falls into
// shutdown and this process exits.
thor_swap_and_relaunch :: proc(thor: ^Thor) {
    thor.update_swap_pending = false
    root := thor.update_swap_root

    // Resolved before the teardown and out of the temp allocator: thor_drain_io
    // frees it, and after the rename /proc/self/exe and proc_pidpath read the
    // path back as thor.old, so resolving it later would start the old build.
    exe, exe_err := os.get_executable_path(context.allocator)
    if exe_err != nil {
        log.errorf("Could not resolve executable path: %v", exe_err)
        thor_update_swap_failed(thor, "Could not find the running Thor", restore = false)
        return
    }
    defer delete(exe)
    install := os.dir(exe) // borrows exe

    // Settle everything that reads or writes the install before it changes.
    thor_shutdown_watcher(thor)
    thor_drain_io(thor)
    thor_save_session(thor)
    // The new process claims the folder, so this one must let go of it first.
    thor_unregister_window(thor.workspace_dir)

    if failed, ok := update.swap_files(install, root, update.LOCKED_NAMES[:]); !ok {
        thor_update_swap_failed(thor, fmt.tprintf("Could not replace %s", failed))
        return
    }
    // Before the swap replaces settings/, since that is what it carries over.
    if carried, ok := update.migrate_json_files(setting.GLOBAL_DIR, setting.USER_DIR); ok {
        log.infof("Carried %d settings files of an older install into %q", carried, setting.USER_DIR)
    }
    if _, failed := update.swap_dirs(install, root, update.SWAPPED_DIRS[:]); failed > 0 {
        log.warnf("%d resource directories were not replaced; the next start puts them back", failed)
    }

    // Past the point of no return: the install is the new build now, so the
    // staged copy has nothing left to offer a retry.
    delete(thor.update_swap_root)
    thor.update_swap_root = ""
    if err := os.remove_all(update.STAGE_DIR); err != nil && os.exists(update.STAGE_DIR) {
        log.warnf("Could not clear %q: %v", update.STAGE_DIR, err)
    }

    if !thor_spawn_updated(exe, thor.workspace_dir) {
        thor_update_swap_stranded(thor)
        return
    }
    log.infof("Updated to Thor %s, restarting", thor.update_version)
    thor.relaunching = true
    thor.should_close = true
}

// Starts the new binary, answering whether it went.
@(private = "file")
thor_spawn_updated :: proc(exe: string, workspace: string) -> bool {
    for _ in 0 ..< SPAWN_ATTEMPTS {
        if shell.spawn(exe, workspace, workspace) {
            return true
        }
        time.sleep(SPAWN_RETRY_DELAY)
    }
    log.errorf("Could not start the updated Thor at %q", exe)
    return false
}

// Reports a swap that did not happen and puts the session back on its feet: the
// watcher and the folder claim go before the swap, so without this the window
// runs on with no live tree and no claim on its folder. The staged tree is kept,
// so the retry costs no second download. `restore` is false only before anything
// was torn down — thor_init_watcher over a live watcher would orphan its thread.
@(private = "file")
thor_update_swap_failed :: proc(thor: ^Thor, message: string, restore := true) {
    if restore {
        update.install_restore(".")
        thor_register_window(thor)
        thor_init_watcher(thor)
    }
    thor.update_state = .Found
    thor_sync_update_button(thor)
    thor_flash_status(thor, message, true)
}

// The swap went through but the new binary did not start. The install is the
// new build, so there is nothing left to install and the backups beside it are
// the old one, which the next start prunes.
@(private = "file")
thor_update_swap_stranded :: proc(thor: ^Thor) {
    thor_register_window(thor)
    thor_init_watcher(thor)
    thor.update_state = .Idle
    thor_sync_update_button(thor)
    thor_flash_status(thor, "Thor was updated. Close it and start it again", true)
}
