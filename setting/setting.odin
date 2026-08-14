package setting

// Loads Thor's config from a directory of comments.json, keybinds.json and
// settings.json. Missing or malformed files degrade to empty lookups.
//
// Three layers, each overlaying the last per key: GLOBAL_DIR holds the shipped
// defaults, USER_DIR what the GUI writes, and a workspace's .thor/ its own
// overlay. Only USER_DIR and .thor/ are ever written — GLOBAL_DIR is replaced
// wholesale by a build and by an update.

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

import "../input"
import "../lang"

// A parsed key chord, e.g. "ctrl+shift+k" -> {key = .K, mods = {.Ctrl, .Shift}}.
Keybind :: struct {
    key:  rl.KeyboardKey,
    mods: input.Modifiers,
}

// General editor preferences with sensible defaults, overridable via
// settings.json.
General :: struct {
    tab_width:         int,
    font_size:         int,
    autosave_delay_ms: int,
    // Active color theme (a name under assets/themes/, no extension), text
    // font family (a name in fonts.json), and the primary and file icon packs
    // (family names in icons.json). Empty means "use the built-in default"; all
    // are owned strings, freed in destroy.
    theme:             string,
    font:              string,
    icon_pack:         string,
    file_icon_pack:    string,
    // What opening a folder does: "ask" (default), "same" to replace the current
    // window's workspace, "new" to launch another window. Owned, freed in destroy.
    open_folder_in:    string,
    // The shell a new terminal starts, by profile id ("pwsh", "git-bash",
    // "msvc", ...). Empty picks the best shell installed. Owned.
    default_shell:     string,
    // Draw the font's programming ligatures ("->" as one glyph). On by default.
    ligatures:         bool,
    // Format the active buffer before an explicit save (Ctrl+S, Save All, the
    // palette) — never before an autosave. Off by default.
    format_on_save:    bool,
    // Format-on-type: dispatch Format_On_Type as the user types a trigger
    // character the backend asked for. Off by default — an edit landing while
    // the user is still typing is intrusive, unlike a save-triggered format.
    format_on_type:    bool,
    // Ask GitHub for a newer release shortly after start, at most once a day.
    // On by default; Help > Check for Updates asks whatever this holds.
    check_for_updates: bool,
    // Show the hover explanation of a control after a short dwell. On by default.
    tooltips:          bool,
    // Show the tip of the day: the card on the welcome page, and the one that
    // opens over the editor on the first start of a day. On by default.
    tip_of_the_day:    bool,
    // Language intelligence: the master switch and the features still allowed
    // under it, read from the "language_intelligence" entry. Both are on by
    // default; the editor pushes them onto lang.Manager, which enforces them.
    language_enabled:  bool,
    language_features: bit_set[lang.Request_Kind],
    // Per-backend admin gate: a server id ("clangd") or the Odin analyzer
    // ("odin") mapped to its own enabled switch and feature bit_set, read from
    // "language_backends"'s per-id entry the same way the top-level
    // language_intelligence entry is read. An id absent from the map is fully
    // enabled — this only ever holds ids a user has touched. ANDs with the
    // top-level language_features gate rather than replacing it: a kind either
    // one declines stays declined. Owned keys.
    language_backends: map[string]Backend_Setting,
}

// One backend's admin gate: mirrors General's own language_enabled/
// language_features pair, scoped to a single backend id. The *_set fields say
// which keys a config layer actually stated; a key no layer states falls back to
// the backend's own default (an lsp.json entry's `enabled`/`features`) rather
// than to this struct's.
Backend_Setting :: struct {
    enabled:      bool,
    features:     bit_set[lang.Request_Kind],
    enabled_set:  bool,
    features_set: bit_set[lang.Request_Kind],
}

// settings.json key holding the language-intelligence gate: either a boolean
// (the master switch alone) or an object of "enabled" plus one key per feature.
LANGUAGE_SETTING :: "language_intelligence"

// The key of the master switch inside that object.
LANGUAGE_ENABLED_KEY :: "enabled"

// settings.json key holding the per-backend admin gate: an object of backend
// id -> either a bare bool (that backend's master switch alone) or an object
// shaped exactly like language_intelligence's own ("enabled" plus one key per
// feature). Layered the same way: only the ids, and within an id only the
// keys, present in a given file overlay what's already there.
LANGUAGE_BACKENDS_SETTING :: "language_backends"

// The shipped defaults, staged beside the binary by a build and swapped by an
// update. Read-only: nothing Thor writes lands here.
GLOBAL_DIR :: "settings"

