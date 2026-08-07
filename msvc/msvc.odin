// Where the MSVC tools are. The build driver needs them to link harfbuzz.lib and
// libtree-sitter.lib, the terminal to offer a developer prompt as a shell.
package msvc

import "core:os"
import "core:path/filepath"
import "core:strings"

// Ships with every Visual Studio since 2017, always at this path.
VSWHERE :: "C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"

// The batch file that loads the environment of the newest Visual Studio with the
// C++ tools, as vswhere reports it. ok is false when the tools are absent and on
// a platform that has no vswhere. Temporary memory.
find_vsdevcmd :: proc() -> (path: string, ok: bool) {
    if !os.is_file(VSWHERE) {
        return "", false
    }

    desc := os.Process_Desc {
        command = {
            VSWHERE,
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

    bat, join_err := filepath.join({install, "Common7", "Tools", "VsDevCmd.bat"}, context.temp_allocator)
    if join_err != nil {
        return "", false
    }
    return bat, os.is_file(bat)
}
