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

## Homebrew (HEAD)

```sh
brew tap undivisible/tap https://github.com/undivisible/homebrew-tap
brew install --HEAD vro
```

Requires the `vlang` formula to compile.

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
