package thor

import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// A thor.exec with a callback runs on a worker, and the reap queues its output for the run loop.
@(test)
test_plugin_exec_async_reaps_output :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    thor.workspace_dir = "."

    first := thor_plugin_exec_async(thor, "echo thor-exec")
    second := thor_plugin_exec_async(thor, "echo again")
    testing.expect(t, first != second, "two calls got the same id")

    deadline := time.tick_now()
    for time.tick_since(deadline) < 30 * time.Second {
        sync.lock(&thor.io_mutex)
        done := len(thor.finished_plugin_execs) == 2
        sync.unlock(&thor.io_mutex)
        if done {
            break
        }
        time.sleep(time.Millisecond)
    }
    sync.lock(&thor.io_mutex)
    jobs := make([]^Plugin_Exec_Job, len(thor.finished_plugin_execs), context.temp_allocator)
    copy(jobs, thor.finished_plugin_execs[:])
    clear(&thor.finished_plugin_execs)
    sync.unlock(&thor.io_mutex)

    thor_reap_plugin_execs(thor, jobs)
    testing.expect_value(t, thor.inflight_jobs, 0)
    testing.expect_value(t, len(thor.plugin_exec_results), 2)
    for job in thor.plugin_exec_results {
        if job.id == first {
            testing.expectf(t, strings.contains(job.output, "thor-exec"), "output: %q", job.output)
            testing.expect_value(t, job.code, 0)
        }
    }
    thor_free_plugin_execs(thor)
}
