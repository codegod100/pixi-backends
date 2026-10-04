## Turns the pixi project model plus the `.nimble` file into package
## outputs: metadata, dependencies, variant and the build script.
## This is the Nim equivalent of the Rust backend's `generate_recipe`.

import std/[algorithm, json, os, strutils]
import buildscript, config, hashing, nimble, selectors

type
  RecipeError* = object of CatchableError

  Project* = object
    ## Everything `initialize` handed us.
    manifestPath*: string
    sourceDir*: string       ## Package root: where `pixi.toml` and `.nimble` live.
    model*: JsonNode         ## The `ProjectModel`, as sent by pixi.
    config*: NimBackendConfig
    targetConfigs*: seq[(string, NimBackendConfig)]

  Variant* = seq[(string, JsonNode)]  ## Sorted by key.

  RunExports* = object
    weak*, strong*, noarch*, weakConstrains*, strongConstrains*: seq[JsonNode]

  PackageOutput* = object
    name*, version*, buildString*, subdir*: string
    buildNumber*: int
    variant*: Variant
    license*, summary*, description*: string
    homepage*, repository*, documentation*: string
    buildDeps*, hostDeps*, runDeps*, runConstraints*: seq[JsonNode]  ## NamedSpec JSON
    runExports*: RunExports
    extras*: seq[(string, seq[JsonNode])]
    script*: string
    scriptEnv*: seq[(string, string)]
    secrets*: seq[string]
    metadataInputGlobs*: seq[string]

const buildInputGlobs* = [
  "**/*.nim", "**/*.nims", "**/*.nimble", "**/nim.cfg", "**/*.nim.cfg",
  "nimble.lock", "**/*.{c,h,cpp,hpp}"]

proc manifestRoot*(manifestPath: string): string =
  if fileExists(manifestPath): manifestPath.parentDir else: manifestPath

proc getStrOrEmpty(node: JsonNode, key: string): string =
  if node.isNil or node.kind != JObject: return ""
  let v = node.getOrDefault(key)
  if v.isNil or v.kind != JString: "" else: v.getStr

proc defaultCompiler(platform, lang: string): string =
  let osx = platform.startsWith("osx")
  case lang
  of "c": (if osx: "clang" else: "gcc")
  of "cxx": (if osx: "clangxx" else: "gxx")
  of "fortran": "gfortran"
  of "cuda": "cuda-nvcc"
  else: lang

proc variantStr(v: JsonNode): string =
  case v.kind
  of JString: v.getStr
  of JInt: $v.getInt
  of JBool: $v.getBool
  else: $v

proc pythonJson(v: JsonNode): string =
  case v.kind
  of JString: escapeJson(v.getStr)
  else: $v

proc hashInput*(variant: Variant): string =
  ## The variant serialized like rattler-build's `hash_input.json`
  ## (sorted keys, Python-style separators).
  var parts: seq[string]
  for (k, v) in variant: parts.add escapeJson(k) & ": " & pythonJson(v)
  "{" & parts.join(", ") & "}"

proc buildString*(variant: Variant, buildNumber: int, prefix = ""): string =
  ## `{prefix}_h{sha1(hash_input)[:7]}_{build_number}`, as rattler-build does.
  let hash = "h" & sha1Hex(hashInput(variant))[0 ..< 7]
  (if prefix.len > 0: prefix & "_" else: "") & hash & "_" & $buildNumber

proc versionSpec(v: string): string =
  ## A bare variant version like `13` or `2.28` becomes `13.*` / `2.28.*`.
  if v.len > 0 and v.allCharsInSet(Digits + {'.'}): v & ".*" else: v

proc binarySpec*(name: string, version = ""): JsonNode =
  result = %*{"name": name, "binary": {}}
  if version.len > 0: result["binary"]["version"] = %version

proc pinBound(bound: JsonNode, version: string, upper: bool): string =
  ## Apply a `x.x` style pin expression (or a literal version) to `version`.
  if bound.isNil or bound.kind == JNull: return ""
  if bound.kind == JObject and bound.hasKey("version"): return bound["version"].getStr
  let expr = if bound.kind == JObject: bound.getStrOrEmpty("expression") else: bound.getStr
  let n = expr.count('x')
  var segs = version.split('.')
  if n <= 0: return ""
  if segs.len > n: segs.setLen(n)
  if not upper: return segs.join(".")
  while segs.len < n: segs.add "0"
  segs[^1] = $(parseInt(segs[^1]) + 1)
  segs.join(".") & ".0a0"

