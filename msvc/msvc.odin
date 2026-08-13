// Where the MSVC tools are. The build driver needs them to link harfbuzz.lib and
// libtree-sitter.lib, the terminal to offer a developer prompt as a shell.
package msvc

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Ships with every Visual Studio since 2017, always at this path. Still under
// "Program Files (x86)" on an ARM64 machine, where the installer also lands.
VSWHERE :: "C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"

// The VC toolset components vswhere is asked for, one per architecture.
@(private)
TOOLS_X64 :: "Microsoft.VisualStudio.Component.VC.Tools.x86.x64"

@(private)
TOOLS_ARM64 :: "Microsoft.VisualStudio.Component.VC.Tools.ARM64"

// The architecture of the machine itself, as VsDevCmd spells it. Read at run
// time and not from ODIN_ARCH: an x64 binary runs emulated on an ARM64 machine,
// where its own architecture is not the host's. PROCESSOR_ARCHITEW6432 is what
// the emulated process sees the real machine as.
native_arch :: proc() -> string {
    for name in ([?]string {"PROCESSOR_ARCHITEW6432", "PROCESSOR_ARCHITECTURE"}) {
        value := os.get_env(name, context.temp_allocator)
        if value == "" {
            continue
        }
        if strings.equal_fold(value, "ARM64") {
            return "arm64"
        }
        return "amd64"
    }
    return "amd64"
}

// The `call` line that loads the MSVC environment for `target_arch` from
// `vsdevcmd`. The tools themselves are the host's, so -host_arch names the
// machine and -arch what it builds for. Temporary memory.
vsdevcmd_call :: proc(vsdevcmd: string, target_arch: string) -> string {
    return fmt.tprintf(
        `call "%s" -arch=%s -host_arch=%s`,
        vsdevcmd,
        target_arch,
        native_arch(),
    )
}

// The batch file that loads the environment of the newest Visual Studio with the
// C++ tools, as vswhere reports it. ok is false when the tools are absent and on
// a platform that has no vswhere. Temporary memory.
find_vsdevcmd :: proc() -> (path: string, ok: bool) {
    if !os.is_file(VSWHERE) {
        return "", false
    }

    // An ARM64 machine may carry either toolset, so either one answers; asking
    // for the x64 one alone hides an ARM64-only install altogether.
    requires := [][]string {{"-requires", TOOLS_X64}}
    if native_arch() == "arm64" {
        requires = {{"-requires", TOOLS_X64}, {"-requires", TOOLS_ARM64}, {"-requiresAny"}}
    }
    command := make([dynamic]string, 0, 12, context.temp_allocator)
    append(&command, VSWHERE, "-latest", "-products", "*")
    for group in requires {
        append(&command, ..group)
    }
    append(&command, "-property", "installationPath")

    desc := os.Process_Desc {
        command = command[:],
    }
    state, stdout, _, err := os.process_exec(desc, context.temp_allocator)
    if err != nil || state.exit_code != 0 {
        return "", false
    }

    install := strings.trim_space(string(stdout))
    if install == "" {
        return "", false
    }

    bat, join_err := filepath.join({install, "Common7", "Tools", "VsDevCmd.bat"}, context.temp_allocator)
    if join_err != nil {
        return "", false
    }
    return bat, os.is_file(bat)
}
