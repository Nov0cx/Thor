package odinsyntax

import "core:fmt"
import "core:strings"

// An indented listing of the tree, one line per node and token, trivia included:
// `Kind@start..end` for a node, `Kind@start..end "text" {flags}` for a token.
debug_dump :: proc(root: ^Green_Node, allocator := context.allocator) -> string {
    sb := strings.builder_make(allocator)
    dump_node(&sb, root, 0, 0)
    return strings.to_string(sb)
}

@(private)
dump_node :: proc(sb: ^strings.Builder, node: ^Green_Node, offset: u32, depth: int) {
    write_indent(sb, depth)
    fmt.sbprintf(sb, "%v@%d..%d\n", node.kind, offset, offset + node.text_len)
    pos := offset
    for child in node.children {
        switch v in child {
        case ^Green_Node:
            dump_node(sb, v, pos, depth + 1)
        case ^Green_Token:
            write_indent(sb, depth + 1)
            fmt.sbprintf(sb, "%v@%d..%d %q", v.kind, pos, pos + u32(len(v.text)), v.text)
            if v.flags != {} {
                strings.write_string(sb, " {")
                sep := ""
                for flag in v.flags {
                    fmt.sbprintf(sb, "%s%v", sep, flag)
                    sep = ", "
                }
                strings.write_byte(sb, '}')
            }
            strings.write_byte(sb, '\n')
        }
        pos += element_len(child)
    }
}

@(private)
write_indent :: proc(sb: ^strings.Builder, depth: int) {
    for _ in 0 ..< depth {
        strings.write_string(sb, "  ")
    }
}
