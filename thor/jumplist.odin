package thor

import "core:strings"

import "../textedit"

// A spot worth returning to: the file's absolute path (owned) and the caret's
// 1-based line/column when a jump left it. Line/column rather than a byte
// offset because the buffer keeps being edited between leaving a spot and
// coming back to it — typing above a byte offset slides it by every character,
// a line only by the newlines.
Jump_Point :: struct {
    path: string,
    line: int,
    col:  int,
}

// Depth of each trail. Older entries fall off the bottom: this is a navigation
// convenience, not a history to audit.
JUMP_LIST_MAX :: 64

// The caret's location, or ok=false when there is nothing loaded to record.
// `path` is borrowed from the file.
@(private = "file")
thor_current_location :: proc(thor: ^Thor) -> (path: string, line, col: int, ok: bool) {
    file := thor_active_open_file(thor)
    if file == nil || !file.loaded {
        return
    }
    caret := textedit.primary_cursor(&file.state).caret
    txt := textedit.text(&file.state)
    index := textedit.line_index(txt, caret)
    return file.path, index + 1, caret - textedit.line_start_of_index(txt, index) + 1, true
}

// Records where the caret is as the spot a jump is leaving, and drops the
// forward trail — arriving somewhere new ends the branch Go Forward would have
// replayed, as following a link does in a browser.
//
// Called by the jump procs themselves rather than by their callers, so every
// way into one (go-to-definition, either symbol picker, find-references, a
// console error, Go to Line) is recorded without each remembering to.
thor_jump_record :: proc(thor: ^Thor) {
    // Go Back and Go Forward move the caret through those same procs; they keep
    // both trails themselves and must not also count as leaving somewhere.
    if thor.jump_navigating {
        return
    }
    path, line, col, ok := thor_current_location(thor)
    if !ok {
        return
    }
    thor_jump_clear_stack(&thor.jump_forward)
    // Repeated jumps off one line collapse into one entry: what is worth coming
    // back to is the line, not each column the caret passed through chasing
    // symbols across it.
    if len(thor.jump_back) > 0 {
        top := thor.jump_back[len(thor.jump_back) - 1]
        if top.path == path && top.line == line {
            return
        }
    }
    thor_jump_push(&thor.jump_back, path, line, col)
}

// Returns to the spot the last jump left, pushing where we are now onto the
// forward trail.
thor_jump_back :: proc(thor: ^Thor) {
    if len(thor.jump_back) == 0 {
        thor_flash_status(thor, "No earlier location")
        return
    }
    thor_jump_step(thor, &thor.jump_back, &thor.jump_forward)
}

// Replays a jump Go Back walked out of.
thor_jump_forward :: proc(thor: ^Thor) {
    if len(thor.jump_forward) == 0 {
        thor_flash_status(thor, "No later location")
        return
    }
    thor_jump_step(thor, &thor.jump_forward, &thor.jump_back)
}

// Pops `from`, pushes where we are onto `to`, and jumps. The two directions
// differ only in which trail is which. Routed through thor_goto_file_line_col
// so a target whose file was closed since is reopened, and one still loading is
// deferred, exactly as any other jump is.
@(private = "file")
thor_jump_step :: proc(thor: ^Thor, from, to: ^[dynamic]Jump_Point) {
    target := pop(from)
    defer delete(target.path)
    if path, line, col, ok := thor_current_location(thor); ok {
        thor_jump_push(to, path, line, col)
    }
    thor.jump_navigating = true
    defer thor.jump_navigating = false
    thor_goto_file_line_col(thor, target.path, target.line, target.col)
}

// Appends a point, dropping the oldest once the trail is full. Clones `path`.
@(private = "file")
thor_jump_push :: proc(stack: ^[dynamic]Jump_Point, path: string, line, col: int) {
    if len(stack) >= JUMP_LIST_MAX {
        delete(stack[0].path)
        ordered_remove(stack, 0)
    }
    append(stack, Jump_Point {path = strings.clone(path), line = line, col = col})
}

@(private = "file")
thor_jump_clear_stack :: proc(stack: ^[dynamic]Jump_Point) {
    for point in stack^ {
        delete(point.path)
    }
    clear(stack)
}

// Empties both trails. Called on shutdown and when the workspace is swapped:
// the paths name files in the tree being left.
thor_clear_jump_list :: proc(thor: ^Thor) {
    thor_jump_clear_stack(&thor.jump_back)
    thor_jump_clear_stack(&thor.jump_forward)
}
