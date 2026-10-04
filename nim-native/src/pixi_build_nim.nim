## pixi-build-nim: a pixi build backend for Nim packages, written in Nim.
##
## pixi starts the backend and talks JSON-RPC 2.0 to it over stdin/stdout,
## one message per line. The methods are those of pixi-build API version 7:
## `negotiateCapabilities`, `initialize`, `conda/outputs` and `conda/build_v1`.
## Everything the backend wants to show the user goes to stderr.

import std/[json, os, strutils]
import pixi_build_nim/[builder, config, recipe]

const
  backendName* = "pixi-build-nim"
  backendVersion* = "0.2.0"
  apiVersion* = 7

type
  RpcError = object of CatchableError
    code: int

  Server = object
    project: Project
    initialized: bool
    pendingModel: JsonNode  ## Logged with the first request that has a work dir.

proc rpcError(code: int, msg: string): ref RpcError =
  result = newException(RpcError, msg)
  result.code = code

proc errorObject(code: int, msg: string): JsonNode =
  ## Shaped like the miette JSON reports the Rust backends send, which pixi
  ## renders as a diagnostic.
  %*{"code": code, "message": msg,
     "data": {"message": msg, "severity": "error", "causes": [], "labels": [], "related": []}}

proc writeDebug(workDir, file: string, value: JsonNode) =
  ## Same debug files as the Rust backends, under `<work dir>/debug`.
  if workDir.len == 0: return
  try:
    createDir(workDir / "debug")
    writeFile(workDir / "debug" / file, value.pretty(2))
  except CatchableError:
    discard

proc capabilities(): JsonNode =
  %*{"capabilities": {"providesCondaOutputs": true, "providesCondaBuildV1": true}}

proc initialize(s: var Server, params: JsonNode): JsonNode =
  if s.initialized: raise rpcError(-32600, "the backend is already initialized")
  let model = params{"projectModel"}
  if model.isNil or model.kind != JObject:
    raise rpcError(-32000, "project model is required")
  let manifestPath = params{"manifestPath"}.getStr
  if manifestPath.len == 0: raise rpcError(-32602, "missing `manifestPath`")
  let sourceDirNode = params{"sourceDirectory"}
  let sourceDir = if not sourceDirNode.isNil and sourceDirNode.kind == JString:
                    sourceDirNode.getStr else: manifestRoot(manifestPath)
  var targets: seq[(string, NimBackendConfig)]
  for selector, cfg in params{"targetConfiguration"}.pairsOrEmpty:
    targets.add (selector, parseConfig(cfg))
  s.project = Project(manifestPath: manifestPath, sourceDir: sourceDir, model: model,
                      config: parseConfig(params{"configuration"}), targetConfigs: targets)
  s.initialized = true
  s.pendingModel = model
  newJObject()

proc depsJson(specs: seq[JsonNode]): JsonNode =
  %*{"depends": specs, "constraints": []}

proc condaOutputs(s: var Server, params: JsonNode): JsonNode =
  let platform = params{"hostPlatform"}.getStr
  var variantConfig: seq[(string, seq[JsonNode])]
  for key, values in params{"variantConfiguration"}.pairsOrEmpty:
    var vs: seq[JsonNode]
    for v in values.elemsOrEmpty: vs.add v
    variantConfig.add (key, vs)
  for f in params{"variantFiles"}.elemsOrEmpty:
    stderr.writeLine "warning: pixi-build-nim ignores variant file " & f.getStr
  let outputs = generateOutputs(s.project, platform, variantConfig)
  var list = newJArray()
  var globs: seq[string]
  for o in outputs:
    globs = o.metadataInputGlobs
    var variant = newJObject()
    for (k, v) in o.variant: variant[k] = v
    var extras = newJObject()
    for (group, specs) in o.extras: extras[group] = %specs
    let item = %*{
      "metadata": {
        "name": o.name, "version": o.version, "build": o.buildString,
        "buildNumber": o.buildNumber, "subdir": o.subdir,
        "license": (if o.license.len > 0: %o.license else: newJNull()),
        "licenseFamily": nil, "noarch": false, "purls": nil,
        "pythonSitePackagesPath": nil, "variant": variant},
      "buildDependencies": depsJson(o.buildDeps),
      "hostDependencies": depsJson(o.hostDeps),
      "runDependencies": {"depends": o.runDeps, "constraints": o.runConstraints},
      "ignoreRunExports": {"byName": [], "fromPackage": []},
      "runExports": {
        "weak": o.runExports.weak, "strong": o.runExports.strong,
        "noarch": o.runExports.noarch, "weakConstrains": o.runExports.weakConstrains,
        "strongConstrains": o.runExports.strongConstrains},
      "inputGlobs": nil}
    if extras.len > 0: item["extraDependencies"] = extras
    list.add item
  %*{"outputs": list, "inputGlobs": globs}

