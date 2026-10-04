# Nim (native)

`nim-native/` is a second implementation of `pixi-build-nim`, written in Nim instead of Rust. It behaves the same as the [Rust backend](nim.md) (same `.nimble` handling, build script, config keys and samples) but does not use prefix.dev's `pixi_build_backend` crate or rattler-build. Instead it implements the pieces itself:

- **The backend protocol.** pixi starts the backend and talks JSON-RPC 2.0 to it over stdin/stdout, one message per line. The backend answers `negotiateCapabilities`, `initialize`, `conda/outputs` and `conda/build_v1` as defined by **pixi-build API version 7** (pixi 0.81).
- **Recipe generation.** Dependencies from `pixi.toml` are passed through to pixi as-is, including source dependencies and `if(...)` conditional targets. Compiler and `c_stdlib` variants work like rattler-build's `compiler()` and `stdlib()`, and the build string is computed the same way, so both backends give a package the same build string.
- **Packaging.** pixi prepares the build and host prefixes; the backend runs the build script with the prefixes activated, collects the new files in the host prefix, rewrites ELF `RPATH`s that point into the host prefix to `$ORIGIN`-relative paths, records any remaining prefix references as placeholders, and writes the `.conda` file (zip, tar and zstd writers included).

It only depends on the Nim standard library. At runtime it loads `libzstd` to compress packages; without it, it still writes valid but uncompressed `.conda` files.

## Building and using it

```sh
cd nim-native
pixi run build          # bin/pixi-build-nim
pixi run test           # unit tests
pixi run e2e            # builds and runs the four samples with bin/pixi-build-nim

export PIXI_BUILD_BACKEND_OVERRIDE="pixi-build-nim=$PWD/bin/pixi-build-nim"
cd ../samples/nim/hello_nim && pixi run hello_nim
```

## Building it with pixi

`nim-native/pixi.toml` is also the backend's own package definition, and it uses `pixi-build-nim` as its build backend, so the backend builds itself:

```sh
cd nim-native
pixi run build
PIXI_BUILD_BACKEND_OVERRIDE="pixi-build-nim=$PWD/bin/pixi-build-nim" pixi build
# pixi-build-nim-0.2.0-<hash>_0.conda
```

The package installs `bin/pixi-build-nim` and depends on `pixi-build-api-version >=7,<8` and `zstd`, so a channel holding it can serve it as a regular pixi build backend.

## Differences from the Rust backend

- `namedBin["module"] = "exe-name"` entries in `.nimble` files are supported.
- Rebuilds remove the files the previous build installed into the reused host prefix before building again.
- `pin-subpackage` specs on the package itself are resolved by the backend. `pin-compatible` specs are passed through to pixi.
- Variant files (`variant-files` / `[workspace.build-variants-files]`) are ignored with a warning; inline `build-variants` work.
- Only `.conda` packages are written, even if pixi asks for `.tar.bz2`.

The Rust crate stays in `crates/pixi_build_nim` for now.
