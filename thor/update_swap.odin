package thor

// Replacing the install with a staged update, then starting the new binary.
//
// Every replaced name is renamed aside before its new copy lands, never removed
// first. A rename inside one directory is a metadata operation, so it is legal
// on the running image and on a loaded library, and it is what leaves a swap
// that dies part-way recoverable: update.install_cleanup_leftovers puts the
// backups back at the next start. The one window it cannot cover is between the
// binary's rename and its copy, where there is no binary left to run it.

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../setting"
import "../shell"
import "../update"

// The binary this platform runs.
@(private = "file")
EXE :: "thor" + update.EXE_SUFFIX

// The library the Windows build loads, which is locked exactly like the binary
// and so moves with it, as one group.
@(private = "file")
LOCKED_FILES :: [?]string{EXE, "lua54.dll"} when ODIN_OS == .Windows else [?]string{EXE}

// Swaps the staged tree in and starts the new binary. Runs on the main thread
// from thor_poll_update, with no job in flight and nothing else touching the
// install. Leaves should_close set on success, so the run loop falls into
// shutdown and this process exits.
thor_swap_and_relaunch :: proc(thor: ^Thor) {
    root := thor.update_swap_root
    defer {
        delete(thor.update_swap_root)
        thor.update_swap_root = ""
    }

    exe, exe_err := os.get_executable_path(context.temp_allocator)
    if exe_err != nil {
        log.errorf("Could not resolve executable path: %v", exe_err)
        thor_update_swap_failed(thor, "Could not find the running Thor")
        return
    }

    // Settle everything that reads or writes the install before it changes.
    thor_shutdown_watcher(thor)
    thor_drain_io(thor)
    thor_save_session(thor)
    // The new process claims the folder, so this one must let go of it first.
    thor_unregister_window(thor.workspace_dir)

    if !thor_swap_locked_files(thor, root) {
        return
    }
    // Before the swap replaces settings/, since that is what it saves.
    thor_migrate_user_settings()
    thor_swap_directories(thor, root)

    // The staged copy has served its purpose; a leftover only costs disk and
    // the next start clears it anyway.
    if err := os.remove_all(update.STAGE_DIR); err != nil {
        log.warnf("Could not clear %q: %v", update.STAGE_DIR, err)
    }
    if !shell.spawn(exe, thor.workspace_dir, thor.workspace_dir) {
        // The new build is already in place, so the user only has to start it.
        log.errorf("Could not start the updated Thor")
        thor_flash_status(thor, "Thor was updated but could not restart", true)
        return
    }
    log.infof("Updated to Thor %s, restarting", thor.update_version)
    thor.should_close = true
}

// Moves the binary and the library it loads aside and copies the new ones in.
// Both move or neither does: a failure after the first rename is the only case
// that needs a rollback, and this is where it is done.
@(private = "file")
thor_swap_locked_files :: proc(thor: ^Thor, root: string) -> bool {
    moved := make([dynamic]string, 0, len(LOCKED_FILES), context.temp_allocator)
    rollback := proc(moved: []string) {
        for name in moved {
            if err := os.rename(thor_old_name(name), name); err != nil {
                log.errorf("Could not undo the move of %q: %v", name, err)
            }
        }
    }

    for name in LOCKED_FILES {
        old := thor_old_name(name)
        // A backup from an earlier update. It has to go before the rename, and
        // a failure to remove it is a failure to replace the file.
        if err := os.remove(old); err != nil && os.exists(old) {
            log.errorf("Could not remove %q: %v", old, err)
            rollback(moved[:])
            thor_update_swap_failed(thor, fmt.tprintf("Could not replace %s", name))
            return false
        }
        if err := os.rename(name, old); err != nil {
            log.errorf("Could not move %q aside: %v", name, err)
            rollback(moved[:])
            thor_update_swap_failed(thor, fmt.tprintf("Could not replace %s", name))
            return false
        }
        append(&moved, name)
    }
    for name in moved {
        source, join_err := filepath.join({root, name}, context.temp_allocator)
        copy_err: os.Error = join_err == nil ? os.copy_file(name, source) : .Invalid_Path
        if copy_err != nil {
            log.errorf("Could not copy %q into place: %v", name, copy_err)
            // Whatever landed is half a build, so it goes before the backups
            // come back.
            for done in moved {
                if remove_err := os.remove(done); remove_err != nil && os.exists(done) {
                    log.errorf("Could not remove the half-written %q: %v", done, remove_err)
                }
            }
            rollback(moved[:])
            thor_update_swap_failed(thor, fmt.tprintf("Could not write %s", name))
            return false
        }
    }
    when ODIN_OS != .Windows {
        if err := os.change_mode(EXE, os.perm_number(0o755)); err != nil {
            log.warnf("Could not make %q executable: %v", EXE, err)
        }
    }
    return true
}

