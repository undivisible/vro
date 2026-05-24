# TODO

## Git gutter backend

- Keep the editor dependency-free by default.
- Do not call `git` subprocesses while the TUI is running.
- Add a read-only native V git gutter backend when ready.
- Scope the backend to local gutter marks only: repository discovery, `.git/index` parsing, blob lookup, working-tree comparison, and line-diff mapping.
- Support loose objects and packed objects before enabling it by default.
- Keep `libgit2` as an optional fallback only if the native backend gets too large or fragile.