// What the GUI writes, beside the binary and beside GLOBAL_DIR. Never staged
// and never swapped, so a build or an update keeps it.
USER_DIR :: "user"

// Where an opened folder goes. Parsed from the open_folder_in setting.
Open_Folder_In :: enum {
    Ask,
    Same,
    New,
}

// One entry of tips.json: a short lesson the welcome page shows, one a day.
Tip :: struct {
    title:  string, // owned
    body:   string, // owned
    // The keybinds.json action the tip is about ("command_palette"), never a
    // chord: the reader resolves it against the keybinds in force, so a rebind
    // shows the new chord. Owned; "" for a tip with no action of its own.
    action: string,
}

Settings :: struct {
    // File extension (".odin") -> line-comment marker ("//").
    comments: map[string]string,
    // Action name ("toggle_line_comment") -> bound chord.
    keybinds: map[string]Keybind,
    general:  General,
    // The tips of every config layer, in load order. Layers append here rather
    // than overlay: a workspace adds its own tips, it does not hide the shipped
    // ones. Owned.
    tips:     [dynamic]Tip,
}

// Reads comments.json and keybinds.json from dir. Always returns an
// initialized Settings; parse failures just leave the maps sparse.
load :: proc(dir: string) -> Settings {
    s: Settings
    s.comments = make(map[string]string)
    s.keybinds = make(map[string]Keybind)
    s.tips = make([dynamic]Tip)
    s.general = General {
        tab_width         = 4,
        font_size         = 18,
        autosave_delay_ms = 1500,
        ligatures         = true,
        format_on_save    = false,
        format_on_type    = false,
        check_for_updates = true,
        tooltips          = true,
        tip_of_the_day    = true,
        language_enabled  = true,
        language_features = lang.FEATURES_ALL,
        language_backends = make(map[string]Backend_Setting),
    }

    load_dir(&s, dir)
    return s
}

// Overlays the config in dir onto an already-loaded Settings: per-key entries
// win, missing/malformed leaves the base untouched. Layers .thor/ over the defaults.
load_overlay :: proc(s: ^Settings, dir: string) {
    load_dir(s, dir)
}

@(private)
load_dir :: proc(s: ^Settings, dir: string) {
    load_comments(s, strings.concatenate({dir, "/comments.json"}, context.temp_allocator))
    load_keybinds(s, strings.concatenate({dir, "/keybinds.json"}, context.temp_allocator))
    load_general(s, strings.concatenate({dir, "/settings.json"}, context.temp_allocator))
    load_tips(s, strings.concatenate({dir, "/tips.json"}, context.temp_allocator))
}

destroy :: proc(s: ^Settings) {
    for key, value in s.comments {
        delete(key)
        delete(value)
    }
    delete(s.comments)

    for key in s.keybinds {
        delete(key)
    }
    delete(s.keybinds)

    delete(s.general.theme)
    delete(s.general.font)
    delete(s.general.icon_pack)
    delete(s.general.file_icon_pack)
    delete(s.general.open_folder_in)
    delete(s.general.default_shell)

    for key in s.general.language_backends {
        delete(key)
    }
    delete(s.general.language_backends)

    for tip in s.tips {
        delete(tip.title)
        delete(tip.body)
        delete(tip.action)
    }
    delete(s.tips)
    s.tips = nil
}

// Line-comment marker for a file, or "" when the language is unknown (which
// disables Ctrl+K commenting for that file).
comment_prefix :: proc(s: ^Settings, filename: string) -> string {
    slash := max(strings.last_index_byte(filename, '/'), strings.last_index_byte(filename, '\\'))
    base := filename[slash + 1:]
    // A whole-name entry ("CMakeLists.txt") wins over the extension it happens
    // to carry, and is the only key for a name that has none ("Makefile").
    if prefix, ok := s.comments[base]; ok {
        return prefix
    }

    dot := strings.last_index_byte(base, '.')
    if dot < 0 {
        return ""
    }
    return s.comments[base[dot:]]
}

keybind :: proc(s: ^Settings, action: string) -> (Keybind, bool) {
    kb, ok := s.keybinds[action]
    return kb, ok
}

tab_width :: proc(s: ^Settings) -> int {
    return s.general.tab_width
}

font_size :: proc(s: ^Settings) -> int {
    return s.general.font_size
}

autosave_delay_ms :: proc(s: ^Settings) -> int {
    return s.general.autosave_delay_ms
}

// Active theme name, or "" when unset (caller falls back to its built-in default).
theme_name :: proc(s: ^Settings) -> string {
    return s.general.theme
}

// Active font family name, or "" when unset (caller uses the manifest default).
font_family :: proc(s: ^Settings) -> string {
    return s.general.font
}

