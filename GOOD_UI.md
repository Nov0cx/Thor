# Good UI for Thor

This document defines what good UI means for Thor. It gives the principles, the numbers a change is
checked against, what Loom can and cannot do, and where Thor does not follow its own rules today.

Read sections 2 and 5 to 10 before a UI change. Check the change against section 12 before a commit.
Section 11 is a snapshot (2026-11, version 2026.11.4): fix an item, then remove it.

Each rule has two parts: the **principle** (why) and the **number** (what to check). When they
disagree in a case this document did not foresee, the principle wins and the number is corrected here.

## 1. The target

Thor is quiet and fast. The code is the brightest and sharpest thing on the screen. The chrome
around it is flat, has little contrast and does not move unless the user caused the movement.

| Quality | Meaning | Not |
| --- | --- | --- |
| Quiet | Flat surfaces, hairline borders, one accent colour, no ornament. | Gradients, glows, heavy shadows, coloured panels. |
| Fast | Each input shows a result in the same frame. Motion is short and can be interrupted. | Animations the user must wait for. Spinners for work under 250 ms. |
| Keyboard first | Each action has a command, each command can have a key. | A function that needs the pointer. |
| Predictable | One shape for each kind of thing: one row, one modal, one picker. | A new look for each view. |
| Honest | State is visible: focus, selection, unsaved, busy, failed. | A silent failure. A control that looks active and is not. |

## 2. Principles

1. **Content first.** The editor area has the highest contrast. Chrome text uses `foreground` and
   `muted`, not `text`. A panel has no border where a change of surface colour already separates it.
2. **Feedback in the frame.** Hover, press, selection and typed text show in the frame of the input
   (`ui.frame` runs a second pass for this; do not defeat it with a delay). Slow work goes through
   the async job pattern and the view stays usable.
3. **Keyboard first, pointer complete.** Each action is reachable by key, and also by pointer. The
   palette is the one entry point that lists everything.
4. **One way.** A list of things to pick from is the palette shape. A question is the modal shape. A
   row is the row shape. A new view uses these before it makes its own.
5. **Reversible and escapable.** Escape closes the top layer and only that layer. A click on the
   scrim does the same. An edit is covered by undo. A destructive action asks, and names the thing
   it destroys.
6. **Progressive disclosure.** The default view shows what most sessions need. Detail appears on
   demand: a tooltip, a fold, a second line, a modal.
7. **State is visible, and not by colour alone.** A status colour comes with an icon, a letter or a
   text. Focus has a ring. A modified file has a mark.
8. **Stable layout.** A node does not change size or place because an async result arrived. Reserve
   the space (a fixed column, a fixed row) before the data lands.
9. **Tokens, not literals.** A size, a radius, a shadow, a duration or a colour comes from section 5
   or from the theme. A literal in a view file is a defect.
10. **Scale with the user.** The UI follows `general.font_size` and the display scale. A pixel
    constant that does not scale is allowed only for hairlines.

## 3. What other editors teach

| Editor | Take | Leave |
| --- | --- | --- |
| VS Code | The fixed region model (side bar, editor, panel, status bar). Status bar split: workspace items left, file items right. Notification rules: only when necessary, one at a time, a "do not show again" choice, progress kept in context. Its 2026 UI refresh: shared design tokens replace per-component spacing, a tighter range of surface colours, no all-caps labels, and a compact density setting because users asked for the old density back. | Web latency. Notification toasts for routine results. Many always-visible toolbars added by extensions. |
| JetBrains (new UI) | Fewer always-visible actions: toolbar actions move into menus and widgets. Icons that appear on hover (fold arrows). A compact mode as an explicit setting. Search Everywhere: one field for files, symbols and actions. | Deep settings trees. Tool-window buttons on all four edges. Modal dialogs that stack. |
| Visual Studio | Its refresh named three goals: cohesiveness, accessibility, productivity. Larger spacing lowers visual clutter. The user reaction: larger default spacing costs density, so density must be a choice. | Toolbar rows. Dialogs with tabs inside tabs. |
| Zed | The editor is rendered as a game: a frame budget is a design rule, not an optimisation. Chrome is nearly invisible. Flat panels, one accent, short motion. | Features that have a button and no command. |
| Lapce | A lag on a key press is a bug. The palette shows the key of each command next to it. Modal editing is a setting, not a plugin. | — |
| Sublime Text | Goto Anything: one fuzzy field with prefixes (`@` symbol, `:` line). The minimap as an optional overview. No chrome by default. | Settings as raw files only. |
| Helix, Neovim | Each function has a key. A key hint popup shows the next possible keys. | No pointer path for a new user. |

