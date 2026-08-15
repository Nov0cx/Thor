package main

import "core:log"
import "core:mem"
import "core:os"

import "../thor"

main :: proc() {
    // Answered before anything is allocated or the window is created, so a
    // version query works with no display.
    if thor.cli_handled(os.args) {
        return
    }

    // Outside the debug block: a release build starts with no console, so the
    // file half of this is the only place its warnings ever land.
    logging := thor.log_init(.Debug when ODIN_DEBUG else .Info)
    defer thor.log_destroy(logging)
    context.logger = logging.logger

    when ODIN_DEBUG {
        track: mem.Tracking_Allocator
        mem.tracking_allocator_init(&track, context.allocator)
        context.allocator = mem.tracking_allocator(&track)

        defer {
            if len(track.allocation_map) > 0 {
                log.errorf("=== %v allocations not freed: ===", len(track.allocation_map))
                for _, entry in track.allocation_map {
                    log.debugf("%v bytes @ %v", entry.size, entry.location)
                }
            }
            if len(track.bad_free_array) > 0 {
                log.errorf("=== %v incorrect frees: ===", len(track.bad_free_array))
                for entry in track.bad_free_array {
                    log.debugf("%p @ %v", entry.memory, entry.location)
                }
            }
            mem.tracking_allocator_destroy(&track)
        }
    }

    thor_instance := thor.init()
    defer thor.shutdown(thor_instance)

    thor.run(thor_instance)
}