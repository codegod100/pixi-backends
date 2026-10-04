## `conda/build_v1`: run the build script against the prefixes pixi has
## prepared, collect what it installed and package it as a `.conda` file.
## This replaces the part of rattler-build the Rust backends link in.

import std/[algorithm, json, os, osproc, sets, streams, strutils, tables, times]
import archive, elf, hashing, matchspec, recipe, selectors

type BuildError* = object of CatchableError

type BuildResult* = object
  outputFile*: string
  name*, version*, build*, subdir*: string

proc log(msg: string) =
  stderr.writeLine msg
  stderr.flushFile

proc shellQuote(s: string): string =
  if s.len > 0 and s.allCharsInSet(Letters + Digits + {'/', '.', '_', '-', '+', ':', ',', '='}):
    s
  else:
    "'" & s.replace("'", "'\\''") & "'"

proc snapshot(prefix: string): Table[string, Time] =
  ## Every file and symlink in `prefix` (relative, `/`-separated) with its mtime.
  if not dirExists(prefix): return
  for path in walkDirRec(prefix, yieldFilter = {pcFile, pcLinkToFile, pcLinkToDir},
                         followFilter = {pcDir}, relative = true):
    let info = getFileInfo(prefix / path, followSymlink = false)
    result[path.replace('\\', '/')] = info.lastWriteTime

proc ownedFiles(prefix: string): HashSet[string] =
  ## Files that belong to packages installed in `prefix` (from conda-meta).
  for kind, p in walkDir(prefix / "conda-meta"):
    if not p.endsWith(".json"): continue
    try:
      for f in parseFile(p){"files"}.elemsOrEmpty: result.incl f.getStr
    except CatchableError:
      discard

proc buildEnvScript(vars: seq[(string, string)], hostPrefix, buildPrefix: string): string =
  var lines: seq[string]
  for (k, v) in vars: lines.add "export " & k & "=" & shellQuote(v)
  # Activate the host prefix, then the build prefix (so build tools win),
  # sourcing their activation scripts like `conda activate` would.
  for prefix in [hostPrefix, buildPrefix]:
    lines.add ""
    lines.add "export PATH=" & shellQuote(prefix / "bin") & ":\"${PATH}\""
    lines.add "export CONDA_SHLVL=1"
    lines.add "export CONDA_PREFIX=" & shellQuote(prefix)
    let activateDir = prefix / "etc" / "conda" / "activate.d"
    if dirExists(activateDir):
      var scripts: seq[string]
      for kind, p in walkDir(activateDir):
        if p.endsWith(".sh"): scripts.add p
      scripts.sort()
      for s in scripts: lines.add ". " & shellQuote(s)
  lines.join("\n") & "\n"

proc runScript(scriptPath, workDir, logPath: string) =
  ## Secrets reach the script through the inherited environment only, so
  ## they are never written to `build_env.sh`.
  let p = startProcess("bash", args = [scriptPath], workingDir = workDir,
                       env = nil, options = {poStdErrToStdOut, poUsePath})
  let logFile = open(logPath, fmWrite)
  defer: logFile.close()
  let output = p.outputStream
  var line = ""
  while output.readLine(line):
    log line
    logFile.writeLine line
  let code = p.waitForExit()
  p.close()
  if code != 0:
    raise newException(BuildError, "Script failed to execute (exit code " & $code &
      "). To run it manually: cd " & shellQuote(workDir) & " && ./conda_build.sh")

proc compressionLevel(format: JsonNode): int =
  let level = format{"compressionLevel"}
  if level.isNil: return 15
  case level.kind
  of JString:
    case level.getStr
    of "lowest": 1
    of "highest": 19
    else: 15
  of JInt: clamp(level.getInt, -7, 22)
  else: 15

proc specList(node: JsonNode): seq[string] =
  if node.isNil or node.kind != JArray: return
  for dep in node:
    let s = matchSpecString(dep{"spec"})
    if s notin result: result.add s

proc writeJson(node: JsonNode): string = node.pretty(2) & "\n"

proc findOutput(outputs: seq[PackageOutput], wanted: JsonNode): PackageOutput =
  let name = wanted{"name"}.getStr
  var candidates: seq[PackageOutput]
  for o in outputs:
    if o.name == name: candidates.add o
  if candidates.len == 0:
    raise newException(BuildError, "there is no output defined for the package '" & name & "'")
  let wantedVariant = wanted{"variant"}
  for o in candidates:
    var all = true
    if not wantedVariant.isNil and wantedVariant.kind == JObject:
      for k, v in wantedVariant:
        var found = false
        for (ok, ov) in o.variant:
          if ok == k and ov == v: found = true
        if not found: all = false
    if all: return o
  let build = wanted{"build"}.getStr
  for o in candidates:
    if build.len == 0 or o.buildString == build: return o
  raise newException(BuildError, "the requested output " & name & " was not found in the recipe")

