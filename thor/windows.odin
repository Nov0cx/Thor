package thor

// Multi-window support. raylib owns one window per process — the GL context, the
// input state and the font atlas are all process-global — so a second window is
// a second Thor process, launched with the workspace as its path argument (the
// same argument a shell launch uses, see thor_startup_target).
//
// Each window records the workspace it owns under sessions/windows/, so a folder
// that is already open somewhere is raised instead of opened twice. A record is
// only trusted while its window still exists and still belongs to the recorded
// process; a crashed window leaves a stale file that the next reader removes.

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:strings"
import win32 "core:sys/windows"
import rl "vendor:raylib"

import "../shell"

// Directory of window records, next to the session files and likewise relative
// to the exe directory.
@(private = "file")
WINDOWS_DIR :: "sessions/windows"

// On-disk shape of a window record. Field names are the JSON keys. `hwnd` is the
// native window handle widened to an integer, which is all JSON can carry.
@(private = "file")
Window_Record :: struct {
    workspace: string,
    pid:       int,
    hwnd:      i64,
}

// user32.lib cannot be linked (its CloseWindow/ShowCursor collide with
// raylib's), so the handful of window calls used here are resolved at runtime —
// the same trick as thor/dialogs.odin and ui/keymap_windows.odin.
@(private = "file")
Is_Window_Proc :: #type proc "system" (hwnd: win32.HWND) -> win32.BOOL
@(private = "file")
Is_Iconic_Proc :: #type proc "system" (hwnd: win32.HWND) -> win32.BOOL
@(private = "file")
Show_Window_Proc :: #type proc "system" (hwnd: win32.HWND, cmd: win32.c_int) -> win32.BOOL
@(private = "file")
Set_Foreground_Proc :: #type proc "system" (hwnd: win32.HWND) -> win32.BOOL
@(private = "file")
Window_Pid_Proc :: #type proc "system" (hwnd: win32.HWND, pid: ^win32.DWORD) -> win32.DWORD

@(private = "file")
User32 :: struct {
    is_window:      Is_Window_Proc,
    is_iconic:      Is_Iconic_Proc,
    show_window:    Show_Window_Proc,
    set_foreground: Set_Foreground_Proc,
    window_pid:     Window_Pid_Proc,
}

@(private = "file")
user32: User32

@(private = "file")
user32_resolved := false

foreign import kernel32 "system:kernel32.lib"

@(default_calling_convention = "system", private = "file")
foreign kernel32 {
    LoadLibraryA   :: proc(name: cstring) -> rawptr ---
    GetProcAddress :: proc(module: rawptr, name: cstring) -> rawptr ---
}

// Resolves the user32 entry points once. Every caller must tolerate a nil proc:
// without them a folder simply opens in a new window instead of raising the old.
@(private = "file")
thor_load_user32 :: proc() -> ^User32 {
    if user32_resolved {
        return &user32
    }
    user32_resolved = true

    lib := LoadLibraryA("user32.dll")
    if lib == nil {
        log.warn("Could not load user32.dll; existing windows cannot be raised")
        return &user32
    }
    user32.is_window = cast(Is_Window_Proc) GetProcAddress(lib, "IsWindow")
    user32.is_iconic = cast(Is_Iconic_Proc) GetProcAddress(lib, "IsIconic")
    user32.show_window = cast(Show_Window_Proc) GetProcAddress(lib, "ShowWindow")
    user32.set_foreground = cast(Set_Foreground_Proc) GetProcAddress(lib, "SetForegroundWindow")
    user32.window_pid = cast(Window_Pid_Proc) GetProcAddress(lib, "GetWindowThreadProcessId")
    return &user32
}

@(private = "file")
SW_RESTORE :: 9

// Record file for a workspace: sessions/windows/<path-key>.json, keyed exactly
// like that workspace's session file.
thor_window_file :: proc(workspace: string, allocator := context.temp_allocator) -> string {
    return strings.concatenate({WINDOWS_DIR, "/", thor_path_key(workspace), ".json"}, allocator)
}

