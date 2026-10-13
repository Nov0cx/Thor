package markdown

import "core:strings"
import "core:testing"

import ui "../vendor/loom/loom"

// A monospace face of a fixed advance, so a laid-out box has a real width with
// no font atlas: every test below can state where a thing lands.
@(private = "file")
CELL :: f32(10)

@(private = "file")
LINE :: f32(20)

@(private = "file")
fake_metrics :: proc() -> Metrics {
    return Metrics {
        measure = proc(text: string, size: i32, user: rawptr) -> f32 {
            return f32(len(text)) * CELL
        },
        line_height = proc(size: i32, user: rawptr) -> f32 {
            return LINE
        },
    }
}

@(private = "file")
test_palette :: proc() -> Palette {
    return Palette {
        text = {1, 0, 0, 255},
        strong = {2, 0, 0, 255},
        heading = {3, 0, 0, 255},
        code = {4, 0, 0, 255},
        code_bg = {5, 0, 0, 255},
        link = {6, 0, 0, 255},
        quote = {7, 0, 0, 255},
        rule = {8, 0, 0, 255},
        accent = {9, 0, 0, 255},
    }
}

@(private = "file")
lay :: proc(page: ^Page, source: string, avail := f32(600)) {
    layout(page, source, avail, 16, test_palette(), fake_metrics())
}

@(private = "file")
first_url :: proc(page: ^Page) -> string {
    for item in page.items {
        if item.url != "" {
            return item.url
        }
    }
    return ""
}

// Anything that is not a full [text](url) is prose, so nothing in it opens. An
// empty target is a link with nowhere to go, which is the same thing here.
@(test)
test_partial_link_has_no_target :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)

    for source in ([]string{"[docs\n", "[docs]\n", "[docs] (x)\n", "[docs](x\n", "[docs]()\n"}) {
        lay(&page, source)
        testing.expect_value(t, first_url(&page), "")
    }

    // The complete form does resolve, so the cases above fail on their shape and
    // not because the fixture never finds anything.
    lay(&page, "[docs](x)\n")
    testing.expect_value(t, first_url(&page), "x")
}

// The url has to survive parsing and layout: it is what a click opens.
@(test)
test_layout_keeps_link_url :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)
    lay(&page, "see [docs](building.md) here\n")

    found := false
    for item in page.items {
        if item.url == "" {
            continue
        }
        testing.expect_value(t, item.kind, Item_Kind.Text)
        testing.expect_value(t, item.text, "docs")
        testing.expect_value(t, item.url, "building.md")
        found = true
    }
    testing.expect(t, found, "the laid-out link carries its target")
}

@(test)
test_plain_text_has_no_url :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)
    lay(&page, "just some words\n")

    for item in page.items {
        testing.expect_value(t, item.url, "")
    }
}

// The link box is what the click is tested against, so it has to sit on the
// text and nowhere else.
@(test)
test_link_hit_test_covers_the_word :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)
    lay(&page, "see [docs](building.md) here\n")

    index := -1
    for item, i in page.items {
        if item.url != "" && item.kind == .Text {
            index = i
            break
        }
    }
    testing.expect(t, index >= 0, "the page holds a link")

    box := page.items[index]
    testing.expect_value(t, box.w, 4 * CELL)
    testing.expect_value(t, link_at(&page, box.x + 1, box.y + 1), index)
    testing.expect_value(t, link_at(&page, box.x - 4, box.y + 1), -1)
    testing.expect_value(t, link_at(&page, box.x + 1, box.y + LINE + 1), -1)
}

// A word that does not fit starts the next row, at the block's indent.
@(test)
test_wrap_breaks_on_the_column :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)
    // Four five-letter words at 10 px a character: two fit in 120 px, not three.
    lay(&page, "aaaaa bbbbb ccccc ddddd\n", 120 + 2 * PAD_X)

    rows: [dynamic]f32
    defer delete(rows)
    for item in page.items {
        if item.kind != .Text {
            continue
        }
        if len(rows) == 0 || rows[len(rows) - 1] != item.y {
            append(&rows, item.y)
        }
    }
    testing.expect_value(t, len(rows), 2)
    testing.expect_value(t, page.items[0].x, f32(0))
    testing.expect(t, rows[1] - rows[0] == LINE, "the second row is one line down")
}

