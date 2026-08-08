package thor

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "../shell"

// The shell detection lands long after startup, so thor_apply_shell_profiles has
// to tell a live terminal list from a shut-down one. A list made without a
// capacity has no backing data, so it reads as nil while it is live.
// Run from the repository root: odin test thor

// A finished detection job, built the way thor_terminals_init builds one so the
// join, the free and the inflight count stay valid.
@(private = "file")
shell_detect_job_stub :: proc(thor: ^Thor, profiles: []shell.Profile) -> ^Shell_Detect_Job {
    job := new(Shell_Detect_Job)
    job.owner = thor
    job.allocator = context.allocator
    job.profiles = profiles
    thor.inflight_jobs += 1
    job.worker = thread.create_and_start_with_poly_data(job, shell_detect_stub_worker)
    return job
}

@(private = "file")
shell_detect_stub_worker :: proc(job: ^Shell_Detect_Job) {}

// Profiles allocated like detected ones, so the drop path frees every part.
@(private = "file")
shell_profiles_stub :: proc(count: int) -> []shell.Profile {
    profiles := make([]shell.Profile, count)
    for &profile, i in profiles {
        profile.id = fmt.aprintf("stub%d", i)
        profile.name = strings.clone("Stub Shell")
        profile.exe = strings.clone("stub")
        profile.args = make([]string, 1)
        profile.args[0] = strings.clone("-i")
    }
    return profiles
}

// Takes the real detection off the queue, the way thor_process_io drains it.
@(private = "file")
shell_detect_job_wait :: proc(thor: ^Thor) -> ^Shell_Detect_Job {
    for {
        sync.lock(&thor.io_mutex)
        job, ok := pop_safe(&thor.finished_shells)
        sync.unlock(&thor.io_mutex)
        if ok {
            return job
        }
        time.sleep(time.Millisecond)
    }
}

// A detection that lands on a live terminal list must fill the shell list. The
// list itself is nil right after thor_terminals_init, so only terminals_live
// proves the state.
@(test)
test_shell_profiles_apply_after_init :: proc(t: ^testing.T) {
    thor: Thor
    thor.finished_shells = make([dynamic]^Shell_Detect_Job)
    defer delete(thor.finished_shells)

    thor_terminals_init(&thor)
    testing.expect(t, thor.terminals_live, "init must mark the terminal list live")

    // A stale list proves the assignment ran: the drop path returns before it.
    stale := shell_profiles_stub(1)
    defer shell.profiles_destroy(stale)
    thor.shell_profiles = stale

    // No profile keeps thor_terminal_open, and with it every widget, out of the
    // test.
    thor_apply_shell_profiles(&thor, shell_detect_job_stub(&thor, nil))
    testing.expect_value(t, len(thor.shell_profiles), 0)
    // The stale list is the test's to free, whatever the call left behind.
    thor.shell_profiles = nil

    detected := shell_detect_job_wait(&thor)
    thor_terminals_shutdown(&thor)
    testing.expect(t, !thor.terminals_live, "shutdown must clear the live flag")

    // The real detection lands after shutdown, so it only frees its profiles.
    thor_apply_shell_profiles(&thor, detected)
    testing.expect_value(t, len(thor.shell_profiles), 0)
    testing.expect_value(t, thor.inflight_jobs, 0)
}

// A detection that lands after shutdown has no console to fill: it frees the
// profiles and leaves the shell list empty.
@(test)
test_shell_profiles_dropped_after_shutdown :: proc(t: ^testing.T) {
    thor: Thor

    job := shell_detect_job_stub(&thor, shell_profiles_stub(2))
    thor_apply_shell_profiles(&thor, job)

    testing.expect_value(t, len(thor.shell_profiles), 0)
    testing.expect_value(t, len(thor.shell_choices), 0)
    testing.expect_value(t, thor.inflight_jobs, 0)
}
