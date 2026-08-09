// Tests for the Manager seam itself: dispatch, cancellation, the worker pool
// and the debounce slots, driven by a stub backend so no real analysis runs.
// The in-client Odin backend has its own tests in lang/odin.
package lang

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// A Backend that parks inside `resolve` until the test releases it, so a cancel
// can be observed landing mid-flight. Counters are touched from both the worker
// and the test thread, hence the atomics.
@(private = "file")
Probe :: struct {
    started:   int,
    release:   bool,
    cancelled: int, // resolve calls that saw the cancellation flag
    resolved:  int, // resolve calls that ran to completion
}

@(private = "file")
probe_handles :: proc(data: rawptr, ext: string) -> bool {
    return ext == ".probe"
}

@(private = "file")
probe_resolve :: proc(data: rawptr, req: ^Request, res: ^Result) {
    p := cast(^Probe) data
    sync.atomic_add(&p.started, 1)
    for !sync.atomic_load(&p.release) {
        time.sleep(time.Millisecond)
    }
    if request_cancelled(req) {
        sync.atomic_add(&p.cancelled, 1)
        return
    }
    sync.atomic_add(&p.resolved, 1)
    res.ok = true
}

@(private = "file")
probe_backend :: proc(p: ^Probe) -> Backend {
    return Backend{data = p, name = "probe", handles = probe_handles, resolve = probe_resolve}
}

// A Backend that fills the three optional vtable entries a subprocess client
// needs: per-kind support, unsolicited results, and document events. Kept apart
// from Probe so the tests above keep the nil vtable an in-client engine leaves.
// Main thread only, so no atomics.
@(private = "file")
Push_Probe :: struct {
    unsupported: bit_set[Request_Kind], // `supports` answers false for these
    queued:      [dynamic]Request_Kind, // one unsolicited result each, oldest first
    events:      [dynamic]Doc_Event,
    allocator:   runtime.Allocator, // the Manager's, as a real backend would hold
}

@(private = "file")
push_handles :: proc(data: rawptr, ext: string) -> bool {
    return ext == ".push"
}

@(private = "file")
push_supports :: proc(data: rawptr, ext: string, kind: Request_Kind) -> bool {
    p := cast(^Push_Probe) data
    return kind not_in p.unsupported
}

@(private = "file")
push_resolve :: proc(data: rawptr, req: ^Request, res: ^Result) {
    res.ok = true
}

@(private = "file")
push_poll :: proc(data: rawptr, res: ^Result) -> bool {
    p := cast(^Push_Probe) data
    if len(p.queued) == 0 {
        return false
    }
    kind := p.queued[0]
    ordered_remove(&p.queued, 0)
    res.kind = kind
    res.ok = true
    // Owned output uses the Manager's allocator, so result_free reaches it.
    res.report.scope = strings.clone("/w/a.push", p.allocator)
    res.report.items = make([dynamic]Diagnostic, p.allocator)
    append(
        &res.report.items,
        Diagnostic{
            path = strings.clone("/w/a.push", p.allocator),
            line = 1,
            col = 1,
            severity = .Error,
            message = strings.clone("pushed", p.allocator),
        },
    )
    return true
}

@(private = "file")
push_notify :: proc(data: rawptr, event: Doc_Event, path, ext, source: string, revision: u64) {
    p := cast(^Push_Probe) data
    append(&p.events, event)
}

@(private = "file")
push_backend :: proc(p: ^Push_Probe) -> Backend {
    return Backend {
        data = p,
        name = "push",
        handles = push_handles,
        resolve = push_resolve,
        supports = push_supports,
        poll = push_poll,
        notify = push_notify,
    }
}

// Spins (bounded, so a wedged worker fails the test instead of hanging it) until
// an atomic counter reaches `want`.
@(private = "file")
wait_for :: proc(counter: ^int, want: int) -> bool {
    for _ in 0 ..< 2000 {
        if sync.atomic_load(counter) >= want {
            return true
        }
        time.sleep(time.Millisecond)
    }
    return false
}

@(private = "file")
count_results :: proc(user: rawptr, res: ^Result) {
    n := cast(^int) user
    n^ += 1
}

// Drains every in-flight job, counting the results that reached the handler.
@(private = "file")
drain_manager :: proc(m: ^Manager) -> int {
    delivered := 0
    for manager_busy(m) {
        manager_dispatch(m, &delivered, count_results)
        time.sleep(time.Millisecond)
    }
    manager_dispatch(m, &delivered, count_results)
    return delivered
}