// Active primary icon pack (a family name in icons.json), or "" when unset
// (caller falls back to its built-in default).
icon_pack_name :: proc(s: ^Settings) -> string {
    return s.general.icon_pack
}

// Active file-tree icon pack (a family name in icons.json), or "" when unset
// (caller falls back to its built-in default).
file_icon_pack_name :: proc(s: ^Settings) -> string {
    return s.general.file_icon_pack
}

// Profile id of the shell a new terminal starts, or "" to let the editor pick
// the best one installed.
default_shell :: proc(s: ^Settings) -> string {
    return s.general.default_shell
}

// Whether text draws the font's ligatures.
ligatures :: proc(s: ^Settings) -> bool {
    return s.general.ligatures
}

// Whether an explicit save formats the buffer first.
format_on_save :: proc(s: ^Settings) -> bool {
    return s.general.format_on_save
}

// Whether typing a trigger character dispatches on-type formatting.
format_on_type :: proc(s: ^Settings) -> bool {
    return s.general.format_on_type
}

// Whether Thor asks GitHub for a newer release in the background.
check_for_updates :: proc(s: ^Settings) -> bool {
    return s.general.check_for_updates
}

// Whether a control explains itself when the cursor rests on it.
tooltips :: proc(s: ^Settings) -> bool {
    return s.general.tooltips
}

// Whether the tip of the day is shown. Off hides the welcome page card and
// keeps the card over the editor closed; tips.json is still read.
tip_of_the_day :: proc(s: ^Settings) -> bool {
    return s.general.tip_of_the_day
}

// Whether language intelligence runs at all. Off makes every backend silent,
// whatever the per-feature gate holds.
language_enabled :: proc(s: ^Settings) -> bool {
    return s.general.language_enabled
}

// The language features the config allows, ignoring the master switch — what a
// settings UI shows as the per-feature rows.
language_features :: proc(s: ^Settings) -> bit_set[lang.Request_Kind] {
    return s.general.language_features
}

// Whether one language feature runs: the master switch and its own key.
language_feature_enabled :: proc(s: ^Settings, kind: lang.Request_Kind) -> bool {
    return s.general.language_enabled && kind in s.general.language_features
}

// What the config layers state about one backend, and whether any of them named
// it at all. The caller reads the *_set fields to tell a stated value from the
// struct's default, and falls back to the backend's own default for the rest.
backend_state :: proc(s: ^Settings, id: string) -> (Backend_Setting, bool) {
    cfg, ok := s.general.language_backends[id]
    return cfg, ok
}

// Whether one backend (an LSP server id, or "odin" for the in-client analyzer)
// is admin-enabled by the settings alone. An id the config never mentions is
// enabled by default — a caller that has a backend default to fall back to
// wants backend_state instead.
backend_enabled :: proc(s: ^Settings, id: string) -> bool {
    cfg, ok := s.general.language_backends[id]
    return !ok || cfg.enabled
}

// The features one backend allows, ignoring its own enabled switch — what a
// settings UI shows as that backend's per-feature rows. An id the config never
// mentions allows everything.
backend_features :: proc(s: ^Settings, id: string) -> bit_set[lang.Request_Kind] {
    cfg, ok := s.general.language_backends[id]
    if !ok {
        return lang.FEATURES_ALL
    }
    return cfg.features
}

// Whether one backend answers one kind: its own enabled switch and its own
// feature key. Does not fold in the top-level language_intelligence gate — the
// Manager already ANDs that in separately.
backend_feature_enabled :: proc(s: ^Settings, id: string, kind: lang.Request_Kind) -> bool {
    return backend_enabled(s, id) && kind in backend_features(s, id)
}

// Where an opened folder goes. Unset or unrecognized means Ask.
open_folder_in :: proc(s: ^Settings) -> Open_Folder_In {
    return parse_open_folder_in(s.general.open_folder_in)
}

// Maps the open_folder_in setting string onto the enum. Anything else is Ask, so
// a typo prompts rather than silently picking a window.
parse_open_folder_in :: proc(value: string) -> Open_Folder_In {
    switch value {
    case "same":
        return .Same
    case "new":
        return .New
    }
    return .Ask
}

// The settings.json spelling of a choice, for persisting it back.
open_folder_in_value :: proc(choice: Open_Folder_In) -> string {
    switch choice {
    case .Same:
        return "same"
    case .New:
        return "new"
    case .Ask:
        return "ask"
    }
    return "ask"
}

