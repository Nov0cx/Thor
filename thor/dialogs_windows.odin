#+build windows
package thor

// Windows pickers for Open File / Open Folder, straight out of the shell. Both
// are modal: the shell runs its own message loop, so Thor's frame loop is paused
// while one is up. dialogs_posix.odin answers the same two calls with a helper
// program.

import "core:strings"
import win32 "core:sys/windows"
import rl "vendor:raylib"

// SHBrowseForFolderW is not bound in core:sys/windows, so its pieces are
// declared here. The PIDL it returns is an opaque shell id list; only
// SHGetPathFromIDListW and CoTaskMemFree ever touch it.
@(private = "file")
BROWSEINFOW :: struct {
    hwndOwner:      win32.HWND,
    pidlRoot:       rawptr,
    pszDisplayName: win32.wstring,
    lpszTitle:      win32.wstring,
    ulFlags:        win32.UINT,
    lpfn:           Browse_Callback,
    lParam:         win32.LPARAM,
    iImage:         win32.c_int,
}

@(private = "file")
Browse_Callback :: #type proc "system" (hwnd: win32.HWND, msg: win32.UINT, lparam: win32.LPARAM, data: win32.LPARAM) -> win32.c_int

foreign import shell32 "system:Shell32.lib"
foreign import kernel32 "system:kernel32.lib"

@(default_calling_convention = "system", private = "file")
foreign shell32 {
    SHBrowseForFolderW   :: proc(lpbi: ^BROWSEINFOW) -> rawptr ---
    SHGetPathFromIDListW :: proc(pidl: rawptr, pszPath: win32.wstring) -> win32.BOOL ---
}

// user32.lib cannot be linked (its CloseWindow/ShowCursor collide with
// raylib's), so the browser's one message send is resolved at runtime — same
// trick as ui/keymap_windows.odin.
@(default_calling_convention = "system", private = "file")
foreign kernel32 {
    LoadLibraryA   :: proc(name: cstring) -> rawptr ---
    GetProcAddress :: proc(module: rawptr, name: cstring) -> rawptr ---
}

@(private = "file")
Send_Message_Proc :: #type proc "system" (hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) -> win32.LRESULT

@(private = "file")
send_message: Send_Message_Proc

@(private = "file")
send_message_resolved := false

@(private = "file")
BIF_RETURNONLYFSDIRS :: 0x00000001
@(private = "file")
BIF_NEWDIALOGSTYLE :: 0x00000040
@(private = "file")
BFFM_INITIALIZED :: 1
@(private = "file")
BFFM_SETSELECTIONW :: win32.WM_USER + 103

// Selects the folder handed in as lParam (a wide string) once the browser is up,
// so it opens on the current workspace instead of the desktop root.
@(private = "file")
thor_browse_callback :: proc "system" (hwnd: win32.HWND, msg: win32.UINT, lparam: win32.LPARAM, data: win32.LPARAM) -> win32.c_int {
    if msg == BFFM_INITIALIZED && data != 0 && send_message != nil {
        send_message(hwnd, BFFM_SETSELECTIONW, win32.WPARAM(1), data)
    }
    return 0
}

// Opens the shell folder browser starting at `initial`. Returns the chosen
// directory (caller owns) and false when the user cancelled.
thor_pick_folder :: proc(title: string, initial: string, allocator := context.allocator) -> (string, bool) {
    // The browser needs an initialized apartment for its modern layout; raylib
    // may already have done it, in which case the matching uninit is not ours.
    owns_com := win32.CoInitializeEx(nil, .APARTMENTTHREADED) == win32.S_OK
    defer if owns_com {win32.CoUninitialize()}

    display: [win32.MAX_PATH]u16
    info := BROWSEINFOW {
        hwndOwner      = cast(win32.HWND) rl.GetWindowHandle(),
        pszDisplayName = win32.wstring(&display[0]),
        lpszTitle      = win32.utf8_to_wstring(title, context.temp_allocator),
        ulFlags        = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE,
        lpfn           = thor_browse_callback,
    }
    if initial != "" {
        if !send_message_resolved {
            send_message_resolved = true
            if user32 := LoadLibraryA("user32.dll"); user32 != nil {
                send_message = cast(Send_Message_Proc) GetProcAddress(user32, "SendMessageW")
            }
        }
        native, _ := strings.replace_all(initial, "/", "\\", context.temp_allocator)
        info.lParam = cast(win32.LPARAM) transmute(uintptr) win32.utf8_to_wstring(native, context.temp_allocator)
    }

    pidl := SHBrowseForFolderW(&info)
    if pidl == nil {
        return "", false
    }
    defer win32.CoTaskMemFree(pidl)

    buf: [win32.MAX_PATH]u16
    if !SHGetPathFromIDListW(pidl, win32.wstring(&buf[0])) {
        return "", false
    }
    path, err := win32.utf16_to_utf8(buf[:], allocator)
    if err != nil || path == "" {
        return "", false
    }
    return path, true
}

// Opens the shell file picker in `initial`. Returns the chosen file (caller
// owns) and false when the user cancelled.
thor_pick_file :: proc(title: string, initial: string, allocator := context.allocator) -> (string, bool) {
    buf: [win32.MAX_PATH]u16
    ofn := win32.OPENFILENAMEW {
        lStructSize = size_of(win32.OPENFILENAMEW),
        hwndOwner   = cast(win32.HWND) rl.GetWindowHandle(),
        lpstrFile   = win32.wstring(&buf[0]),
        nMaxFile    = len(buf),
        lpstrTitle  = win32.utf8_to_wstring(title, context.temp_allocator),
        // NOCHANGEDIR matters: assets and settings load relative to the CWD (the
        // exe directory), which the dialog would otherwise leave in the browsed folder.
        Flags       = win32.OFN_EXPLORER |
            win32.OFN_PATHMUSTEXIST |
            win32.OFN_FILEMUSTEXIST |
            win32.OFN_NOCHANGEDIR,
    }
    if initial != "" {
        native, _ := strings.replace_all(initial, "/", "\\", context.temp_allocator)
        ofn.lpstrInitialDir = win32.utf8_to_wstring(native, context.temp_allocator)
    }

    if !win32.GetOpenFileNameW(&ofn) {
        return "", false
    }
    path, err := win32.utf16_to_utf8(buf[:], allocator)
    if err != nil || path == "" {
        return "", false
    }
    return path, true
}
