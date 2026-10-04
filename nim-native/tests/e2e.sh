#!/usr/bin/env bash
# End-to-end test: build and run the four Nim samples with this backend.
#
# Needs `pixi` on PATH and network access to conda-forge (and to the nimble
# package list for greet_deps). If XDG_CONFIG_HOME is set, it is passed to
# the builds so nimble can use a local package list from there.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
backend="${BACKEND:-$here/bin/pixi-build-nim}"

# Don't let an outer `pixi run` leak its workspace into the sample builds.
for var in $(env | grep -o '^PIXI_[A-Z_]*' || true); do unset "$var"; done
unset CONDA_PREFIX CONDA_DEFAULT_ENV
export PIXI_BUILD_BACKEND_OVERRIDE="pixi-build-nim=$backend"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -r "$here/../samples/nim/." "$tmp/"
if [ -n "${XDG_CONFIG_HOME:-}" ]; then
  for manifest in "$tmp"/*/pixi.toml; do
    printf '\n[package.build.config]\nenv = { XDG_CONFIG_HOME = "%s" }\n' "$XDG_CONFIG_HOME" >> "$manifest"
  done
fi

check() {
  local sample="$1" expected="$2"; shift 2
  echo "::group::$sample"
  local out
  out="$(cd "$tmp/$sample" && "$@" 2>&1)" || { echo "$out"; echo "FAIL: $sample"; exit 1; }
  echo "$out" | tail -n 5
  echo "::endgroup::"
  if ! grep -q -- "$expected" <<<"$out"; then
    echo "FAIL: $sample: expected output containing '$expected'"
    exit 1
  fi
  echo "ok: $sample"
}

check hello_nim "Hello from Nim" pixi run hello_nim
check greet_deps "Hello, pixi!" pixi run greet --name pixi
check mathlib "mathlib-0.1.0-h" pixi build
check usemath "double(21) = 42" pixi run usemath
echo "all samples passed"
