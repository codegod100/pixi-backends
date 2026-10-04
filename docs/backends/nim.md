# Nim

`pixi-build-nim` builds Nim packages. It reads the package's `.nimble` file and generates a rattler-build recipe that compiles with conda-forge's `nim` (2.2.6, which also ships `nimble`).

## Using it in a project

```toml
[package.build.backend]
name = "pixi-build-nim"
version = "*"
```

`[package] name/version` are optional; they fall back to the `.nimble` file.

### What gets read from `.nimble`

`packageName` (else the file name), `version`, `license`, `description` (becomes the summary), `srcDir`, `bin`, `backend` and `requires`. The file is NimScript, so only the usual declarative `key = "value"` / `requires "..."` forms are understood; `when` blocks and computed values are ignored.

### What the generated recipe does

- Build requirements: `${{ compiler('c') }}` (or `cxx` when `backend = "cpp"`), `nim` (pinned from `requires "nim >= x"` when it's a plain `>=`/`<`/`==` spec), and `git` if there are other nimble dependencies.
- Packages with `bin` entries: nimble dependencies are fetched with `nimble install --depsOnly` into a private nimble dir, then each binary is compiled with `nim c -d:release` straight into `$PREFIX/bin`. If there are no dependencies besides `nim`, nimble is never run, so no network is needed.
- Library-only packages (no `bin`): `nimble install` into `$PREFIX/share/nimble/pkgs2`.
- Binaries also search `$PREFIX/share/nimble/pkgs2`, so a Nim library packaged with this backend can be a `host-dependency` of a Nim CLI (see [`samples/nim/usemath`](../samples.md#nim)).

### Build config (`[package.build.config]`)

| Key | Meaning |
|---|---|
| `extra-args` | Extra flags appended to every `nim c` call |
| `env` | Environment variables for the build script |
| `compilers` | Override the compiler list (default `["c"]`) |
| `nimble-file` | Which `.nimble` file to use if there are several |
| `ignore-nimble-file` | Take metadata only from `pixi.toml` |
| `extra-input-globs` | Extra files that should trigger rebuilds |

!!! tip
    There is also a [native Nim implementation](nim-native.md) of this backend that doesn't need Rust.

## Samples

Four sample projects live in `samples/nim/`; see [Samples](../samples.md#nim).

## Limits

- Platforms follow conda-forge's `nim`: linux-64, linux-aarch64, osx-64. The backend gives a clear error on Windows; osx-arm64 has no `nim` package yet.
- Nimble dependencies are downloaded during the build, not mapped to conda packages, so `requires` entries that are also provided as conda host dependencies get downloaded anyway.
- `namedBin`, custom nimble tasks/hooks and the `js` backend aren't supported.
- The test sandbox couldn't reach `nim-lang.org`, so `greet_deps` and `mathlib` were tested with a local nimble package list. That was set through the `env` config and isn't part of the shipped samples.