proc resolvePinSubpackage(name: string, pin: JsonNode, version, build: string): JsonNode =
  ## A `pin-subpackage` on the package itself, resolved to a binary spec.
  if pin{"exact"}.getBool(false):
    result = binarySpec(name, "==" & version)
    result["binary"]["build"] = %build
    return
  let lowerNode = if pin.hasKey("lowerBound"): pin["lowerBound"] else: %*{"expression": "x.x.x.x.x.x"}
  let upperNode = if pin.hasKey("upperBound"): pin["upperBound"] else: %*{"expression": "x"}
  var parts: seq[string]
  let lower = pinBound(lowerNode, version, false)
  let upper = pinBound(upperNode, version, true)
  if lower.len > 0: parts.add ">=" & lower
  if upper.len > 0: parts.add "<" & upper
  result = binarySpec(name, parts.join(","))

proc namedSpec(name: string, spec: JsonNode, own: (string, string, string),
               allowPins: bool, table: string): JsonNode =
  ## Model `PackageSpec` -> output `NamedSpec<PackageSpec>`. Specs are passed
  ## through as-is except `pin-subpackage` on the package itself.
  if spec.kind != JObject:
    raise newException(RecipeError, "invalid spec for `" & name & "` in " & table)
  if spec.hasKey("pinSubpackage") or spec.hasKey("pinCompatible"):
    if not allowPins:
      raise newException(RecipeError, "`" & name & "`: pin specs are not allowed in " & table)
    if spec.hasKey("pinSubpackage") and name == own[0]:
      return resolvePinSubpackage(name, spec["pinSubpackage"], own[1], own[2])
  result = copy(spec)
  result["name"] = %name

iterator pairsOrEmpty*(node: JsonNode): (string, JsonNode) =
  if not node.isNil and node.kind == JObject:
    for k, v in node: yield (k, v)

iterator elemsOrEmpty*(node: JsonNode): JsonNode =
  if not node.isNil and node.kind == JArray:
    for v in node: yield v

type ModelTarget = object
  build, host, run, constraints: seq[(string, JsonNode)]
  extras: seq[(string, seq[(string, JsonNode)])]
  runExports: seq[(string, seq[(string, JsonNode)])]

proc pairsOf(node: JsonNode): seq[(string, JsonNode)] =
  if node.isNil or node.kind != JObject: return
  for k, v in node: result.add (k, v)

proc addTarget(acc: var ModelTarget, t: JsonNode) =
  if t.isNil or t.kind != JObject: return
  acc.build.add pairsOf(t.getOrDefault("buildDependencies"))
  acc.host.add pairsOf(t.getOrDefault("hostDependencies"))
  acc.run.add pairsOf(t.getOrDefault("runDependencies"))
  acc.constraints.add pairsOf(t.getOrDefault("runConstraints"))
  for (group, deps) in pairsOf(t.getOrDefault("extraDependencies")):
    acc.extras.add (group, pairsOf(deps))
  for (bucket, deps) in pairsOf(t.getOrDefault("runExports")):
    acc.runExports.add (bucket, pairsOf(deps))

proc collectTargets(model: JsonNode, platform: string): ModelTarget =
  let targets = model.getOrDefault("targets")
  if targets.isNil or targets.kind != JObject: return
  result.addTarget(targets.getOrDefault("defaultTarget"))
  for expr, target in targets.getOrDefault("conditional").pairsOrEmpty:
    if evalCondition(expr, platform): result.addTarget(target)

proc variantCombos(variantConfig: seq[(string, seq[JsonNode])], keys: seq[string],
                   platform: string): seq[Variant] =
  ## Cartesian product of the used variant keys, each with `target_platform`.
  result = @[@[("target_platform", %platform)]]
  for key in keys:
    var values: seq[JsonNode]
    for (k, vs) in variantConfig:
      if k == key: values = vs
    if values.len == 0: continue
    var next: seq[Variant]
    for combo in result:
      for v in values:
        var c = combo
        c.add (key, v)
        next.add c
    result = next
  for combo in result.mitems:
    combo.sort(proc (a, b: (string, JsonNode)): int = cmp(a[0], b[0]))

proc lookup(variant: Variant, key: string): string =
  for (k, v) in variant:
    if k == key: return variantStr(v)
  ""