What Thor already takes from this: the palette with a count, quick open, the status bar
split, chords in tooltips, the three-layer configuration, a tutorial instead of a manual.

## 4. What Loom gives

Facts from `vendor/loom/loom`. A capability missing here is added upstream in Loom, never worked
around in Thor.

### 4.1 Available

| Area | Capability | Where |
| --- | --- | --- |
| Layout | Multi-pass flexbox: `dir`, `wrap`, `justify`, `align`, `align_self`, `gap`, `pad`, `margin`, `order`, `aspect`, min and max sizes. Sizes are `Px`, `Pct`, `Grow`, `Fit`. | `props.odin`, `layout.odin`, `size.odin` |
| Layers | `position` (`Flow`, `Relative`, `Absolute`, `Fixed`), `inset`, `z`, `.Floating`, `.Pass_Through`. | `props.odin`, `tree.odin` |
| Surface | `bg` as a colour or a gradient (linear, radial, bilinear), `border` (width per edge), `radius` (per corner), `shadow` (offset, blur, spread, inset), `opacity`. | `props.odin` |
| State styles | `hover`, `active`, `focus`, `disabled`, `group_hover` props, and `rules` on a `State_Set` (`Checked`, `Open`, `Focus_Within`, …). | `tree.odin`, `cascade.odin` |
| Motion | `Transition{props, dur, delay, ease}` on 22 props (sizes, pad, gap, bg, border, radius, shadow, opacity, colour, font size). Eases: `Linear`, `Out_Quad`, `In_Out_Quad`, `Out_Cubic`, `Out_Back`, `Spring`. `.No_Anim` turns a node off. A node does not animate on its first frame. | `transition.odin` |
| Scrolling | Scrollbars from `overflow`, wheel bubbling, inertia (`Config.scroll_inertia`, `no_scroll_inertia`), animated scroll-to (`scroll_to_dur`), `.Wheel` for a view that owns its offset. | `scroll.odin`, `containers.odin` |
| Text | Colour spans per byte range, tab stops, wrap modes (`Words`, `Chars`, `None`, `Ellipsis`), horizontal and vertical alignment, `caret_x` and `offset_at`. | `text.odin` |
| Widgets | `label`, `spacer`, `divider`, `button`, `image`, `checkbox`, `radio`, `slider`, `input` (selection, word moves, undo, clipboard), `scroll`, `popup`, `tooltip`, `virtual`. | `widgets.odin`, `containers.odin`, `input_text.odin`, `virtual.odin` |
| Docking | `dockspace`, `panel`: tabs, splitters, drag to dock, detach, `dock_save` and `dock_load`. | `dock.odin`, `dock_viewport.odin` |
| Painting | `paint_rect`, `paint_line`, `paint_poly` in node-local coordinates, under or over the text. `custom` for the host renderer. | `paint.odin` |
| Interaction | Click counts, right and middle click, drag delta, hover enter and exit, 8 cursor shapes, `.Hoverable`. | `input.odin`, `interact.odin` |
| Keyboard | An ordered key stream with `consumed`. Tab and Shift+Tab move the focus over `.Focusable` nodes in tree order. Escape drops the focus. Space and Enter activate. | `interact.odin` |
| Theme | 20 colour slots, set once with `set_theme`. Loom's own widgets read only these. | `theme.odin` |
| Debug | `debug_overlay`, `debug_rects`, `dump_tree`, `stats`. | `debug.odin` |

Loom's own widget timings are a good base: button 120 ms `Out_Quad`, checkbox 100 ms, popup fade
100 ms, tooltip delay 500 ms.

### 4.2 Limits

