package ui

import rl "vendor:raylib"

// user32.lib cannot be linked here: it exports CloseWindow/ShowCursor, which
// collide with raylib's symbols. Load MapVirtualKeyW dynamically instead.
foreign import kernel32 "system:kernel32.lib"

@(default_calling_convention = "system", private = "file")
foreign kernel32 {
    LoadLibraryA :: proc(name: cstring) -> rawptr ---
    GetProcAddress :: proc(module: rawptr, name: cstring) -> rawptr ---
}

@(private = "file")
Map_Virtual_Key_Proc :: #type proc "system" (code: u32, map_type: u32) -> u32

@(private = "file")
map_virtual_key: Map_Virtual_Key_Proc

@(private = "file")
map_virtual_key_resolved := false

// raylib/GLFW reports physical keys named after the US layout, so on QWERTZ
// the labeled Z arrives as .Y (and vice versa). Translate letter keys through
// the active Windows keyboard layout so shortcuts follow the key labels.
@(private = "file")
us_letter_scancodes := [26]u32 {
    0x1E, 0x30, 0x2E, 0x20, 0x12, 0x21, 0x22, 0x23, // A-H
    0x17, 0x24, 0x25, 0x26, 0x32, 0x31, 0x18, 0x19, // I-P
    0x10, 0x13, 0x1F, 0x14, 0x16, 0x2F, 0x11, 0x2D, // Q-X
    0x15, 0x2C,                                     // Y, Z
}

remap_key_to_layout :: proc(key: rl.KeyboardKey) -> rl.KeyboardKey {
    key_value := cast(u32) key
    if key_value < cast(u32) rl.KeyboardKey.A || key_value > cast(u32) rl.KeyboardKey.Z {
        return key
    }

    if !map_virtual_key_resolved {
        map_virtual_key_resolved = true
        user32 := LoadLibraryA("user32.dll")
        if user32 != nil {
            map_virtual_key = cast(Map_Virtual_Key_Proc) GetProcAddress(user32, "MapVirtualKeyW")
        }
    }
    if map_virtual_key == nil {
        return key
    }

    MAPVK_VSC_TO_VK :: 1
    scancode := us_letter_scancodes[key_value - cast(u32) rl.KeyboardKey.A]
    vk := map_virtual_key(scancode, MAPVK_VSC_TO_VK)
    if vk >= 'A' && vk <= 'Z' {
        return cast(rl.KeyboardKey) vk
    }
    return key
}