proc condaBuildV1*(project: Project, params: JsonNode): BuildResult =
  let hostPrefixNode = params{"hostPrefix"}
  let buildPrefixNode = params{"buildPrefix"}
  let workDir = params{"workDirectory"}.getStr
  let platform = block:
    var p = ""
    if not hostPrefixNode.isNil and hostPrefixNode.kind == JObject: p = hostPrefixNode{"platform"}.getStr
    if p.len == 0: p = params{"output"}{"subdir"}.getStr
    p
  let buildPlatform = if not buildPrefixNode.isNil and buildPrefixNode.kind == JObject:
                        buildPrefixNode{"platform"}.getStr else: platform

  # The single variant pixi asks for.
  var variantConfig: seq[(string, seq[JsonNode])]
  for k, v in params{"output"}{"variant"}.pairsOrEmpty:
    if k != "target_platform": variantConfig.add (k, @[v])
  let output = findOutput(generateOutputs(project, platform, variantConfig), params{"output"})

  let hostPrefix = if not hostPrefixNode.isNil and hostPrefixNode.kind == JObject:
                     hostPrefixNode{"prefix"}.getStr else: workDir / "host"
  let buildPrefix = if not buildPrefixNode.isNil and buildPrefixNode.kind == JObject:
                      buildPrefixNode{"prefix"}.getStr else: workDir / "build"
  let srcDir = workDir / "work"
  let outDirParam = params{"outputDirectory"}
  let outputDir = (if outDirParam.isNil or outDirParam.kind != JString: workDir / "output"
                   else: outDirParam.getStr) / output.subdir
  for d in [hostPrefix, buildPrefix, srcDir, outputDir]: createDir(d)

  # pixi keeps the host prefix between builds, so files the previous build
  # installed are still there and would look pre-existing. Remove them first
  # (unless a package installed in the prefix owns them now).
  let manifest = workDir / "pixi-build-nim-files.txt"
  if fileExists(manifest):
    let owned = ownedFiles(hostPrefix)
    for rel in readFile(manifest).splitLines:
      if rel.len > 0 and rel notin owned:
        let full = hostPrefix / rel
        if symlinkExists(full) or fileExists(full): removeFile(full)
  let before = snapshot(hostPrefix)
  let epoch = getTime().toUnix
  let stem = output.name & "-" & output.version & "-" & output.buildString
  let hash = output.buildString.split('_')[^2]

  var vars = @[
    ("PREFIX", hostPrefix), ("BUILD_PREFIX", buildPrefix), ("SRC_DIR", srcDir),
    ("RECIPE_DIR", project.sourceDir), ("BUILD_DIR", workDir), ("HOME", srcDir),
    ("PKG_NAME", output.name), ("PKG_VERSION", output.version),
    ("PKG_BUILDNUM", $output.buildNumber), ("PKG_BUILD_STRING", output.buildString),
    ("PKG_HASH", hash), ("SOURCE_DATE_EPOCH", $epoch),
    ("target_platform", platform), ("host_platform", platform),
    ("build_platform", buildPlatform), ("SUBDIR", platform),
    ("ARCH", if archOf(platform) in ["x86_64", "aarch64", "arm64", "ppc64le"]: "64" else: "32"),
    ("CPU_COUNT", $countProcessors()),
    ("SHLIB_EXT", if platform.startsWith("osx"): ".dylib" else: ".so"),
    ("PKG_CONFIG_PATH", hostPrefix / "lib" / "pkgconfig"),
    ("CONDA_BUILD", "1"), ("CONDA_BUILD_STATE", "BUILD"),
    ("CONDA_BUILD_CROSS_COMPILATION", if platform == buildPlatform: "0" else: "1"),
    ("CONDA_DEFAULT_ENV", hostPrefix), ("LANG", "C.UTF-8"), ("LC_ALL", "C.UTF-8"),
  ]
  if platform.startsWith("linux"): vars.add ("LD_RUN_PATH", hostPrefix / "lib")
  for (k, v) in output.variant:
    if k != "target_platform":
      vars.add (k, if v.kind == JString: v.getStr else: $v)
  for (k, v) in output.scriptEnv: vars.add (k, v)

  writeFile(srcDir / "build_env.sh", buildEnvScript(vars, hostPrefix, buildPrefix))
  let scriptPath = srcDir / "conda_build.sh"
  writeFile(scriptPath, "#!/usr/bin/env bash\nset -e\n" &
    "if [ -z ${CONDA_BUILD+x} ]; then\n    source " & shellQuote(srcDir / "build_env.sh") & "\nfi\n" &
    "set -x\n\n(\n" & output.script & "\n)\n")
  setFilePermissions(scriptPath, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpOthersRead})

  log "Building " & stem & " with pixi-build-nim (native)"
  runScript(scriptPath, srcDir, srcDir / "conda_build.log")

  # Package what the script added to the host prefix.
  var added: seq[string]
  # New files, plus files that were already there but got rewritten (left
  # over from a build that predates the manifest above).
  for p, mtime in snapshot(hostPrefix):
    if p.startsWith("conda-meta/"): continue
    if p notin before or before[p] != mtime: added.add p
  added.sort()
  writeFile(manifest, added.join("\n") & "\n")
  if added.len == 0:
    log "warning: the build script did not install any files into $PREFIX"

  var pkgEntries: seq[TarEntry]
  var paths = newJArray()
  for rel in added:
    let full = hostPrefix / rel
    let info = getFileInfo(full, followSymlink = false)
    if info.kind in {pcLinkToFile, pcLinkToDir}:
      pkgEntries.add TarEntry(path: rel, kind: tekSymlink, mode: 0o777,
                              linkTarget: expandSymlink(full))
      paths.add %*{"_path": rel, "path_type": "softlink"}
      continue
    var data = readFile(full)
    if platform.startsWith("linux") and data.isElf:
      if relocateElf(data, full, hostPrefix, buildPrefix):
        if fpUserWrite notin info.permissions:
          setFilePermissions(full, info.permissions + {fpUserWrite})
        writeFile(full, data)
    var mode = 0o644
    if fpUserExec in info.permissions: mode = 0o755
    let entry = %*{"_path": rel, "path_type": "hardlink"}
    if hostPrefix.len > 0 and data.contains(hostPrefix):
      entry["file_mode"] = %(if data.contains('\0'): "binary" else: "text")
      entry["prefix_placeholder"] = %hostPrefix
    entry["sha256"] = %sha256Hex(data)
    entry["size_in_bytes"] = %data.len
    paths.add entry
    pkgEntries.add TarEntry(path: rel, kind: tekFile, mode: mode, data: data)

  # info/
  let depends = specList(params{"runDependencies"})
  let constrains = specList(params{"runConstraints"})
  let (arch, plat) = (archOf(platform), platformFamily(platform))
  let index = newJObject()
  index["arch"] = (if arch.len > 0: %arch else: newJNull())
  index["build"] = %output.buildString
  index["build_number"] = %output.buildNumber
  if constrains.len > 0: index["constrains"] = %constrains
  index["depends"] = %depends
  var extras = newJObject()
  for group, deps in params{"extraDependencies"}.pairsOrEmpty:
    extras[group] = %specList(deps)
  if extras.len > 0: index["extra_depends"] = extras
  if output.license.len > 0: index["license"] = %output.license
  index["name"] = %output.name
  index["platform"] = %plat
  index["subdir"] = %output.subdir
  index["timestamp"] = %(epoch * 1000)
  index["version"] = %output.version

  let about = newJObject()
  if output.homepage.len > 0: about["home"] = %output.homepage
  if output.repository.len > 0: about["dev_url"] = %output.repository
  if output.documentation.len > 0: about["doc_url"] = %output.documentation
  if output.license.len > 0: about["license"] = %output.license
  if output.summary.len > 0: about["summary"] = %output.summary

  var infoEntries = @[
    TarEntry(path: "info/about.json", mode: 0o644, data: writeJson(about)),
    TarEntry(path: "info/hash_input.json", mode: 0o644, data: hashInput(output.variant)),
    TarEntry(path: "info/index.json", mode: 0o644, data: writeJson(index)),
    TarEntry(path: "info/paths.json", mode: 0o644,
             data: writeJson(%*{"paths": paths, "paths_version": 1})),
  ]
  let runExports = newJObject()
  for key in ["weak", "strong", "noarch", "weakConstrains", "strongConstrains"]:
    let specs = specList(params{"runExports"}{key})
    if specs.len > 0:
      let outKey = case key
        of "weakConstrains": "weak_constrains"
        of "strongConstrains": "strong_constrains"
        else: key
      runExports[outKey] = %specs
  if runExports.len > 0:
    infoEntries.add TarEntry(path: "info/run_exports.json", mode: 0o644, data: writeJson(runExports))
  let licenseFile = project.model{"licenseFile"}
  if not licenseFile.isNil and licenseFile.kind == JString:
    let lic = project.sourceDir / licenseFile.getStr
    if fileExists(lic):
      infoEntries.add TarEntry(path: "info/licenses/" & lic.extractFilename,
                               mode: 0o644, data: readFile(lic))
    else:
      log "warning: license file " & lic & " not found"
  infoEntries.sort(proc (a, b: TarEntry): int = cmp(a.path, b.path))

  let format = params{"packageFormat"}
  if not format.isNil and format{"archiveType"}.getStr("conda") != "conda":
    log "note: pixi-build-nim always writes .conda packages"
  if not zstdAvailable():
    log "note: libzstd not found, writing an uncompressed .conda"
  let outputFile = outputDir / stem & ".conda"
  writeFile(outputFile, writeConda(stem, infoEntries, pkgEntries, epoch,
                                   compressionLevel(format)))
  log "Wrote " & outputFile
  BuildResult(outputFile: outputFile, name: output.name, version: output.version,
              build: output.buildString, subdir: output.subdir)
