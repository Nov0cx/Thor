package ui

import "base:runtime"
import "core:encoding/json"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"

import hb "../vendor/odin-harfbuzz/harfbuzz"

// Everything the font system owns (families, atlas job records, the icon
// map) lives in this arena. The bootstrap thread fills it, ownership hands
// off to the main thread at text_finish_async_load, and text_shutdown frees
// the whole plane at once. This avoids freeing memory across threads with
// mismatched allocators (the debug tracking allocator panics on that).
font_arena: virtual.Arena
font_allocator: runtime.Allocator

// A font family is one TTF file plus the codepoint set baked into its
// atlases. Rasterization happens per size in text.odin; the file data stays
// resident so sizes not preloaded at startup can be loaded on demand.
Font_Family :: struct {
    name:          string,
    path:          string,
    file_data:     []u8,
    codepoints:    []rune,
    preload_sizes: []i32,
    // Icon fonts have no ligatures, so the shaping probes skip them.
    icon_font:     bool,
    cache:         map[i32]rl.Font,
    // Per preloaded size: glyph index -> atlas entry, for the HarfBuzz
    // shaped draw path (includes ligature glyphs, which have no codepoint).
    shaped:        map[i32]map[u32]Shaped_Glyph,
    // Persistent HarfBuzz objects for main-thread shaping at draw time;
    // created in text_finish_async_load, destroyed in text_shutdown.
    hb_blob:       ^hb.blob_t,
    hb_face:       ^hb.face_t,
    hb_font:       ^hb.font_t,
}

// Family name of the manifest's primary (UI) icon set. Widgets address
// icons by icon name through draw_icon, never through this directly.
ICON_FAMILY :: "icons"

families: map[string]^Font_Family
default_family_name: string

// Icons from every set in the manifest share one namespace; each name
// carries the family it resolves in (e.g. tabler "folder" vs. devicon
// "devicon-c-plain").
@(private = "file")
Icon_Glyph :: struct {
    family:    string,
    codepoint: rune,
}

@(private = "file")
icon_map: map[string]Icon_Glyph

@(private = "file")
icon_warned: map[string]bool

// Load ASCII, Latin-1 Supplement, and Latin Extended-A so characters
// like äöüéè render instead of falling back to '?'.
build_codepoint_list :: proc(allocator := context.temp_allocator) -> [dynamic]rune {
    codepoints := make([dynamic]rune, allocator)
    for c: rune = 0x0020; c <= 0x007E; c += 1 {
        append(&codepoints, c)
    }
    for c: rune = 0x00A0; c <= 0x017F; c += 1 {
        append(&codepoints, c)
    }
    extras := [?]rune {'€', '–', '—', '‘', '’', '“', '”', '…'}
    for c in extras {
        append(&codepoints, c)
    }
    return codepoints
}

@(private = "file")
register_family :: proc(name, ttf_path: string, codepoints: []rune, preload_sizes: []i32) -> ^Font_Family {
    data, read_err := os.read_entire_file_from_path(ttf_path, context.allocator)
    if read_err != nil {
        log.warnf("Font family %q: cannot read %q: %v", name, ttf_path, read_err)
        return nil
    }

    family := new(Font_Family)
    family.name = strings.clone(name)
    family.path = strings.clone(ttf_path)
    family.file_data = data
    family.codepoints = slice.clone(codepoints)
    family.preload_sizes = slice.clone(preload_sizes)
    family.cache = make(map[i32]rl.Font)
    family.shaped = make(map[i32]map[u32]Shaped_Glyph)
    families[family.name] = family
    return family
}

@(private = "file")
manifest_dir :: proc(path: string) -> string {
    index := max(strings.last_index_byte(path, '/'), strings.last_index_byte(path, '\\'))
    if index < 0 {
        return ""
    }
    return path[:index + 1]
}

@(private = "file")
manifest_parse :: proc(path: string) -> (json.Object, bool) {
    data, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
    if read_err != nil {
        log.warnf("Cannot read manifest %q: %v", path, read_err)
        return nil, false
    }

    root, parse_err := json.parse(data, parse_integers = true, allocator = context.temp_allocator)
    if parse_err != .None {
        log.warnf("Cannot parse manifest %q: %v", path, parse_err)
        return nil, false
    }

    obj, ok := root.(json.Object)
    if !ok {
        log.warnf("Manifest %q: root is not an object", path)
        return nil, false
    }
    return obj, true
}

@(private = "file")
manifest_sizes :: proc(entry: json.Object, key: string) -> [dynamic]i32 {
    sizes := make([dynamic]i32, context.temp_allocator)
    array, ok := entry[key].(json.Array)
    if !ok {
        return sizes
    }
    for value in array {
        #partial switch v in value {
        case json.Integer:
            append(&sizes, cast(i32) v)
        case json.Float:
            append(&sizes, cast(i32) v)
        }
    }
    return sizes
}

