#+build windows
package shell

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import win32 "core:sys/windows"

// An empty prompt function: PowerShell writes the prompt to stdout before every
// command it reads, and a terminal draws its own.
@(private = "file")
POWERSHELL_QUIET :: "function prompt { '' }"

// cmd.exe has no empty prompt, so it is reduced to one space; the terminal drops
// the blank run that sits just before an end marker.
@(private = "file")
CMD_QUIET :: "prompt $S"

// Every shell installed on this machine, best first.
profiles_detect :: proc(allocator := context.allocator) -> []Profile {
    list := make([dynamic]Profile, allocator)

    system_root := os.get_env("SystemRoot", context.temp_allocator)
    if system_root == "" {
        system_root = "C:/Windows"
    }
    system32 := join_temp(system_root, "System32")
    comspec := os.get_env("ComSpec", context.temp_allocator)

    program_files := os.get_env("ProgramFiles", context.temp_allocator)
    program_files_x86 := os.get_env("ProgramFiles(x86)", context.temp_allocator)
    local_app_data := os.get_env("LocalAppData", context.temp_allocator)

    // PowerShell 7 installs beside Windows PowerShell instead of replacing it.
    add_profile(
        &list,
        "pwsh",
        "PowerShell",
        {
            join_temp(program_files, "PowerShell/7/pwsh.exe"),
            which_temp("pwsh.exe"),
        },
        {"-NoLogo"},
        {POWERSHELL_QUIET},
        .Powershell,
        allocator,
    )

    add_profile(
        &list,
        "powershell",
        "Windows PowerShell",
        {join_temp(system32, "WindowsPowerShell/v1.0/powershell.exe")},
        {"-NoLogo"},
        {POWERSHELL_QUIET},
        .Powershell,
        allocator,
    )

    // /Q keeps cmd from echoing back every line it reads off the pipe.
    add_profile(&list, "cmd", "Command Prompt", {comspec, join_temp(system32, "cmd.exe")}, {"/Q"}, {CMD_QUIET}, .Cmd, allocator)

    add_profile(
        &list,
        "git-bash",
        "Git Bash",
        {
            join_temp(program_files, "Git/bin/bash.exe"),
            join_temp(program_files_x86, "Git/bin/bash.exe"),
            join_temp(local_app_data, "Programs/Git/bin/bash.exe"),
            git_bash_beside_git(),
        },
        {"--login"},
        {},
        .Posix,
        allocator,
    )

    // The MSVC environment is loaded by the batch file the installer ships;
    // -startdir=none keeps it from moving out of the workspace directory.
    if vsdevcmd, ok := find_vsdevcmd(); ok {
        call := fmt.tprintf(`call "%s" -arch=amd64 -host_arch=amd64 -startdir=none`, vsdevcmd)
        add_profile(
            &list,
            "msvc",
            "Developer Command Prompt",
            {comspec, join_temp(system32, "cmd.exe")},
            {"/Q"},
            {call, CMD_QUIET},
            .Cmd,
            allocator,
        )
    }

    add_profile(&list, "msys2", "MSYS2", env_candidates(MSYS2), {"--login"}, {}, .Posix, allocator)
    add_profile(&list, "cygwin", "Cygwin", env_candidates(CYGWIN), {"--login"}, {}, .Posix, allocator)

    // wsl.exe is a part of Windows, so its presence alone proves no shell.
    if wsl_has_distribution() {
        add_profile(&list, "wsl", "WSL", {join_temp(system32, "wsl.exe")}, {}, {}, .Posix, allocator)
    }
    add_profile(&list, "nu", "Nushell", {which_temp("nu.exe"), join_temp(program_files, "nu/bin/nu.exe")}, {}, {}, .Nushell, allocator)

    return list[:]
}

// A POSIX environment ported to Windows. The user can install it anywhere, so
// its root is looked for in more than one place.
@(private = "file")
Posix_Env :: struct {
    roots:  []string,         // default install roots, best first
    bash:   string,           // bash.exe, relative to the root
    marker: string,           // file that only the root of this environment has
    keys:   []Registry_Value, // where the installer records the root it used
}

// Where a value is in the registry.
@(private = "file")
Registry_Value :: struct {
    root:   win32.HKEY,
    subkey: string,
    value:  string,
}

@(private = "file")
UNINSTALL :: `Software\Microsoft\Windows\CurrentVersion\Uninstall`

// The uninstall entry is what shows MSYS2 in "Apps & features"; it carries the
// directory the installer wrote to.
@(private = "file")
MSYS2 := Posix_Env {
    roots  = {"C:/msys64", "C:/msys32"},
    bash   = "usr/bin/bash.exe",
    marker = "msys2_shell.cmd",
    keys   = {
        {win32.HKEY_CURRENT_USER, UNINSTALL + `\MSYS2 64bit`, "InstallLocation"},
        {win32.HKEY_LOCAL_MACHINE, UNINSTALL + `\MSYS2 64bit`, "InstallLocation"},
        {win32.HKEY_CURRENT_USER, UNINSTALL + `\MSYS2 32bit`, "InstallLocation"},
        {win32.HKEY_LOCAL_MACHINE, UNINSTALL + `\MSYS2 32bit`, "InstallLocation"},
    },
}

