#+build windows
package thor

import "core:strings"
import win32 "core:sys/windows"

// Opens the OS file explorer with `path` selected.
thor_reveal_path :: proc(path: string) {
    if path == "" {
        return
    }
    native, _ := strings.replace_all(path, "/", "\\", context.temp_allocator)
    param := strings.concatenate({"/select,", native}, context.temp_allocator)
    win32.ShellExecuteW(nil, win32.utf8_to_wstring("open"), win32.utf8_to_wstring("explorer.exe"), win32.utf8_to_wstring(param), nil, win32.SW_SHOWNORMAL)
}