| Limit | Result for Thor |
| --- | --- |
| No key routing. Call order is priority. | Global chords run before the tree. A widget takes a key only inside `ui.focus_within`. |
| A new node has a zero rect and no hover until the next pass. | An enter animation cannot start from the final geometry in frame one. Anchor popups to a node that exists; fade in from opacity 0 as `ui.popup` does. |
| Virtual rows have one height. | A list row never grows. A second line is a second row type with a fixed height. |
| `Cmd_Push_Clip.radius` is ignored by `render` (a scissor is a rectangle). | A rounded container that clips children shows square corners on the children. Keep children inside the radius with padding. |
| No backdrop blur, no blend modes. | A scrim is a flat colour with alpha. |
| No drag-and-drop payload API. | Drag sources and targets are host code on `dragging` and `drag_delta`. |
| No accessibility tree. | A screen reader cannot read Thor. See 9.5. |
| No IME composition surface. | Composed input shows only when committed. |
| No reduce-motion switch. | The host must set `.No_Anim` or zero durations. See 8.5. |
| No UI scale. `Input.dpi` exists; props are raw pixels. | The host must multiply. See 9.3. |
| `Transition` is one set for all listed props of a node. | A node that needs two durations is two nodes. |

## 5. Tokens

These are the only values a view uses. They are stated in pixels at scale 1.0 (see 9.3).

### 5.1 Spacing

Principle: space groups things. Less space inside a group, more between groups, the same step for
the same relation everywhere.

| Token | px | Use |
| --- | --- | --- |
| `xxs` | 2 | Icon to its badge. Inside a chip. |
| `xs` | 4 | Icon to label. Between rows of a dense group. |
| `s` | 6 | Row edge padding in a tree. |
| `m` | 8 | Control padding. Gap between controls of a group. |
| `l` | 12 | Padding of a card or popup. Gap between groups. |
| `xl` | 16 | Padding of a modal. Tree indent. |
| `xxl` | 24 | Between sections of a modal. |
| `xxxl` | 32 | Page margins (welcome, empty state). |

No other value. 10 and 14 are not on the scale.

### 5.2 Heights

Principle: a small number of heights makes rows line up across panels and makes a pointer target
predictable.

| Token | px | Use |
| --- | --- | --- |
| Bar: title | 44 | `TITLEBAR_HEIGHT` |
| Bar: tabs | 38 | `TAB_HEIGHT` |
| Bar: status, strip | 28 | `STATUSBAR_HEIGHT`, `TERMINAL_STRIP_HEIGHT` |
| Control | 28 | Buttons, inputs, dropdowns, titlebar buttons. |
| Row: compact | 22 | A tab inside a strip. A chip. |
| Row: list | 26 | Trees, menus, result lists, git rows. |
| Row: picker | 30 | The palette and each picker that uses its shape. |
| Row: form | 34 | A settings row with a control at the right. |
| Row: two-line | 46 | A row with a title and a second line. |

A code row (editor, diff, peek, terminal) is not a token: its height is the line height of its font.

### 5.3 Radius

Principle: the radius says what layer a thing is on. Larger things on higher layers have a larger
radius. A nested shape has the outer radius minus the gap.

| px | Use |
| --- | --- |
| 0 | Panels, bars, tabs, rows that touch the panel edge. |
| 4 | Controls, chips, row hover fills that do not touch the edge. |
| 6 | Popups: menus, tooltips, completion, hover and signature cards. |
| 8 | Floating cards and pickers: palette, select, find, tips, permission. |
| 10 | Large modals: settings, git, problems, theme editor, undo history. |
| Half the height | Pills and toggles. |

### 5.4 Borders

Principle: a border is a hairline that separates two things of the same colour. Where the surface
colour changes, there is no border.

- Width 1 px. It does not scale.
- Colour: the `border` role. A focus ring uses `accent`.
- A floating layer always has a border and a shadow, since a dark theme hides the shadow.
- A splitter is 3 px wide (`DOCK_SPLITTER_WIDTH`, `PANE_HANDLE_WIDTH`) and shows `accent` on hover.

### 5.5 Elevation

Principle: three layers, no more. A shadow says "this floats"; it is not decoration.

| Level | Shadow (offset, blur) | Scrim alpha | Use |
| --- | --- | --- | --- |
| 0 | none | none | Panels, bars, rows. |
| 1 | `{0, 4}`, 16 | none | Popups anchored to a node: menus, editor cards, tooltips. |
| 2 | `{0, 6}`, 24 | 120 | Pickers and cards: palette, select, find, tips. |
| 3 | `{0, 8}`, 32 | 140 | Large modals. |

The shadow colour is the `contrast` role. The scrim is black with the alpha of the table. Two modals
never stack: a modal that needs a question shows it in place.

### 5.6 Type

