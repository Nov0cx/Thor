package platform

import "core:strings"
import rl "vendor:raylib"

// The clipboard text, cloned with `allocator`. "" when it holds no text.
clipboard_get :: proc(allocator := context.temp_allocator) -> string {
    text := rl.GetClipboardText()
    if text == nil {
        return ""
    }
    return strings.clone(string(text), allocator)
}

clipboard_set :: proc(text: string) {
    rl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator))
}
