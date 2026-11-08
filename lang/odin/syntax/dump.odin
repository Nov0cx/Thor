package odinsyntax

import "core:fmt"
import "core:strings"

// An indented listing of the tree, one line per node and token:
// `Kind@start..end` for a node, `Kind@start..end "text" {flags}` for a token.
// With `trivia` false, trivia tokens are left out.
debug_dump :: proc(tree: ^Green_Tree, allocator := context.allocator, trivia := true) -> string {
    sb := strings.builder_make(allocator)
    if tree.root != nil {
        dump_node(&sb, tree.text, tree.root, 0, 0, trivia)
    }
    return strings.to_string(sb)
}

@(private)
dump_node :: proc(sb: ^strings.Builder, text: string, node: ^Green_Node, offset: u32, depth: int, trivia: bool) {
    write_indent(sb, depth)
    fmt.sbprintf(sb, "%v@%d..%d\n", node.kind, offset, offset + node.text_len)
    pos := offset
    for child in green_children(node) {
        if n, is_node := element_node(child); is_node {
            dump_node(sb, text, n, pos, depth + 1, trivia)
        } else if tok, _ := element_token(child); trivia || !token_is_trivia(tok.kind) {
            dump_token(sb, text, tok, pos, depth + 1)
        }
        pos += element_len(child)
    }
}

@(private)
dump_token :: proc(sb: ^strings.Builder, text: string, tok: Green_Token, pos: u32, depth: int) {
    write_indent(sb, depth)
    fmt.sbprintf(sb, "%v@%d..%d %q", tok.kind, pos, pos + tok.len, text[pos:][:tok.len])
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
