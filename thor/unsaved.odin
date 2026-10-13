// What keeps unsaved edits when a tab, a folder or the window closes. Thor
// saves by itself, so a close writes the buffer instead of asking. It asks only
// for a buffer the disk refused, and a buffer still unsaved at exit is kept as
// a backup that the next open of the file restores.
package thor

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"

import "../textedit"

BACKUP_DIR :: "sessions/backups"

// True when the buffer is not the text on disk.
thor_file_dirty :: proc(file: ^Open_File) -> bool {
    if !file.loaded || file.is_image || file.is_model {
        return false
    }
    thor_sync_saved(file)
    return file.state.revision != file.saved_revision
}

// Backup file of one path: sessions/backups/<path-key>.txt.
@(private = "file")
thor_backup_file :: proc(path: string, allocator := context.temp_allocator) -> string {
    return strings.concatenate({BACKUP_DIR, "/", thor_path_key(path), ".txt"}, allocator)
}

// Keeps the buffer text of a file the disk refused. False when the backup could
// not be written either.
thor_write_backup :: proc(file: ^Open_File) -> bool {
    for dir in ([2]string{"sessions", BACKUP_DIR}) {
        if os.exists(dir) {
            continue
        }
        if err := os.make_directory(dir); err != nil {
            log.warnf("Cannot make %q: %v", dir, err)
            return false
        }
    }
    target := thor_backup_file(file.path)
    if err := os.write_entire_file(target, textedit.text(&file.state)); err != nil {
        log.warnf("Cannot keep the unsaved edits of %q: %v", file.path, err)
        return false
    }
    log.infof("Kept the unsaved edits of %q in %q", file.path, target)
    return true
}

// Puts the backup of a just-loaded file back into its buffer as one undo
// entry, so the buffer is unsaved again and undo gives the text on disk. The
// backup is deleted: the buffer holds the edits now.
thor_restore_backup :: proc(thor: ^Thor, file: ^Open_File) {
    target := thor_backup_file(file.path)
    if !os.exists(target) {
        return
    }
    data, read_err := os.read_entire_file(target, context.temp_allocator)
    if read_err != nil {
        log.warnf("Cannot read the backup %q: %v", target, read_err)
        return
    }
    if err := os.remove(target); err != nil {
        log.warnf("Cannot delete the backup %q: %v", target, err)
    }
    if textedit.replace_text(&file.state, string(data)) {
        textedit.set_single_cursor(&file.state, 0)
        thor_flash_status(thor, fmt.tprintf("Restored the unsaved edits of %s", file.name))
    }
}

// Writes every unsaved buffer and waits for the writes. A buffer the disk
// refuses is kept as a backup. For the points where the buffers go away: a
// folder switch and the exit.
thor_flush_dirty_files :: proc(thor: ^Thor) {
    // The second pass takes a buffer that was edited while its save ran.
    for _ in 0 ..< 2 {
        any := false
        for file in thor.open_files {
            if thor_file_dirty(file) {
                thor_save_file(thor, file)
                any = true
            }
        }
        thor_drain_io(thor)
        if !any {
            break
        }
    }
    for file in thor.open_files {
        if thor_file_dirty(file) {
            thor_write_backup(file)
        }
    }
}

// Closes a tab the user asked to close. An unsaved buffer is written first; the
// write outlives the tab. A buffer the disk refused stays open: with `ask` the
// user is asked whether to drop its edits. True when the tab closed.
thor_request_close_file :: proc(thor: ^Thor, index: int, ask := true) -> bool {
    if index < 0 || index >= len(thor.open_files) {
        return false
    }
    file := thor.open_files[index]
    if thor_file_dirty(file) {
        if file.save_failed {
            if ask {
                thor.close_prompt_file = file
                delete(thor.close_prompt)
                thor.close_prompt = fmt.aprintf("\"%s\" could not be saved. Close it and lose the edits?", file.name)
                thor_palette_confirm(thor, thor.close_prompt, thor_confirm_close_discard, thor)
            } else {
                thor_flash_status(thor, fmt.tprintf("%s is not saved and stays open", file.name), is_error = true)
            }
            return false
        }
        // A save that runs now holds older text: the reap writes again.
        thor_save_file(thor, file)
    }
    thor_close_file(thor, index)
    return true
}

// The confirm of thor_request_close_file: the tab closes with its edits.
@(private = "file")
thor_confirm_close_discard :: proc(data: rawptr) {
    thor := cast(^Thor) data
    target := thor.close_prompt_file
    thor.close_prompt_file = nil
    for file, index in thor.open_files {
        if file == target {
            thor_close_file(thor, index)
            return
        }
    }
}

// Closes every tab that can close, last first so the indexes hold.
thor_request_close_all :: proc(thor: ^Thor) {
    for index := len(thor.open_files) - 1; index >= 0; index -= 1 {
        thor_request_close_file(thor, index, ask = false)
    }
}
