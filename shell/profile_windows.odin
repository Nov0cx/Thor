#+build windows
package shell

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

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

    add_profile(&list, "msys2", "MSYS2", {"C:/msys64/usr/bin/bash.exe", "C:/msys32/usr/bin/bash.exe"}, {"--login"}, {}, .Posix, allocator)
    add_profile(&list, "cygwin", "Cygwin", {"C:/cygwin64/bin/bash.exe", "C:/cygwin/bin/bash.exe"}, {"--login"}, {}, .Posix, allocator)
    add_profile(&list, "wsl", "WSL", {join_temp(system32, "wsl.exe")}, {}, {}, .Posix, allocator)
    add_profile(&list, "nu", "Nushell", {which_temp("nu.exe"), join_temp(program_files, "nu/bin/nu.exe")}, {}, {}, .Nushell, allocator)

    return list[:]
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
