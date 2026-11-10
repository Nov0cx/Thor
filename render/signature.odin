package render

import "core:hash/xxhash"
import "core:mem"

import ui "../vendor/loom/loom"

// A hash of what `list` draws: two lists with one signature give the same frame, as long as no texture
// changed its pixels. `stable` is false when the list holds a custom command, whose output the hash cannot see.
list_signature :: proc(list: ui.Draw_List) -> (sig: u64, stable: bool) {
    state: xxhash.XXH3_state
    xxhash.XXH3_init_state(&state)
    if xxhash.XXH3_64_reset(&state) != .None {
        return 0, false
    }
    for cmd in list.cmds {
        tag := u8(0)
        switch v in cmd {
        case ui.Cmd_Rect:
            tag = 1
            hash_value(&state, tag, v)
        case ui.Cmd_Text:
            tag = 2
            fixed := v
            fixed.text = ""
            hash_value(&state, tag, fixed)
            hash_bytes(&state, transmute([]u8)v.text)
        case ui.Cmd_Image:
            tag = 3
            hash_value(&state, tag, v)
        case ui.Cmd_Line:
            tag = 4
            hash_value(&state, tag, v)
        case ui.Cmd_Poly:
            tag = 5
            hash_value(&state, tag, v.color)
            hash_bytes(&state, mem.slice_to_bytes(v.points))
        case ui.Cmd_Push_Clip:
            tag = 6
            hash_value(&state, tag, v)
        case ui.Cmd_Pop_Clip:
            tag = 7
            hash_bytes(&state, {tag})
        case ui.Cmd_Custom:
            return 0, false
        }
    }
    return u64(xxhash.XXH3_64_digest(&state)), true
}

// Hashes the tag and the bytes of `value`. Padding that differs only costs a frame that is drawn again.
@(private = "file")
hash_value :: proc(state: ^xxhash.XXH3_state, tag: u8, value: $T) {
    value := value
    hash_bytes(state, {tag})
    hash_bytes(state, mem.ptr_to_bytes(&value))
}

@(private = "file")
hash_bytes :: proc(state: ^xxhash.XXH3_state, data: []u8) {
    _ = xxhash.XXH3_64_update(state, data)
}