Principle: one UI font, three sizes, weight before size. Monospace in chrome only for things that
are code: a path, a key chord, a hash, a value.

| Token | Size | Use |
| --- | --- | --- |
| Small | UI size − 2 | Second lines, badges, counts, chords in tooltips. |
| Body | UI size | All else. |
| Title | UI size + 2 | The title of a modal or a card. |
| Display | 2 × UI size | The welcome page only. |

UI size is `general.font_size`. No all-caps labels longer than one word. Sentence case for commands
and labels ("Open folder", not "Open Folder"). No full stop on a label; a full stop on a sentence.
Text that does not fit ends in an ellipsis (`text_wrap = .Ellipsis`); a path is cut in the middle so
the file name stays.

### 5.7 Colour

Principle: surfaces differ by small steps of lightness. Colour with hue means something: the accent
means "this is active or will act", a status colour means a status.

| Thing | Role |
| --- | --- |
| Editor, main panels | `background` |
| Side panels, headers, hovered row | `second_background` |
| Inputs, the deepest surface, shadow | `contrast` |
| Buttons, chips, inactive tabs | `buttons` |
| Selected tab, row or button | `active` |
| Current line | `highlight` |
| Selected text, selected row of a picker | `selection_background` (+ `selection_foreground`) |
| Labels and control text | `foreground` |
| Names in lists | `primary_text` |
| Second lines, paths, hints | `muted` |
| Disabled controls, line numbers | `disabled` |
| Caret, focus ring, toggles on, the default button | `accent` |
| Status | `success`, `warning`, `info`, `danger`, `error`, `conflict` |

Rules:

- One accent. `accent_secondary` is for plugins and marks, never for a second kind of emphasis in
  the chrome.
- A status colour is used only for that status. A red button is a destructive button.
- No colour literal in a view, except black with alpha for a scrim and full transparency.
- Syntax roles are for code. Chrome does not borrow them.
- Colours go to Loom once, through `thor_push_theme`. No per-node colour setters for what a Loom
  slot already covers.

### 5.8 Icons

- Sizes: 14 in bars and controls, 16 in rows.
- An icon has one meaning in the whole program.
- An icon-only control has a tooltip, and the tooltip has the chord when there is one (`thor_tip`).
- Icon colour is `foreground` or `muted`. A file-type icon may keep its own tint.
- An action icon inside a row (close, discard, stage) shows on row hover or focus, and its column is
  always reserved so the row does not move.

### 5.9 Motion

See section 8 for the rules. The values:

| Token | Value | Use |
| --- | --- | --- |
| Instant | 0 ms | Hover in, press, selection, focus ring, text, caret. |
| Fast | 100 ms, `Out_Quad` | Hover out, colour and border changes, popup fade. |
| Normal | 150 ms, `Out_Cubic` | A panel or fold that opens, a modal that enters, a scroll-to. |
| Limit | 200 ms | No UI transition is longer. |
| Tooltip delay | 500 ms | `TOOLTIP_DELAY`. |
| Busy delay | 250 ms | `LANG_BUSY_DELAY_SECS`. No busy mark before it. |

## 6. Components

### 6.1 Titlebar and menus

- The titlebar holds the menus, the task selector and the window buttons. A new permanent button
  needs a reason that holds for most sessions; all else goes in a menu or the palette.
- A menu row: 26 high, label left, chord right in `muted`, a separator between groups. A row that
  opens a dialog ends in "…".
- A menu holds commands. Each row is also in the palette under the same name.
- A context menu holds only actions for the thing under the pointer, the most likely first, the
  destructive last and separated.

### 6.2 Tabs

- A tab shows the icon, the name and one state mark: unsaved, loading or the close button.
- Two files with one name get the shortest folder part that tells them apart.
- The close button is in a reserved column. The active tab uses `active` and an accent line.
- Middle click closes.

### 6.3 Trees and lists

- Rows are virtual (`ui.virtual`) and 26 high. Indent 16 per level, with guides in the `tree` role.
- Hover fills with `second_background`, selection with `selection_background`. The focused list
  shows the selection stronger than an unfocused one.
- Right-aligned data (a git letter, a count) has a fixed column.
- Arrow keys move, Enter opens, typing filters or jumps. Home, End, Page Up and Page Down work.
- An empty list says why it is empty and what to do ("No changes", "No results for 'x'").

### 6.4 Palette and pickers

