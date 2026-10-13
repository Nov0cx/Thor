// External-change reload for the open files the workspace watcher does not
// cover: a file outside the workspace, and every file when no folder is open.
// A worker reads the time and size of each one once a second; a change reloads
// the buffer through the same path a watcher event takes.
package thor

import "base:runtime"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

@(private = "file")
OUTSIDE_POLL_INTERVAL :: 1 * time.Second

// What one file looked like on disk at the last look.
Disk_Stamp :: struct {
    time:  time.Time,
    size:  i64,
    known: bool,
}

@(private = "file")
Outside_Entry :: struct {
    path:  string, // owned
    stamp: Disk_Stamp,
}

Outside_Stat_Job :: struct {
    owner:     ^Thor,
    allocator: runtime.Allocator,
    worker:    ^thread.Thread,
    entries:   [dynamic]Outside_Entry, // owned, with the paths in it
}

// True for an open file no watcher event can name.
@(private = "file")
thor_file_is_outside :: proc(thor: ^Thor, file: ^Open_File) -> bool {
    if !file.loaded || file.closed || file.is_image || file.is_model {
        return false
    }
    if !thor.watcher.running || thor.workspace_dir == "" {
        return true
    }
    return !thor_path_within(file.path, thor.workspace_dir)
}

// Run-loop tick: starts one look at the outside files when the last one is done
// and old enough.
thor_poll_outside_files :: proc(thor: ^Thor) {
    if thor.outside_stat_inflight || time.tick_since(thor.outside_stat_at) < OUTSIDE_POLL_INTERVAL {
        return
    }
    thor.outside_stat_at = time.tick_now()

    job: ^Outside_Stat_Job
    for file in thor.open_files {
        if !thor_file_is_outside(thor, file) {
            continue
        }
        if job == nil {
            job = new(Outside_Stat_Job)
            job.owner = thor
            job.allocator = context.allocator
            job.entries = make([dynamic]Outside_Entry)
        }
        append(&job.entries, Outside_Entry {path = strings.clone(file.path)})
    }
    if job == nil {
        return
    }
    thor.outside_stat_inflight = true
    thor.inflight_jobs += 1
    job.worker = thread.create_and_start_with_poly_data(job, outside_stat_worker)
}

@(private = "file")
outside_stat_worker :: proc(job: ^Outside_Stat_Job) {
    context.allocator = job.allocator
    defer free_all(context.temp_allocator)

    for &entry in job.entries {
        info, err := os.stat(entry.path, context.temp_allocator)
        if err != nil {
            continue // a file that is gone keeps its buffer
        }
        entry.stamp = {time = info.modification_time, size = info.size, known = true}
    }

    sync.lock(&job.owner.io_mutex)
    append(&job.owner.finished_outside_stats, job)
    sync.unlock(&job.owner.io_mutex)
}

// Drains a finished look (called from thor_process_io): a file whose stamp moved
// since the last look is reloaded. The first look only records the stamp.
thor_apply_outside_stats :: proc(thor: ^Thor, job: ^Outside_Stat_Job) {
    thread.join(job.worker)
    thread.destroy(job.worker)
    thor.outside_stat_inflight = false
    thor.inflight_jobs -= 1

    for entry in job.entries {
        defer delete(entry.path)
        if !entry.stamp.known {
            continue
        }
        file, _ := thor_find_open_file(thor, entry.path)
        if file == nil {
            continue
        }
        changed := file.disk_stamp.known && file.disk_stamp != entry.stamp
        file.disk_stamp = entry.stamp
        if changed {
            thor_reload_file(thor, file)
        }
    }
    delete(job.entries)
    free(job)
}
