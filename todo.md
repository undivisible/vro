# TODO

## Git gutter backend

- Keep the editor dependency-free by default.
- Do not call `git` subprocesses while the TUI is running.
- Add a read-only native V git gutter backend when ready.
- Scope the backend to local gutter marks only: repository discovery, `.git/index` parsing, blob lookup, working-tree comparison, and line-diff mapping.
- Support loose objects and packed objects before enabling it by default.
- Keep `libgit2` as an optional fallback only if the native backend gets too large or fragile.

## Terminal panes

- Keep file splits as the current supported split type.
- Do not fake `top zsh`, `top bash cargo check`, or similar commands with plain split rendering.
- Add terminal panes only after there is a real PTY/process lifecycle layer: spawn, resize, redraw, input routing, scrollback, exit status, and cleanup.

## Editor parity audit

- Make split layout a real tree before supporting complex nested split combinations.
- Add pane-local command/status state so inactive panes never steal command input or cursor visibility.
- Decide whether clipboard should stay internal or integrate with platform clipboards like micro does.
- Add color-scheme support and a 16-color fallback; micro notes that weak terminal color support can make highlighting appear sparse.
- Add richer syntax-region nested rules if the regex highlighter stays; otherwise evaluate a parser-backed highlighter later.
