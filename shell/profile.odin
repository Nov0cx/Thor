package shell

import "core:os"
import "core:strings"

// A shell a terminal can run on: the executable, the arguments that make it read
// commands from a pipe, and the syntax the terminal needs to drive it.
//
// Each platform file supplies:
//
//     profiles_detect :: proc(allocator := context.allocator) -> []Profile
//
// It returns every shell installed on this machine, best first. Every string in
// the result is owned; release the slice with profiles_destroy.

// How a shell spells the things the terminal has to say. One entry per syntax,
// not per shell: bash, zsh, dash and git bash all share Posix.
Profile_Kind :: enum {
    Posix,
    Cmd,
    Powershell,
    Fish,
    Nushell,
}

Profile :: struct {
    id:   string,   // stable key: what settings and the tab state store
    name: string,   // shown in the tab and the shell menu
    exe:  string,   // absolute path
    args: []string, // owned
    // Commands sent once at start, whose output the terminal drops. They quiet
    // the prompt and, for a developer shell, load the MSVC environment.
    init: []string, // owned
    kind: Profile_Kind,
}

// Frees a detected profile list.
profiles_destroy :: proc(profiles: []Profile) {
    for profile in profiles {
        delete(profile.id)
        delete(profile.name)
        delete(profile.exe)
        for arg in profile.args {
            delete(arg)
        }
        delete(profile.args)
        for command in profile.init {
            delete(command)
        }
        delete(profile.init)
    }
    delete(profiles)
}

// The profile with this id, or ok=false when it is absent (an uninstalled shell
// named in settings, say).
profile_find :: proc(profiles: []Profile, id: string) -> (Profile, bool) {
    for profile in profiles {
        if profile.id == id {
            return profile, true
        }
    }
    return {}, false
}

// The command that makes a shell announce that the previous command finished:
// `token` followed by the exit status on a line of its own. The terminal sends
// it after every command and treats its arrival as the end of the output.
end_command :: proc(kind: Profile_Kind, token: string, allocator := context.allocator) -> string {
    switch kind {
    case .Cmd:
        return strings.concatenate({"echo ", token, "%ERRORLEVEL%"}, allocator)
    case .Powershell:
        // $LASTEXITCODE only tracks native programs, so a cmdlet failure is read
        // off $? instead.
        return strings.concatenate({`Write-Output "`, token, `$(if ($?) { 0 } else { 1 })"`}, allocator)
    case .Fish:
        return strings.concatenate({"printf '%s%s\\n' '", token, "' $status"}, allocator)
    case .Nushell:
        return strings.concatenate({`print $"`, token, `($env.LAST_EXIT_CODE)"`}, allocator)
    case .Posix:
        return strings.concatenate({"printf '%s%s\\n' '", token, "' \"$?\""}, allocator)
    }
    return strings.clone("", allocator)
}

// Absolute path of `name` on PATH, searched the way the platform searches it.
// Returns ok=false when the executable is absent.
which :: proc(name: string, allocator := context.allocator) -> (string, bool) {
    path := os.get_env("PATH", context.temp_allocator)
    if path == "" {
        return "", false
    }

    separator := ODIN_OS == .Windows ? ";" : ":"
    for dir in strings.split_iterator(&path, separator) {
        trimmed := strings.trim_space(dir)
        if trimmed == "" {
            continue
        }
        candidate := strings.concatenate({trimmed, "/", name}, context.temp_allocator)
        if os.is_file(candidate) {
            return strings.clone(candidate, allocator), true
        }
    }
    return "", false
}

// Appends a profile when one of `candidates` names an existing executable. The
// candidates are tried in order and an empty one is skipped, so a detector can
// pass a `which` result that found nothing. Every stored string is cloned into
// `allocator`. Returns whether a profile was added.
@(private)
add_profile :: proc(
    list: ^[dynamic]Profile,
    id, name: string,
    candidates: []string,
    args, init: []string,
    kind: Profile_Kind,
    allocator := context.allocator,
) -> bool {
    exe := ""
    for candidate in candidates {
        if candidate != "" && os.is_file(candidate) {
            exe = candidate
            break
        }
    }
    if exe == "" {
        return false
    }

    append(list, Profile {
        id   = strings.clone(id, allocator),
        name = strings.clone(name, allocator),
        exe  = strings.clone(exe, allocator),
        args = clone_list(args, allocator),
        init = clone_list(init, allocator),
        kind = kind,
    })
    return true
}

// Clones a string list, for the args and init fields a detector fills.
@(private)
clone_list :: proc(items: []string, allocator := context.allocator) -> []string {
    out := make([]string, len(items), allocator)
    for item, i in items {
        out[i] = strings.clone(item, allocator)
    }
    return out
}