// Rewrites `path` (a settings JSON object) with key set to value, preserving
// every other key. Used to persist a UI-chosen theme/font back into
// settings.json. A missing/malformed file starts a fresh object. Returns ok.
persist_string :: proc(path, key, value: string) -> bool {
    root := load_root_object(path)
    root[key] = json.String(value)
    return write_object(path, root)
}

// Creates `path` as an empty settings object when it does not exist, keeping an
// existing file as it is. Lets a layer the user has never written be opened for
// hand editing.
persist_object :: proc(path: string) -> bool {
    return write_object(path, load_root_object(path))
}

// Like persist_string but for an integer field (tab_width, font_size, ...).
persist_int :: proc(path, key: string, value: int) -> bool {
    root := load_root_object(path)
    root[key] = json.Integer(value)
    return write_object(path, root)
}

// Like persist_string but for a boolean field (ligatures, ...).
persist_bool :: proc(path, key: string, value: bool) -> bool {
    root := load_root_object(path)
    root[key] = json.Boolean(value)
    return write_object(path, root)
}

// Like persist_bool but one level down, in the object under `group` — the
// language-intelligence gate's shape. The rest of the group is preserved; a
// group that is missing, or holds anything but an object (the boolean shorthand
// of "language_intelligence"), is replaced by a fresh one.
persist_nested_bool :: proc(path, group, key: string, value: bool) -> bool {
    root := load_root_object(path)
    obj, ok := root[group].(json.Object)
    if !ok {
        obj = make(json.Object, allocator = context.temp_allocator)
    }
    obj[key] = json.Boolean(value)
    root[group] = obj
    return write_object(path, root)
}

// Like persist_nested_bool but two levels down: `root[group][subgroup][key] =
// value`. The per-backend admin gate's shape — subgroup is a backend id, key is
// either LANGUAGE_ENABLED_KEY or a feature name. Every other id and key is
// preserved; a level that is missing, or holds anything but an object (a bare
// bool at that level), is replaced by a fresh one.
persist_double_nested_bool :: proc(path, group, subgroup, key: string, value: bool) -> bool {
    root := load_root_object(path)
    outer, outer_ok := root[group].(json.Object)
    if !outer_ok {
        outer = make(json.Object, allocator = context.temp_allocator)
    }
    inner, inner_ok := outer[subgroup].(json.Object)
    if !inner_ok {
        inner = make(json.Object, allocator = context.temp_allocator)
    }
    inner[key] = json.Boolean(value)
    outer[subgroup] = inner
    root[group] = outer
    return write_object(path, root)
}

// Rewrites keybinds.json with `action` bound to `spec`, updating it in whichever
// group already holds it and preserving every other binding. An action not yet
// present lands in a "custom" group. An empty spec persists as an explicit unbind.
persist_keybind :: proc(path, action, spec: string) -> bool {
    root := load_root_object(path)

    updated := false
    for _, group_value in root {
        group, ok := group_value.(json.Object)
        if !ok {
            continue
        }
        if _, has := group[action]; has {
            group[action] = json.String(spec)
            updated = true
            break
        }
    }
    if !updated {
        group: json.Object
        if existing, ok := root["custom"].(json.Object); ok {
            group = existing
        } else {
            group = make(json.Object, allocator = context.temp_allocator)
        }
        group[action] = json.String(spec)
        root["custom"] = group
    }
    return write_object(path, root)
}

// Parses `path` as a JSON object, or a fresh temp-allocated one when it is
// missing or malformed. The result is only valid until the temp allocator resets.
@(private)
load_root_object :: proc(path: string) -> json.Object {
    if existing, ok := parse_object(path); ok {
        return existing
    }
    return make(json.Object, allocator = context.temp_allocator)
}

// The directory part of a config path, empty when it names none. Both
// separators count: a workspace path carries whatever the platform gave it.
@(private)
parent_dir :: proc(path: string) -> string {
    cut := strings.last_index_any(path, "/\\")
    if cut <= 0 {
        return ""
    }
    return path[:cut]
}

@(private)
write_object :: proc(path: string, root: json.Object) -> bool {
    data, err := json.marshal(root, {pretty = true, use_spaces = true, spaces = 4}, context.temp_allocator)
    if err != nil {
        log.errorf("Cannot marshal settings %q: %v", path, err)
        return false
    }
    // USER_DIR does not exist until the first write to it.
    dir := parent_dir(path)
    if dir != "" && dir != "." && !os.is_dir(dir) {
        if derr := os.make_directory(dir); derr != nil {
            log.errorf("Cannot create settings directory %q: %v", dir, derr)
            return false
        }
    }
    if werr := os.write_entire_file(path, data); werr != nil {
        log.errorf("Cannot write settings %q: %v", path, werr)
        return false
    }
    return true
}

