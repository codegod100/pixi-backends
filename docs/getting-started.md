# Getting started

## Build the backends

You need a Rust toolchain; `rust-toolchain` pins the version the pixi repository uses.

```sh
git clone https://github.com/codegod100/pixi-backends
cd pixi-backends
cargo build --release
```

This produces `target/release/pixi-build-nim` and `target/release/pixi-build-flutter`.

## Point pixi at them

Since the backends aren't on a conda channel, tell pixi to use your local binaries instead of installing them:

```sh
export PIXI_BUILD_BACKEND_OVERRIDE="pixi-build-nim=$PWD/target/release/pixi-build-nim,pixi-build-flutter=$PWD/target/release/pixi-build-flutter"
```

Then any project whose `pixi.toml` names one of them as its build backend uses it:

```toml
[workspace]
channels = ["https://prefix.dev/conda-forge"]
platforms = ["linux-64"]
preview = ["pixi-build"]

[package.build.backend]
name = "pixi-build-nim"   # or "pixi-build-flutter"
version = "*"

[dependencies]
my_package = { path = "." }
```

## Try a sample

```sh
cd samples/nim/hello_nim
pixi run hello_nim
# Hello from Nim 2.2.6 (hello_nim v0.1.0)
```

See [Samples](samples.md) for the full list.

## Run the tests

```sh
cargo test
```

Recipe generation is covered by [insta](https://insta.rs) snapshot tests in each crate's `src/snapshots/`.
