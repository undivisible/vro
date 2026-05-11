# Agent notes (vro)

Concise context for humans and coding agents working in this repository.

## What this is

`vro` is a small terminal text editor in [V](https://vlang.io/), micro-inspired: buffers, search, command bar, YAML-driven syntax highlighting under `syntax/`.

## V toolchain and `-gc none`

Use **`-gc none`** for `run`, `test`, `-check`, and release builds unless you have Boehm GC dev headers installed. Without them, plain `v test .` may error on missing `<gc.h>`. CI always uses `-gc none`.

Examples:

- `v -gc none test .`
- `v -gc none -prod -o vro .`
- `v -gc none run . [file]`

## Formatting (enforced in CI)

Before pushing, ensure the tracked V sources are vfmt-clean:

```sh
v fmt -verify main.v input.v syntax.v syntax_test.v
```

To fix drift: `v fmt -w main.v input.v syntax.v syntax_test.v` (sometimes a second pass on `input.v` is needed if the formatter stabilizes across files). CI builds **V from `vlang/v` master** each run; a different local `v` binary can disagree on layout—when in doubt, format with the same compiler revision as CI (clone `https://github.com/vlang/v.git`, `make`, then use `./v fmt`).

GitHub Actions runs this verify step on every push/PR (`ci.yml`) and before release builds (`release.yml`).

## CI expectations

- `v fmt -verify` on the four `.v` files above
- `v -gc none -check .`
- `v -gc none test .`
- `v -gc none -prod -o vro .`, then `./vro -version` and `--help`

## Docs and packaging

User-facing install docs prefer **Wax** (`wax tap` / `wax install`). **Homebrew** is documented as an alternative that consumes the same tap formula and release assets—keep wording aligned with `README.md` and `scripts/bench-cli.sh` (avoid implying Brew is the only way to get tools like hyperfine).

## Change discipline

Match existing naming and structure in `main.v` / `input.v` / `syntax.v`. Prefer small, focused diffs; do not reformat unrelated code.