// True when an incoming key event exactly matches the chord (modifiers must
// match precisely so ctrl+k and ctrl+shift+k stay distinct).
keybind_matches :: proc(kb: Keybind, key: rl.KeyboardKey, mods: input.Modifiers) -> bool {
    return kb.key == key && kb.mods == mods
}

// Formats a chord for display, e.g. {key = .K, mods = {.Ctrl, .Shift}} ->
// "Ctrl+Shift+K". Returns "" for an unset key so callers can treat it as "no
// binding".
keybind_to_string :: proc(kb: Keybind, allocator := context.temp_allocator) -> string {
    if kb.key == .KEY_NULL {
        return ""
    }
    b := strings.builder_make(allocator)
    input.write_names(&b, kb.mods)
    write_key_name(&b, kb.key)
    return strings.to_string(b)
}

// Serializes a chord to the canonical spec parse_keybind reads back, e.g.
// {key = .PAGE_UP, mods = {.Ctrl}} -> "ctrl+page_up". An unset key yields "" (an
// unbind).
keybind_spec :: proc(kb: Keybind, allocator := context.temp_allocator) -> string {
    if kb.key == .KEY_NULL {
        return strings.clone("", allocator)
    }
    b := strings.builder_make(allocator)
    input.write_tokens(&b, kb.mods)
    write_key_token(&b, kb.key)
    return strings.to_string(b)
}

// Canonical lowercase token for a key, matching key_from_name so the spec round-trips.
@(private)
write_key_token :: proc(b: ^strings.Builder, key: rl.KeyboardKey) {
    #partial switch key {
    case .PAGE_UP:      strings.write_string(b, "page_up");   return
    case .PAGE_DOWN:    strings.write_string(b, "page_down"); return
    case .UP:           strings.write_string(b, "up");        return
    case .DOWN:         strings.write_string(b, "down");      return
    case .LEFT:         strings.write_string(b, "left");      return
    case .RIGHT:        strings.write_string(b, "right");     return
    case .HOME:         strings.write_string(b, "home");      return
    case .END:          strings.write_string(b, "end");       return
    case .ENTER, .KP_ENTER: strings.write_string(b, "enter"); return
    case .ESCAPE:       strings.write_string(b, "escape");    return
    case .TAB:          strings.write_string(b, "tab");       return
    case .SPACE:        strings.write_string(b, "space");     return
    case .BACKSPACE:    strings.write_string(b, "backspace"); return
    case .DELETE:       strings.write_string(b, "delete");    return
    case .BACKSLASH:    strings.write_string(b, "backslash"); return
    case .PERIOD:       strings.write_string(b, "period");    return
    case .COMMA:        strings.write_string(b, "comma");     return
    case .KP_ADD:       strings.write_string(b, "kp_add");      return
    case .KP_SUBTRACT:  strings.write_string(b, "kp_subtract"); return
    case .F1:  strings.write_string(b, "f1");  return
    case .F2:  strings.write_string(b, "f2");  return
    case .F3:  strings.write_string(b, "f3");  return
    case .F4:  strings.write_string(b, "f4");  return
    case .F5:  strings.write_string(b, "f5");  return
    case .F6:  strings.write_string(b, "f6");  return
    case .F7:  strings.write_string(b, "f7");  return
    case .F8:  strings.write_string(b, "f8");  return
    case .F9:  strings.write_string(b, "f9");  return
    case .F10: strings.write_string(b, "f10"); return
    case .F11: strings.write_string(b, "f11"); return
    case .F12: strings.write_string(b, "f12"); return
    }
    ki := int(key)
    if ki >= int(rl.KeyboardKey.A) && ki <= int(rl.KeyboardKey.Z) {
        strings.write_byte(b, u8('a' + (ki - int(rl.KeyboardKey.A))))
        return
    }
    if ki >= int(rl.KeyboardKey.ZERO) && ki <= int(rl.KeyboardKey.NINE) {
        strings.write_byte(b, u8('0' + (ki - int(rl.KeyboardKey.ZERO))))
        return
    }
}

