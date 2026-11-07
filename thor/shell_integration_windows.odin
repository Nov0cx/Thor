#+build windows
package thor

import "core:log"
import "core:os"
import "core:strings"
import win32 "core:sys/windows"

foreign import advapi32 "system:Advapi32.lib"

@(default_calling_convention = "system")
foreign advapi32 {
    RegDeleteTreeW :: proc(hKey: win32.HKEY, lpSubKey: win32.LPCWSTR) -> win32.LSTATUS ---
}

// The per-user keys of the classes the entry sits under: every file, a folder, and the
// background of an open folder. `%1` is the clicked item, `%V` the folder of the background.
@(private = "file")
Menu_Class :: struct {
    key:      string,
    argument: string,
}

@(private = "file")
MENU_CLASSES := [?]Menu_Class{{"*", "%1"}, {"Directory", "%1"}, {"Directory\\Background", "%V"}}

thor_shell_menu_supported :: proc() -> bool {
    return true
}

// True when every class has the entry and its command names this executable.
thor_shell_menu_registered :: proc() -> bool {
    exe := menu_exe() or_return
    for class in MENU_CLASSES {
        want := menu_command(exe, class.argument)
        if registry_default(menu_key(class, true)) != want {
            return false
        }
    }
    return true
}

// Adds the entry for the current user, or removes it. No admin right is needed.
thor_shell_menu_set :: proc(on: bool) -> bool {
    ok := true
    if !on {
        for class in MENU_CLASSES {
            status := RegDeleteTreeW(win32.HKEY_CURRENT_USER, win32.utf8_to_wstring(menu_key(class, false), context.temp_allocator))
            // 2 is ERROR_FILE_NOT_FOUND: the entry was not there.
            if status != 0 && status != 2 {
                log.warnf("explorer menu: removing %q failed with %d", class.key, status)
                ok = false
            }
        }
        return ok
    }
    exe := menu_exe() or_return
    icon := strings.concatenate({"\"", exe, "\",0"}, context.temp_allocator)
    for class in MENU_CLASSES {
        parent := menu_key(class, false)
        if !registry_set(parent, "", SHELL_MENU_LABEL) ||
           !registry_set(parent, "Icon", icon) ||
           !registry_set(menu_key(class, true), "", menu_command(exe, class.argument)) {
            log.warnf("explorer menu: writing %q failed", class.key)
            ok = false
        }
    }
    return ok
}

// The executable with native separators. Temporary memory.
@(private = "file")
menu_exe :: proc() -> (exe: string, ok: bool) {
    path, err := os.get_executable_path(context.temp_allocator)
    if err != nil {
        log.warnf("explorer menu: no executable path: %v", err)
        return "", false
    }
    native, _ := strings.replace_all(path, "/", "\\", context.temp_allocator)
    return native, true
}

@(private = "file")
menu_command :: proc(exe, argument: string) -> string {
    return strings.concatenate({"\"", exe, "\" \"", argument, "\""}, context.temp_allocator)
}

// The registry path of the entry of `class`, or of its command. Temporary memory.
@(private = "file")
menu_key :: proc(class: Menu_Class, command: bool) -> string {
    base := strings.concatenate({"Software\\Classes\\", class.key, "\\shell\\Thor"}, context.temp_allocator)
    return command ? strings.concatenate({base, "\\command"}, context.temp_allocator) : base
}

// Sets a string value of a key of the current user; an empty `name` is the default value.
@(private = "file")
registry_set :: proc(subkey, name, value: string) -> bool {
    key: win32.HKEY
    status := win32.RegCreateKeyExW(
        win32.HKEY_CURRENT_USER, win32.utf8_to_wstring(subkey, context.temp_allocator), 0, nil, 0, win32.KEY_WRITE, nil, &key, nil,
    )
    if status != 0 {
        return false
    }
    defer win32.RegCloseKey(key)

    wide := win32.utf8_to_utf16(value, context.temp_allocator)
    data := make([]u16, len(wide) + 1, context.temp_allocator)
    copy(data, wide)
    wname := name != "" ? win32.utf8_to_wstring(name, context.temp_allocator) : nil
    return win32.RegSetValueExW(key, wname, 0, win32.REG_SZ, cast(^win32.BYTE)raw_data(data), win32.DWORD(len(data) * size_of(u16))) == 0
}

// The default string value of a key of the current user; empty when absent. Temporary memory.
@(private = "file")
registry_default :: proc(subkey: string) -> string {
    buf: [1024]u16
    size := win32.DWORD(size_of(buf))
    status := win32.RegGetValueW(
        win32.HKEY_CURRENT_USER, win32.utf8_to_wstring(subkey, context.temp_allocator), nil, win32.RRF_RT_REG_SZ, nil, raw_data(buf[:]), &size,
    )
    if status != 0 {
        return ""
    }
    text, err := win32.wstring_to_utf8(cast(win32.wstring)raw_data(buf[:]), -1, context.temp_allocator)
    if err != nil {
        return ""
    }
    return text
}
