package lang

import "core:testing"

// A URI carries one separator and Windows has two, so the comparison the document
// lookup makes cannot be a string compare there.
@(test)
test_path_equal :: proc(t: ^testing.T) {
    testing.expect(t, path_equal("/home/x/main.c", "/home/x/main.c"))
    testing.expect(t, !path_equal("/home/x/main.c", "/home/x/other.c"))
    testing.expect(t, !path_equal("/home/x", "/home/x/"))

    when ODIN_OS == .Windows {
        testing.expect(t, path_equal("C:/src/main.c", "c:\\src\\Main.c"))
    } else {
        testing.expect(t, !path_equal("/home/X", "/home/x"))
    }
}
