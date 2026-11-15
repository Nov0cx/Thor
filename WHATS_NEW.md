# 2026.11.5

- **Project and personal settings.** `.thor/settings.lua` applies only project settings: indentation, formatting and language. Keys such as `theme` or `font` there are skipped, and the status bar names them once. `.thor/keybinds.lua` is not read.
- **This folder.** Settings has a "This folder" tab for personal settings of one folder, kept in `user/workspaces/`. The "Workspace" tab is now "Project".
- **Pickers write `user/`.** The theme, font, icon pack, ligature and default shell pickers write `user/settings.lua`, also in a folder with a `.thor/`.
- **Keyboard focus.** `tab` reaches the buttons, toggles and chips of the title bar, the status bar and every dialog, and stays inside an open dialog. A ring shows the keyboard focus.
- **Scales with the font.** Row heights, paddings, corner radii and shadows follow `font_size`, so a large font no longer clips in a row.
- **Motion.** Buttons, list rows, dialogs and cards fade. The new `reduce_motion` setting turns off the fades, scroll inertia, animated scrolls and blinking.
- **Window move and resize.** A drag on the empty part of the title bar moves the window, and a double click maximizes it. The edges and corners of a restored window resize it.
- **Themes.** Each shipped theme meets the contrast minimums. Material Lighter and Solarized dark change the most.
- **Sentence case.** Command, menu and picker names read "View: Toggle word wrap". Keybinds are unchanged.
