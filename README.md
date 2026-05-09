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

## Run

```sh
v -gc none run main.v [file]
```

## Build

```sh
v -gc none -prod -o vro main.v
./vro [file]
```

## Install (pick one)

Recommended order (same style as [inauguration](https://github.com/semitechnological/inauguration/blob/main/README.md#install-cli-pick-one)):

**1. Prebuilt binaries (GitHub Releases)**

Tagged releases publish `vro-macos-aarch64.tar.gz`, `vro-linux-x86_64.tar.gz`, and matching `*.sha256` checksum files (see [`.github/workflows/release.yml`](.github/workflows/release.yml)). Verify with `shasum -a 256 -c vro-<platform>.sha256`, extract the tarball, put `vro` on your `PATH`.

**2. Wax (Homebrew-compatible parity)**

```sh
wax tap undivisible/tap
wax install vro
```

**3. Homebrew tap**

```sh
brew tap undivisible/tap https://github.com/undivisible/homebrew-tap
brew install vro
```

Both **wax** and **brew** use the versioned formula with pinned `url` + `sha256` per platform (no compile step for end users).

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