// Registers every text font family listed in the manifest. Paths are
// relative to the manifest file. Safe to call before InitWindow; nothing
// here touches the GL context.
text_load_font_manifest :: proc(manifest_path: string) -> bool {
    root, root_ok := manifest_parse(manifest_path)
    if !root_ok {
        return false
    }
    dir := manifest_dir(manifest_path)

    if value, has_default := root["default"]; has_default {
        if name, ok := value.(json.String); ok {
            default_family_name = strings.clone(string(name))
        }
    }

    fonts, fonts_ok := root["fonts"].(json.Object)
    if !fonts_ok {
        log.warnf("Font manifest %q: missing \"fonts\" object", manifest_path)
        return false
    }

    text_codepoints := build_codepoint_list(context.temp_allocator)
    registered := 0
    for name, value in fonts {
        entry, entry_ok := value.(json.Object)
        if !entry_ok {
            log.warnf("Font manifest %q: entry %q is not an object", manifest_path, name)
            continue
        }
        rel, rel_ok := entry["path"].(json.String)
        if !rel_ok {
            log.warnf("Font manifest %q: entry %q has no \"path\"", manifest_path, name)
            continue
        }

        sizes := manifest_sizes(entry, "preload_sizes")
        full_path := strings.concatenate({dir, strings.trim_prefix(string(rel), "./")}, context.temp_allocator)
        if register_family(name, full_path, text_codepoints[:], sizes[:]) != nil {
            registered += 1
        }
    }

    // No explicit default: fall back to any registered family.
    if default_family_name == "" {
        for name in fonts {
            default_family_name = strings.clone(name)
            break
        }
    }
    return registered > 0
}

// Registers one icon font family per manifest "fonts" entry plus the icon
// name -> (family, codepoint) map. Only the "preload" icons are baked into
// startup atlases; names outside that list still resolve but render their
// font's fallback glyph.
text_load_icon_manifest :: proc(manifest_path: string) -> bool {
    root, root_ok := manifest_parse(manifest_path)
    if !root_ok {
        return false
    }
    dir := manifest_dir(manifest_path)

    fonts, fonts_ok := root["fonts"].(json.Object)
    if !fonts_ok {
        log.warnf("Icon manifest %q: missing \"fonts\" object", manifest_path)
        return false
    }

    sizes := manifest_sizes(root, "preload_sizes")
    icon_map = make(map[string]Icon_Glyph)
    icon_warned = make(map[string]bool)

    registered := 0
    for family_name, value in fonts {
        entry, entry_ok := value.(json.Object)
        if !entry_ok {
            log.warnf("Icon manifest %q: entry %q is not an object", manifest_path, family_name)
            continue
        }
        rel, rel_ok := entry["font"].(json.String)
        if !rel_ok {
            log.warnf("Icon manifest %q: entry %q has no \"font\"", manifest_path, family_name)
            continue
        }
        icons, icons_ok := entry["icons"].(json.Object)
        if !icons_ok {
            log.warnf("Icon manifest %q: entry %q has no \"icons\" object", manifest_path, family_name)
            continue
        }

        family_key := strings.clone(family_name)
        for name, glyph_value in icons {
            glyph, glyph_ok := glyph_value.(json.String)
            if !glyph_ok || len(glyph) == 0 {
                continue
            }
            codepoint, _ := utf8.decode_rune_in_string(string(glyph))
            icon_map[strings.clone(name)] = Icon_Glyph {family = family_key, codepoint = codepoint}
        }

        codepoints := make([dynamic]rune, context.temp_allocator)
        if preload, preload_ok := entry["preload"].(json.Array); preload_ok {
            for preload_value in preload {
                name, name_ok := preload_value.(json.String)
                if !name_ok {
                    continue
                }
                if glyph, found := icon_map[string(name)]; found && glyph.family == family_key {
                    append(&codepoints, glyph.codepoint)
                } else {
                    log.warnf("Icon manifest %q: preload icon %q not in icon map", manifest_path, name)
                }
            }
        }

        full_path := strings.concatenate({dir, strings.trim_prefix(string(rel), "./")}, context.temp_allocator)
        if family := register_family(family_key, full_path, codepoints[:], sizes[:]); family != nil {
            family.icon_font = true
            registered += 1
        }
    }
    return registered > 0
}

icon_codepoint :: proc(name: string) -> (rune, bool) {
    glyph, ok := icon_map[name]
    return glyph.codepoint, ok
}

// Draws a single icon glyph; size is the pixel height of the icon font.
draw_icon :: proc(name: string, x, y, size: i32, color: rl.Color) {
    glyph, ok := icon_map[name]
    if !ok {
        if !icon_warned[name] {
            icon_warned[strings.clone(name, font_allocator)] = true
            log.warnf("Unknown icon %q", name)
        }
        return
    }
    font := get_font(size, glyph.family)
    rl.DrawTextCodepoint(font, glyph.codepoint, rl.Vector2 {cast(f32) x, cast(f32) y}, cast(f32) size, color)
}

measure_icon :: proc(name: string, size: i32) -> i32 {
    glyph, ok := icon_map[name]
    if !ok {
        return 0
    }

    font := get_font(size, glyph.family)
    index := rl.GetGlyphIndex(font, glyph.codepoint)
    scale := cast(f32) size / cast(f32) font.baseSize
    advance := font.glyphs[index].advanceX
    if advance != 0 {
        return cast(i32) (cast(f32) advance * scale)
    }
    return cast(i32) (font.recs[index].width * scale)
}

text_shutdown :: proc() {
    // Fonts hold raylib/libc-allocated glyph buffers and GPU textures, so
    // they are unloaded individually; all Odin-side memory goes with the
    // arena in one call.
    default_texture_id := rl.GetFontDefault().texture.id
    for _, family in families {
        for _, font in family.cache {
            if font.texture.id != default_texture_id {
                rl.UnloadFont(font)
            }
        }
        shape_family_destroy(family)
    }
    shape_shutdown()

    families = nil
    icon_map = nil
    icon_warned = nil
    default_family_name = ""

    virtual.arena_destroy(&font_arena)
    font_allocator = {}
}
