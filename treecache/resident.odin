package treecache

import "core:sync"

// True when `path` holds a tree parsed with `grammar` that no parse holds now, so for_source only copies
// it or re-parses the edit. False also while another thread parses the buffer.
resident :: proc(c: ^Cache, path, grammar: string) -> bool {
    sync.lock(&c.mutex)
    defer sync.unlock(&c.mutex)
    for entry in c.entries {
        if entry.path != path {
            continue
        }
        if !sync.try_lock(&entry.mutex) {
            return false
        }
        defer sync.unlock(&entry.mutex)
        return entry.tree != nil && entry.grammar == grammar
    }
    return false
}