@(test)
test_cancel_drops_result :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    p := Probe{}
    manager_register(&m, probe_backend(&p))

    id := manager_request(&m, .Hover, "a.probe", ".probe", "", 0, 0, "")
    testing.expect(t, id != 0, "expected the probe backend to claim .probe")
    testing.expect(t, wait_for(&p.started, 1), "worker never started")

    // Cancel while the worker is parked, then let it run on to its check.
    testing.expect(t, manager_cancel(&m, id), "expected the in-flight id to be cancellable")
    sync.atomic_store(&p.release, true)

    delivered := drain_manager(&m)
    testing.expect(t, sync.atomic_load(&p.cancelled) == 1, "the backend did not observe the cancellation")
    testing.expect(t, sync.atomic_load(&p.resolved) == 0, "a cancelled request should not produce a result")
    testing.expectf(t, delivered == 0, "a cancelled result must not reach the handler (got %d)", delivered)

    // The job is reaped, so its id is no longer cancellable.
    testing.expect(t, !manager_cancel(&m, id), "a reaped id should not be cancellable")
}

@(test)
test_request_latest_supersedes :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    p := Probe{}
    manager_register(&m, probe_backend(&p))

    // The first request parks in the backend; the second supersedes it.
    first := manager_request(&m, .Completion, "a.probe", ".probe", "", 0, 0, "")
    testing.expect(t, wait_for(&p.started, 1), "first worker never started")
    second := manager_request_latest(&m, .Completion, "a.probe", ".probe", "", 0, 0, "")
    testing.expect(t, first != second, "expected a fresh id for the replacement")
    sync.atomic_store(&p.release, true)

    delivered := drain_manager(&m)
    testing.expect(t, sync.atomic_load(&p.cancelled) == 1, "the superseded request should have been cancelled")
    testing.expect(t, sync.atomic_load(&p.resolved) == 1, "the replacement request should have resolved")
    testing.expectf(t, delivered == 1, "only the latest result should reach the handler (got %d)", delivered)
}

@(test)
test_cancel_kind_leaves_others :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    p := Probe{}
    manager_register(&m, probe_backend(&p))

    hover := manager_request(&m, .Hover, "a.probe", ".probe", "", 0, 0, "")
    defn := manager_request(&m, .Definition, "a.probe", ".probe", "", 0, 0, "")
    testing.expect(t, wait_for(&p.started, 2), "both workers never started")

    // Cancelling by kind must not touch a request of a different kind.
    testing.expectf(t, manager_cancel_kind(&m, .Hover) == 1, "expected exactly one Hover cancelled")
    testing.expect(t, hover != defn, "expected distinct ids")
    sync.atomic_store(&p.release, true)

    delivered := drain_manager(&m)
    testing.expect(t, sync.atomic_load(&p.cancelled) == 1, "only the Hover should have been cancelled")
    testing.expect(t, sync.atomic_load(&p.resolved) == 1, "the Definition should have resolved")
    testing.expectf(t, delivered == 1, "only the Definition result should be delivered (got %d)", delivered)
}

@(test)
test_busy_kinds_reports_in_flight :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    p := Probe{}
    manager_register(&m, probe_backend(&p))

    testing.expect(t, manager_busy_kinds(&m) == {}, "an idle manager should report no work")

    manager_request(&m, .Hover, "a.probe", ".probe", "", 0, 0, "")
    references := manager_request(&m, .References, "a.probe", ".probe", "", 0, 0, "")
    testing.expect(t, wait_for(&p.started, 2), "both workers never started")
    testing.expect(t, manager_busy_kinds(&m) == {.Hover, .References}, "both kinds should be reported in flight")

    // A cancelled request is on its way out; the indicator must not name it.
    testing.expect(t, manager_cancel(&m, references), "expected the in-flight id to be cancellable")
    testing.expect(t, manager_busy_kinds(&m) == {.Hover}, "a cancelled request should drop out of the busy set")

    sync.atomic_store(&p.release, true)
    drain_manager(&m)
    testing.expect(t, manager_busy_kinds(&m) == {}, "a drained manager should report no work")
}

