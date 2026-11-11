package thor

import "core:strings"
import "core:testing"
import "core:time"

import "../lockfree"

// A thor.exec with a callback runs on a worker, and the reap queues its output for the run loop.
@(test)
test_plugin_exec_async_reaps_output :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    thor.workspace_dir = "."

    first  := thor_plugin_exec_async(thor, "echo thor-exec")
    second := thor_plugin_exec_async(thor, "echo again")
    testing.expect(t, first != second, "two calls got the same id")

    jobs     := make([dynamic]^Plugin_Exec_Job, context.temp_allocator)
    deadline := time.tick_now()
    for len(jobs) < 2 && time.tick_since(deadline) < 30 * time.Second {
        for job := lockfree.stack_take(&thor.finished_plugin_execs); job != nil; job = job.queue_next {
            append(&jobs, job)
        }
        time.sleep(time.Millisecond)
    }

    thor_reap_plugin_execs(thor, jobs[:])
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
