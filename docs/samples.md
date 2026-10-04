# Samples

Every sample is a small pixi project under `samples/`. With [`PIXI_BUILD_BACKEND_OVERRIDE`](getting-started.md#point-pixi-at-them) set, `cd` into one and run `pixi run <name>` (or `pixi build` for libraries).

The samples use `https://conda.anaconda.org/conda-forge` as their channel; `https://prefix.dev/conda-forge` works the same.

## Nim

| Sample | Shows |
|---|---|
| `nim/hello_nim` | Plain CLI, no dependencies |
| `nim/greet_deps` | CLI using `cligen` fetched by nimble |
| `nim/mathlib` | Library-only package, built with `pixi build` |
| `nim/usemath` | CLI that imports `mathlib` through a conda host dependency |

All four were built and run on linux-64.

## Flutter and Dart

| Sample | Shows |
|---|---|
| `flutter/hello_cli` | Pure Dart CLI compiled with `dart compile exe` |
| `flutter/hello_flutter` | Flutter desktop app for the build machine's platform |
| `flutter/hello_web` | Flutter app built for the web (`target = "web"`) |

On linux-64 the Dart CLI builds and runs, and the Linux and web Flutter builds install with all libraries resolved. macOS and Windows builds have not been tested yet.
