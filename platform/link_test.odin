package platform

import "core:testing"
import rl "vendor:raylib"

// The one call into raylib.lib this test binary must make. The binding removes
// the default CRT and takes the one raylib.lib names, so an optimized link with
// no raylib object has no CRT.
@(test)
test_raylib_links :: proc(t: ^testing.T) {
    testing.expect_value(t, rl.ColorToInt(rl.Color{12, 34, 56, 78}), 0x0c22384e)
}
