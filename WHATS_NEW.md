# 2026.11.1

- **Completion card.** A card beside the completion list shows the selected item's signature and documentation, rendered as Markdown.
- **Build target per file.** "Odin: Select Build Target..." or the target segment of the status bar picks the target of one file. The choice is kept in the `file_targets` setting.
- **`thor fmt`.** `thor fmt [-w|--check] <file|folder>...` formats Odin files and packages from the command line. `-` reads stdin.
- **Several language servers per language.** Every enabled server that claims a language answers for it, and lists such as completion and code actions merge.
- **Restart keeps your place.** Each file reopens with the caret on its line, and a tab keeps its scroll position when you switch back.
- **Large files.** A file of 8 MB or more opens with the heavy language features off, and a status message says so. Typing in it is much faster.
- **New Odin quick fixes.** Declare a `for` variable as `&x`, remove an unneeded cast, and indent with tabs under `-vet-tabs`.