@(private)
write_key_name :: proc(b: ^strings.Builder, key: rl.KeyboardKey) {
    #partial switch key {
    case .PAGE_UP:      strings.write_string(b, "PgUp");  return
    case .PAGE_DOWN:    strings.write_string(b, "PgDn");  return
    case .UP:           strings.write_string(b, "Up");    return
    case .DOWN:         strings.write_string(b, "Down");  return
    case .LEFT:         strings.write_string(b, "Left");  return
    case .RIGHT:        strings.write_string(b, "Right"); return
    case .HOME:         strings.write_string(b, "Home");  return
    case .END:          strings.write_string(b, "End");   return
    case .ENTER, .KP_ENTER: strings.write_string(b, "Enter"); return
    case .ESCAPE:       strings.write_string(b, "Esc");   return
    case .TAB:          strings.write_string(b, "Tab");   return
    case .SPACE:        strings.write_string(b, "Space"); return
    case .BACKSPACE:    strings.write_string(b, "Backspace"); return
    case .DELETE:       strings.write_string(b, "Del");   return
    case .BACKSLASH:    strings.write_string(b, "\\");    return
    case .PERIOD:       strings.write_string(b, ".");     return
    case .COMMA:        strings.write_string(b, ",");     return
    case .KP_ADD:       strings.write_string(b, "+");     return
    case .KP_SUBTRACT:  strings.write_string(b, "-");     return
    case .F1:  strings.write_string(b, "F1");  return
    case .F2:  strings.write_string(b, "F2");  return
    case .F3:  strings.write_string(b, "F3");  return
    case .F4:  strings.write_string(b, "F4");  return
    case .F5:  strings.write_string(b, "F5");  return
    case .F6:  strings.write_string(b, "F6");  return
    case .F7:  strings.write_string(b, "F7");  return
    case .F8:  strings.write_string(b, "F8");  return
    case .F9:  strings.write_string(b, "F9");  return
    case .F10: strings.write_string(b, "F10"); return
    case .F11: strings.write_string(b, "F11"); return
    case .F12: strings.write_string(b, "F12"); return
    }
    ki := int(key)
    if ki >= int(rl.KeyboardKey.A) && ki <= int(rl.KeyboardKey.Z) {
        strings.write_byte(b, u8('A' + (ki - int(rl.KeyboardKey.A))))
        return
    }
    if ki >= int(rl.KeyboardKey.ZERO) && ki <= int(rl.KeyboardKey.NINE) {
        strings.write_byte(b, u8('0' + (ki - int(rl.KeyboardKey.ZERO))))
        return
    }
    strings.write_string(b, "?")
}

// Parses "ctrl+shift+k" into a Keybind. Modifiers are order-insensitive; the
// single non-modifier token names the key (see key_from_name). An empty (or
// whitespace-only) spec is an explicit unbind: a valid Keybind whose key is
// KEY_NULL, which keybind_matches never matches against a real press.
parse_keybind :: proc(spec: string) -> (Keybind, bool) {
    kb: Keybind
    if strings.trim_space(spec) == "" {
        return kb, true
    }
    key_set := false

    parts := strings.split(spec, "+", context.temp_allocator)
    for part in parts {
        token := strings.to_lower(strings.trim_space(part), context.temp_allocator)
        if mod, is_mod := input.modifier_from_token(token); is_mod {
            kb.mods += {mod}
            continue
        }
        key, ok := key_from_name(token)
        if !ok {
            return kb, false
        }
        kb.key = key
        key_set = true
    }
    return kb, key_set
}

@(private)
key_from_name :: proc(name: string) -> (rl.KeyboardKey, bool) {
    if len(name) == 1 {
        c := name[0]
        switch {
        case c >= 'a' && c <= 'z':
            return rl.KeyboardKey(int(rl.KeyboardKey.A) + int(c - 'a')), true
        case c >= 'A' && c <= 'Z':
            return rl.KeyboardKey(int(rl.KeyboardKey.A) + int(c - 'A')), true
        case c >= '0' && c <= '9':
            return rl.KeyboardKey(int(rl.KeyboardKey.ZERO) + int(c - '0')), true
        }
    }

    switch name {
    case "page_up":   return .PAGE_UP, true
    case "page_down": return .PAGE_DOWN, true
    case "up":        return .UP, true
    case "down":      return .DOWN, true
    case "left":      return .LEFT, true
    case "right":     return .RIGHT, true
    case "home":      return .HOME, true
    case "end":       return .END, true
    case "enter":     return .ENTER, true
    case "escape":    return .ESCAPE, true
    case "tab":       return .TAB, true
    case "space":     return .SPACE, true
    case "backspace": return .BACKSPACE, true
    case "delete":    return .DELETE, true
    // Physical key right of the home row: \ on US, # on QWERTZ.
    case "backslash": return .BACKSLASH, true
    case ".", "period": return .PERIOD, true
    case ",", "comma":  return .COMMA, true
    case "kp_add":      return .KP_ADD, true
    case "kp_subtract": return .KP_SUBTRACT, true
    case "f1":  return .F1, true
    case "f2":  return .F2, true
    case "f3":  return .F3, true
    case "f4":  return .F4, true
    case "f5":  return .F5, true
    case "f6":  return .F6, true
    case "f7":  return .F7, true
    case "f8":  return .F8, true
    case "f9":  return .F9, true
    case "f10": return .F10, true
    case "f11": return .F11, true
    case "f12": return .F12, true
    }
    return .KEY_NULL, false
}

