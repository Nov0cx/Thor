// What a checker read from outside the request's buffer, kept so a result made from it can be reused.
package odinsema

import "core:mem"
import "core:slice"

// The files and package views a checker read, with the state each had. Owns its maps and slices.
Checker_Inputs :: struct {
    stamps:         map[File_Id]u64,
    package_stamps: map[Package_Id]Package_Stamp,
    allocator:      mem.Allocator,
}

// Starts watching [lo, hi) of the request's buffer: a read of a procedure body outside it sets
// `read_outside`, which checker_watch_end returns.
checker_watch :: proc(c: ^Checker, lo, hi: int) {
    c.watch_lo, c.watch_hi = lo, hi
    c.read_outside = false
}

// Stops the watch. True when a body outside the range was read.
checker_watch_end :: proc(c: ^Checker) -> bool {
    outside := c.read_outside
    c.watch_lo, c.watch_hi = 0, 0
    c.read_outside = false
    return outside
}

// Adds what `c` read, and what the frozen state it started from read, to `inputs`.
checker_inputs_add :: proc(inputs: ^Checker_Inputs, c: ^Checker, allocator := context.allocator) -> mem.Allocator_Error {
    if inputs.allocator.procedure == nil {
        inputs.allocator = allocator
        inputs.stamps = make(map[File_Id]u64, inputs.allocator)
        inputs.package_stamps = make(map[Package_Id]Package_Stamp, inputs.allocator)
    }
    add_stamps(inputs, c.stamps, c.package_stamps) or_return
    if c.base != nil {
        add_stamps(inputs, c.base.stamps, c.base.package_stamps) or_return
    }
    return nil
}

@(private = "file")
add_stamps :: proc(inputs: ^Checker_Inputs, stamps: map[File_Id]u64, package_stamps: map[Package_Id]Package_Stamp) -> mem.Allocator_Error {
    for id, stamp in stamps {
        if id not_in inputs.stamps {
            _, value, _, err := map_entry(&inputs.stamps, id)
            if err != nil {
                return err
            }
            value^ = stamp
        }
    }
    for pkg, ps in package_stamps {
        if pkg in inputs.package_stamps {
            continue
        }
        files       := slice.clone(ps.files, inputs.allocator) or_return
        shapes, err := slice.clone(ps.shapes, inputs.allocator)
        if err != nil {
            delete(files, inputs.allocator)
            return err
        }
        _, value, _, merr := map_entry(&inputs.package_stamps, pkg)
        if merr != nil {
            delete(files, inputs.allocator)
            delete(shapes, inputs.allocator)
            return merr
        }
        value^ = {files = files, shapes = shapes, missing = ps.missing}
    }
    return nil
}

// True when every file and package of `inputs` is as it was read.
checker_inputs_valid :: proc(snap: ^Snapshot, inputs: ^Checker_Inputs) -> bool {
    return stamps_valid(snap, inputs.stamps, inputs.package_stamps)
}

checker_inputs_destroy :: proc(inputs: ^Checker_Inputs) {
    if inputs.allocator.procedure == nil {
        return
    }
    for _, ps in inputs.package_stamps {
        delete(ps.files, inputs.allocator)
        delete(ps.shapes, inputs.allocator)
    }
    delete(inputs.stamps)
    delete(inputs.package_stamps)
    inputs^ = {}
}