// Replaces the resource directories. A failure here leaves the old copy under
// its .old name for the next start to restore, so it is logged and the swap
// carries on rather than leaving the binary newer than nothing.
@(private = "file")
thor_swap_directories :: proc(thor: ^Thor, root: string) {
    dirs := make([dynamic]string, 0, 4, context.temp_allocator)
    when ODIN_OS == .Darwin {
        // The dylibs are mapped into this process. Replacing the directory
        // entry is safe; copying over them in place would truncate a mapped
        // file and fault the process on its next page.
        append(&dirs, "libs")
    }
    for dir in update.SWAPPED_DIRS {
        append(&dirs, dir)
    }

    for dir in dirs {
        source, join_err := filepath.join({root, dir}, context.temp_allocator)
        if join_err != nil {
            log.errorf("Could not build the source path for %q: %v", dir, join_err)
            continue
        }
        if !os.exists(source) {
            continue
        }
        old := thor_old_name(dir)
        if err := os.remove_all(old); err != nil && os.exists(old) {
            log.errorf("Could not remove %q: %v", old, err)
            continue
        }
        if err := os.rename(dir, old); err != nil && os.exists(dir) {
            log.errorf("Could not move %q aside: %v", dir, err)
            continue
        }
        if err := os.copy_directory_all(dir, source); err != nil {
            log.errorf("Could not copy %q: %v", source, err)
        }
    }
}

// Carries an install made before settings/ and user/ were split over into the
// new layout. An install that already has user/ is left alone, so this runs at
// most once: the swap is the only place that knows settings/ still holds what
// the user wrote, and a fresh install never reaches it.
@(private = "file")
thor_migrate_user_settings :: proc() {
    if os.is_dir(setting.USER_DIR) || !os.is_dir(setting.GLOBAL_DIR) {
        return
    }
    entries, err := os.read_all_directory_by_path(setting.GLOBAL_DIR, context.temp_allocator)
    if err != nil {
        log.warnf("Could not read %q: %v", setting.GLOBAL_DIR, err)
        return
    }
    if make_err := os.make_directory_all(setting.USER_DIR); make_err != nil {
        log.errorf("Could not create %q: %v", setting.USER_DIR, make_err)
        return
    }
    for entry in entries {
        if entry.type == .Directory || !strings.has_suffix(entry.name, ".json") {
            continue
        }
        destination, dest_err := filepath.join({setting.USER_DIR, entry.name}, context.temp_allocator)
        from, from_err := filepath.join({setting.GLOBAL_DIR, entry.name}, context.temp_allocator)
        if dest_err != nil || from_err != nil {
            log.warnf("Could not build a path for %q: %v", entry.name, dest_err != nil ? dest_err : from_err)
            continue
        }
        if copy_err := os.copy_file(destination, from); copy_err != nil {
            log.warnf("Could not carry %q over: %v", entry.name, copy_err)
        }
    }
    log.infof("Carried the settings of an older install into %q", setting.USER_DIR)
}

// The name a replaced file is kept under until the next start.
@(private = "file")
thor_old_name :: proc(name: string) -> string {
    return fmt.tprintf("%s%s", name, update.OLD_SUFFIX)
}

// Reports a swap that did not happen. The release is still there, so the button
// stays and the user can try again.
@(private = "file")
thor_update_swap_failed :: proc(thor: ^Thor, message: string) {
    thor.update_state = .Found
    thor_sync_update_button(thor)
    thor_flash_status(thor, message, true)
    update.install_cleanup_leftovers()
}