// Claims `workspace` for this process, so another window opening the same folder
// raises this one. Called once the window exists (the handle is part of the
// record) and again after every workspace switch.
//
// A folder a live window already holds is left alone: a switch never targets one
// (thor_open_folder_request rules it out first), so this only fires when a launch
// argument names a folder that is already open — and there the first window
// stays the one raised, rather than both claiming and both writing its session.
thor_register_window :: proc(thor: ^Thor) {
    if _, taken := thor_workspace_window(thor.workspace_dir); taken {
        log.infof("Workspace %s is already held by another window; not claiming it", thor.workspace_dir)
        return
    }
    if !os.is_dir(WINDOWS_DIR) {
        if err := os.make_directory(WINDOWS_DIR); err != nil && !os.is_dir(WINDOWS_DIR) {
            log.errorf("Could not create %q: %v", WINDOWS_DIR, err)
            return
        }
    }

    record := Window_Record {
        workspace = thor.workspace_dir,
        pid       = cast(int) win32.GetCurrentProcessId(),
        hwnd      = cast(i64) cast(uintptr) rl.GetWindowHandle(),
    }
    data, err := json.marshal(record, {pretty = true}, context.temp_allocator)
    if err != nil {
        log.errorf("Could not marshal window record: %v", err)
        return
    }
    path := thor_window_file(thor.workspace_dir)
    if werr := os.write_entire_file(path, data); werr != nil {
        log.errorf("Could not write window record %q: %v", path, werr)
    }
}

// Releases this process's claim on `workspace`. Called before a switch and at
// shutdown; a missed call (a crash) only leaves a record the next reader prunes.
thor_unregister_window :: proc(workspace: string) {
    if workspace == "" {
        return
    }
    path := thor_window_file(workspace)
    if !os.exists(path) {
        return
    }
    // Only drop the record if it is still ours: a window that took the folder
    // over after us owns the file now.
    if record, ok := thor_read_window_record(path); ok {
        if record.pid != cast(int) win32.GetCurrentProcessId() {
            return
        }
    }
    if err := os.remove(path); err != nil {
        log.warnf("Could not remove window record %q: %v", path, err)
    }
}

// Parses a window record. A malformed file reads as absent.
@(private = "file")
thor_read_window_record :: proc(path: string) -> (Window_Record, bool) {
    data, read_err := os.read_entire_file(path, context.temp_allocator)
    if read_err != nil {
        return {}, false
    }
    record: Window_Record
    if err := json.unmarshal(data, &record, allocator = context.temp_allocator); err != nil {
        log.warnf("Ignoring malformed window record %q: %v", path, err)
        return {}, false
    }
    return record, true
}

// The live window owning `workspace`, or ok=false when the folder is free. A
// record whose window is gone (or now belongs to another process, the handle
// having been recycled) is stale and removed here, so the folder frees itself.
thor_workspace_window :: proc(workspace: string) -> (win32.HWND, bool) {
    path := thor_window_file(workspace)
    record, read_ok := thor_read_window_record(path)
    if !read_ok {
        return nil, false
    }
    if record.pid == cast(int) win32.GetCurrentProcessId() {
        return nil, false // our own claim is not another window
    }

    u32 := thor_load_user32()
    if u32.is_window == nil || u32.window_pid == nil {
        // Cannot tell whether it is live, so leave the record alone and treat
        // the folder as free: opening a second window beats refusing to open one.
        return nil, false
    }

    hwnd := cast(win32.HWND) cast(uintptr) cast(uint) record.hwnd
    if record.hwnd != 0 && u32.is_window(hwnd) {
        owner: win32.DWORD
        u32.window_pid(hwnd, &owner)
        if cast(int) owner == record.pid {
            return hwnd, true
        }
    }

    log.debugf("Pruning stale window record %q", path)
    if err := os.remove(path); err != nil {
        log.warnf("Could not remove stale window record %q: %v", path, err)
    }
    return nil, false
}

// Brings an existing window to the front. A minimized window is restored first —
// an unconditional restore would un-maximize one that is merely behind. The
// foreground handover is allowed because the calling window currently holds it.
thor_focus_window :: proc(hwnd: win32.HWND) {
    u32 := thor_load_user32()
    if u32.is_iconic != nil && u32.show_window != nil && u32.is_iconic(hwnd) {
        u32.show_window(hwnd, SW_RESTORE)
    }
    if u32.set_foreground != nil {
        u32.set_foreground(hwnd)
    }
}

// Launches a second Thor on `workspace`. The new process resolves the folder
// from its path argument, so it restores that folder's own session and layout.
// Returns whether it started.
thor_spawn_window :: proc(workspace: string) -> bool {
    exe, err := os.get_executable_path(context.temp_allocator)
    if err != nil {
        log.errorf("Could not resolve executable path: %v", err)
        return false
    }
    // The child moves its own working directory to the exe directory at startup;
    // the workspace is passed explicitly and already absolute.
    if !shell.spawn(exe, workspace, workspace) {
        log.errorf("Could not start a new window for %q", workspace)
        return false
    }
    log.infof("Opened %s in a new window", workspace)
    return true
}