// A heading is bigger than the body and, at level 1 and 2, draws its rule.
@(test)
test_heading_steps_the_size_and_rules :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)
    lay(&page, "# Title\n")

    text_size := i32(0)
    rules := 0
    for item in page.items {
        switch item.kind {
        case .Text:
            text_size = item.size
        case .Rect:
            rules += 1
        }
    }
    testing.expect_value(t, text_size, i32(16 + 13))
    testing.expect_value(t, rules, 1)

    lay(&page, "#### Small\n")
    rules = 0
    for item in page.items {
        if item.kind == .Rect {
            rules += 1
        }
    }
    testing.expect_value(t, rules, 0)
}

// An ordered list's number is built, not sliced out of the source, so the page
// has to own it — and let it go on the next layout.
@(test)
test_ordered_list_owns_its_numbers :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)

    lay(&page, "3. first\n4. second\n")
    testing.expect_value(t, len(page.owned), 2)
    testing.expect_value(t, page.owned[0], "3.")
    testing.expect_value(t, page.owned[1], "4.")

    lay(&page, "no list here\n")
    testing.expect_value(t, len(page.owned), 0)
}

// A fenced block draws verbatim on one panel, and the fence lines are not text.
@(test)
test_code_block_draws_verbatim :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)
    lay(&page, "```odin\nx := 1\n**not bold**\n```\n")

    texts: [dynamic]string
    defer delete(texts)
    panels := 0
    for item in page.items {
        switch item.kind {
        case .Text:
            append(&texts, item.text)
        case .Rect:
            panels += 1
        }
    }
    testing.expect_value(t, panels, 1)
    testing.expect_value(t, len(texts), 2)
    testing.expect_value(t, texts[0], "x := 1")
    testing.expect_value(t, texts[1], "**not bold**")
}

// The page grows with its content, which is the scroll extent the host states.
@(test)
test_content_height_follows_the_rows :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)

    lay(&page, "one line\n")
    short := page.content_height

    lay(&page, "one line\n\ntwo\n\nthree\n")
    testing.expect(t, page.content_height > short, "more rows, more page")
    testing.expect(t, short > PAD_TOP + PAD_BOTTOM, "and a row of its own takes height")
}

// The column is capped, so a wide pane centres a readable measure instead of
// running the text edge to edge.
@(test)
test_content_column_is_capped_and_centred :: proc(t: ^testing.T) {
    narrow := content_width(400)
    testing.expect_value(t, narrow, 400 - 2 * PAD_X)
    testing.expect_value(t, content_left(400, narrow), PAD_X)

    wide := content_width(4000)
    testing.expect_value(t, wide, MAX_WIDTH)
    testing.expect_value(t, content_left(4000, wide), (4000 - MAX_WIDTH) * 0.5)
}

// Emphasis and code carry the palette, which is how the page reads without a
// second face to bold or slant with.
@(test)
test_inline_styles_take_their_colors :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)
    pal := test_palette()
    lay(&page, "plain **strong** and `code` here\n")

    seen: map[string]ui.Color
    defer delete(seen)
    for item in page.items {
        if item.kind == .Text {
            seen[item.text] = item.color
        }
    }
    testing.expect_value(t, seen["plain"], pal.text)
    testing.expect_value(t, seen["strong"], pal.strong)
    testing.expect_value(t, seen["code"], pal.code)
}

// The text items of a page, in order.
@(private = "file")
texts :: proc(page: ^Page) -> [dynamic]Item {
    out := make([dynamic]Item, context.temp_allocator)
    for item in page.items {
        if item.kind == .Text {
            append(&out, item)
        }
    }
    return out
}

@(private = "file")
count_rects :: proc(page: ^Page) -> int {
    n := 0
    for item in page.items {
        if item.kind == .Rect {
            n += 1
        }
    }
    return n
}

// An escaped marker is the character itself, with no space around it and no
// style opened.
@(test)
test_backslash_escape_is_literal :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)
    pal := test_palette()
    lay(&page, "a\\*b\\* c\n")

    items := texts(&page)
    testing.expect_value(t, len(items), 5)
    if len(items) != 5 {
        return
    }
    testing.expect_value(t, items[1].text, "*")
    testing.expect_value(t, items[1].color, pal.text)
    // "a", "*", "b", "*" touch; "c" is one space on.
    testing.expect_value(t, items[1].x, 1 * CELL)
    testing.expect_value(t, items[3].x, 3 * CELL)
    testing.expect_value(t, items[4].x, 5 * CELL)
}