- One shape for all: a floating card, width 720 (palette) or 420 (a select), a text field at the top
  with the focus, at most 10 to 12 rows of 30, a count when rows are hidden.
- Fuzzy match with the matched characters marked. The most recent or most likely row is first and is
  selected, so Enter alone does something useful.
- A row shows the chord of its command at the right.
- Enter runs, Escape closes, the arrows move and wrap. Nothing else is needed to use it.
- A picker previews its effect when the preview is cheap and reverts on Escape (theme, icon pack).

### 6.5 Modals and dialogs

- A modal is for a decision the user must make now, or for a tool that needs the room (settings,
  git). Information that needs no answer is not a modal.
- Width classes: 420 (question), 520 (form, permission), 720 to 940 (tool), at most 1080. A modal is
  never larger than the window minus 32 on each side.
- Structure: a title, the body, the buttons at the bottom right. The default button is last, uses
  `accent` and is the one Enter runs. The destructive button uses `danger`, is never the default and
  names the action ("Discard changes", not "OK").
- Escape and a click on the scrim cancel. A modal with unsaved input asks before it closes that way.
- The focus goes to the first field or to the default button when it opens, and back to where it
  was when it closes.

### 6.6 Tooltips

- A tooltip says what a control does in one line, with the chord dim on a second line.
- It never holds something the user needs and cannot get another way.
- It appears after 500 ms, goes away on any key or press, and can be turned off (`tooltips`).

### 6.7 Status bar

- Left: the workspace (branch, problems, a busy mark, a message). Right: the active file (position,
  indent, line ending, encoding, language).
- Each segment is a text or an icon with a text. A segment that can be clicked has a hover fill and
  a tooltip.
- A message stays 3 s (`STATUS_MESSAGE_SECS`). An error stays until the next message.
- The status bar is the place for a routine result ("Saved", "Formatted", "3 references").

### 6.8 Notifications and cards

- A routine result goes to the status bar. A card is for something the user must know and did not
  ask for (an update, a migrated config, a tip).
- One card at a time. Each card can be closed and has a "do not show again" path where it can come
  back.
- A card never takes the focus and never covers the caret.
- Progress shows where the work is: in the tab (loading), in the panel, in the status bar. A global
  progress card is the last choice, and then it has a cancel.

### 6.9 Editor overlays

- Completion, hover, signature and peek are level-1 popups anchored to the caret or the pointer.
  They use the editor font and never cover the line the caret is on.
- They flip above the line when there is no room below, and they do not jump between frames while
  they are open.
- No animation on the typing path: a completion list appears and updates in the frame.
- Diagnostics: a squiggle in the status colour, the same colour in the gutter and in the scrollbar,
  and the text on hover and in the problems view.

### 6.10 Settings and forms

- A form row: 34 high, the label left, the control right, the description in `muted` below the label
  (a 56 row).
- A setting applies at once. No "Apply" button. A setting that needs a restart says so in the row.
- A changed value shows that it differs from the default and can be reset.
- Search filters the rows as the user types.

### 6.11 Terminal

- The grid uses the editor font and the theme's palette. The chrome around it follows this document.
- A focused terminal owns the keys (`thor_terminal_owns_key`); the chords that leave it are shown in
  the tooltip of its tab strip.

### 6.12 Empty, loading and error states

- Empty: one line that says what is missing and one action that fixes it.
- Loading: nothing for 250 ms, then a quiet mark at the place the result will be. The layout does
  not move when the result lands.
- Error: what failed, why if it is known, and what the user can do. In the place where it failed.
  Never only in the log.

## 7. Keyboard first

Principle: a user who never touches the pointer loses no function. A user who never learns a key
loses none either.

1. Each action is a command with a `keybinds` name, shows in the palette, and can be bound.
2. Each route that runs an action calls `thor_note_action`.
3. A chord is shown where the action is shown: the menu row, the palette row, the tooltip.
4. Each interactive node is `.Focusable` and has a `focus` style: a 1 px `accent` border or ring.
   The ring shows for keyboard focus and is never removed for looks.
5. Tab order is the reading order: left to right, top to bottom, inside one layer. A modal keeps Tab
   inside itself.
6. Escape closes the top layer only: a popup, then the modal, then the selection.
7. In a list: Up, Down, Home, End, Page Up, Page Down, Enter, and typing to filter.
8. Panels have focus chords (`"explorer"`, `"console"`, `"pane0"` … `"pane5"`), and the focused
   panel is visible: its selection is stronger, or its header is marked.