proc generateOutputs*(project: Project, platform: string,
                      variantConfig: seq[(string, seq[JsonNode])]): seq[PackageOutput] =
  if platform.startsWith("win"):
    raise newException(RecipeError, "pixi-build-nim does not support " & platform &
      ": conda-forge has no `nim` package for Windows")
  let cfg = effectiveConfig(project.config, project.targetConfigs, platform)
  let root = project.sourceDir
  let pkg = discoverNimble(root, cfg.nimbleFile)
  let useNimble = not cfg.ignoreNimbleFile
  let model = project.model

  var name = model.getStrOrEmpty("name")
  if name.len == 0 and useNimble: name = pkg.name.toLowerAscii
  if name.len == 0:
    raise newException(RecipeError, "no package name: set `[package] name` in the manifest")
  var version = model.getStrOrEmpty("version")
  if version.len == 0 and useNimble: version = pkg.version
  if version.len == 0:
    raise newException(RecipeError, "no package version: set `version` in the .nimble file or `[package] version` in the manifest")

  let backend = if pkg.backend.len > 0: pkg.backend else: "c"
  if backend == "js":
    raise newException(RecipeError, "the `js` nimble backend is not supported by pixi-build-nim")
  let compilers = if cfg.hasCompilers: cfg.compilers
                  else: @[if backend == "cpp": "cxx" else: "c"]

  # Variant keys this recipe uses, like rattler-build's `compiler()` and `stdlib()`.
  var usedKeys: seq[string]
  var hasStdlib = false
  for (k, _) in variantConfig:
    if k == "c_stdlib": hasStdlib = true
  for lang in compilers:
    usedKeys.add [lang & "_compiler", lang & "_compiler_version"]
  if hasStdlib and compilers.len > 0: usedKeys.add ["c_stdlib", "c_stdlib_version"]

  let buildNumber = if model.hasKey("buildNumber") and model["buildNumber"].kind == JInt:
                      model["buildNumber"].getInt else: 0
  let bsPrefix = model.getStrOrEmpty("buildStringPrefix")
  let targets = collectTargets(model, platform)

  let srcDir = if pkg.srcDir.len > 0: root / pkg.srcDir else: root
  var bins: seq[BinTarget]
  for (module, exe) in pkg.buildTargets: bins.add BinTarget(module: module, name: exe)
  let script = BuildScriptContext(
    sourceDir: root, srcDir: srcDir, backend: backend, bins: bins,
    isLibrary: bins.len == 0, hasNimbleDeps: pkg.hasNimbleDependencies,
    version: pkg.version, extraArgs: cfg.extraArgs).render

  var secrets: seq[string]
  for s in model.getOrDefault("secrets").elemsOrEmpty: secrets.add s.getStr

  var globs: seq[string]
  if useNimble and pkg.path.len > 0:
    globs.add relativePath(pkg.path, root).replace('\\', '/')

  for variant in variantCombos(variantConfig, usedKeys, platform):
    var o = PackageOutput(name: name, version: version, buildNumber: buildNumber,
                          subdir: platform, variant: variant, script: script,
                          scriptEnv: cfg.env, secrets: secrets, metadataInputGlobs: globs)
    o.buildString = buildString(variant, buildNumber, bsPrefix)
    o.license = model.getStrOrEmpty("license")
    if o.license.len == 0 and useNimble: o.license = pkg.license
    o.summary = model.getStrOrEmpty("description")
    if o.summary.len == 0 and useNimble: o.summary = pkg.description
    o.homepage = model.getStrOrEmpty("homepage")
    o.repository = model.getStrOrEmpty("repository")
    o.documentation = model.getStrOrEmpty("documentation")
    let own = (name, version, o.buildString)

    for (n, s) in targets.build: o.buildDeps.add namedSpec(n, s, own, false, "build-dependencies")
    for lang in compilers:
      let compiler = block:
        let v = variant.lookup(lang & "_compiler")
        if v.len > 0: v else: defaultCompiler(platform, lang)
      o.buildDeps.add binarySpec(compiler & "_" & platform,
                                 versionSpec(variant.lookup(lang & "_compiler_version")))
    if hasStdlib and compilers.len > 0:
      o.buildDeps.add binarySpec(variant.lookup("c_stdlib") & "_" & platform,
                                 versionSpec(variant.lookup("c_stdlib_version")))
    # nim ships nimble; honour `requires "nim >= x"` from the .nimble file.
    o.buildDeps.add binarySpec("nim", pkg.nimConstraint)
    # nimble shells out to git to fetch dependencies.
    if pkg.hasNimbleDependencies: o.buildDeps.add binarySpec("git")

    for (n, s) in targets.host: o.hostDeps.add namedSpec(n, s, own, true, "host-dependencies")
    for (n, s) in targets.run: o.runDeps.add namedSpec(n, s, own, true, "run-dependencies")
    for (n, s) in targets.constraints:
      if s.hasKey("source"):
        raise newException(RecipeError, "`" & n & "`: source specs can't be run constraints")
      o.runConstraints.add namedSpec(n, s, own, true, "run-constraints")
    for (group, deps) in targets.extras:
      var specs: seq[JsonNode]
      for (n, s) in deps: specs.add namedSpec(n, s, own, true, "extra dependencies")
      o.extras.add (group, specs)
    for (bucket, deps) in targets.runExports:
      for (n, s) in deps:
        let spec = namedSpec(n, s, own, true, "run-exports")
        case bucket
        of "weak": o.runExports.weak.add spec
        of "strong": o.runExports.strong.add spec
        of "noarch": o.runExports.noarch.add spec
        of "weakConstraints": o.runExports.weakConstrains.add spec
        of "strongConstraints": o.runExports.strongConstrains.add spec
        else: discard
    result.add o