@(test)
test_pool_caps_concurrency :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    p := Probe{}
    manager_register(&m, probe_backend(&p))

    n := manager_worker_count(&m)
    testing.expectf(t, n >= WORKERS_MIN && n <= WORKERS_MAX, "pool size %d out of bounds", n)

    // More requests than there are workers: the surplus waits in the queue
    // instead of spawning a thread each.
    total := n + 3
    for _ in 0 ..< total {
        testing.expect(t, manager_request(&m, .Hover, "a.probe", ".probe", "", 0, 0, "") != 0, "dispatch failed")
    }
    testing.expect(t, wait_for(&p.started, n), "the pool never filled")
    time.sleep(20 * time.Millisecond) // long enough for a stray worker to have started
    testing.expectf(t, sync.atomic_load(&p.started) == n, "%d jobs ran at once, the pool caps at %d", sync.atomic_load(&p.started), n)

    // Releasing the parked jobs frees the workers, which then drain the queue.
    sync.atomic_store(&p.release, true)
    delivered := drain_manager(&m)
    testing.expectf(t, sync.atomic_load(&p.started) == total, "expected all %d jobs to run eventually", total)
    testing.expectf(t, delivered == total, "expected %d results (got %d)", total, delivered)
}

@(test)
test_queued_job_cancelled_before_it_starts :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    p := Probe{}
    manager_register(&m, probe_backend(&p))

    n := manager_worker_count(&m)
    for _ in 0 ..< n {
        manager_request(&m, .Hover, "a.probe", ".probe", "", 0, 0, "")
    }
    testing.expect(t, wait_for(&p.started, n), "the pool never filled")

    // This one has no worker yet, so cancelling it must keep it out of the
    // backend entirely rather than have `resolve` poll and return.
    queued := manager_request(&m, .Hover, "a.probe", ".probe", "", 0, 0, "")
    testing.expect(t, manager_cancel(&m, queued), "a queued job should be cancellable")

    sync.atomic_store(&p.release, true)
    delivered := drain_manager(&m)
    testing.expectf(t, sync.atomic_load(&p.started) == n, "the cancelled job should never have reached the backend")
    testing.expectf(t, sync.atomic_load(&p.cancelled) == 0, "the backend should not have observed the cancellation itself")
    testing.expectf(t, delivered == n, "expected %d results (got %d)", n, delivered)
}

@(test)
test_debounce_collapses_burst :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    p := Probe{}
    manager_register(&m, probe_backend(&p))
    sync.atomic_store(&p.release, true) // nothing to park for here

    // A burst of keystrokes: each queues a request, none dispatches yet.
    first := manager_request_debounced(&m, .Completion, "a.probe", ".probe", "", 0, 0, "")
    last: u64
    for _ in 0 ..< 4 {
        last = manager_request_debounced(&m, .Completion, "a.probe", ".probe", "", 0, 0, "")
    }
    testing.expect(t, first != last, "each keystroke should reserve a fresh id")
    testing.expect(t, manager_debounce_pending(&m, .Completion), "the last request should still be queued")
    testing.expect(t, !manager_busy(&m), "a debounced request must not dispatch before its delay")
    testing.expect(t, sync.atomic_load(&p.started) == 0, "no worker should have run during the burst")

    testing.expectf(t, manager_flush_debounced(&m, force = true) == 1, "the burst should flush as one request")
    testing.expect(t, !manager_debounce_pending(&m, .Completion), "the slot should be empty after a flush")

    delivered := drain_manager(&m)
    testing.expectf(t, sync.atomic_load(&p.started) == 1, "expected exactly one worker for the whole burst")
    testing.expectf(t, delivered == 1, "expected one result from the burst (got %d)", delivered)
}

@(test)
test_debounce_delay_elapses :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    p := Probe{}
    manager_register(&m, probe_backend(&p))
    sync.atomic_store(&p.release, true)

    manager_request_debounced(&m, .Signature_Help, "a.probe", ".probe", "", 0, 0, "", delay = time.Millisecond)
    // Not yet due: the unforced flush leaves it queued.
    testing.expectf(t, manager_flush_debounced(&m) == 0, "flushed before the delay elapsed")

    for _ in 0 ..< 2000 {
        if manager_flush_debounced(&m) == 1 {
            break
        }
        time.sleep(time.Millisecond)
    }
    testing.expect(t, !manager_debounce_pending(&m, .Signature_Help), "the delay elapsed but nothing dispatched")

    delivered := drain_manager(&m)
    testing.expectf(t, delivered == 1, "expected the debounced request's result (got %d)", delivered)
}

