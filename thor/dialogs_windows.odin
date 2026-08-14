#+build windows
package thor

// Windows pickers for Open File / Open Folder: the shell's common item dialog,
// the same browser Explorer draws. Both are modal — the shell runs its own
// message loop, so Thor's frame loop is paused while one is up.
// dialogs_posix.odin answers the same two calls with a helper program.

import "base:runtime"
import "core:strings"
import win32 "core:sys/windows"
import rl "vendor:raylib"

// Opens the folder browser starting at `initial`. Returns the chosen directory
// (caller owns) and false when the user cancelled.
thor_pick_folder :: proc(title: string, initial: string, allocator := context.allocator) -> (string, bool) {
    return thor_pick_shell_item(title, initial, true, allocator)
}

// Opens the file browser in `initial`. Returns the chosen file (caller owns) and
// false when the user cancelled.
thor_pick_file :: proc(title: string, initial: string, allocator := context.allocator) -> (string, bool) {
    return thor_pick_shell_item(title, initial, false, allocator)
}

// Runs the common item dialog. `folders` picks a directory, else an existing
// file. Every failure reads as a cancel: the dialog reports one as a failed
// HRESULT (ERROR_CANCELLED), so the two cannot be told apart.
@(private = "file")
thor_pick_shell_item :: proc(
    title: string,
    initial: string,
    folders: bool,
    allocator: runtime.Allocator,
) -> (string, bool) {
    // The dialog needs an initialized apartment; raylib may already have done
    // it, in which case the matching uninit is not ours.
    owns_com := win32.CoInitializeEx(nil, .APARTMENTTHREADED) == win32.S_OK
    defer if owns_com {win32.CoUninitialize()}

    dialog: ^win32.IFileOpenDialog
    hr := win32.CoCreateInstance(
        win32.CLSID_FileOpenDialog,
        nil,
        win32.CLSCTX_INPROC_SERVER,
        win32.IID_IFileOpenDialog,
        cast(^win32.LPVOID) &dialog,
    )
    if win32.FAILED(hr) || dialog == nil {
        return "", false
    }
    defer dialog->Release()

    // Added to the shell's own defaults, not in place of them. NOCHANGEDIR
    // matters: assets and settings load relative to the CWD (the exe
    // directory), which the dialog would otherwise leave in the browsed folder.
    options: win32.FILEOPENDIALOGOPTIONS
    if win32.SUCCEEDED(dialog->GetOptions(&options)) {
        options |= win32.FOS_FORCEFILESYSTEM | win32.FOS_NOCHANGEDIR
        if folders {
            options |= win32.FOS_PICKFOLDERS
        } else {
            options |= win32.FOS_FILEMUSTEXIST | win32.FOS_PATHMUSTEXIST
        }
        dialog->SetOptions(options)
    }
    dialog->SetTitle(win32.utf8_to_wstring(title, context.temp_allocator))

    if initial != "" {
        // The shell parses backslash paths only.
        native, _ := strings.replace_all(initial, "/", "\\", context.temp_allocator)
        folder: ^win32.IShellItem
        created := win32.SHCreateItemFromParsingName(
            win32.utf8_to_wstring(native, context.temp_allocator),
            nil,
            win32.IID_IShellItem,
            cast(^rawptr) &folder,
        )
        if win32.SUCCEEDED(created) && folder != nil {
            dialog->SetFolder(folder)
            folder->Release()
        }
    }

    if win32.FAILED(dialog->Show(cast(win32.HWND) rl.GetWindowHandle())) {
        return "", false
    }

    item: ^win32.IShellItem
    if win32.FAILED(dialog->GetResult(&item)) || item == nil {
        return "", false
    }
    defer item->Release()

    wide: win32.LPWSTR
    if win32.FAILED(item->GetDisplayName(.FILESYSPATH, &wide)) || wide == nil {
        return "", false
    }
    defer win32.CoTaskMemFree(wide)

    path, err := win32.wstring_to_utf8(win32.wstring(wide), -1, allocator)
    if err != nil || path == "" {
        return "", false
    }
    return path, true
}
