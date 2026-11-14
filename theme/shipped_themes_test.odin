package theme

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import ui "../vendor/loom/loom"

@(private = "file")
THEMES_DIR :: "assets/themes"

// `top` over `bottom` by the alpha of `top`.
@(private = "file")
over :: proc(top, bottom: ui.Color) -> ui.Color {
    a := f32(top.a) / 255
    return {
        u8(f32(top.r) * a + f32(bottom.r) * (1 - a) + 0.5),
        u8(f32(top.g) * a + f32(bottom.g) * (1 - a) + 0.5),
        u8(f32(top.b) * a + f32(bottom.b) * (1 - a) + 0.5),
        255,
    }
}

@(private = "file")
expect_ratio :: proc(t: ^testing.T, name, pair: string, fg, bg: ui.Color, floor: f32) {
    ratio := color_contrast_ratio(over(fg, bg), bg)
    testing.expectf(t, ratio >= floor, "%s: %s is %.2f : 1, the floor is %.1f : 1", name, pair, ratio, floor)
}

// Each shipped theme passes the contrast table of GOOD_UI.md 9.1.
@(test)
test_shipped_themes_contrast :: proc(t: ^testing.T) {
    entries, err := os.read_all_directory_by_path(THEMES_DIR, context.allocator)
    testing.expectf(t, err == nil, "cannot read %s: %v", THEMES_DIR, err)
    defer os.file_info_slice_delete(entries, context.allocator)

    count := 0
    for entry in entries {
        if !strings.has_suffix(entry.name, ".lua") {
            continue
        }
        path, join_err := filepath.join({THEMES_DIR, entry.name}, context.temp_allocator)
        if join_err != nil {
            testing.expectf(t, false, "cannot join %s: %v", entry.name, join_err)
            continue
        }
        theme, ok := load(path)
        testing.expectf(t, ok, "cannot load %s", path)
        if !ok {
            continue
        }
        defer destroy(&theme)
        count += 1

        name := theme.name
        bg   := theme.background
        expect_ratio(t, name, "text", theme.text, bg, 7)
        expect_ratio(t, name, "foreground", theme.foreground, bg, 7)
        expect_ratio(t, name, "primary_text", theme.primary_text_color, bg, 7)
        expect_ratio(t, name, "muted", theme.muted_color, bg, 4.5)
        expect_ratio(t, name, "links", theme.links_color, bg, 4.5)
        expect_ratio(t, name, "disabled", theme.disabled, bg, 3)
        expect_ratio(t, name, "accent", theme.accent_color, bg, 3)
        expect_ratio(t, name, "success", theme.success_color, bg, 3)
        expect_ratio(t, name, "warning", theme.warning_color, bg, 3)
        expect_ratio(t, name, "info", theme.info_color, bg, 3)
        expect_ratio(t, name, "danger", theme.danger_color, bg, 3)
        expect_ratio(t, name, "error", theme.error_color, bg, 3)
        expect_ratio(t, name, "conflict", theme.conflict_color, bg, 3)
        selected := over(theme.selection_background, bg)
        expect_ratio(t, name, "selection_foreground on selection", theme.selection_foreground, selected, 4.5)
        for entry, i in COLORS {
            if entry.group == .Syntax {
                expect_ratio(t, name, fmt.tprintf("syntax %s", entry.role), color_at(&theme, i)^, bg, 4.5)
            }
        }
    }
    testing.expect(t, count > 0, "no shipped theme found")
}