proc condaBuild(s: var Server, params: JsonNode): JsonNode =
  let cfg = effectiveConfig(s.project.config, s.project.targetConfigs,
                            params{"hostPrefix"}{"platform"}.getStr)
  let built = condaBuildV1(s.project, params)
  var globs = @buildInputGlobs
  globs.add cfg.extraInputGlobs
  %*{"output_file": built.outputFile, "input_globs": globs, "name": built.name,
     "version": built.version, "build": built.build, "subdir": built.subdir}

proc dispatch(s: var Server, meth: string, params: JsonNode): JsonNode =
  case meth
  of "negotiateCapabilities": result = capabilities()
  of "initialize": result = s.initialize(params)
  of "conda/outputs", "conda/build_v1":
    if not s.initialized: raise rpcError(-32600, "the backend is not initialized")
    let workDir = params{"workDirectory"}.getStr
    let prefix = if meth == "conda/outputs": "conda_outputs" else: "conda_build_v1"
    if s.pendingModel != nil:
      writeDebug(workDir, "project_model.json", s.pendingModel)
      s.pendingModel = nil
    writeDebug(workDir, prefix & "_params.json", params)
    try:
      result = if meth == "conda/outputs": s.condaOutputs(params) else: s.condaBuild(params)
      writeDebug(workDir, prefix & "_response.json", result)
    except RpcError as e:
      writeDebug(workDir, prefix & "_error.json", errorObject(e.code, e.msg))
      raise
    except CatchableError as e:
      writeDebug(workDir, prefix & "_error.json", errorObject(-32000, e.msg))
      raise
  else: raise rpcError(-32601, "Method not found: " & meth)

proc handle(s: var Server, request: JsonNode): JsonNode =
  ## The response to one request, or nil for a notification.
  if request.kind != JObject:
    return %*{"jsonrpc": "2.0", "error": errorObject(-32600, "Invalid request"), "id": nil}
  let id = request.getOrDefault("id")
  let meth = request{"method"}.getStr
  let params = if request.hasKey("params"): request["params"] else: newJObject()
  var response = %*{"jsonrpc": "2.0"}
  try:
    response["result"] = s.dispatch(meth, params)
  except RpcError as e:
    response["error"] = errorObject(e.code, e.msg)
  except CatchableError as e:
    response["error"] = errorObject(-32000, e.msg)
  if id.isNil: return nil
  response["id"] = id
  response

proc serve() =
  var s: Server
  var line: string
  while stdin.readLine(line):
    if line.strip.len == 0: continue
    var reply: JsonNode
    try:
      let msg = parseJson(line)
      if msg.kind == JArray:
        reply = newJArray()
        for req in msg:
          let r = s.handle(req)
          if r != nil: reply.add r
        if reply.len == 0: reply = nil
      else:
        reply = s.handle(msg)
    except JsonParsingError as e:
      reply = %*{"jsonrpc": "2.0", "error": errorObject(-32700, "Parse error: " & e.msg), "id": nil}
    if reply != nil:
      stdout.write($reply & "\n")
      stdout.flushFile

proc usage() =
  echo backendName & " " & backendVersion & " - a pixi build backend for Nim packages\n\n" &
    "Usage: " & backendName & " [capabilities | --version | --help]\n\n" &
    "Without arguments it serves pixi-build API v" & $apiVersion & " JSON-RPC on stdin/stdout."

when isMainModule:
  var args = commandLineParams()
  # pixi may pass verbosity flags; they don't change anything here.
  var positional: seq[string]
  for a in args:
    case a
    of "--help", "-h":
      usage()
      quit 0
    of "--version", "-V":
      echo backendName & " " & backendVersion
      quit 0
    else:
      if a.startsWith("--http-port"):
        stderr.writeLine "error: --http-port is not supported by " & backendName
        quit 2
      if not a.startsWith("-"): positional.add a
  if positional.len == 0:
    serve()
  elif positional == @["capabilities"]:
    stderr.writeLine "Supports conda/outputs: true"
    stderr.writeLine "Supports conda/build_v1: true"
  else:
    usage()
    quit 2
