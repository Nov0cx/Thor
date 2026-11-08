package thor

// The tutorial lab: a broken Odin file the reader repairs with Thor's own tools.
// Each task reads the live buffer, so a fix ticks off before it is saved.

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../atomicfile"
import "../editview"
import odinsyntax "../lang/odin/syntax"
import "../setting"
import "../textedit"
import ui "../vendor/loom/loom"

LAB_TASKS :: 8

// The lab file, relative to the binary.
LAB_FILE :: setting.USER_DIR + "/tutorial/playground.odin"

// The broken playground, line by line. The trailing spaces are deliberate.
@(private = "file")
LAB_LINES := [?]string {
    "package tutorial",
    "",
    "// Thor's tutorial playground. Every defect in this file is deliberate: it",
    "// does not parse, it does not compile.",
    "// The tutorial card explains them one at a time and names the key that",
    "// fixes each one.",
    "",
    "import \"core:strings\"",
    "",
    "MAX_ITEMS :: 32",
    "DEFAULT_LABEL :: \"item\"  ",
    "RETRY_LIMIT   :: 3",
    "",
    "Shape :: enum {",
    "    Circle,",
    "    Square,",
    "    Triangle,",
    "}",
    "",
    "Item :: struct {",
    "    name:  string,",
    "    count: int, ",
    "    shape: Shape,",
    "}",
    "",
    "// The number of sides a shape has.",
    "sides :: proc(shape: Shape) -> int {",
    "    switch shape {",
    "    case .Circle:",
    "        return 0",
    "    }",
    "    return -1",
    "}",
    "",
    "// Prints one line per item, then the total.",
    "report :: proc(items: []Item) {",
    "    total = 0",
    "    for it in items {",
    "    total += it.count",
    "    fmt.printfln(\"%s x%d\", it.name, it.count",
    "    }",
    "        fmt.printfln(\"%s: %d items, %d total\", DEFAULT_LABEL, len(items), total)   ",
    "}",
    "",
}

@(private = "file")
LAB_SHAPES := [?]string{"Circle", "Square", "Triangle"}

@(private = "file")
LAB_CONSTANTS := [?]string{"MAX_ITEMS", "DEFAULT_LABEL", "RETRY_LIMIT"}

@(private = "file")
LAB_TITLES := [LAB_TASKS]string {
    "Close the call, so the file parses",
    "Import the package `fmt` comes from",
    "Remove the import nothing uses",
    "Declare `total` before you assign to it",
    "Handle every `Shape` in the switch",
    "Put the body of `report` at the right depth",
    "Remove the trailing whitespace",
    "Align the three constants",
}

// A line of `report` and the indent it must have.
@(private = "file")
Indent_Rule :: struct {
    prefix: string, // the trimmed line with its spaces removed starts with this
    want:   int,
    label:  string,
}

@(private = "file")
LAB_INDENT := [?]Indent_Rule {
    {"total+=it.count", 8, "`total += it.count`"},
    {"fmt.printfln(\"%sx%d\"", 8, "the per-item `fmt.printfln`"},
    {"fmt.printfln(\"%s:%ditems", 4, "the last `fmt.printfln`"},
}

Lab :: struct {
    // The range "Show me" selected, spotlit while the step is up.
    show_lo:   int,
    show_hi:   int,
    show_task: int, // -1 when nothing is shown
}

// What every task reads: the buffer, its lines and where the parse stopped.
// All in the temp allocator; `src` borrows the buffer for the frame.
Lab_State :: struct {
    src:        string,
    lines:      []string,
    starts:     []int, // byte offset of each line
    parse_ok:   bool,
    parse_at:   int,
    parse_end:  int,
    parse_msg:  string,
}

thor_lab_destroy :: proc(lab: ^Lab) {
    lab^ = {}
}

// The broken source. In the temp allocator.
thor_lab_source :: proc() -> string {
    return strings.join(LAB_LINES[:], "\n", context.temp_allocator)
}

thor_lab_title :: proc(task: int) -> string {
    return task >= 0 && task < LAB_TASKS ? LAB_TITLES[task] : ""
}

// The absolute path of the lab file. In the temp allocator.
thor_lab_path :: proc() -> string {
    return thor_abs_path(LAB_FILE)
}

