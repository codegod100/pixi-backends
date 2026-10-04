# pixi-build extra backends

Two extra [pixi-build](https://pixi.sh/latest/build/getting_started/) backends that let pixi build packages from a language's own manifest:

| Backend | Reads | Builds |
|---|---|---|
| [`pixi-build-nim`](backends/nim.md) | `<name>.nimble` | Nim command-line tools and libraries, with conda-forge's `nim` |
| [`pixi-build-flutter`](backends/flutter.md) | `pubspec.yaml` | Flutter apps (Linux, macOS, Windows, web) and Dart command-line tools |

Both are built on the `pixi_build_backend` crate from the [pixi repository](https://github.com/prefix-dev/pixi), pinned to commit `22c8af5`, and speak pixi-build API version 7 (pixi 0.81 and later).

!!! warning
    `pixi-build` is a preview feature of pixi and still changes between releases.
    Projects need to opt in:

    ```toml
    [workspace]
    preview = ["pixi-build"]
    ```

These backends are not published to a conda channel yet, so for now you [build them from source](getting-started.md) and point pixi at the binary.