@(test)
test_debounce_cancelled_never_dispatches :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    p := Probe{}
    manager_register(&m, probe_backend(&p))
    sync.atomic_store(&p.release, true)

    // Cancelling by kind drops the queued request...
    manager_request_debounced(&m, .Completion, "a.probe", ".probe", "", 0, 0, "")
    testing.expectf(t, manager_cancel_kind(&m, .Completion) == 1, "expected the queued request to be cancelled")
    testing.expectf(t, manager_flush_debounced(&m, force = true) == 0, "a cancelled request must not dispatch")

    // ...as does cancelling it by its reserved id.
    id := manager_request_debounced(&m, .Completion, "a.probe", ".probe", "", 0, 0, "")
    testing.expect(t, manager_cancel(&m, id), "a queued request should be cancellable by id")
    testing.expectf(t, manager_flush_debounced(&m, force = true) == 0, "a cancelled request must not dispatch")

    // An explicit request supersedes a queued one of the same kind: only the
    // explicit one runs, so the debounced answer can't land on top of it.
    queued := manager_request_debounced(&m, .Completion, "a.probe", ".probe", "", 0, 0, "")
    now := manager_request_latest(&m, .Completion, "a.probe", ".probe", "", 0, 0, "")
    testing.expect(t, queued != now, "expected a fresh id for the explicit request")
    testing.expectf(t, manager_flush_debounced(&m, force = true) == 0, "the queued request should have been dropped")

    delivered := drain_manager(&m)
    testing.expectf(t, sync.atomic_load(&p.started) == 1, "only the explicit request should have run")
    testing.expectf(t, delivered == 1, "expected only the explicit request's result (got %d)", delivered)
}

// An EXCLUSIVE_KINDS request waits in its debounce slot while one of its kind is
// in flight, rather than on a worker: a compiler run cannot be interrupted, so a
// second one blocking on it would occupy the second of the pool's WORKERS_MIN
// threads for the whole run.
@(test)
test_exclusive_kind_waits_in_its_slot :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    p := Probe{}
    manager_register(&m, probe_backend(&p))

    // The first check parks in the backend, standing in for a compiler run.
    manager_request(&m, .Diagnostics, "a.probe", ".probe", "", 0, 0, "")
    testing.expect(t, wait_for(&p.started, 1), "the first check never started")

    // The next save queues another. It supersedes the running check, which
    // cannot be interrupted, so the slot holds it — a forced flush included.
    manager_request_debounced(&m, .Diagnostics, "a.probe", ".probe", "", 0, 0, "")
    testing.expectf(t, manager_flush_debounced(&m, force = true) == 0, "the queued check dispatched under a running one")
    testing.expect(t, manager_debounce_pending(&m, .Diagnostics), "the queued check should still hold its slot")
    testing.expectf(
        t,
        sync.atomic_load(&p.started) == 1,
        "the queued check took a worker (%d started)",
        sync.atomic_load(&p.started),
    )

    // Once the run is reaped the gate opens and the held slot dispatches.
    sync.atomic_store(&p.release, true)
    delivered := drain_manager(&m)
    testing.expectf(t, manager_flush_debounced(&m, force = true) == 1, "the queued check never dispatched")
    delivered += drain_manager(&m)

    testing.expect(t, !manager_debounce_pending(&m, .Diagnostics), "the slot should empty once the run is reaped")
    testing.expectf(
        t,
        sync.atomic_load(&p.started) == 2,
        "the queued check should run after the first (%d started)",
        sync.atomic_load(&p.started),
    )
    testing.expectf(t, delivered == 1, "expected only the queued check's result (got %d)", delivered)
}

