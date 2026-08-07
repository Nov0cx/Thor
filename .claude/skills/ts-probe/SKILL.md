---
name: ts-probe
description: Settles a tree-sitter node-shape question by dumping the real parse tree from a throwaway test. Use before writing or debugging code that matches node types, fields or child order — never guess a grammar shape.
---

# Probe a tree-sitter node shape

Grammar shapes are the usual source of bugs in `lang/odin` and `syntax`, because
tree-sitter-odin's node names often do not match intuition. **Never guess a node
type — dump the real tree.** The probe takes under a minute.

## Why not `ts.node_string`

It hides the anonymous tokens that decide child indices. Print `ts.node_type`,
`ts.node_is_named` and the node's source text for **all** children, named and
anonymous.

## The probe

Write `lang/odin/zprobe_test.odin` — the `z` prefix sorts it away from the real
tests and marks it as throwaway:

```odin
package odin

import "core:fmt"
import "core:strings"
import "core:testing"

import ts "../../vendor/odin-tree-sitter"

@(test)
ztest_probe :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    parser := ts.parser_new()
    defer ts.parser_delete(parser)
    ts.parser_set_language(parser, e.language)

    src := `package demo

main :: proc() {
	p: Point
	x := v
}
`
    tree := ts.parser_parse_string(parser, src)
    defer ts.tree_delete(tree)

    zdump(ts.tree_root_node(tree), src, 0)
}

@(private = "file")
zdump :: proc(node: ts.Node, src: string, depth: int) {
    pad := strings.repeat(" ", depth * 2, context.temp_allocator)
    start := int(ts.node_start_byte(node))
    end := int(ts.node_end_byte(node))

    text := src[start:end]
    if len(text) > 40 {
        text = text[:40]
    }

    fmt.printfln("%s%s named=%v %q", pad, ts.node_type(node), ts.node_is_named(node), text)

    for i in 0 ..< ts.node_child_count(node) {
        zdump(ts.node_child(node, i), src, depth + 1)
    }
}
```

Put the exact construct you are matching in `src`, and nothing else — a minimal
source keeps the dump readable.

## Run it

```bash
odin test lang/odin -define:ODIN_TEST_NAMES=odin.ztest_probe -out:bin/test/zprobe.exe
```

The test name is `<package>.<proc>`, and `lang/odin`'s package name is `odin`.
`-out:` keeps the binary out of the repository root. Linking needs MSVC on PATH,
so run it from a developer shell, or through `odin run build.odin -file -- test`
if a plain shell fails to link.

For a different language, probe in `syntax` instead and set the parser's
language from `h.languages["<id>"]`.

## Delete it

**Remove `zprobe_test.odin` when the question is answered.** It is a print, not
an assertion, and it does not belong in the suite. If the answer is worth
keeping, write a real test that asserts the shape, or record it as a one-line
comment where the matching code lives.

## Worked example

Probing `x := v` shows the node type depends on where it sits:

```
  var_declaration named=true "p: Point"          <- p: Point is NOT a decl of the
    identifier named=true "p"                       name you would guess
    : named=false ":"
    type named=true "Point"
  assignment_statement named=true "x := v"       <- inside a block
```

but the same `x := v` at file scope parses as `variable_declaration`. One
construct, two node types, decided by context — which is exactly the class of
assumption that silently breaks a resolver.

Other shapes worth checking before matching them: a container literal drops its
`[]` from the named children, and a procedure body sits under
`procedure_declaration > procedure > block`, not directly under the declaration.