// The lab buffer, when it is open and loaded.
thor_lab_file :: proc(thor: ^Thor) -> ^Open_File {
    file, _ := thor_find_open_file(thor, thor_lab_path())
    if file == nil || !file.loaded {
        return nil
    }
    return file
}

// Opens the lab chapter: writes the playground when it is missing, opens it, and
// asks before it resets a copy that was edited.
thor_lab_start :: proc(thor: ^Thor) {
    thor.tutorial.lab.show_task = -1
    path := thor_lab_path()
    source := thor_lab_source()
    current, err := os.read_entire_file(path, context.temp_allocator)
    if err != nil {
        if !thor_lab_write(thor, path, source) {
            return
        }
    }
    thor_open_file(thor, path)
    if err == nil && string(current) != source {
        thor_palette_confirm(thor, "Reset playground.odin to the broken original?", thor_lab_reset, thor)
    }
}

// Confirm callback: puts the broken original back, in the buffer too.
thor_lab_reset :: proc(data: rawptr) {
    thor := cast(^Thor) data
    path := thor_lab_path()
    source := thor_lab_source()
    if !thor_lab_write(thor, path, source) {
        return
    }
    if file, _ := thor_find_open_file(thor, path); file != nil && file.loaded {
        textedit.set_text(&file.state, source)
        thor_mark_saved(file)
        thor_invalidate_file_derived(file)
    }
    thor.tutorial.lab.show_task = -1
}

@(private = "file")
thor_lab_write :: proc(thor: ^Thor, path, source: string) -> bool {
    if dir := filepath.dir(path); dir != "" && !os.is_dir(dir) {
        if err := os.make_directory_all(dir); err != nil {
            log.errorf("Could not create %q: %v", dir, err)
            thor_flash_status(thor, "The tutorial folder could not be created", is_error = true)
            return false
        }
    }
    if err := atomicfile.write(path, transmute([]byte)source); err != nil {
        log.errorf("Could not write %q: %v", path, err)
        thor_flash_status(thor, "The playground could not be written", is_error = true)
        return false
    }
    return true
}

// The state of the open lab buffer, or false when it is not open.
thor_lab_state :: proc(thor: ^Thor) -> (Lab_State, bool) {
    file := thor_lab_file(thor)
    if file == nil {
        return {}, false
    }
    return lab_state_of(textedit.text(&file.state)), true
}

lab_state_of :: proc(src: string) -> (st: Lab_State) {
    st.src = src
    lines := make([dynamic]string, context.temp_allocator)
    starts := make([dynamic]int, context.temp_allocator)
    at := 0
    for at <= len(src) {
        end := strings.index_byte(src[at:], '\n')
        line := end < 0 ? src[at:] : src[at:at + end]
        append(&starts, at)
        append(&lines, strings.trim_suffix(line, "\r"))
        if end < 0 {
            break
        }
        at += end + 1
    }
    st.lines = lines[:]
    st.starts = starts[:]

    parsed, err := odinsyntax.parse(src, context.temp_allocator)
    if err != nil {
        st.parse_msg = "the parser ran out of memory"
        return
    }
    if len(parsed.errors) == 0 {
        st.parse_ok = true
        return
    }
    e := parsed.errors[0]
    st.parse_at = int(e.offset)
    st.parse_end = int(e.end)
    st.parse_msg = odinsyntax.error_message(e, context.temp_allocator)
    return
}

// Whether the open lab buffer passes `task`.
thor_lab_passes :: proc(thor: ^Thor, task: int) -> bool {
    st, ok := thor_lab_state(thor)
    return ok && lab_check(&st, task)
}

@(private = "file")
indent_of :: proc(line: string) -> int {
    n := 0
    for n < len(line) && (line[n] == ' ' || line[n] == '\t') {
        n += 1
    }
    return n
}

// The trimmed line with its spaces and tabs removed. In the temp allocator.
@(private = "file")
squeeze :: proc(line: string) -> string {
    b := strings.builder_make(context.temp_allocator)
    for i in 0 ..< len(line) {
        if line[i] != ' ' && line[i] != '\t' {
            strings.write_byte(&b, line[i])
        }
    }
    return strings.to_string(b)
}