9. Nothing is hover-only. What appears on hover also appears on focus or has a command.
10. A shipped chord does not shadow a common platform chord (copy, paste, undo, close window).

## 8. Motion and feedback

Principle: motion explains a change the user caused. It never makes the user wait, and it never
runs on its own.

### 8.1 Budgets

| Event | Budget |
| --- | --- |
| Key to glyph, press to pressed state, hover in | The same frame. |
| A command with a local result (open palette, switch tab, fold) | The next frame. |
| A result from a worker (completion, hover, search) | Shown when it lands. A busy mark after 250 ms. |
| Work over 1 s | A busy mark with a text that names the work. |
| Work over 10 s | Progress, and a way to cancel. |

### 8.2 What may animate

- Colour, border colour and opacity of a control: Fast.
- A popup or modal that enters: opacity, Normal or shorter. It leaves in 0 ms.
- A panel, fold or accordion that opens: size, Normal.
- A scroll-to that the user asked for (go to definition in the same file): `scroll_to_dur`.

### 8.3 What never animates

- Text, the caret position, selection, syntax colours.
- A list while the user types into its filter.
- Layout of the editor rows.
- A thing the user did not cause. No pulsing, no attention loops, no idle motion. The one exception
  is the caret blink and a busy mark.

### 8.4 Rules

- An animation can be interrupted: a new input starts from the current value (Loom does this).
- `Out_Quad` and `Out_Cubic` for all UI. `Spring` and `Out_Back` only for a position the user
  dragged. `Linear` only for a busy mark.
- Work that advances with time on its own checks `thor.frame_pass == 0`.
- An idle window draws nothing new. An animation ends, and `ui.animating()` goes false.

### 8.5 Reduce motion

A `reduce_motion` setting is required. When it is on: all durations are 0, scroll inertia is off
(`Config.no_scroll_inertia`), the caret does not blink.

## 9. Accessibility and scaling

### 9.1 Contrast

Principle: text must be readable by a user with average sight on an average display in a bright
room. A theme that fails is a broken theme.

| Pair | Minimum ratio |
| --- | --- |
| `text`, `foreground`, `primary_text` on their surface | 7 : 1 |
| `muted`, `links`, each syntax role on `background` | 4.5 : 1 |
| `disabled` on its surface | 3 : 1 |
| `accent`, status colours, focus ring, icons on their surface | 3 : 1 |
| Selected text on `selection_background` over `background` | 4.5 : 1 |
| Adjacent surfaces (`background` and `second_background`) | No minimum. A border or space separates them. |

`theme.color_contrast_ratio` measures, `theme.color_ensure_contrast` repairs, and the generator uses
both (`TEXT_FLOOR` is 4.5). The ratios are WCAG 2.2 AA; the first row is stricter by choice.

### 9.2 Targets

- A pointer target is at least 24 × 24. A smaller mark (a 16 px icon) sits in a 24 hit area.
- Two targets do not touch without a gap or a visible boundary.
- A splitter is 3 px to the eye. Its grab area must be at least 6.

### 9.3 Scale

- UI text follows `general.font_size`. Each token of 5.1 to 5.3 is multiplied by
  `ui_scale = font_size / 18` and rounded to a whole pixel, so a row grows with its text.
- Hairlines stay 1 px.
- The window is usable at 800 × 500: panels hide below a width (`EXPLORER_HIDE_W`), a modal shrinks
  and scrolls.
- No text is cut without an ellipsis, at any supported font size.

### 9.4 Not by colour alone

A git status has a letter. A diagnostic has an icon and a text. A diff row has `+` or `-`. A
selected tab has a line, not only a fill.

### 9.5 Known gap

Thor has no screen-reader support: Loom has no accessibility tree and raylib exposes none. This
document does not claim otherwise. All rules above still hold, since they also serve low vision,
motor limits and a bad display.

## 10. Plugin and theme authors

### 10.1 Plugins

A plugin panel is `View_Node` data that `thor/plugin_panel.odin` declares as Loom nodes, so it gets
the tokens of this document for free. The rules for the plugin:

- Colours are role names (`thor.theme.<role>`), never literal values. A panel must be readable in
  each shipped theme.
