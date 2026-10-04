## The bash build script run inside the build environment. conda-forge
## only ships `nim` for unix platforms, so there is no Windows variant.

import std/strutils

type
  BinTarget* = object
    module*: string  ## Module path relative to `srcDir`, without `.nim`.
    name*: string    ## Name of the installed executable.

  BuildScriptContext* = object
    sourceDir*: string  ## The package root (where the `.nimble` file lives).
    srcDir*: string     ## Absolute directory containing the Nim sources.
    backend*: string    ## The nim command to compile with (`c`, `cpp`, `objc`).
    bins*: seq[BinTarget]
    isLibrary*: bool
    hasNimbleDeps*: bool
    version*: string    ## Empty when unknown.
    extraArgs*: seq[string]

proc render*(ctx: BuildScriptContext): string =
  var lines = @[
    "nim --version",
    "nimble --version",
    "",
    "export NIMBLE_DIR=\"$SRC_DIR/nimble\"",
    "mkdir -p \"$NIMBLE_DIR\"",
  ]
  if ctx.isLibrary:
    lines.add [
      "",
      "# No `bin` entries: install the package sources (and its nimble dependencies)",
      "# into a nimble directory inside the prefix.",
      "pushd \"" & ctx.sourceDir & "\"",
      "nimble install -y --useSystemNim --nimbleDir:\"$PREFIX/share/nimble\"",
      "popd",
      "# Drop nimble's global bookkeeping so several Nim library packages can be",
      "# installed into the same environment without file clashes.",
      "rm -f \"$PREFIX/share/nimble/\"*.json",
    ]
  else:
    if ctx.hasNimbleDeps:
      lines.add [
        "",
        "# Fetch nimble dependencies into a private nimble dir.",
        "pushd \"" & ctx.sourceDir & "\"",
        "nimble install --depsOnly -y --useSystemNim --nimbleDir:\"$NIMBLE_DIR\"",
        "popd",
      ]
    lines.add ["", "mkdir -p \"$PREFIX/bin\""]
    for bin in ctx.bins:
      var cmd = @[
        "nim " & ctx.backend & " \\",
        "    -d:release \\",
        "    --hints:off \\",
        "    --nimblePath:\"$NIMBLE_DIR/pkgs2\" \\",
        "    --nimblePath:\"$NIMBLE_DIR/pkgs\" \\",
        "    --nimblePath:\"$PREFIX/share/nimble/pkgs2\" \\",
        "    --nimcache:\"$SRC_DIR/nimcache/" & bin.name & "\" \\",
      ]
      if ctx.version.len > 0:
        cmd.add "    -d:NimblePkgVersion=" & ctx.version & " \\"
      cmd.add "    --passL:\"$LDFLAGS\" \\"
      cmd.add "    --out:\"$PREFIX/bin/" & bin.name & "\" \\"
      for arg in ctx.extraArgs:
        cmd.add "    " & arg & " \\"
      cmd.add "    \"" & ctx.srcDir & "/" & bin.module & ".nim\""
      lines.add ""
      lines.add cmd
  lines.join("\n").strip
