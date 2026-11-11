// Spall trace zones, compiled in only by a profile build (`build.odin -- -profile`).
// Each thread that records calls thread_begin first; a thread without a buffer records nothing.
package prof

// Used by the profile build only.
@(require)
import "base:runtime"
@(require)
import "core:log"
import "core:prof/spall"
@(require)
import "core:sync"

// Set by `-profile`: the zones record.
ENABLED :: #config(THOR_PROFILE, false)
// Set by `-profile-all`: every procedure records too.
ALL     :: #config(THOR_PROFILE_ALL, false)

@(private)
ctx: spall.Context
// True between init and destroy. A detached worker reads it before it flushes.
@(private)
live: bool
@(private, thread_local)
buffer: spall.Buffer
@(private, thread_local)
backing: []u8
// Open procedure events of this thread, so an exit of a frame entered before thread_begin is skipped.
@(private, thread_local)
depth: int
// True while thread_scope holds a zone named after the thread open.
@(private, thread_local)
thread_zone: bool

// Opens the trace at `path` and starts the buffer of the calling thread.
@(no_instrumentation)
init :: proc(path: string) -> bool {
    when ENABLED {
        // The overload without a scale sleeps two seconds to measure the TSC; tick_now is in nanoseconds.
        c, ok := spall.context_create_with_scale(path, false, 1)
        if !ok {
            log.errorf("prof: could not open the trace %s", path)
            return false
        }
        ctx = c
        sync.atomic_store(&live, true)
        thread_begin("main")
        log.infof("prof: trace at %s", path)
        return true
    } else {
        return false
    }
}

// Flushes the buffer of the calling thread and closes the trace.
@(no_instrumentation)
destroy :: proc() {
    when ENABLED {
        if !sync.atomic_load(&live) {
            return
        }
        thread_end()
        sync.atomic_store(&live, false)
        spall.context_destroy(&ctx)
    }
}

// Starts the buffer of the calling thread, shown as `name` in the trace.
@(no_instrumentation)
thread_begin :: proc(name: string) {
    when ENABLED {
        if len(buffer.data) > 0 || !sync.atomic_load(&live) {
            return
        }
        data := make([]u8, spall.BUFFER_DEFAULT_SIZE, runtime.heap_allocator())
        if data == nil {
            return
        }
        b, ok := spall.buffer_create(data, u32(sync.current_thread_id()))
        if !ok {
            delete(data, runtime.heap_allocator())
            return
        }
        backing = data
        depth = 0
        buffer = b
        spall._buffer_name_thread(&ctx, &buffer, name)
    }
}

// Flushes and frees the buffer of the calling thread.
@(no_instrumentation)
thread_end :: proc() {
    when ENABLED {
        if len(buffer.data) == 0 {
            return
        }
        if thread_zone {
            spall._buffer_end(&ctx, &buffer)
            thread_zone = false
        }
        if sync.atomic_load(&live) {
            spall.buffer_destroy(&ctx, &buffer)
        }
        buffer = {}
        depth = 0
        delete(backing, runtime.heap_allocator())
        backing = nil
    }
}

// Starts the buffer of the calling thread and a zone named `name`, both until the end of the enclosing scope.
@(no_instrumentation, deferred_none = thread_end)
thread_scope :: proc(name: string, loc := #caller_location) {
    when ENABLED {
        thread_begin(name)
        if len(buffer.data) > 0 && !thread_zone {
            spall._buffer_begin(&ctx, &buffer, name, "", loc)
            thread_zone = true
        }
    }
}

// Records a zone named `name` until the end of the enclosing scope. `args` shows as the zone's detail.
@(no_instrumentation, deferred_out = zone_end)
scope :: proc(name: string, args := "", loc := #caller_location) -> bool {
    when ENABLED {
        if len(buffer.data) == 0 {
            return false
        }
        spall._buffer_begin(&ctx, &buffer, name, args, loc)
        return true
    } else {
        return false
    }
}

// Records a zone named after the calling procedure until the end of the enclosing scope.
@(no_instrumentation, deferred_out = zone_end)
proc_scope :: proc(loc := #caller_location) -> bool {
    when ENABLED {
        if len(buffer.data) == 0 {
            return false
        }
        spall._buffer_begin(&ctx, &buffer, loc.procedure, "", loc)
        return true
    } else {
        return false
    }
}

// Starts a zone that zone_end closes, for a span that is not one Odin scope.
@(no_instrumentation)
zone_begin :: proc(name: string, loc := #caller_location) -> bool {
    when ENABLED {
        if len(buffer.data) == 0 {
            return false
        }
        spall._buffer_begin(&ctx, &buffer, name, "", loc)
        return true
    } else {
        return false
    }
}

// Closes the zone that zone_begin started when it returned true.
@(no_instrumentation)
zone_end :: proc(began: bool) {
    when ENABLED {
        if began && len(buffer.data) > 0 {
            spall._buffer_end(&ctx, &buffer)
        }
    }
}

// Set by `-profile-min`: a procedure call shorter than this many microseconds that calls no recorded
// procedure is dropped from a `-profile-all` trace, which is what keeps a long run's trace small.
MIN_US :: #config(THOR_PROFILE_MIN_US, 0)

when ENABLED && ALL {
    // Nesting that the drop of short calls tracks; deeper calls are always kept.
    @(private)
    MAX_TRACKED :: 512

    // For each open call: where its begin event starts in `buffer`, and where the buffer ended after it.
    @(private, thread_local)
    begin_at: [MAX_TRACKED]int
    @(private, thread_local)
    begin_end: [MAX_TRACKED]int

    @(instrumentation_enter)
    enter :: proc "contextless"(proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
        if len(buffer.data) == 0 {
            return
        }
        depth += 1
        spall._buffer_begin(&ctx, &buffer, "", "", loc)
        when MIN_US > 0 {
            if depth <= MAX_TRACKED {
                // A flush inside _buffer_begin moves the event to the front, so it is found back from the end.
                begin_end[depth - 1] = buffer.head
                begin_at[depth - 1] = buffer.head - size_of(spall.Begin_Event) - min(len(loc.procedure), 255)
            }
        }
    }

    @(instrumentation_exit)
    exit :: proc "contextless"(proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
        if depth == 0 || len(buffer.data) == 0 {
            return
        }
        depth -= 1
        when MIN_US > 0 {
            if depth < MAX_TRACKED && drop_short(begin_at[depth], begin_end[depth]) {
                return
            }
        }
        spall._buffer_end(&ctx, &buffer)
    }

    // Rewinds the buffer over a begin event that nothing followed, when the call took less than MIN_US.
    @(private, no_instrumentation)
    drop_short :: proc "contextless"(at, end: int) -> bool {
        if buffer.head != end || at < size_of(spall.Manual_Buffer_Header) {
            return false
        }
        ev := (^spall.Begin_Event)(&buffer.data[at])
        if ev.type != .Begin {
            return false
        }
        elapsed := spall._trace_now(&ctx) - u64(ev.ts)
        if f64(elapsed) * ctx.timestamp_scale >= f64(MIN_US) * 1000 {
            return false
        }
        buffer.head = at
        return true
    }
}
