#+build !windows
package shell

import "core:os"
import "core:strings"

// An empty prompt function: PowerShell writes the prompt to stdout before every
// command it reads, and a terminal draws its own.
@(private = "file")
POWERSHELL_QUIET :: "function prompt { '' }"

// A shell to look for, and how to drive it once found.
@(private = "file")
Known :: struct {
    id:   string,
    name: string,
    exe:  string,
    args: []string,
    init: []string,
    kind: Profile_Kind,
}

// A login shell reads the profile files, so the terminal gets the same PATH and
// environment a desktop terminal emulator would.
@(private = "file")
KNOWN := []Known {
    {"bash", "Bash", "bash", {"-l"}, {}, .Posix},
    {"zsh", "Zsh", "zsh", {"-l"}, {}, .Posix},
    {"fish", "Fish", "fish", {"-l"}, {}, .Fish},
    {"sh", "Shell", "sh", {"-l"}, {}, .Posix},
    {"nu", "Nushell", "nu", {}, {}, .Nushell},
    {"pwsh", "PowerShell", "pwsh", {"-NoLogo"}, {POWERSHELL_QUIET}, .Powershell},
}

// The directories a shell lands in outside PATH, so a shell that the editor's
// own environment cannot see is still offered.
@(private = "file")
PREFIXES := []string {"/bin", "/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"}

// Every shell installed on this machine, best first.
profiles_detect :: proc(allocator := context.allocator) -> []Profile {
    list := make([dynamic]Profile, allocator)

    for known in KNOWN {
        candidates := make([dynamic]string, context.temp_allocator)
        if path, ok := which(known.exe, context.temp_allocator); ok {
            append(&candidates, path)
        }
        for prefix in PREFIXES {
            append(&candidates, strings.concatenate({prefix, "/", known.exe}, context.temp_allocator))
        }
        add_profile(&list, known.id, known.name, candidates[:], known.args, known.init, known.kind, allocator)
    }

    promote_login_shell(list[:])
    return list[:]
}

// Moves the shell named by $SHELL to the front: the login shell is the one the
// user already chose, so it makes the better default.
@(private = "file")
promote_login_shell :: proc(profiles: []Profile) {
    login := os.get_env("SHELL", context.temp_allocator)
    if login == "" {
        return
    }
    for profile, i in profiles {
        if profile.exe != login {
            continue
        }
        for j := i; j > 0; j -= 1 {
            profiles[j], profiles[j - 1] = profiles[j - 1], profiles[j]
        }
        return
    }
}