// Language intelligence turned off refuses every dispatch, whatever backend
// claims the extension, and turning it back on restores it.
@(test)
test_disabled_manager_refuses_requests :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    p := Probe{}
    manager_register(&m, probe_backend(&p))
    sync.atomic_store(&p.release, true)

    manager_set_enabled(&m, false)
    testing.expect(t, !manager_supports(&m, ".probe"), "a disabled manager must claim no extension")
    testing.expectf(t, manager_request(&m, .Hover, "a.probe", ".probe", "", 0, 0, "") == 0, "a disabled manager dispatched")
    testing.expectf(
        t,
        manager_request_debounced(&m, .Completion, "a.probe", ".probe", "", 0, 0, "") == 0,
        "a disabled manager queued a debounced request",
    )
    testing.expect(t, !manager_debounce_pending(&m, .Completion), "a refused request must fill no slot")

    manager_set_enabled(&m, true)
    testing.expect(t, manager_supports(&m, ".probe"), "the backend should be reachable again")
    testing.expect(t, manager_request(&m, .Hover, "a.probe", ".probe", "", 0, 0, "") != 0, "dispatch failed after re-enabling")
    testing.expectf(t, drain_manager(&m) == 1, "expected the re-enabled request's result")
}

// One feature off stops that kind alone: the extension is still handled and
// every other kind still dispatches.
@(test)
test_feature_gate_is_per_kind :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    p := Probe{}
    manager_register(&m, probe_backend(&p))
    sync.atomic_store(&p.release, true)

    manager_set_features(&m, FEATURES_ALL - {.Hover})
    testing.expect(t, manager_supports(&m, ".probe"), "one gated kind must not unclaim the extension")
    testing.expect(t, !manager_allows(&m, ".probe", .Hover), "the gated kind should be refused")
    testing.expect(t, manager_allows(&m, ".probe", .Definition), "an ungated kind should be allowed")
    testing.expectf(t, manager_request(&m, .Hover, "a.probe", ".probe", "", 0, 0, "") == 0, "the gated kind dispatched")
    testing.expect(t, manager_request(&m, .Definition, "a.probe", ".probe", "", 0, 0, "") != 0, "an ungated kind was refused")
    testing.expectf(t, drain_manager(&m) == 1, "expected only the ungated kind's result")

    // The master switch overrides the gate in the other direction.
    manager_set_enabled(&m, false)
    testing.expect(t, !manager_allows(&m, ".probe", .Definition), "the master switch must gate every kind")
}

// A feature turned off while it is working stops there: the result of the run it
// had in flight never reaches the handler.
@(test)
test_disabling_feature_cancels_inflight :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    p := Probe{}
    manager_register(&m, probe_backend(&p))

    testing.expect(t, manager_request(&m, .Hover, "a.probe", ".probe", "", 0, 0, "") != 0, "dispatch failed")
    testing.expect(t, wait_for(&p.started, 1), "worker never started")

    manager_set_features(&m, FEATURES_ALL - {.Hover})
    sync.atomic_store(&p.release, true)

    delivered := drain_manager(&m)
    testing.expect(t, sync.atomic_load(&p.cancelled) == 1, "the backend did not observe the cancellation")
    testing.expectf(t, delivered == 0, "a gated-off result must not reach the handler (got %d)", delivered)
}

// Every kind has its own config name, and each one reads back as that kind.
@(test)
test_feature_names_round_trip :: proc(t: ^testing.T) {
    for kind in Request_Kind {
        name := feature_name(kind)
        testing.expectf(t, name != "", "%v has no config name", kind)
        parsed, ok := feature_from_name(name)
        testing.expectf(t, ok && parsed == kind, "%q read back as %v", name, parsed)
    }
    _, ok := feature_from_name("not_a_feature")
    testing.expect(t, !ok, "an unknown name must not name a kind")
}

// A result no request asked for reaches the handler through the same per-frame
// drain, and the queue empties: the channel a server pushing diagnostics uses.
@(test)
test_pushed_result_reaches_handler :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    p := Push_Probe{allocator = m.allocator}
    defer delete(p.queued)
    defer delete(p.events)
    manager_register(&m, push_backend(&p))

    append(&p.queued, Request_Kind.Diagnostics)
    append(&p.queued, Request_Kind.Diagnostics)

    delivered := 0
    manager_dispatch(&m, &delivered, count_results)
    testing.expectf(t, delivered == 2, "expected both pushed results (got %d)", delivered)
    testing.expect(t, len(p.queued) == 0, "the drain should have emptied the queue")

    manager_dispatch(&m, &delivered, count_results)
    testing.expectf(t, delivered == 2, "an empty poll must deliver nothing (got %d)", delivered)
}

