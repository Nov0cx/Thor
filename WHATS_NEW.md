# 2026.11.3

- **Formatter fixes.** `foreign import` with an expression path and `else` after a `do` body format to code that parses again.
- **Trailing comments.** The formatter writes one space before a trailing comment, not two, and keeps the comment after the item it follows.
- **Stable formatting.** `thor fmt --check` passes right after `thor fmt -w` for expanded composite literals.
