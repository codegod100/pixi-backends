# pixi-build extra backends

[pixi-build](https://pixi.sh/latest/build/getting_started/) backends for languages pixi doesn't cover yet:

- **`pixi-build-nim`**: builds Nim packages from their `.nimble` file.
- **`pixi-build-flutter`**: builds Flutter apps and Dart packages from `pubspec.yaml`.

Documentation: https://codegod100.github.io/pixi-backends/

## Quick start

```sh
cargo build --release
export PIXI_BUILD_BACKEND_OVERRIDE="pixi-build-nim=$PWD/target/release/pixi-build-nim,pixi-build-flutter=$PWD/target/release/pixi-build-flutter"
cd samples/nim/hello_nim && pixi run hello_nim
```

## Layout

| Path | What it is |
|---|---|
| `crates/pixi_build_nim` | The Nim backend |
| `crates/pixi_build_flutter` | The Flutter and Dart backend |
| `samples/` | Example projects for both backends |
| `docs/` | The MkDocs site (`pip install -r requirements-docs.txt && mkdocs serve`) |

Both crates depend on `pixi_build_backend` from [prefix-dev/pixi](https://github.com/prefix-dev/pixi) at commit `22c8af5`; `Cargo.lock` is taken from that commit so dependency versions match.

## License

BSD-3-Clause, like pixi. See `LICENSE`.
