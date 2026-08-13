package msvc

import "core:fmt"
import "core:testing"

// Run from the repository root: odin test msvc

// The host architecture is read off the machine, so an x64 runner must still
// produce the command line it always did. The ARM64 branch has no runner.
@(test)
test_native_arch_is_one_vsdevcmd_knows :: proc(t: ^testing.T) {
    arch := native_arch()
    testing.expectf(t, arch == "amd64" || arch == "arm64", "unknown host architecture %q", arch)
}

// -arch is the target and -host_arch the machine, so a cross build keeps the
// toolset that actually runs here.
@(test)
test_vsdevcmd_call_names_target_and_host :: proc(t: ^testing.T) {
    for target in ([?]string {"amd64", "arm64"}) {
        want := fmt.tprintf(
            `call "C:/VS/Common7/Tools/VsDevCmd.bat" -arch=%s -host_arch=%s`,
            target,
            native_arch(),
        )
        call := vsdevcmd_call("C:/VS/Common7/Tools/VsDevCmd.bat", target)
        testing.expect_value(t, call, want)
    }
}
