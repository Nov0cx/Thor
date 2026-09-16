package thor

import "core:strings"
import "core:time"
import rl "vendor:raylib"

import "../lang"
import "../plugin"
import "../textedit"
import ui "../vendor/loom/loom"
import "../theme"
import "../editview"
// Byte window to highlight `file` over: what the pane showing it displays, plus
// a screen of margin on each side so a small scroll does not re-run the query.
// ok is false when no pane shows the file, or its rows are not built yet.
@(private = "file")
thor_highlight_window :: proc(thor: ^Thor, file: ^Open_File) -> (start, end: int, ok: bool) {
    for index, pane in thor.pane_file {
        if index < 0 || index >= len(thor.open_files) || thor.open_files[index] != file {
            continue
        }
        editor := thor_pane_editor(thor, pane)
        margin := max(editview.editor_visible_row_count(editor), 1)
        // A pane whose rows are not built yet answers nothing; the other pane
        // showing the same file may already have them.
        if s, e, got := editview.editor_visible_byte_range(editor, margin); got {
            return s, e, true
        }
    }
    return 0, 0, false
}

// Rebuilds `file`'s highlight spans (resolved to theme colors) over the window
// the pane showing it displays. Only files shown in a pane are highlighted, so
// this runs when their buffers change or their view scrolls off the window.
thor_update_highlights :: proc(thor: ^Thor, file: ^Open_File) {
    key := thor_highlight_key(&thor.plugins, file.name)

    win_start, win_end, windowed := thor_highlight_window(thor, file)
    if !windowed {
        // No view to scope to. Leaving it stale costs nothing and the pane pass
        // highlights it the moment it is shown; coloring it whole would not.
        clear(&file.highlights)
        file.highlighted = false
        thor_apply_file_highlights(thor, file)
        return
    }

    clear(&file.highlights)
    if plugin.supports(&thor.plugins, key) {
        source := textedit.text(&file.state)
        win_start = clamp(win_start, 0, len(source))
        win_end = clamp(win_end, win_start, len(source))
        // The buffer's path lets a grammar-backed language re-parse only what
        // this revision changed, off the tree it kept from the last one.
        grammar := make([dynamic]editview.Highlight_Span, context.temp_allocator)
        spans, covered_start, covered_end := plugin.highlight_range(
            &thor.plugins,
            file.path,
            source,
            key,
            win_start,
            win_end,
            context.temp_allocator,
        )
        // What the language answered for, which is wider than the window asked
        // for when a pure-Lua lexer reads the whole buffer. Recording the window
        // instead would re-highlight a buffer already covered on every scroll.
        win_start, win_end = covered_start, covered_end
        for span in spans {
            color := theme.role_color(thor.theme, span.role)
            append(&grammar, editview.Highlight_Span{span.start, span.end, color})
        }
        thor_merge_semantic(thor, file, key, source, grammar[:], win_start, win_end)
    }

    file.highlighted = true
    file.highlight_revision = file.state.revision
    file.highlight_start = win_start
    file.highlight_end = win_end
    thor_apply_file_highlights(thor, file)
    // Ask what this revision's identifiers are, now that the grammar's answer is
    // in. The result marks the highlights stale again and lands on the next pass.
    thor_request_semantic(thor, file)
}

// How long a buffer must sit unedited before its folds are derived again.
FOLD_IDLE_DELAY :: 250 * time.Millisecond

// Rebuilds `file.folds` once the buffer has been still for FOLD_IDLE_DELAY.
//
// Fold ranges cover whole lines across the whole buffer, so unlike the
// highlights they cannot be scoped to a view — deriving them means walking the
// tree, which is far too slow to do per keystroke on a large file. They are also
// not needed promptly: between the edit and the rebuild the chevrons sit at the
// line numbers they had, which only shows if the edit added or removed lines.
@(private)
thor_update_folds :: proc(thor: ^Thor, file: ^Open_File) {
    if file.folds_ready && file.folds_revision == file.state.revision {
        return
    }
    if time.tick_since(file.last_edit) < FOLD_IDLE_DELAY {
        return
    }
    key := thor_highlight_key(&thor.plugins, file.name)
    if !plugin.supports(&thor.plugins, key) {
        // A plugin reload can leave folds behind that the new language did not
        // derive, so drop them rather than keep another grammar's answer.
        had := len(file.folds) > 0
        clear(&file.folds)
        file.folds_revision = file.state.revision
        file.folds_ready = true
        if had {
            thor_apply_file_highlights(thor, file)
        }
        return
    }

    source := textedit.text(&file.state)
    clear(&file.folds)
    for r in plugin.fold_ranges(&thor.plugins, file.path, source, key, context.temp_allocator) {
        append(&file.folds, editview.Fold_Range{r.start_line, r.end_line})
    }
    file.folds_revision = file.state.revision
    file.folds_ready = true
    thor_apply_file_highlights(thor, file)
}

