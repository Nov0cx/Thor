package thor

import "core:os"
import "core:strings"
import "core:testing"

import "../plugin"
import "../setting"
import "../theme"
import ui "../vendor/loom/loom"

@(private = "file")
migrate_write :: proc(t: ^testing.T, path, text: string) {
    dir := path[:strings.last_index_byte(path, '/')]
    testing.expect(t, os.make_directory_all(dir) == nil || os.is_dir(dir), "could not create the test dir")
    testing.expect(t, os.write_entire_file(path, transmute([]u8)text) == nil, "could not write the test file")
}

// A folder of old JSON config converts to Lua that loads the same values, and
// the JSON stays beside it as .json.bak.
@(test)
test_migrate_json_config :: proc(t: ^testing.T) {
    root :: "thor_migrate_lua.tmp"
    defer os.remove_all(root)

    migrate_write(t, root + "/settings.json", `{"font_size": 21, "theme": "x"}`)
    migrate_write(t, root + "/keybinds.json", `{"files": {"save": "ctrl+s"}}`)
    migrate_write(t, root + "/themes/x.json", `{"name": "X", "colors": {"Keywords Color": "#112233"}}`)
    migrate_write(t, root + "/plugins/p/plugin.json", `{"name": "p", "permissions": ["read"]}`)
    // A Lua file already there wins; its JSON stays.
    migrate_write(t, root + "/tips.json", `{}`)
    migrate_write(t, root + "/tips.lua", "return {}")

    converted := make([dynamic]string)
    defer {
        for path in converted {
            delete(path)
        }
        delete(converted)
    }
    thor_migrate_json_config(root, &converted)
    testing.expect_value(t, len(converted), 4)

    loaded := setting.load(root)
    defer setting.destroy(&loaded)
    testing.expect_value(t, setting.font_size(&loaded), 21)
    _, has_save := loaded.keybinds["save"]
    testing.expect(t, has_save, "the keybind converts")

    palette, ok := theme.load(root + "/themes/x.lua")
    defer theme.destroy(&palette)
    testing.expect(t, ok && palette.name == "X", "the theme converts")
    testing.expect_value(t, palette.keywords_color, ui.Color {0x11, 0x22, 0x33, 0xFF})

    perms := plugin.manifest_permissions(root + "/plugins/p")
    testing.expect(t, perms != {}, "the manifest converts")

    for name in ([]string {"settings.json.bak", "keybinds.json.bak", "themes/x.json.bak", "plugins/p/plugin.json.bak", "tips.json"}) {
        testing.expectf(t, os.exists(strings.concatenate({root, "/", name}, context.temp_allocator)), "%s is kept", name)
    }

    // A second run finds nothing left to convert.
    again := len(converted)
    thor_migrate_json_config(root, &converted)
    testing.expect_value(t, len(converted), again)
}
