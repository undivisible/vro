#!/usr/bin/env bash
# Compare cold CLI startup: vro -version vs micro -version (needs hyperfine: wax install hyperfine, a distro package, or https://github.com/sharkdp/hyperfine#installation).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
vro="${VRO:-${root}/vro}"
if [[ ! -x "$vro" ]]; then
	echo "build vro first: (cd \"$root\" && v -gc none -prod -o vro .)" >&2
	exit 1
fi
if ! command -v hyperfine >/dev/null 2>&1; then
	echo "install hyperfine to run this benchmark (e.g. wax install hyperfine, or see https://github.com/sharkdp/hyperfine#installation)" >&2
	exit 1
fi
hyperfine --warmup 5 --min-runs 50 'micro -version' "\"$vro\" -version"