- Use the given node kinds (label, button, list, separator, spacer) before a canvas. A canvas draws
  with role colours and the given font.
- A plugin adds commands and, with a reason, one titlebar button. It does not add chrome.
- Each plugin action is a command, so it is in the palette and can be bound.
- A plugin does not open a modal by itself at load, does not show a card for a routine result, and
  writes routine output to the console.
- Text follows 5.6: sentence case, no full stop on a label.

`plugins/README.md` is the reference for the API.

### 10.2 Themes

- A theme sets each role of `theme.COLORS`. A missing role takes the Mjolnir value, which will not
  fit a light theme.
- A theme passes the table of 9.1.
- Surfaces are steps of one hue: `contrast` < `background` < `second_background` < `buttons` <
  `active` < `highlight` for a dark theme, the reverse for a light one.
- `selection_background` has alpha, so syntax colours stay visible.
- `success`, `warning`, `danger` and `info` differ in more than hue (lightness too), for users who
  do not see red and green apart.
- Test a theme in: the editor with a diagnostic, the palette, a modal, the git view, the terminal.

## 11. Gap audit

Where Thor does not follow this document. Line numbers are of version 2026.11.4.

### 11.1 Thor

| # | Rule | Finding | Where |
| --- | --- | --- | --- |
| 1 | 2.9 | No shared token file. Each view has its own constants for row height, width, pad and gap. | `thor/explorer.odin:13`, `menu.odin:9`, `palette.odin:68`, `select.odin:14`, `settings_view.odin:12`, `git_view.odin:12`, `find.odin:13`, `permission.odin:12`, … |
| 2 | 5.2 | Row heights off the scale: 28 (`UNDO_ROW_H`). The same height has four names (`EXPLORER_ROW_H`, `MENU_ROW_H`, `GIT_ROW_H`, and a literal 26). | `thor/undo_history.odin:16`, `plugin_panel.odin:391` |
| 3 | 5.1 | 10 and 14 are common paddings. | `thor/console_view.odin:29`, `hex_view.odin:24`, `image_view.odin:23`, `tutorial_view.odin:17`, `view.odin:415`, `tasks.odin:25`, `update.odin:29` |
| 4 | 5.3 | Radii 2, 3, 7, 11 and 12 are in use beside 4, 6, 8 and 10, all as `ui.rad(n)` literals (about 110 sites). | `thor/view.odin`, `settings_view.odin`, `tutorial_view.odin` |
| 5 | 5.5 | The shadows already form three levels (4/16, 6/24, 8/32) but are copied as literals at 19 sites. The scrim alpha is 120, 140 or 150. | `thor/palette.odin:658` (120), `settings_view.odin:449` (140), `permission.odin:115` (150) |
| 6 | 5.9, 8.2 | No node in `thor/` sets a `transition`. Only Loom's own widgets (`button`, `checkbox`, `popup`) animate. Hover on each custom row and button is a hard switch in and out. | all of `thor/` |
| 7 | 7.4 | No node in `thor/` sets a `focus` style. Custom buttons are `.Clickable` and not `.Focusable`, so Tab does not reach them and nothing would show if it did. | `thor/view.odin:408` (`thor_text_button`), `view.odin:430` (`thor_titlebar_button`) |
| 8 | 2.4 | `thor_text_button` and `thor_titlebar_button` are private to `view.odin`. Other views build their own buttons. | `thor/view.odin:407`, `model_view.odin:268`, `plugin_panel.odin` (`plugin_view_button`) |
| 9 | 9.3 | Row and control heights are pixel constants, and UI text follows `general.font_size`. A large font size clips in a 26 px row. No `ui_scale`. | `thor/view.odin:114`, `explorer.odin:555`, `menu.odin:179`, `palette.odin:893` |
| 10 | 5.6 | Font sizes as literals (36, 10) and as ad-hoc offsets (−1, −2, +2). | `thor/view.odin:765`, `view.odin:955`, `peek.odin:343`, `peek.odin:349`, `tutorial_view.odin`, `whats_new.odin` |
| 11 | 5.7 | `thor_push_theme` sets `dark = true` for each theme, maps `overlay` to the same role as `surface`, and `divider` to `border`. A light theme tells Loom it is dark. | `thor/view.odin:74`, `view.odin:78`, `view.odin:80` |
| 12 | 9.1 | Mjolnir: `disabled` on `background` is 2.78 : 1 (rule 3 : 1) and is used for line numbers and tooltip chords. `comments` is 3.12 : 1 (rule 4.5 : 1). `border` on `background` is 1.03 : 1, so a hairline is invisible and panels separate by surface colour only. | `theme/theme.odin:137`, `theme.odin:140`, `theme.odin:156`, `thor/tooltips.odin:25` |
| 13 | 9.1 | The contrast rules are checked for generated themes only (`theme_generate_test.odin`). No test checks the shipped theme files. | `theme/theme_generate_test.odin:41` |
| 14 | 8.5 | No `reduce_motion` setting. | `settings/settings.lua` |
| 15 | 9.2 | Splitters are 3 px wide and the grab area is the same 3 px. | `thor/view.odin:25`, `panes.odin:17` |
| 16 | 10.1 | Plugin panel metrics are literals too (header 32, button 24 × 20, canvas font 14 that does not follow the UI size). | `thor/plugin_panel.odin:56`, `plugin_panel.odin:259`, `plugin_panel.odin:266` |

