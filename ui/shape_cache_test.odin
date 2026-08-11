package ui

import "core:fmt"
import "core:testing"

@(test)
test_shape_cache_eviction_is_lru :: proc(t: ^testing.T) {
    cache: Shape_Cache
    defer shape_cache_clear(&cache)

    dummy: Font_Family
    glyphs := []Placed_Glyph{{}}

    // Fill to capacity.
    for i in 0 ..< SHAPE_CACHE_CAPACITY {
        key := Shape_Cache_Key{family = &dummy, size = 17, line = fmt.tprintf("line-%d", i)}
        shape_cache_put(&cache, key, glyphs)
    }
    testing.expect_value(t, shape_cache_len(&cache), SHAPE_CACHE_CAPACITY)

    // Touch entry 0 so it's the most recently used, then insert one more:
    // eviction must take entry 1 (now the true oldest), not entry 0.
    key0 := Shape_Cache_Key{family = &dummy, size = 17, line = "line-0"}
    _, hit0 := shape_cache_get(&cache, key0)
    testing.expect(t, hit0, "entry 0 should still be resident before overflow")

    key1 := Shape_Cache_Key{family = &dummy, size = 17, line = "line-1"}
    overflow_key := Shape_Cache_Key{family = &dummy, size = 17, line = "overflow"}
    shape_cache_put(&cache, overflow_key, glyphs)

    testing.expect_value(t, shape_cache_len(&cache), SHAPE_CACHE_CAPACITY)
    _, still_hit0 := shape_cache_get(&cache, key0)
    testing.expect(t, still_hit0, "recently touched entry should survive eviction")
    _, hit1 := shape_cache_get(&cache, key1)
    testing.expect(t, !hit1, "true least-recently-used entry should be evicted")
}

@(test)
test_shape_cache_clear_frees_and_allows_reinsert :: proc(t: ^testing.T) {
    cache: Shape_Cache
    defer shape_cache_clear(&cache)

    dummy: Font_Family
    key := Shape_Cache_Key{family = &dummy, size = 17, line = "x"}
    shape_cache_put(&cache, key, []Placed_Glyph{{advance = 7}})
    testing.expect_value(t, shape_cache_len(&cache), 1)

    shape_cache_clear(&cache)
    testing.expect_value(t, shape_cache_len(&cache), 0)

    glyphs, hit := shape_cache_get(&cache, key)
    testing.expect(t, !hit, "cleared cache must not resurrect old entries")
    testing.expect(t, glyphs == nil, "miss must return nil, not stale data")
}
