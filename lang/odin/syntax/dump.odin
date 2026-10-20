package odinsyntax

import "core:fmt"
import "core:strings"

// An indented listing of the tree, one line per node and token:
// `Kind@start..end` for a node, `Kind@start..end "text" {flags}` for a token.
// With `trivia` false, trivia tokens are left out.
debug_dump :: proc(root: ^Green_Node, allocator := context.allocator, trivia := true) -> string {
    sb := strings.builder_make(allocator)
    dump_node(&sb, root, 0, 0, trivia)
    return strings.to_string(sb)
}

@(private)
dump_node :: proc(sb: ^strings.Builder, node: ^Green_Node, offset: u32, depth: int, trivia: bool) {
    write_indent(sb, depth)
    fmt.sbprintf(sb, "%v@%d..%d\n", node.kind, offset, offset + node.text_len)
    pos := offset
    for child in node.children {
        switch v in child {
        case ^Green_Node:
            dump_node(sb, v, pos, depth + 1, trivia)
        case ^Green_Token:
            if trivia || !token_is_trivia(v.kind) {
                dump_token(sb, v, pos, depth + 1)
            }
        }
        pos += element_len(child)
    }
}

@(private)
dump_token :: proc(sb: ^strings.Builder, tok: ^Green_Token, pos: u32, depth: int) {
    write_indent(sb, depth)
    fmt.sbprintf(sb, "%v@%d..%d %q", tok.kind, pos, pos + u32(len(tok.text)), tok.text)
    if tok.flags != {} {
        strings.write_string(sb, " {")
        sep := ""
        for flag in tok.flags {
            fmt.sbprintf(sb, "%s%v", sep, flag)
            sep = ", "
        }
        strings.write_byte(sb, '}')
    }
    strings.write_byte(sb, '\n')
}

@(private)
write_indent :: proc(sb: ^strings.Builder, depth: int) {
    for _ in 0 ..< depth {
        strings.write_string(sb, "  ")
    }
}
