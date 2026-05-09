#!/usr/bin/env bash
# Print sha256 lines for Homebrew Formula after a tag is published (same assets as inauguration release.yml).
set -euo pipefail
repo="${VRO_GITHUB_REPO:-undivisible/vro}"
version="${1:?usage: $0 v0.1.0}"
for suffix in macos-aarch64 linux-x86_64; do
  url="https://github.com/${repo}/releases/download/${version}/vro-${suffix}.tar.gz"
  sum="$(curl -fsSL "$url" | shasum -a 256 | awk '{print $1}')"
  printf '%s  vro-%s.tar.gz\n' "$sum" "$suffix"
done