// The feature gate covers the push channel too, so a kind the user turned off
// cannot arrive through the back door.
@(test)
test_pushed_result_of_gated_kind_is_dropped :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    p := Push_Probe{allocator = m.allocator}
    defer delete(p.queued)
    defer delete(p.events)
    manager_register(&m, push_backend(&p))

    manager_set_features(&m, FEATURES_ALL - {.Diagnostics})
    append(&p.queued, Request_Kind.Diagnostics)

    delivered := 0
    manager_dispatch(&m, &delivered, count_results)
    testing.expectf(t, delivered == 0, "a gated-off push must not reach the handler (got %d)", delivered)
    testing.expect(t, len(p.queued) == 0, "the push should still have been taken and freed")

    // The master switch gates it as well.
    manager_set_features(&m, FEATURES_ALL)
    manager_set_enabled(&m, false)
    append(&p.queued, Request_Kind.Diagnostics)
    manager_dispatch(&m, &delivered, count_results)
    testing.expectf(t, delivered == 0, "a push must not outlive the master switch (got %d)", delivered)
}

// A backend that answers only some kinds refuses those it cannot, while still
// claiming the extension: the difference manager_allows exists to report.
@(test)
test_supports_gates_kind_not_extension :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    p := Push_Probe{allocator = m.allocator, unsupported = {.Rename}}
    defer delete(p.queued)
    defer delete(p.events)
    manager_register(&m, push_backend(&p))

    testing.expect(t, manager_supports(&m, ".push"), "one unsupported kind must not unclaim the extension")
    testing.expect(t, !manager_allows(&m, ".push", .Rename), "the unsupported kind should be refused")
    testing.expect(t, manager_allows(&m, ".push", .Definition), "a supported kind should be allowed")

    testing.expectf(t, manager_request(&m, .Rename, "a.push", ".push", "", 0, 0, "", "x") == 0, "the unsupported kind dispatched")
    testing.expectf(
        t,
        manager_request_debounced(&m, .Rename, "a.push", ".push", "", 0, 0, "") == 0,
        "the unsupported kind filled a debounce slot",
    )
    testing.expect(t, !manager_debounce_pending(&m, .Rename), "a refused request must fill no slot")

    testing.expect(t, manager_request(&m, .Definition, "a.push", ".push", "", 0, 0, "") != 0, "a supported kind was refused")
    testing.expectf(t, drain_manager(&m) == 1, "expected the supported kind's result")
}

// Document events reach the backend that claims the extension, in order, and
// only while the seam is on.
@(test)
test_notify_reaches_backend :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    p := Push_Probe{allocator = m.allocator}
    defer delete(p.queued)
    defer delete(p.events)
    manager_register(&m, push_backend(&p))

    manager_notify(&m, .Opened, "a.push", ".push", "x", 1)
    manager_notify(&m, .Changed, "a.push", ".push", "xy", 2)
    manager_notify(&m, .Saved, "a.push", ".push", "xy", 2)
    manager_notify(&m, .Closed, "a.push", ".push", "", 2)
    testing.expectf(t, len(p.events) == 4, "expected four events (got %d)", len(p.events))
    testing.expect(t, p.events[0] == .Opened && p.events[3] == .Closed, "events should arrive in order")

    // An extension no backend claims, and a backend with no notify, are both
    // silent rather than an error.
    manager_notify(&m, .Opened, "a.other", ".other", "", 1)
    testing.expectf(t, len(p.events) == 4, "an unclaimed extension must reach no backend (got %d)", len(p.events))

    manager_set_enabled(&m, false)
    manager_notify(&m, .Changed, "a.push", ".push", "z", 3)
    testing.expectf(t, len(p.events) == 4, "the master switch must gate document events (got %d)", len(p.events))
}

@(test)
test_debounce_slots_are_per_kind :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    p := Probe{}
    manager_register(&m, probe_backend(&p))
    sync.atomic_store(&p.release, true)

    manager_request_debounced(&m, .Completion, "a.probe", ".probe", "", 0, 0, "")
    manager_request_debounced(&m, .Signature_Help, "a.probe", ".probe", "", 0, 0, "")
    testing.expectf(t, manager_cancel_kind(&m, .Completion) == 1, "expected one queued Completion cancelled")
    testing.expect(t, manager_debounce_pending(&m, .Signature_Help), "another kind's slot must be untouched")

    testing.expectf(t, manager_flush_debounced(&m, force = true) == 1, "only Signature_Help should dispatch")
    delivered := drain_manager(&m)
    testing.expectf(t, delivered == 1, "expected only the Signature_Help result (got %d)", delivered)
}