// An underscore inside a word is not emphasis.
@(test)
test_underscore_in_a_word_stays :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)
    lay(&page, "snake_case_name and _em_\n")

    items := texts(&page)
    testing.expect_value(t, items[0].text, "snake_case_name")
    testing.expect_value(t, items[len(items) - 1].text, "em")
    testing.expect_value(t, items[len(items) - 1].color, test_palette().strong)
}

@(test)
test_strikethrough_draws_a_line :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)
    lay(&page, "keep ~~drop~~\n")

    testing.expect_value(t, count_rects(&page), 1)
    items := texts(&page)
    testing.expect_value(t, items[1].text, "drop")
    for item in page.items {
        if item.kind == .Rect {
            testing.expect_value(t, item.x, items[1].x)
            testing.expect_value(t, item.w, 4 * CELL)
            testing.expect(t, item.y > items[1].y && item.y < items[1].y + LINE)
        }
    }
}

// Two spaces, a backslash or a <br> end the row; a plain line end does not.
@(test)
test_hard_break_starts_a_row :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)

    for source in ([]string{"one  \ntwo\n", "one\\\ntwo\n", "one<br>two\n"}) {
        lay(&page, source)
        items := texts(&page)
        testing.expect_value(t, len(items), 2)
        if len(items) == 2 {
            testing.expect_value(t, items[1].y - items[0].y, LINE)
            testing.expect_value(t, items[1].x, f32(0))
        }
    }

    lay(&page, "one\ntwo\n")
    items := texts(&page)
    testing.expect_value(t, items[1].y, items[0].y)
}

// A line of = or - under a paragraph makes it a heading, and the underline is
// not drawn as text.
@(test)
test_setext_heading :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)

    lay(&page, "Title\n=====\n\nSub\n---\n\nbody\n")
    items := texts(&page)
    testing.expect_value(t, len(items), 3)
    if len(items) != 3 {
        return
    }
    testing.expect_value(t, items[0].size, i32(16 + 13))
    testing.expect_value(t, items[1].size, i32(16 + 8))
    testing.expect_value(t, items[2].size, i32(16))
    testing.expect_value(t, count_rects(&page), 2)
}

// A reference link takes its url from the definition, which is not drawn.
@(test)
test_reference_link_resolves :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)
    lay(&page, "see [the docs][Docs], [site] and [none]\n\n[docs]: building.md \"Build\"\n[site]: <https://example.org>\n")

    urls: [dynamic]string
    defer delete(urls)
    for item in page.items {
        if item.url != "" {
            append(&urls, item.url)
        }
        if item.kind == .Text {
            testing.expect(t, item.text != "building.md", "a definition is not text")
        }
    }
    testing.expect_value(t, len(urls), 2)
    if len(urls) == 2 {
        testing.expect_value(t, urls[0], "building.md")
        testing.expect_value(t, urls[1], "https://example.org")
    }
}

@(test)
test_autolink :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)
    lay(&page, "at <https://example.org/x> now\n")
    testing.expect_value(t, first_url(&page), "https://example.org/x")
}

// A deeper indent is a deeper level; a shallower one comes back to its level.
@(test)
test_nested_list_indents :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)
    lay(&page, "- one\n  - two\n    - three\n  - four\n- five\n")

    xs: [dynamic]f32
    defer delete(xs)
    for item in page.items {
        if item.kind == .Text && item.text != "•" {
            append(&xs, item.x)
        }
    }
    testing.expect_value(t, len(xs), 5)
    if len(xs) != 5 {
        return
    }
    testing.expect_value(t, xs[0], f32(24))
    testing.expect_value(t, xs[1], f32(48))
    testing.expect_value(t, xs[2], f32(72))
    testing.expect_value(t, xs[3], f32(48))
    testing.expect_value(t, xs[4], f32(24))
}

// A plain line under an item belongs to the item, at its indent.
@(test)
test_list_item_continues :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)
    lay(&page, "- one\n  two\n")

    items := texts(&page)
    testing.expect_value(t, len(items), 3)
    if len(items) == 3 {
        testing.expect_value(t, items[2].text, "two")
        testing.expect_value(t, items[2].y, items[1].y)
    }
}

