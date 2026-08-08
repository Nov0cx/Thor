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

// Opens `target` -- a URL or a file path -- in the default browser. The browser
// comes from the https protocol association, not from the file association: a
// local .html is often registered to an editor, and the shell would open that
// instead. Falls back to the association when the lookup finds no browser.
thor_open_in_browser :: proc(target: string) {
    if target == "" {
        return
    }
    if browser := default_browser_exe(); browser != "" {
        args := strings.concatenate({`"`, target, `"`}, context.temp_allocator)
        win32.ShellExecuteW(nil, win32.utf8_to_wstring("open"), win32.utf8_to_wstring(browser), win32.utf8_to_wstring(args), nil, win32.SW_SHOWNORMAL)
        return
    }
    win32.ShellExecuteW(nil, win32.utf8_to_wstring("open"), win32.utf8_to_wstring(target), nil, nil, win32.SW_SHOWNORMAL)
}

// Executable of the default browser, "" when it cannot be resolved. Only the
// program is taken from the registered command; its arguments are a %1 template
// whose quoting rules differ per browser, and every browser opens a target
// given as its one argument. Temporary memory.
@(private = "file")
default_browser_exe :: proc() -> string {
    prog_id := registry_string(
        win32.HKEY_CURRENT_USER,
        `Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice`,
        "ProgId",
    )
    if prog_id == "" {
        return ""
    }

    subkey := strings.concatenate({prog_id, `\shell\open\command`}, context.temp_allocator)
    command := registry_string(win32.HKEY_CLASSES_ROOT, subkey, "")
    if command == "" {
        return ""
    }

    // "<exe>" <args>, or <exe> <args> when the path holds no space.
    if strings.has_prefix(command, `"`) {
        if end := strings.index_byte(command[1:], '"'); end >= 0 {
            return command[1:1 + end]
        }
        return ""
    }
    if space := strings.index_byte(command, ' '); space >= 0 {
        return command[:space]
    }
    return command
}

// A string value of the registry. Empty when the key or the value is absent; an
// empty `value` reads the default one. Temporary memory.
@(private = "file")
registry_string :: proc(root: win32.HKEY, subkey, value: string) -> string {
    key: win32.HKEY
    if win32.RegOpenKeyExW(root, win32.utf8_to_wstring(subkey, context.temp_allocator), 0, win32.KEY_READ, &key) != 0 {
        return ""
    }
    defer win32.RegCloseKey(key)

    // A registered command carries the program and its argument template, so it
    // outgrows MAX_PATH more easily than a plain path value.
    buf: [1024]u16
    size := win32.DWORD(size_of(buf))
    wvalue := value != "" ? win32.utf8_to_wstring(value, context.temp_allocator) : nil
    flags := win32.DWORD(win32.RRF_RT_REG_SZ | win32.RRF_RT_REG_EXPAND_SZ)
    if win32.RegGetValueW(key, nil, wvalue, flags, nil, raw_data(buf[:]), &size) != 0 {
        return ""
    }

    text, err := win32.wstring_to_utf8(cast(win32.wstring) raw_data(buf[:]), -1, context.temp_allocator)
    if err != nil {
        return ""
    }
    return strings.trim_space(text)
}
