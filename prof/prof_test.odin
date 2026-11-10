package prof

import "core:os"
import "core:prof/spall"
import "core:testing"
import "core:thread"

@(test)
test_trace_records_threads :: proc(t: ^testing.T) {
    // Before init every call does nothing.
    thread_begin("unused")
    {
        testing.expect(t, !scope("no trace"), "a zone recorded with no trace open")
    }
    thread_end()
    destroy()
    when !ENABLED {
        return
    }
    PATH :: "bin/test/prof_test.spall"
    if !testing.expect(t, init(PATH), "the trace did not open") {
        return
    }
    defer os.remove(PATH)
    {
        scope("main zone")
        proc_scope()
    }
    worker := thread.create_and_start(proc() {
        thread_begin("worker")
        defer thread_end()
        scope("worker zone")
    })
    thread.join(worker)
    thread.destroy(worker)
    destroy()

    data, err := os.read_entire_file(PATH, context.allocator)
    if !testing.expectf(t, err == nil, "the trace did not read: %v", err) {
        return
    }
    defer delete(data)
    header := size_of(spall.Manual_Stream_Header)
    testing.expect(t, len(data) > header + 2 * size_of(spall.Manual_Buffer_Header), "the trace holds no buffers")
    if len(data) >= header {
        magic := (^spall.Manual_Stream_Header)(raw_data(data)).magic
        testing.expect_value(t, magic, spall.MANUAL_MAGIC)
    }
}