// A code line wider than the panel continues on the next row, and the panel
// grows with it.
@(test)
test_code_block_wraps :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)
    // The panel is 116 px inside its padding: eleven characters a row.
    lay(&page, "~~~\n0123456789abcdefghij\n~~~\n", 132)

    items := texts(&page)
    testing.expect_value(t, len(items), 2)
    if len(items) != 2 {
        return
    }
    testing.expect_value(t, items[0].text, "0123456789a")
    testing.expect_value(t, items[1].text, "bcdefghij")
    testing.expect_value(t, items[1].y - items[0].y, LINE)
    for item in page.items {
        if item.kind == .Rect {
            testing.expect_value(t, item.h, 2 * LINE + 16)
        }
    }
}

// Consecutive quote lines are one block behind one bar.
@(test)
test_quote_lines_fold :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)
    lay(&page, "> one\n> two\n")

    items := texts(&page)
    testing.expect_value(t, len(items), 2)
    testing.expect_value(t, items[1].y, items[0].y)
    testing.expect_value(t, count_rects(&page), 1)
}

@(private = "file")
text_named :: proc(page: ^Page, text: string) -> (Item, bool) {
    for item in page.items {
        if item.kind == .Text && item.text == text {
            return item, true
        }
    }
    return {}, false
}

// A column is as wide as its widest cell, and a cell sits where the delimiter
// row aligns it. The delimiter row is not text.
@(test)
test_table_columns_and_alignment :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)
    pal := test_palette()
    lay(&page, "| name | n | mid |\n|:-----|--:|:---:|\n| ab | 12345 | x |\n| abcdef | 1 | xyz |\n")

    for item in page.items {
        if item.kind == .Text {
            testing.expect(t, !strings.contains(item.text, "-"), "the delimiter row is not drawn")
        }
    }

    // Columns: 6, 5 and 3 characters wide, each inside 10 px of padding.
    name, _ := text_named(&page, "name")
    ab, _ := text_named(&page, "ab")
    testing.expect_value(t, name.x, f32(10))
    testing.expect_value(t, ab.x, f32(10))
    testing.expect_value(t, name.color, pal.strong)
    testing.expect_value(t, ab.color, pal.text)
    testing.expect(t, ab.y > name.y, "a body row is under the header")

    // Right: the cell ends where the column ends.
    one, _ := text_named(&page, "1")
    wide, _ := text_named(&page, "12345")
    testing.expect_value(t, wide.x, f32(80 + 10))
    testing.expect_value(t, one.x + one.w, wide.x + wide.w)

    // Center: one character in a three character column.
    x, _ := text_named(&page, "x")
    xyz, _ := text_named(&page, "xyz")
    testing.expect_value(t, xyz.x, f32(80 + 70 + 10))
    testing.expect_value(t, x.x, xyz.x + CELL)
}

// A table wider than the page shares the page, and its cells wrap.
@(test)
test_table_wraps_its_cells :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)
    lay(&page, "| a | b |\n|---|---|\n| one two three four | five six seven eight |\n", 240)

    one, _ := text_named(&page, "one")
    four, _ := text_named(&page, "four")
    five, _ := text_named(&page, "five")
    testing.expect(t, four.y > one.y, "the cell wraps")
    testing.expect_value(t, five.y, one.y)
    testing.expect(t, five.x >= 120, "the second column starts at the middle")
    for item in page.items {
        testing.expect(t, item.x + item.w <= 240 + 0.5, "nothing leaves the page")
    }
}

// A pipe that is escaped or inside a code span does not split the cell.
@(test)
test_table_keeps_a_pipe_in_a_cell :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)
    lay(&page, "| a | b |\n|---|---|\n| `x|y` | p\\|q |\n")

    _, code := text_named(&page, "x|y")
    testing.expect(t, code, "the code span is one cell")
    _, pipe := text_named(&page, "|")
    testing.expect(t, pipe, "the escaped pipe is text")
}

// Text with a pipe and no delimiter row under it is a paragraph.
@(test)
test_pipe_without_delimiter_is_text :: proc(t: ^testing.T) {
    page: Page
    defer page_destroy(&page)
    lay(&page, "a | b\nc | d\n")
    testing.expect_value(t, count_rects(&page), 0)
}
