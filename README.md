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

## Syntax highlighting

Bundled rules for **V** (`syntax/v.yaml`). Optional overrides live in `~/.config/vro/syntax/<name>.yaml` where `<name>` follows micro bundle names (`v`, `go`, `rust`, `cpp`, …) inferred from the file extension, or the extension without the dot if unknown (e.g. `nim.yaml` for `.nim`). Same schema as below. Rules are a **subset** of [micro](https://github.com/micro-editor/micro/tree/master/runtime/syntax) YAML: `filetype`, `detect.filename`, and ordered `rules` of `- group: "regex"` patterns plus simple `- group:` / `start:` / `end:` / `skip:` regions. Region rules continue across newlines (e.g. `/* … */`). Patterns use V’s `regex` module (not PCRE); `\\b` is stripped on load. Disable with `NO_COLOR` or `VRO_NO_HL=1`.

## Install

**Prebuilt (GitHub Releases)**

Tarballs and `*.sha256` files are attached to each `v*` tag (see [`.github/workflows/release.yml`](.github/workflows/release.yml)). Verify with `shasum -a 256 -c vro-<platform>.sha256`, unpack, put `vro` on your `PATH`.

**Wax**

```sh
wax tap undivisible/tap
wax install vro
```

**Homebrew**

```sh
brew tap undivisible/tap https://github.com/undivisible/homebrew-tap
brew install vro
```

Wax and Homebrew install the same prebuilt binaries (`url` + `sha256` per platform in the tap formula).

To bump checksums after a new tag: `./scripts/print-release-shas.sh v0.x.y`, then update `../homebrew-tap/Formula/vro.rb`.

## Keybindings

- `Ctrl-S`: save file
- `Ctrl-Q`: quit (requires repeated presses if unsaved)
- `Ctrl-F`: search
- `Ctrl-E`: command bar
- `Backspace` / `Delete`: delete character
- `Enter`: new line

## Command Bar

Press `Ctrl-E`, then type a command:

- `open <path>` or `o <path>`
- `write` / `w` / `save` (or pass a path: `write <path>`)
- `saveas <path>`
- `find <text>` (or just `find` for interactive search)
- `goto <line>` or `g <line>`
- `quit`, `q`, or `quit!`
- `help`

## License

[MPL 2.0](LICENSE). Optional user syntax YAML may mirror micro’s MIT-licensed definition layout; vro ships its own highlighter, not micro’s Go engine.
