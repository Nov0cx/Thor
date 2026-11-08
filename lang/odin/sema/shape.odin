package odinsema

import "core:hash"

// A hash of what a package scope reads from an item tree: the package clause, the tags, and per
// item its kind, name, visibility, guard, signature, attributes, path, children and members, with
// the `when` conditions. Offsets and doc comments do not count, so equal hashes mean equal item
// lists, index by index.
item_tree_shape_hash :: proc(tree: ^Item_Tree) -> u64 {
    h := hash.fnv64a(nil)
    if tree == nil {
        return h
    }
    h = shape_string(h, tree.package_name)
    h = shape_int(h, int(tree.private))
    h = shape_int(h, len(tree.tags))
    for tag in tree.tags {
        h = shape_string(h, tag)
    }
    h = shape_int(h, len(tree.items))
    for &item in tree.items {
        h = shape_item(h, &item)
    }
    h = shape_int(h, len(tree.guards))
    for g in tree.guards {
        h = shape_string(h, g.cond)
        h = shape_int(h, g.expr)
        h = shape_int(h, g.previous)
        h = shape_int(h, g.parent)
    }
    h = shape_int(h, len(tree.conds))
    for c in tree.conds {
        h = shape_int(h, int(c.op))
        h = shape_int(h, int(c.value))
        h = shape_string(h, c.text)
        h = shape_int(h, len(c.args))
        for a in c.args {
            h = shape_int(h, a)
        }
    }
    return h
}

@(private = "file")
shape_item :: proc(h: u64, item: ^Item) -> u64 {
    h := h
    h = shape_int(h, int(item.kind))
    h = shape_string(h, item.name)
    h = shape_int(h, int(item.visibility))
    h = shape_int(h, item.guard)
    h = shape_int(h, int(item.in_foreign))
    h = shape_string(h, item.signature)
    h = shape_string(h, item.path)
    h = shape_int(h, len(item.attributes))
    for a in item.attributes {
        h = shape_string(h, a.name)
        h = shape_string(h, a.value)
    }
    h = shape_int(h, len(item.children))
    for child in item.children {
        h = shape_int(h, int(child.kind))
        h = shape_string(h, child.name)
    }
    h = shape_int(h, len(item.members))
    for m in item.members {
        h = shape_string(h, m.operand)
        h = shape_string(h, m.name)
    }
    return h
}

@(private = "file")
shape_string :: proc(h: u64, s: string) -> u64 {
    return hash.fnv64a(transmute([]byte)s, shape_int(h, len(s)))
}

@(private = "file")
shape_int :: proc(h: u64, v: int) -> u64 {
    v := i64(v)
    return hash.fnv64a(([^]byte)(&v)[:size_of(v)], h)
}