// Layers the analyzer's classification over the grammar's spans into
// `file.highlights`, resolving each token's kind to a color first.
//
// A kind the language leaves unmapped is dropped rather than colored, which
// keeps the grammar's answer instead of overruling it with the default
// foreground. A classification behind the buffer is rebased onto it first, so
// the overlay survives an edit without coloring bytes it never classified.
@(private)
thor_merge_semantic :: proc(
    thor: ^Thor,
    file: ^Open_File,
    key, source: string,
    grammar: []editview.Highlight_Span,
    win_start, win_end: int,
) {
    if len(file.semantic) == 0 {
        append(&file.highlights, ..grammar)
        return
    }

    tokens := file.semantic[:]
    // The overlay is a keystroke or two behind the buffer: put its tokens where
    // the text they name now is, rather than merging at offsets that have moved.
    // Keyed on the text, not the revision, because a reload returns the revision
    // to 0 and an equal revision would then prove nothing.
    if file.semantic_source != "" && file.semantic_source != source {
        moved := make([dynamic]lang.Semantic_Token, 0, len(tokens), context.temp_allocator)
        thor_rebase_semantic(&moved, tokens, file.semantic_source, source)
        tokens = moved[:]
    }

    colors: [lang.Token_Kind]ui.Color
    mapped: bit_set[lang.Token_Kind]
    for kind in lang.Token_Kind {
        role := plugin.role_for(&thor.plugins, key, thor_token_capture(kind))
        if role == "" {
            continue
        }
        colors[kind] = theme.role_color(thor.theme, role)
        mapped += {kind}
    }

    over := make([dynamic]editview.Highlight_Span, 0, len(tokens), context.temp_allocator)
    thor_semantic_spans(&over, tokens, colors, mapped, win_start, win_end)
    thor_overlay_spans(&file.highlights, grammar, over[:])
}

// The tokens of `old_text` at their offsets in `new_text`. The two texts differ
// over one span only — what their common affixes leave — so a token below it
// keeps its offsets and one above it moves by the change in length. A token the
// span reaches into is dropped: the bytes it classified are gone, and a trimmed
// one colors part of a name. Ascending, non-overlapping input stays so.
@(private)
thor_rebase_semantic :: proc(
    out: ^[dynamic]lang.Semantic_Token,
    tokens: []lang.Semantic_Token,
    old_text, new_text: string,
) {
    prefix, suffix := thor_common_affixes(old_text, new_text)
    tail := len(old_text) - suffix
    delta := len(new_text) - len(old_text)
    for token in tokens {
        if token.end <= prefix {
            append(out, token)
        } else if token.start >= tail {
            append(out, lang.Semantic_Token{token.start + delta, token.end + delta, token.kind})
        }
    }
}

// The overlay spans for `tokens`: each kind resolved to its color, clipped to
// the highlighted window, and a token that overlaps the one before it dropped
// rather than trimmed — a trimmed token colors part of an identifier, which
// reads as a rendering fault. A kind no role maps is left to the grammar.
@(private)
thor_semantic_spans :: proc(
    out: ^[dynamic]editview.Highlight_Span,
    tokens: []lang.Semantic_Token,
    colors: [lang.Token_Kind]ui.Color,
    mapped: bit_set[lang.Token_Kind],
    win_start, win_end: int,
) {
    // Advanced by every accepted token, even one the window clips away, so the
    // emitted spans stay ascending and non-overlapping.
    cut := 0
    for token in tokens {
        if token.kind not_in mapped || token.start < cut {
            continue
        }
        cut = token.end
        start := max(token.start, win_start)
        end := min(token.end, win_end)
        if start < end {
            append(out, editview.Highlight_Span{start, end, colors[token.kind]})
        }
    }
}

// Interleaves two ascending, non-overlapping span lists into one, `over` winning
// wherever the two meet: it replaces the color across exactly its own range and
// the spans around it are emitted clipped to what it left. The result stays
// ascending and non-overlapping, which is what lets the editor draw it with a
// single cursor that only ever moves forward.
@(private)
thor_overlay_spans :: proc(out: ^[dynamic]editview.Highlight_Span, base, over: []editview.Highlight_Span) {
    b := 0
    // Where base[b] still has ink: an earlier overlay span may have covered its
    // opening bytes.
    cut := 0
    for span in over {
        // Everything the base colors before the overlay span, then the straddling
        // one trimmed to where the overlay begins.
        for b < len(base) {
            under := base[b]
            from := max(under.start, cut)
            if under.end <= span.start {
                if from < under.end {
                    append(out, editview.Highlight_Span{from, under.end, under.color})
                }
                b += 1
                continue
            }
            if from < span.start {
                append(out, editview.Highlight_Span{from, span.start, under.color})
            }
            break
        }

        append(out, span)
        cut = span.end
        for b < len(base) && base[b].end <= cut {
            b += 1
        }
    }

    for ; b < len(base); b += 1 {
        under := base[b]
        from := max(under.start, cut)
        if from < under.end {
            append(out, editview.Highlight_Span{from, under.end, under.color})
        }
    }
}

// The tree-sitter capture name a semantic kind stands in for. Routing the
// analyzer's classification through the same plugin color table the highlights
// query uses means a name it proved is a parameter takes exactly the color the
// grammar gives a parameter it could prove itself, and the mapping stays
// tunable in the language's plugin. `Unresolved` is the one kind with no
// grammar counterpart, so it names a capture of its own — a language that does
// not want undeclared names dimmed simply leaves it unmapped.
@(private = "file")
thor_token_capture :: proc(kind: lang.Token_Kind) -> string {
    switch kind {
    case .Parameter:   return "parameter"
    case .Local:       return "variable"
    case .Field:       return "field"
    case .Procedure:   return "function"
    case .Type:        return "type"
    case .Enum_Member: return "constant"
    case .Package:     return "namespace"
    case .Unresolved:  return "unresolved"
    }
    return ""
}

// The key a language plugin is looked up by: the file extension (".odin") when a
// plugin claims it, else the bare filename ("Dockerfile", "Makefile") so files
// with no extension can still map to a language. Falls back to the extension.
thor_highlight_key :: proc(plugins: ^plugin.Manager, name: string) -> string {
    if ext := thor_file_extension(name); ext != "" && plugin.supports(plugins, ext) {
        return ext
    }
    if base := thor_file_base(name); plugin.supports(plugins, base) {
        return base
    }
    return thor_file_extension(name)
}