@(private)
parse_object :: proc(path: string) -> (json.Object, bool) {
    // An absent file is a supported state (a first run has none), so only a
    // real read failure is worth a warning.
    if !os.exists(path) {
        return nil, false
    }
    data, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
    if read_err != nil {
        log.warnf("Cannot read settings %q: %v", path, read_err)
        return nil, false
    }

    root, parse_err := json.parse(data, allocator = context.temp_allocator)
    if parse_err != .None {
        log.warnf("Cannot parse settings %q: %v", path, parse_err)
        return nil, false
    }

    obj, ok := root.(json.Object)
    if !ok {
        log.warnf("Settings %q: root is not an object", path)
        return nil, false
    }
    return obj, true
}

@(private)
load_comments :: proc(s: ^Settings, path: string) {
    root, ok := parse_object(path)
    if !ok {
        return
    }

    for language, value in root {
        entry, entry_ok := value.(json.Object)
        if !entry_ok {
            continue
        }
        line, line_ok := entry["line"].(json.String)
        if !line_ok {
            continue
        }
        extensions, ext_ok := entry["extensions"].(json.Array)
        if !ext_ok {
            log.warnf("Settings %q: language %q has no \"extensions\" array", path, language)
            continue
        }
        for ext_value in extensions {
            ext, ext_str_ok := ext_value.(json.String)
            if !ext_str_ok {
                continue
            }
            put_comment(s, string(ext), string(line))
        }
    }
}

// Reads tips.json: {"tips": [{"title": ..., "body": ..., "action": ...}]}.
// Appends, so the shipped tips come first and a user/ or workspace file adds to
// them. An entry with no title or no body is skipped; a half tip would show as
// a blank card.
@(private)
load_tips :: proc(s: ^Settings, path: string) {
    root, ok := parse_object(path)
    if !ok {
        return
    }
    read_tips(s, root, path)
}

// The tips of one already-parsed file. `path` only names the file in a warning.
@(private)
read_tips :: proc(s: ^Settings, root: json.Object, path: string) {
    entries, entries_ok := root["tips"].(json.Array)
    if !entries_ok {
        log.warnf("Settings %q: no \"tips\" array", path)
        return
    }

    for value in entries {
        entry, entry_ok := value.(json.Object)
        if !entry_ok {
            continue
        }
        title, title_ok := entry["title"].(json.String)
        body, body_ok := entry["body"].(json.String)
        if !title_ok || !body_ok || title == "" || body == "" {
            log.warnf("Settings %q: a tip has no \"title\" or no \"body\"", path)
            continue
        }
        action, _ := entry["action"].(json.String)
        append(&s.tips, Tip {
            title  = strings.clone(string(title)),
            body   = strings.clone(string(body)),
            action = strings.clone(string(action)),
        })
    }
}

// Inserts or overwrites a comment marker, reusing the owned key and freeing the
// old value on overwrite so an overlay does not leak.
@(private)
put_comment :: proc(s: ^Settings, ext, line: string) {
    if old, ok := s.comments[ext]; ok {
        delete(old)
        s.comments[ext] = strings.clone(line)
    } else {
        s.comments[strings.clone(ext)] = strings.clone(line)
    }
}

@(private)
load_general :: proc(s: ^Settings, path: string) {
    root, ok := parse_object(path)
    if !ok {
        return
    }
    read_int(root, "tab_width", &s.general.tab_width)
    read_int(root, "font_size", &s.general.font_size)
    read_int(root, "autosave_delay_ms", &s.general.autosave_delay_ms)
    read_string(root, "theme", &s.general.theme)
    read_string(root, "font", &s.general.font)
    read_string(root, "icon_pack", &s.general.icon_pack)
    read_string(root, "file_icon_pack", &s.general.file_icon_pack)
    read_bool(root, "ligatures", &s.general.ligatures)
    read_bool(root, "format_on_save", &s.general.format_on_save)
    read_bool(root, "format_on_type", &s.general.format_on_type)
    read_bool(root, "check_for_updates", &s.general.check_for_updates)
    read_bool(root, "tooltips", &s.general.tooltips)
    read_bool(root, "tip_of_the_day", &s.general.tip_of_the_day)
    read_string(root, "open_folder_in", &s.general.open_folder_in)
    read_string(root, "default_shell", &s.general.default_shell)
    read_language(s, root)
    read_backend_toggles(s, root)
}

