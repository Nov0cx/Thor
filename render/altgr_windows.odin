#+build windows
package render

import "core:log"
import win32 "core:sys/windows"

// user32.lib cannot be linked (its CloseWindow/ShowCursor collide with
// raylib's), so the layout calls are resolved at runtime.
@(private = "file")
Get_Keyboard_Layout_Proc :: #type proc "system" (thread: win32.DWORD) -> win32.HANDLE
@(private = "file")
Map_Virtual_Key_Proc :: #type proc "system" (code, map_type: win32.UINT, layout: win32.HANDLE) -> win32.UINT
@(private = "file")
To_Unicode_Proc :: #type proc "system" (
    vk, scan: win32.UINT,
    state: ^[256]u8,
    buffer: [^]u16,
    capacity: win32.c_int,
    flags: win32.UINT,
    layout: win32.HANDLE,
) -> win32.c_int

@(private = "file")
Layout :: struct {
    resolved:        bool,
    keyboard_layout: Get_Keyboard_Layout_Proc,
    map_virtual_key: Map_Virtual_Key_Proc,
    to_unicode:      To_Unicode_Proc,
    scanned:         bool,
    hkl:             win32.HANDLE, // the layout `alt_gr` describes
    alt_gr:          bool,
}

@(private = "file")
layout: Layout

foreign import kernel32 "system:kernel32.lib"

@(default_calling_convention = "system", private = "file")
foreign kernel32 {
    LoadLibraryA   :: proc(name: cstring) -> rawptr ---
    GetProcAddress :: proc(module: rawptr, name: cstring) -> rawptr ---
}

@(private = "file")
VK_CONTROL :: 0x11
@(private = "file")
VK_MENU :: 0x12
@(private = "file")
VK_LCONTROL :: 0xA2
@(private = "file")
VK_RMENU :: 0xA5
@(private = "file")
MAPVK_VK_TO_VSC :: 0
// ToUnicodeEx leaves the kernel keyboard state alone, so a pending dead key survives.
@(private = "file")
TO_UNICODE_KEEP_STATE :: 1 << 2

// The digit and letter keys, then the OEM punctuation keys.
@(private = "file")
SCAN_RANGES := [?][2]win32.UINT{{0x30, 0x5A}, {0xBA, 0xE2}}

@(private = "file")
resolve_user32 :: proc() -> bool {
    if !layout.resolved {
        layout.resolved = true
        lib := LoadLibraryA("user32.dll")
        if lib == nil {
            log.warn("Could not load user32.dll; Right Alt stays AltGr")
            return false
        }
        layout.keyboard_layout = cast(Get_Keyboard_Layout_Proc) GetProcAddress(lib, "GetKeyboardLayout")
        layout.map_virtual_key = cast(Map_Virtual_Key_Proc) GetProcAddress(lib, "MapVirtualKeyExW")
        layout.to_unicode = cast(To_Unicode_Proc) GetProcAddress(lib, "ToUnicodeEx")
    }
    return layout.keyboard_layout != nil && layout.map_virtual_key != nil && layout.to_unicode != nil
}

// Whether a key of `hkl` gives a character or a dead key with Ctrl + Alt held,
// which is what AltGr is.
@(private = "file")
scan_layout :: proc(hkl: win32.HANDLE) -> bool {
    state: [256]u8
    state[VK_CONTROL] = 0x80
    state[VK_MENU] = 0x80
    state[VK_LCONTROL] = 0x80
    state[VK_RMENU] = 0x80

    buffer: [8]u16
    for range in SCAN_RANGES {
        for vk in range[0] ..= range[1] {
            scan := layout.map_virtual_key(vk, MAPVK_VK_TO_VSC, hkl)
            if scan == 0 {
                continue
            }
            n := layout.to_unicode(vk, scan, &state, raw_data(buffer[:]), len(buffer), TO_UNICODE_KEEP_STATE, hkl)
            if n != 0 {
                return true
            }
        }
    }
    return false
}

// The answer is kept per layout, so a layout switch is seen at the next call.
layout_has_alt_gr :: proc() -> bool {
    if !resolve_user32() {
        return true
    }
    hkl := layout.keyboard_layout(0)
    if !layout.scanned || hkl != layout.hkl {
        layout.scanned = true
        layout.hkl = hkl
        layout.alt_gr = scan_layout(hkl)
        log.debugf("Keyboard layout %p: AltGr %v", hkl, layout.alt_gr)
    }
    return layout.alt_gr
}
