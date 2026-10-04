## `[package.build.config]` for the Nim backend.

import std/[json, strutils]

type
  ConfigError* = object of CatchableError

  NimBackendConfig* = object
    extraArgs*: seq[string]        ## Extra args passed to every `nim c` call.
    env*: seq[(string, string)]    ## Environment variables for the build script.
    extraInputGlobs*: seq[string]  ## Extra files that should trigger rebuilds.
    compilers*: seq[string]        ## Empty means the default (`c`, or `cxx` for cpp).
    hasCompilers*: bool
    nimbleFile*: string            ## Which `.nimble` file to read, "" to discover.
    ignoreNimbleFile*: bool
    hasIgnoreNimbleFile*: bool
    hasDebugDir*: bool             ## Deprecated `debug-dir`, accepted and ignored.

proc stringList(node: JsonNode, key: string): seq[string] =
  if node.kind != JArray:
    raise newException(ConfigError, "`" & key & "` must be a list of strings")
  for item in node:
    if item.kind != JString:
      raise newException(ConfigError, "`" & key & "` must be a list of strings")
    result.add item.getStr

proc parseConfig*(node: JsonNode): NimBackendConfig =
  if node.isNil or node.kind == JNull: return
  if node.kind != JObject:
    raise newException(ConfigError, "the build configuration must be a table")
  for key, value in node:
    case key
    of "extra-args": result.extraArgs = stringList(value, key)
    of "extra-input-globs": result.extraInputGlobs = stringList(value, key)
    of "compilers":
      result.compilers = stringList(value, key)
      result.hasCompilers = true
    of "env":
      if value.kind != JObject:
        raise newException(ConfigError, "`env` must be a table of strings")
      for k, v in value:
        if v.kind != JString:
          raise newException(ConfigError, "`env." & k & "` must be a string")
        result.env.add (k, v.getStr)
    of "nimble-file":
      if value.kind != JString:
        raise newException(ConfigError, "`nimble-file` must be a string")
      result.nimbleFile = value.getStr
    of "ignore-nimble-file":
      if value.kind != JBool:
        raise newException(ConfigError, "`ignore-nimble-file` must be a boolean")
      result.ignoreNimbleFile = value.getBool
      result.hasIgnoreNimbleFile = true
    of "debug-dir", "debug_dir": result.hasDebugDir = true
    else:
      raise newException(ConfigError, "unknown field `" & key &
        "`, expected one of `extra-args`, `env`, `debug-dir`, `extra-input-globs`, " &
        "`compilers`, `nimble-file`, `ignore-nimble-file`")

proc merge*(base, target: NimBackendConfig): NimBackendConfig =
  ## Target-specific values override base values:
  ## extra-args and extra-input-globs are replaced when non-empty, env is
  ## merged (target wins), the rest is replaced when set.
  if target.hasDebugDir:
    raise newException(ConfigError, "`debug-dir` cannot have a target specific value")
  result = base
  if target.extraArgs.len > 0: result.extraArgs = target.extraArgs
  if target.extraInputGlobs.len > 0: result.extraInputGlobs = target.extraInputGlobs
  for (k, v) in target.env:
    var replaced = false
    for e in result.env.mitems:
      if e[0] == k:
        e[1] = v
        replaced = true
    if not replaced: result.env.add (k, v)
  if target.hasCompilers:
    result.compilers = target.compilers
    result.hasCompilers = true
  if target.nimbleFile.len > 0: result.nimbleFile = target.nimbleFile
  if target.hasIgnoreNimbleFile:
    result.ignoreNimbleFile = target.ignoreNimbleFile
    result.hasIgnoreNimbleFile = true

proc selectorMatches*(selector, platform: string): bool =
  ## Whether a `[package.build.target.<selector>]` key applies to `platform`.
  case selector
  of "unix": not platform.startsWith("win")
  of "linux": platform.startsWith("linux")
  of "win": platform.startsWith("win")
  of "macos", "osx": platform.startsWith("osx")
  else: selector == platform

proc effectiveConfig*(base: NimBackendConfig, targets: seq[(string, NimBackendConfig)],
                      platform: string): NimBackendConfig =
  ## The first matching target config merged over the base, like the Rust backend.
  for (selector, cfg) in targets:
    if selectorMatches(selector, platform): return base.merge(cfg)
  base