// Reads the language-intelligence gate. A boolean is the master switch on its
// own ("language_intelligence": false turns everything off); an object carries
// "enabled" plus one key per feature (lang.feature_name), each of which layers
// onto what is already there — an unlisted feature keeps its state, so a
// workspace file can turn one off without restating the rest.
@(private)
read_language :: proc(s: ^Settings, root: json.Object) {
    #partial switch value in root[LANGUAGE_SETTING] {
    case json.Boolean:
        s.general.language_enabled = cast(bool) value
    case json.Object:
        read_bool(value, LANGUAGE_ENABLED_KEY, &s.general.language_enabled)
        for kind in lang.Request_Kind {
            on := kind in s.general.language_features
            read_bool(value, lang.feature_name(kind), &on)
            if on {
                s.general.language_features += {kind}
            } else {
                s.general.language_features -= {kind}
            }
        }
    }
}

// Reads the per-backend admin gate: an object of id -> either a bare bool (that
// backend's master switch alone) or an object shaped like language_intelligence
// itself ("enabled" plus one key per feature). Only the ids present overlay the
// map, and within an id only the keys present overlay its Backend_Setting — the
// same two-level layering read_language gives the top-level entry.
@(private)
read_backend_toggles :: proc(s: ^Settings, root: json.Object) {
    obj, ok := root[LANGUAGE_BACKENDS_SETTING].(json.Object)
    if !ok {
        return
    }
    for id, value in obj {
        cfg, existed := s.general.language_backends[id]
        if !existed {
            cfg = Backend_Setting {
                enabled  = true,
                features = lang.FEATURES_ALL,
            }
        }
        #partial switch v in value {
        case json.Boolean:
            cfg.enabled = bool(v)
            cfg.enabled_set = true
        case json.Object:
            if read_bool(v, LANGUAGE_ENABLED_KEY, &cfg.enabled) {
                cfg.enabled_set = true
            }
            for kind in lang.Request_Kind {
                on := kind in cfg.features
                if !read_bool(v, lang.feature_name(kind), &on) {
                    continue
                }
                cfg.features_set += {kind}
                if on {
                    cfg.features += {kind}
                } else {
                    cfg.features -= {kind}
                }
            }
        case:
            continue
        }
        if existed {
            s.general.language_backends[id] = cfg
        } else {
            s.general.language_backends[strings.clone(id)] = cfg
        }
    }
}

// Reads a string field into dst, replacing (and freeing) any prior value so an
// overlay layer wins without leaking. Absent or non-string leaves dst untouched.
@(private)
read_string :: proc(obj: json.Object, key: string, dst: ^string) {
    if value, ok := obj[key].(json.String); ok {
        delete(dst^)
        dst^ = strings.clone(string(value))
    }
}

// Reads an integer field into dst, leaving the default in place if absent.
@(private)
read_int :: proc(obj: json.Object, key: string, dst: ^int) {
    #partial switch v in obj[key] {
    case json.Integer:
        dst^ = cast(int) v
    case json.Float:
        dst^ = cast(int) v
    }
}

// Reads a boolean field into dst, leaving the default in place if absent.
// Returns whether the file stated the key, which is what tells a stated `false`
// from an unstated one.
@(private)
read_bool :: proc(obj: json.Object, key: string, dst: ^bool) -> bool {
    value, ok := obj[key].(json.Boolean)
    if !ok {
        return false
    }
    dst^ = cast(bool) value
    return true
}

@(private)
load_keybinds :: proc(s: ^Settings, path: string) {
    root, ok := parse_object(path)
    if !ok {
        return
    }

    // keybinds.json groups bindings (e.g. "editor", "global"); action names
    // share one flat namespace regardless of group.
    for group_name, group_value in root {
        group, group_ok := group_value.(json.Object)
        if !group_ok {
            continue
        }
        for action, spec_value in group {
            spec, spec_ok := spec_value.(json.String)
            if !spec_ok {
                continue
            }
            kb, parsed := parse_keybind(string(spec))
            if !parsed {
                log.warnf("Settings %q: %s.%s has invalid binding %q", path, group_name, action, spec)
                continue
            }
            if _, ok := s.keybinds[action]; ok {
                s.keybinds[action] = kb // reuse existing owned key
            } else {
                s.keybinds[strings.clone(action)] = kb
            }
        }
    }
}
