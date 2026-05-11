# vro

A small `micro`-inspired terminal text editor written in V.

## Features

- Open files from argv
- Insert and delete text
- Arrow/home/end/page navigation
- Save with `Ctrl-S`
- Incremental search with `Ctrl-F`
- Command bar with `Ctrl-E`
- Dirty-file quit protection with `Ctrl-Q`
- Micro-style **YAML** syntax highlighting (V regex engine; see `syntax/`)

## Run

```sh
v -gc none run . [file]
```

## Build

```sh
v -gc none -prod -o vro .
./vro [file]
```

## Test

```sh
v -gc none test .
```

Plain `v test .` can fail with a missing `<gc.h>` when Boehm GC development headers are not installed. This repo is checked in CI with `-gc none`, so prefer that for local runs too.

## CLI (no TTY)

For scripts, CI, and quick checks, `vro` exits before touching the terminal when you pass:

- `-version` or `--version` — print version and exit
- `-h`, `-help`, or `--help` — print usage and exit

Example: `./vro -version`

**Benchmark** (optional, needs [hyperfine](https://github.com/sharkdp/hyperfine)—install with `wax install hyperfine`, your OS package manager, or the upstream instructions): `bash scripts/bench-cli.sh` compares `vro -version` vs `micro -version`.

## Syntax highlighting

Bundled rules for **V** (`syntax/v.yaml`). Optional overrides live in `~/.config/vro/syntax/<name>.yaml` where `<name>` follows micro bundle names (`v`, `go`, `rust`, `cpp`, …) inferred from the file extension, or the extension without the dot if unknown (e.g. `nim.yaml` for `.nim`). Same schema as below. Rules are a **subset** of [micro](https://github.com/micro-editor/micro/tree/master/runtime/syntax) YAML: `filetype`, `detect.filename`, and ordered `rules` of `- group: "regex"` patterns plus simple `- group:` / `start:` / `end:` / `skip:` regions. Region rules continue across newlines (e.g. `/* … */`). Patterns use V’s `regex` module (not PCRE); `\\b` is stripped on load. Disable with `NO_COLOR` or `VRO_NO_HL=1`.

## Install

**One-liner (release tarball, needs checksum on asset)**

```sh
curl -fsSL https://raw.githubusercontent.com/undivisible/vro/main/install.sh | bash
```

Clone install (builds with `v` in `PATH`): run `./install.sh` from the repo root.  
`VRO_USE_RELEASE=1`, `VRO_VERSION=v0.3.4`, `VRO_INSTALL_DIR=…`, `VRO_NO_VERIFY=1` supported (see `install.sh`).

**Shell completions** (optional): copy `contrib/completions/vro.{bash,zsh,fish}` into your shell’s completion path.

**Prebuilt (GitHub Releases)**

Tarballs and `*.sha256` files are attached to each `v*` tag (see [`.github/workflows/release.yml`](.github/workflows/release.yml)). Verify with `shasum -a 256 -c vro-<platform>.sha256`, unpack, put `vro` on your `PATH`.

**Wax (recommended)**

```sh
wax tap undivisible/tap
wax install vro
```

**Homebrew (alternative)**

The [homebrew-tap](https://github.com/undivisible/homebrew-tap) formula tracks the same release tarballs and `sha256` values as Wax; use it if you standardize on `brew` instead of `wax`.

```sh
brew tap undivisible/tap https://github.com/undivisible/homebrew-tap
brew install vro
```

After you publish a release tag (e.g. `v0.3.4`), refresh the tap: `./scripts/print-release-shas.sh v0.3.4`, then paste the `sha256` values into `../homebrew-tap/Formula/vro.rb`. Do not point the formula at a tag until the release assets exist, or installs will 404.

## Keybindings

- `Ctrl-S`: save file
- `Ctrl-Q`: quit (if unsaved: three presses to force quit; wheel/mouse no longer resets the counter)
- `Ctrl-F`: search
- `Ctrl-E`: command bar
- `Ctrl-N`: cycle buffer word completions (longer words sharing prefix)
- `Tab`: indent with spaces; on `.html`/`.htm` buffers, expands a lone tag at end-of-line (emmet-lite)
- `Backspace` / `Delete`: delete character
- `Enter`: new line
- Mouse: terminals with SGR mode (most modern terminals): left click moves cursor (`VRO_NO_MOUSE=1` disables)

## Command Bar

Press `Ctrl-E`, then type a command:

- `open <path>` or `o <path>`
- `write` / `w` / `save` (or pass a path: `write <path>`)
- `saveas <path>`
- `find <text>` (or just `find` for interactive search)
- `goto <line>` or `g <line>`
- `quit` / `q` / `exit` / `x` (or `quit!` / `exit!` / `x!` to discard)
- `wq` — save and quit
- `help`

## License

[MPL 2.0](LICENSE). Optional user syntax YAML may mirror micro’s MIT-licensed definition layout; vro ships its own highlighter, not micro’s Go engine.