Good as it is, and to keep: chords in tooltips (`thor_tip`), the palette count, the
status bar split, the busy delay, a scrim click and Escape on each modal, virtual lists in the
explorer, the three shadow levels, role colours for plugin panels (`thor_plugin_role_color`).

### 11.2 Needs Loom

| # | Rule | Missing |
| --- | --- | --- |
| L1 | 9.3 | A scale factor applied to pixel props, or a documented host pattern for one. |
| L2 | 8.5 | A context switch that turns all transitions off. |
| L3 | 9.2 | A hit area larger than the drawn rect (a splitter, a small icon). |
| L4 | 5.3 | A rounded clip, or a note in each backend that the radius is ignored. |
| L5 | 7.5 | A focus scope, so Tab stays inside a modal without host code. |
| L6 | 8.2 | A leave transition: a node that is no longer declared is gone in the same frame. |
| L7 | 9.5 | An accessibility tree. Large; stated so it is not forgotten. |
| L8 | 6.3 | Virtual rows of more than one height, for a two-line row inside a list of one-line rows. |

## 12. Review checklist

A UI change passes when each answer is yes.

- [ ] Each size, radius, shadow and duration is a token of section 5.
- [ ] Each colour is a theme role. No literal except a scrim.
- [ ] It uses an existing shape (row, picker, modal, card) or says why it cannot.
- [ ] Each action is a command, is in the palette, and calls `thor_note_action`.
- [ ] Each interactive node can take the focus and shows it.
- [ ] Escape closes it. The focus goes back where it was.
- [ ] Hover, press and selection show in the frame of the input.
- [ ] No transition is over 200 ms, and none is on the typing path.
- [ ] Nothing moves when an async result lands.
- [ ] It has an empty state, a loading state after 250 ms, and an error state.
- [ ] A status is not shown by colour alone.
- [ ] Each icon-only control has a tooltip with its chord.
- [ ] It is readable in Mjolnir and in a light theme, at font size 14 and 24.
- [ ] It works at a window of 800 × 500.
- [ ] Long text ends in an ellipsis and does not push the layout.
- [ ] A loop body has `ui.push_id_int(i)` or a `key`.
- [ ] `docs/` and `CHANGELOG.md` have the change when a user can see it.

## 13. References

- VS Code: [UX Guidelines](https://code.visualstudio.com/api/ux-guidelines/overview),
  [Notifications](https://code.visualstudio.com/api/ux-guidelines/notifications),
  [Modernizing the VS Code UI](https://code.visualstudio.com/blogs/2026/10/15/modern-ui)
- JetBrains: [IntelliJ Platform UI Guidelines](https://jetbrains.github.io/ui),
  [New UI](https://www.jetbrains.com/help/idea/new-ui.html)
- Visual Studio: [Visual Studio UI Refresh](https://devblogs.microsoft.com/visualstudio/visual-studio-ui-refresh/)
- Zed: [Leveraging Rust and the GPU to render user interfaces at 120 FPS](https://zed.dev/blog/videogame)
- Lapce: [lapce/lapce](https://github.com/lapce/lapce), [docs](https://docs.lapce.dev)
- W3C: [WCAG 2.2](https://www.w3.org/TR/WCAG22/) — 1.4.3 contrast, 1.4.11 non-text contrast,
  2.5.8 target size
- Loom: `vendor/loom/README.md`
