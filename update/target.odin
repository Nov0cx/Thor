package update

// Which release archive this machine takes. The four names match the NAME
// variables of .github/workflows/release.yml exactly; a rename there is a rename
// here.

import "core:fmt"
import "core:os"
import "core:strings"

// A published release archive, one per build job of the release workflow.
Target :: enum {
    Windows_X64,
    Linux_X64,
    Arch_X64,
    Macos_Arm64,
}

// The container the archive uses. Windows ships a zip, everything else a
// gzipped tar.
Archive :: enum {
    Zip,
    Tar_Gz,
}

// The `/etc/os-release` file the Arch flavour is read from. A parameter of
// `linux_flavor` rather than a read inside it, so the choice is testable.
OS_RELEASE :: "/etc/os-release"

// The asset name for a target, `thor-<version>-<platform>.<ext>`. The archive
// unpacks to one folder of the same stem.
target_asset_name :: proc(target: Target, version: string, allocator := context.allocator) -> string {
    switch target {
    case .Windows_X64:
        return fmt.aprintf("thor-%s-windows-x86_64.zip", version, allocator = allocator)
    case .Linux_X64:
        return fmt.aprintf("thor-%s-linux-x86_64.tar.gz", version, allocator = allocator)
    case .Arch_X64:
        return fmt.aprintf("thor-%s-arch-x86_64.tar.gz", version, allocator = allocator)
    case .Macos_Arm64:
        return fmt.aprintf("thor-%s-macos-arm64.tar.gz", version, allocator = allocator)
    }
    return ""
}

// The container a target's archive uses.
target_archive :: proc(target: Target) -> Archive {
    return target == .Windows_X64 ? .Zip : .Tar_Gz
}

// The binary name inside a target's archive.
target_exe_name :: proc(target: Target) -> string {
    return target == .Windows_X64 ? "thor.exe" : "thor"
}

// Reads an /etc/os-release body and answers which Linux archive it takes. The
// Arch build links against a rolling glibc, so only Arch and its derivatives
// may have it; everything else takes the Ubuntu build.
linux_flavor :: proc(os_release: string) -> Target {
    lines := os_release
    for line in strings.split_lines_iterator(&lines) {
        key, _, value := strings.partition(strings.trim_space(line), "=")
        value = strings.trim(value, "\"'")
        switch key {
        case "ID":
            if strings.equal_fold(value, "arch") {
                return .Arch_X64
            }
        case "ID_LIKE":
            likes := value
            for like in strings.split_iterator(&likes, " ") {
                if strings.equal_fold(like, "arch") {
                    return .Arch_X64
                }
            }
        }
    }
    return .Linux_X64
}

// The archive this machine takes. False for a platform no release job builds —
// a 32-bit build, an ARM Linux, an Intel mac — where the updater can only send
// the user to the releases page.
target_host :: proc() -> (target: Target, ok: bool) {
    when ODIN_OS == .Windows && ODIN_ARCH == .amd64 {
        return .Windows_X64, true
    } else when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
        return .Macos_Arm64, true
    } else when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
        data, err := os.read_entire_file(OS_RELEASE, context.temp_allocator)
        if err != nil {
            return .Linux_X64, true
        }
        return linux_flavor(string(data)), true
    } else {
        return {}, false
    }
}
