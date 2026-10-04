# Flutter and Dart

The `pixi-build-flutter` backend builds Flutter apps and pure Dart packages. It reads `pubspec.yaml` for package metadata, builds Flutter apps with the official Flutter SDK, and compiles Dart command-line tools with `dart-sdk` from conda-forge.

!!! warning
    `pixi-build` is a preview flag, and will change until it is stabilized.
    This is why we require users to opt in to that feature by adding "pixi-build" to `workspace.preview`.

    ```toml
    [workspace]
    preview = ["pixi-build"]
    ```

## Overview

The backend looks at `pubspec.yaml` and picks one of two modes:

- **Flutter apps** (the pubspec depends on `flutter: {sdk: flutter}`): runs `flutter build <target> --release` and installs the result. Flutter is not packaged on conda-forge, so the build downloads the official SDK archive once, checks its sha256 and keeps it in pixi's cache for later builds.
- **Dart packages** (no Flutter dependency): adds `dart-sdk` from conda-forge, constrained by `environment.sdk`, and compiles every entry of `executables:` (or every script in `bin/` when there is none) with `dart compile exe`. A package without executables installs its `lib/` to `share/dart/packages/<name>`.

Metadata the manifest leaves out (name, version, description, homepage, repository, documentation, license files) comes from `pubspec.yaml`. Pub versions are converted to conda versions: `1.0.0+1` stays as is and `1.0.0-dev.1` becomes `1.0.0_dev.1`.

The build always runs in a copy of the project, so `flutter create`, `pub get` and the `build/` output never touch your checkout.

## Basic Usage

```toml
[workspace]
channels = ["https://prefix.dev/conda-forge"]
platforms = ["linux-64"]
preview = ["pixi-build"]

[package.build.backend]
name = "pixi-build-flutter"
version = "*"

[dependencies]
my_app = { path = "." }
```

`name` and `version` can be left out of `[package]`; they are taken from `pubspec.yaml`.

### What gets installed

| Target | Installed files |
| --- | --- |
| `linux` | The app bundle in `lib/<name>/`, with its executable linked into `bin/` |
| `macos` | The `.app` bundle in `lib/<name>/`, with a launcher script in `bin/<name>` |
| `windows` | The app in `Library\lib\<name>\`, with a `.bat` launcher in `Library\bin\` |
| `web` | The compiled site in `share/<name>/web/` |
| Dart executables | Native binaries in `bin/` (`Library\bin\` on Windows) |

When a project has no runner folder for the target (for example no `linux/` directory), the backend runs `flutter create --platforms=<target>` in the build copy first.

### Required Dependencies

For Flutter apps the backend adds `git` and `cmake` to the build requirements, and `curl` when it downloads the SDK. The Linux desktop target also adds `ninja`, `pkg-config`, `clang`, `clangxx`, `lld`, `patchelf` and `sysroot_linux-64`, and builds against `gtk3` and `glib` from the host environment, with `gtk3` as a run dependency.

For Dart packages the backend adds `dart-sdk` to the build requirements.

## Configuration Options

### `target`

- **Type**: `String` (`linux`, `macos`, `windows` or `web`)
- **Default**: the desktop platform of the build machine
- **Target Merge Behavior**: `Overwrite`

What to build a Flutter app for. Building for the web works on every platform:

```toml
[package.build.config]
target = "web"
```

### `flutter-version`

- **Type**: `String`
- **Default**: the Flutter release the backend ships checksums for (3.47.6)
- **Target Merge Behavior**: `Overwrite`

The stable Flutter release to download. Any other release than the default also needs `flutter-sha256`, which is listed next to each archive in `https://storage.googleapis.com/flutter_infra_release/releases/releases_<os>.json`.

```toml
[package.build.config]
flutter-version = "3.35.0"
flutter-sha256 = "<sha256 of flutter_linux_3.35.0-stable.tar.xz>"
```

### `flutter-sha256`

- **Type**: `String`
- **Default**: Not set
- **Target Merge Behavior**: `Overwrite`

The sha256 of the SDK archive, for releases or URLs the backend has no checksum for. Since archives differ per platform, set it per target:

```toml
[package.build.target.linux-64.config]
flutter-sha256 = "..."
```

### `flutter-sdk-url`

- **Type**: `String`
- **Default**: Not set
- **Target Merge Behavior**: `Overwrite`

Download the SDK from this URL instead, for example from a mirror. Requires `flutter-sha256`.

### `flutter-sdk-path`

- **Type**: `String`
- **Default**: Not set
- **Target Merge Behavior**: `Overwrite`

Use a Flutter SDK that is already on this machine instead of downloading one. This is also the way to build on platforms Google publishes no SDK archive for, such as `linux-aarch64`.

### `extra-args`

- **Type**: `Array<String>`
- **Default**: `[]`
- **Target Merge Behavior**: `Overwrite`

Extra arguments for `flutter build <target>`, or for `dart compile exe` in Dart packages.

```toml
[package.build.config]
extra-args = ["--dart-define=API_URL=https://example.com", "--obfuscate", "--split-debug-info=debug-info"]
```

### `env`

- **Type**: `Map<String, String>`
- **Default**: `{}`
- **Target Merge Behavior**: `Merge`

Environment variables for the build. The build keeps its own pub cache in the work directory unless `PUB_CACHE` is set here.

### `extra-input-globs`

- **Type**: `Array<String>`
- **Default**: `[]`
- **Target Merge Behavior**: `Overwrite`

Files that should trigger a rebuild in addition to the defaults: `pubspec.yaml`, `pubspec.lock`, `**/*.dart`, `assets/**` and the `linux/`, `macos/`, `windows/` and `web/` runner folders.

## Limitations

- The backend does not cross-compile: it builds for the platform it runs on.
- Building macOS and Windows desktop apps needs the same system toolchains as Flutter itself (Xcode, Visual Studio).
- Flutter does not publish SDK archives for Linux on ARM; use `flutter-sdk-path` there.
- Builds need network access for the SDK download and for `pub get`.