@(private = "file")
is_ident_byte :: proc(c: byte) -> bool {
    return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

// Whether `line` holds `word` with no identifier byte after it.
@(private = "file")
has_word :: proc(line, word: string) -> bool {
    rest := line
    for {
        at := strings.index(rest, word)
        if at < 0 {
            return false
        }
        after := at + len(word)
        if after >= len(rest) || !is_ident_byte(rest[after]) {
            return true
        }
        rest = rest[after:]
    }
}

// The index of the first line whose squeezed text starts with `prefix`, or -1.
@(private = "file")
line_with :: proc(st: ^Lab_State, prefix: string) -> int {
    for line, i in st.lines {
        if strings.has_prefix(squeeze(line), prefix) {
            return i
        }
    }
    return -1
}

@(private = "file")
import_line :: proc(st: ^Lab_State, path: string) -> int {
    for line, i in st.lines {
        trimmed := strings.trim_left(line, " \t")
        if strings.has_prefix(trimmed, "import") && strings.contains(trimmed, path) {
            return i
        }
    }
    return -1
}

@(private = "file")
has_case :: proc(st: ^Lab_State, name: string) -> bool {
    dotted := strings.concatenate({".", name}, context.temp_allocator)
    for line in st.lines {
        trimmed := strings.trim_left(line, " \t")
        if strings.has_prefix(trimmed, "case") && has_word(trimmed, dotted) {
            return true
        }
    }
    return false
}

@(private = "file")
trailing_lines :: proc(st: ^Lab_State) -> []int {
    out := make([dynamic]int, context.temp_allocator)
    for line, i in st.lines {
        if n := len(line); n > 0 && (line[n - 1] == ' ' || line[n - 1] == '\t') {
            append(&out, i)
        }
    }
    return out[:]
}

// A line of `report` at the wrong depth.
@(private = "file")
Misindent :: struct {
    line:  int,
    have:  int,
    want:  int,
    label: string,
}

@(private = "file")
misindented :: proc(st: ^Lab_State) -> []Misindent {
    out := make([dynamic]Misindent, context.temp_allocator)
    for rule in LAB_INDENT {
        if i := line_with(st, rule.prefix); i >= 0 {
            if have := indent_of(st.lines[i]); have != rule.want {
                append(&out, Misindent{i, have, rule.want, rule.label})
            }
        }
    }
    return out[:]
}

// The line of each constant and the column of its first `:`. False when one is gone.
@(private = "file")
const_columns :: proc(st: ^Lab_State) -> (lines, cols: [len(LAB_CONSTANTS)]int, ok: bool) {
    for name, k in LAB_CONSTANTS {
        lines[k] = -1
        for line, i in st.lines {
            if len(line) > len(name) && strings.has_prefix(line, name) && (line[len(name)] == ' ' || line[len(name)] == '\t') {
                lines[k] = i
                cols[k] = strings.index_byte(line, ':')
                break
            }
        }
        if lines[k] < 0 {
            return
        }
    }
    ok = true
    return
}

lab_check :: proc(st: ^Lab_State, task: int) -> bool {
    switch task {
    case 0:
        return st.parse_ok
    case 1:
        return import_line(st, "\"core:fmt\"") >= 0
    case 2:
        return import_line(st, "\"core:strings\"") < 0 || strings.contains(st.src, "strings.")
    case 3:
        for line in st.lines {
            s := squeeze(line)
            if strings.has_prefix(s, "total:=") || strings.has_prefix(s, "total:int") {
                return true
            }
        }
        return false
    case 4:
        for name in LAB_SHAPES {
            if !has_case(st, name) {
                return false
            }
        }
        return true
    case 5:
        return len(misindented(st)) == 0
    case 6:
        return len(trailing_lines(st)) == 0
    case 7:
        _, cols, ok := const_columns(st)
        if !ok {
            return false
        }
        for c in cols {
            if c < 1 || c != cols[0] {
                return false
            }
        }
        return true
    }
    return false
}

// The byte range of a line, without its newline.
@(private = "file")
line_range :: proc(st: ^Lab_State, line: int) -> (lo, hi: int) {
    lo = st.starts[line]
    return lo, lo + len(st.lines[line])
}

// Where the defect of `task` is in the buffer.
lab_target :: proc(st: ^Lab_State, task: int) -> (lo, hi: int, ok: bool) {
    switch task {
    case 0:
        if st.parse_ok {
            return
        }
        if i := line_with(st, "fmt.printfln(\"%sx%d\""); i >= 0 {
            lo, hi = line_range(st, i)
            return lo, hi, true
        }
        return st.parse_at, max(st.parse_end, st.parse_at + 1), true
    case 1:
        for line, i in st.lines {
            if at := strings.index(line, "fmt."); at >= 0 {
                lo = st.starts[i] + at
                return lo, lo + len("fmt"), true
            }
        }
    case 2:
        if i := import_line(st, "\"core:strings\""); i >= 0 {
            lo, hi = line_range(st, i)
            return lo, hi, true
        }
    case 3:
        if i := line_with(st, "total=0"); i >= 0 {
            lo = st.starts[i] + indent_of(st.lines[i])
            return lo, lo + len("total"), true
        }
    case 4:
        if i := line_with(st, "switchshape"); i >= 0 {
            lo, hi = line_range(st, i)
            return lo, hi, true
        }
    case 5:
        wrong := misindented(st)
        if len(wrong) > 0 {
            lo, _ = line_range(st, wrong[0].line)
            _, hi = line_range(st, wrong[len(wrong) - 1].line)
            return lo, hi, true
        }
    case 6:
        at := trailing_lines(st)
        if len(at) > 0 {
            lo, hi = line_range(st, at[0])
            return lo + len(strings.trim_right(st.lines[at[0]], " \t")), hi, true
        }
    case 7:
        lines, _, found := const_columns(st)
        if found {
            lo, _ = line_range(st, lines[0])
            _, hi = line_range(st, lines[len(lines) - 1])
            return lo, hi, true
        }
    }
    return
}

// "1, 2 and 3". In the temp allocator.
@(private = "file")
list_of :: proc(items: []string) -> string {
    switch len(items) {
    case 0:
        return ""
    case 1:
        return items[0]
    }
    head := strings.join(items[:len(items) - 1], ", ", context.temp_allocator)
    return fmt.tprintf("%s and %s", head, items[len(items) - 1])
}

@(private = "file")
line_numbers :: proc(lines: []int) -> string {
    out := make([]string, len(lines), context.temp_allocator)
    for line, i in lines {
        out[i] = fmt.tprint(line + 1)
    }
    return list_of(out)
}

// What is still wrong for `task` and the key that fixes it, as markdown with
// `{key:action}` placeholders. In the temp allocator.
lab_detail :: proc(st: ^Lab_State, task: int) -> string {
    switch task {
    case 0:
        at := 1
        for start, i in st.starts {
            if start <= st.parse_at {
                at = i + 1
            }
        }
        return fmt.tprintf(
            "The parser stops at line %d: %s.\n\n" +
            "The cause is the per-item `fmt.printfln`: its `(` is never closed, so every line after it " +
            "belongs to an expression that does not end. Until the file parses, hover, go to definition " +
            "and code actions have nothing to read.\n\n" +
            "Type the missing `)`. {{key:matching_bracket} jumps between a pair of brackets, so you can see " +
            "which one has no partner.",
            at,
            st.parse_msg,
        )
    case 1:
        return "The file calls `fmt.printfln`, but it imports no package of that name, so the compiler " +
            "answers `Undeclared name: fmt`.\n\n" +
            "Put the caret on `fmt` and press {key:code_actions}. Thor offers `Import \"core:fmt\"`, and " +
            "Enter adds the import beside the one that is there."
    case 2:
        return "The file imports `core:strings` and nothing names it. A dead import claims a dependency " +
            "the package does not have.\n\n" +
            "Put the caret on that line and press {key:code_actions}, then pick " +
            "`Remove unused import \"core:strings\"`."
    case 3:
        return "`total = 0` writes to a name that nothing declares. In Odin, `=` assigns to a name that " +
            "exists and `:=` declares one.\n\n" +
            "Put the caret on `total` and press {key:code_actions}, then pick `Declare \"total\" with :=`. " +
            "{key:undo} takes the fix back in one step."
    case 4:
        missing := make([dynamic]string, context.temp_allocator)
        for name in LAB_SHAPES {
            if !has_case(st, name) {
                append(&missing, fmt.tprintf("`.%s`", name))
            }
        }
        return fmt.tprintf(
            "The switch does not name %s. A switch over an enum must cover every member unless it is " +
            "`#partial switch`, so the compiler answers `Unhandled switch cases`.\n\n" +
            "Put the caret in the switch and press {{key:code_actions}: Thor adds the missing arms. Give " +
            "each one its `return`.\n\n" +
            "{{key:goto_definition} on `Shape` opens the enum, and {{key:jump_back} comes back.",
            list_of(missing[:]),
        )
    case 5:
        wrong := misindented(st)
        b := strings.builder_make(context.temp_allocator)
        strings.write_string(&b, "Odin compiles `report` at any depth, but these lines are at the wrong column:\n\n")
        strings.write_string(&b, "| Line | What | Now | Want |\n| --- | --- | --- | --- |\n")
        shallow := make([dynamic]int, context.temp_allocator)
        deep := make([dynamic]int, context.temp_allocator)
        for w in wrong {
            fmt.sbprintf(&b, "| %d | %s | %d | %d |\n", w.line + 1, w.label, w.have, w.want)
            append(w.have < w.want ? &shallow : &deep, w.line)
        }
        if len(shallow) > 0 {
            fmt.sbprintf(&b, "\nSelect line %s and press {{key:indent} to move it in one level.", line_numbers(shallow[:]))
        }
        if len(deep) > 0 {
            fmt.sbprintf(&b, "\nSelect line %s and press {{key:outdent} to move it out one level.", line_numbers(deep[:]))
        }
        return strings.to_string(b)
    case 6:
        return fmt.tprintf(
            "Line %s ends in whitespace you cannot see. It breaks nothing, but it shows in every diff " +
            "that touches the line.\n\n" +
            "{{key:trim_trailing_whitespace} trims every line of the file in one undo step.",
            line_numbers(trailing_lines(st)),
        )
    case 7:
        if _, _, ok := const_columns(st); !ok {
            return "One of the three constants is gone. Start the chapter again to restore the file."
        }
        return "Each constant declares with `::`, and each `::` is in a different column.\n\n" +
            "Select the three lines, press {key:align_at_char}, type `:` and press Enter. The first `:` " +
            "of each line moves into one column."
    }
    return ""
}

// The analyzer's message on the defect of `task`, or "". Borrowed from the file.
thor_lab_diagnostic :: proc(thor: ^Thor, st: ^Lab_State, task: int) -> string {
    file := thor_lab_file(thor)
    lo, hi, ok := lab_target(st, task)
    if file == nil || !ok {
        return ""
    }
    for d in thor_file_live_diagnostics(file) {
        if d.severity == .Error && d.start <= hi && d.end >= lo {
            return d.message
        }
    }
    return ""
}

// "Show me": puts the caret on the defect of `task` and selects it.
thor_lab_show :: proc(thor: ^Thor, task: int) {
    st, ok := thor_lab_state(thor)
    if !ok {
        thor_lab_start(thor)
        return
    }
    lo, hi, found := lab_target(&st, task)
    if !found {
        return
    }
    path := thor_lab_path()
    thor_goto_location(thor, path, lo)
    if file := thor_lab_file(thor); file != nil {
        textedit.select_range(&file.state, lo, hi)
    }
    thor.tutorial.lab = {show_lo = lo, show_hi = hi, show_task = task}
    thor.focus_request = thor_pane_key(thor.active_pane)
}

// The screen rect of the lines the shown range covers, when a pane shows the lab file.
thor_lab_show_rect :: proc(thor: ^Thor) -> (rect: ui.Rect, ok: bool) {
    lab := &thor.tutorial.lab
    file := thor_lab_file(thor)
    if file == nil || lab.show_task < 0 {
        return
    }
    for pane in 0 ..< thor_pane_count(thor) {
        editor := &thor.editors[pane]
        if editor.state != &file.state {
            continue
        }
        _, top, lh, top_ok := editview.editor_screen_at(editor, lab.show_lo)
        _, bottom, _, bottom_ok := editview.editor_screen_at(editor, lab.show_hi)
        if !top_ok || !bottom_ok {
            return
        }
        r := thor.pane_rect[pane]
        y0 := max(top, r.y)
        y1 := min(bottom + lh, r.y + r.h)
        if y1 <= y0 {
            return
        }
        return {r.x, y0, r.w, y1 - y0}, true
    }
    return
}
