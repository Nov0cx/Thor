package thor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:thread"

// Twelve files across two directory levels, walked with a cap of 5, must stop
// at exactly 5 and report that the walk was cut short.
@(test)
test_collect_files_stops_at_the_cap :: proc(t: ^testing.T) {
    root :: "thor_collect_cap.tmp"
    sub, _ := filepath.join({root, "sub"}, context.temp_allocator)
    defer os.remove_all(root)

    testing.expect(t, os.make_directory(root) == nil, "could not create test root")
    testing.expect(t, os.make_directory(sub) == nil, "could not create test subdir")

    for i in 0 ..< 6 {
        path, _ := filepath.join({root, fmt.tprintf("a%d.tmp", i)}, context.temp_allocator)
        testing.expect(t, os.write_entire_file(path, "") == nil, "could not create test file")
    }
    for i in 0 ..< 6 {
        path, _ := filepath.join({sub, fmt.tprintf("b%d.tmp", i)}, context.temp_allocator)
        testing.expect(t, os.write_entire_file(path, "") == nil, "could not create test file")
    }

    files := thor_walk_workspace_files(root, context.temp_allocator, limit = 5, max_depth = 12)
    testing.expect_value(t, len(files), 5)
}

// A finished job built the way thor_refresh_file_index builds one, so the
// join, the free and the inflight count stay valid — matches the
// Shell_Detect_Job stub in terminal_test.odin.
@(private = "file")
file_index_stub_worker :: proc(job: ^File_Index_Job) {}

// A workspace switch while a walk is in flight makes it the wrong folder's
// list once it lands; the reap must throw it away rather than apply it,
// rather than replace an already-ready index with a stale one.
@(test)
test_file_index_reap_ignores_a_stale_workspace :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    thor.workspace_dir = "current"

    job := new(File_Index_Job)
    job.owner = thor
    job.allocator = context.allocator
    job.root = strings.clone("stale")
    append(&job.files, strings.clone("stale/a.odin"))
    thor.inflight_jobs += 1
    job.worker = thread.create_and_start_with_poly_data(job, file_index_stub_worker)

    thor_apply_file_index(thor, job)

    testing.expect(t, !thor.file_index_ready, "a stale walk must not become the ready index")
    testing.expect_value(t, len(thor.file_index), 0)
    testing.expect(t, !thor.file_index_inflight)
    testing.expect_value(t, thor.inflight_jobs, 0)
}

// A refresh requested while one is already running must not start a second
// walk; it coalesces into the dirty flag, picked up once the running one lands.
@(test)
test_file_index_refresh_coalesces :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    thor.workspace_dir = "current"
    thor.file_index_inflight = true

    thor_refresh_file_index(thor)

    testing.expect(t, thor.file_index_dirty, "a refresh while one is running must coalesce into a dirty flag")
    testing.expect_value(t, thor.inflight_jobs, 0)
}
