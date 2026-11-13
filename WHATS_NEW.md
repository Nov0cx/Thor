# 2026.11.4

- **Hex view.** A binary file opens in a read-only hex view with offset, hex and ASCII columns. A click, a drag or `shift` + arrow keys select bytes, and `ctrl+c` copies them as hex. An image or 3D model that does not decode opens there too.
- **Quick open and `.gitignore`.** Quick open and find in files leave out the files `.gitignore` names. With an empty query, quick open lists the open files first.
- **Better ranking.** The palette and quick open rank a query that appears whole in a row above a scattered match.
- **Find in files.** The results are grouped under a row per file. The `Aa`, `ab` and `.*` buttons (`alt` + `c`, `w`, `r`) set case, whole word and regular expression.
- **Find bar.** It marks every match in view and outlines the current one.
- **`ctrl+r` in strings and comments** opens replace, not the rename prompt.
- **Menus.** **File** holds Settings, Language Servers, Open Settings File and Open Keybinds File. **Edit** holds Cut, Copy and Paste. The console panel is now called Terminal: **View > Toggle Terminal**.
- **Settings.** An on/off setting is a switch with a line that says what it does, and the search matches that line. Format on Save, Format on Type and Right Alt Key moved to the Editor page, Tip of the Day to Windows.
- **Narrow windows.** A window narrower than 800 pixels hides the explorer. It comes back when the window is wide again.