// Cygwin's setup writes the root it installed to under its own key, per machine
// or, for a user install, per user.
@(private = "file")
CYGWIN := Posix_Env {
    roots  = {"C:/cygwin64", "C:/cygwin"},
    bash   = "bin/bash.exe",
    marker = "Cygwin.bat",
    keys   = {
        {win32.HKEY_LOCAL_MACHINE, `SOFTWARE\Cygwin\setup`, "rootdir"},
        {win32.HKEY_CURRENT_USER, `SOFTWARE\Cygwin\setup`, "rootdir"},
    },
}

// Every bash.exe that can belong to `env`, best first: the default roots, the
// root the installer recorded, then a bash.exe on PATH. Temporary memory.
@(private = "file")
env_candidates :: proc(env: Posix_Env) -> []string {
    out := make([dynamic]string, context.temp_allocator)
    for root in env.roots {
        append(&out, join_temp(root, env.bash))
    }
    for key in env.keys {
        append(&out, join_temp(registry_string(key.root, key.subkey, key.value), env.bash))
    }
    append(&out, env_bash_on_path(env))
    return out[:]
}

// The first bash.exe on PATH that belongs to `env`. Only the marker file tells
// the environments apart: Git Bash is an MSYS2 build of its own, and it is the
// one of the three that PATH usually holds.
@(private = "file")
env_bash_on_path :: proc(env: Posix_Env) -> string {
    path := os.get_env("PATH", context.temp_allocator)
    for dir in strings.split_iterator(&path, ";") {
        trimmed := strings.trim_right(strings.trim_space(dir), `/\`)
        if trimmed == "" {
            continue
        }
        bash := join_temp(trimmed, "bash.exe")
        if !os.is_file(bash) {
            continue
        }
        // PATH holds the directory of bash, one level below the root for Cygwin
        // and two for MSYS2.
        root := filepath.dir(trimmed)
        if !os.is_file(join_temp(root, env.marker)) {
            root = filepath.dir(root)
        }
        if os.is_file(join_temp(root, env.marker)) {
            return bash
        }
    }
    return ""
}

// Whether a WSL distribution is registered. A distribution is written here as
// it is installed, and bare wsl.exe starts the default one, so an empty value
// means the profile has nothing to run.
@(private = "file")
wsl_has_distribution :: proc() -> bool {
    lxss :: `Software\Microsoft\Windows\CurrentVersion\Lxss`
    return registry_string(win32.HKEY_CURRENT_USER, lxss, "DefaultDistribution") != ""
}

// A string value of the registry, without its trailing separator. Empty when
// the key or the value is absent. Both views are read, since a 32-bit installer
// writes under WOW6432Node. Temporary memory.
@(private = "file")
registry_string :: proc(root: win32.HKEY, subkey, value: string) -> string {
    wsubkey := win32.utf8_to_wstring(subkey, context.temp_allocator)
    wvalue := win32.utf8_to_wstring(value, context.temp_allocator)

    for view in ([]win32.REGSAM{win32.KEY_WOW64_64KEY, win32.KEY_WOW64_32KEY}) {
        key: win32.HKEY
        if win32.RegOpenKeyExW(root, wsubkey, 0, win32.KEY_READ | view, &key) != 0 {
            continue
        }
        defer win32.RegCloseKey(key)

        buf: [win32.MAX_PATH]u16
        size := win32.DWORD(size_of(buf))
        flags := win32.DWORD(win32.RRF_RT_REG_SZ | win32.RRF_RT_REG_EXPAND_SZ)
        if win32.RegGetValueW(key, nil, wvalue, flags, nil, raw_data(buf[:]), &size) != 0 {
            continue
        }
        text, err := win32.wstring_to_utf8(cast(win32.wstring)raw_data(buf[:]), -1, context.temp_allocator)
        if err != nil {
            continue
        }
        if trimmed := strings.trim_right(strings.trim_space(text), `/\`); trimmed != "" {
            return trimmed
        }
    }
    return ""
}

// Git for Windows keeps bash two directories up from git.exe, which finds an
// install that is only on PATH.
@(private = "file")
git_bash_beside_git :: proc() -> string {
    git, ok := which("git.exe", context.temp_allocator)
    if !ok {
        return ""
    }
    // filepath.dir slices the path it is given; neither result is allocated.
    root := filepath.dir(filepath.dir(git))
    return join_temp(root, "bin/bash.exe")
}

// Installation path of the newest Visual Studio with the C++ tools, as vswhere
// reports it, plus the batch file that loads its environment.
@(private = "file")
find_vsdevcmd :: proc() -> (string, bool) {
    vswhere := "C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
    if !os.is_file(vswhere) {
        return "", false
    }

    desc := os.Process_Desc {
        command = {
            vswhere,
            "-latest",
            "-products", "*",
            "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
            "-property", "installationPath",
        },
    }
    state, stdout, _, err := os.process_exec(desc, context.temp_allocator)
    if err != nil || state.exit_code != 0 {
        return "", false
    }

    install := strings.trim_space(string(stdout))
    if install == "" {
        return "", false
    }
    bat := join_temp(install, "Common7/Tools/VsDevCmd.bat")
    return bat, os.is_file(bat)
}

// Joins onto a directory that may be unset, in which case the result is empty
// so add_profile skips the candidate.
@(private = "file")
join_temp :: proc(dir, rest: string) -> string {
    if dir == "" {
        return ""
    }
    return strings.concatenate({dir, "/", rest}, context.temp_allocator)
}

@(private = "file")
which_temp :: proc(name: string) -> string {
    path, _ := which(name, context.temp_allocator)
    return path
}
