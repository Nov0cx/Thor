#+build windows
package thor

// Windows half of the DirectInput block around window creation.
//
// raylib asks GLFW for the game controllers while it makes the window, GLFW
// asks DirectInput, and DirectInput reads a product string out of every HID
// device on the machine. A device that does not answer costs seconds of timeout
// each, with no window up yet to show what is happening — 40 s on the author's
// machine (see docs/troubleshooting.md). Thor reads no gamepad, so the one
// LoadLibraryA("dinput8.dll") GLFW makes is refused for the length of
// InitWindow: GLFW skips the scan and keeps the XInput pads. The import entry
// goes back the moment the window stands.

import "core:log"
import win32 "core:sys/windows"

@(private = "file")
Load_Library_A :: #type proc "system" (name: cstring) -> win32.HMODULE

// IMAGE_IMPORT_DESCRIPTOR and IMAGE_IMPORT_BY_NAME, which core:sys/windows does
// not declare. The name of an import sits two bytes past its hint.
@(private = "file")
Import_Descriptor :: struct {
    original_first_thunk: win32.DWORD,
    time_date_stamp:      win32.DWORD,
    forwarder_chain:      win32.DWORD,
    name:                 win32.DWORD,
    first_thunk:          win32.DWORD,
}

@(private = "file")
IMPORT_NAME_OFFSET :: 2

// An import addressed by ordinal has the top bit of its thunk set and no name.
@(private = "file")
IMPORT_BY_ORDINAL :: uintptr(1) << 63

@(private = "file")
dinput: struct {
    slot:     ^uintptr, // our own LoadLibraryA import entry
    original: Load_Library_A,
    refused:  bool, // whether GLFW asked while the block was up
}

// Answers every load but the DirectInput one, which GLFW handles: it keeps a
// null module and never enumerates. Runs with no context — a worker thread may
// load a library while the block is up.
@(private = "file")
load_library_hook :: proc "system" (name: cstring) -> win32.HMODULE {
    if name != nil && name_equals_fold(name, "dinput8.dll") {
        dinput.refused = true
        return nil
    }
    return dinput.original(name)
}

// ASCII case-insensitive compare against a NUL-terminated name. Stops at the
// first difference, so it never reads past the terminator.
@(private = "file")
name_equals_fold :: proc "contextless" (name: cstring, want: string) -> bool {
    lower :: proc "contextless" (c: u8) -> u8 {
        return c + ('a' - 'A') if 'A' <= c && c <= 'Z' else c
    }

    bytes := transmute([^]u8) name
    for i in 0 ..< len(want) {
        if lower(bytes[i]) != lower(want[i]) {
            return false
        }
    }
    return bytes[len(want)] == 0
}

// The LoadLibraryA entry in the import table of our own image, or nil when the
// image does not import it by name.
@(private = "file")
find_load_library_slot :: proc() -> ^uintptr {
    base := uintptr(win32.GetModuleHandleW(nil))
    if base == 0 {
        return nil
    }
    dos := cast(^win32.IMAGE_DOS_HEADER) rawptr(base)
    nt := cast(^win32.IMAGE_NT_HEADERS64) rawptr(base + uintptr(dos.e_lfanew))
    imports := nt.OptionalHeader.ImportTable
    if imports.VirtualAddress == 0 {
        return nil
    }

    descriptors := cast([^]Import_Descriptor) rawptr(base + uintptr(imports.VirtualAddress))
    for d := 0; descriptors[d].name != 0; d += 1 {
        // A bound import has no name table of its own and names through the
        // address table instead.
        names_rva := descriptors[d].original_first_thunk
        if names_rva == 0 {
            names_rva = descriptors[d].first_thunk
        }
        names := cast([^]uintptr) rawptr(base + uintptr(names_rva))
        addresses := cast([^]uintptr) rawptr(base + uintptr(descriptors[d].first_thunk))
        for i := 0; names[i] != 0; i += 1 {
            if names[i] & IMPORT_BY_ORDINAL != 0 {
                continue
            }
            name := cstring(rawptr(base + uintptr(names[i]) + IMPORT_NAME_OFFSET))
            if name_equals_fold(name, "LoadLibraryA") {
                return &addresses[i]
            }
        }
    }
    return nil
}

@(private = "file")
write_slot :: proc(target: rawptr) -> bool {
    previous: win32.DWORD
    if !win32.VirtualProtect(dinput.slot, size_of(uintptr), win32.PAGE_READWRITE, &previous) {
        return false
    }
    dinput.slot^ = uintptr(target)
    restored: win32.DWORD
    if !win32.VirtualProtect(dinput.slot, size_of(uintptr), previous, &restored) {
        log.warnf("Could not restore import table protection: %v", win32.GetLastError())
    }
    return true
}

// Refuses the DirectInput load until dinput_restore. False when the entry was
// not found or could not be written, which only means the slow scan happens.
dinput_suppress :: proc() -> bool {
    dinput.slot = find_load_library_slot()
    if dinput.slot == nil {
        log.debug("No LoadLibraryA import to hold DirectInput back with")
        return false
    }
    dinput.original = cast(Load_Library_A) rawptr(dinput.slot^)
    dinput.refused = false
    if !write_slot(rawptr(load_library_hook)) {
        log.debugf("Could not write the import entry: %v", win32.GetLastError())
        dinput.slot = nil
        return false
    }
    return true
}

dinput_restore :: proc() {
    if dinput.slot == nil {
        return
    }
    write_slot(rawptr(dinput.original))
    dinput.slot = nil
    if !dinput.refused {
        log.debug("GLFW did not ask for DirectInput; the block changed nothing")
    }
}
