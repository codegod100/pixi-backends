## A small, forgiving reader for `.nimble` package files.
##
## `.nimble` files are NimScript, so they cannot be fully evaluated here. In
## practice almost every package uses the declarative subset
## (`key = "value"`, `key = @["a", "b"]`, `namedBin["a"] = "b"` and
## `requires "..."`), which is what gets extracted. Anything else is ignored.

import std/[algorithm, os, strutils]

type
  NimbleError* = object of CatchableError

  NimblePackage* = object
    path*: string            ## The file the data was read from.
    name*: string            ## `packageName`, falling back to the file stem.
    version*: string         ## Empty when not set.
    author*: string
    description*: string
    license*: string
    srcDir*: string          ## Relative to the package root, empty for the root.
    binDir*: string
    bin*: seq[string]        ## Module paths relative to `srcDir`, without `.nim`.
    namedBin*: seq[(string, string)]  ## module -> executable name overrides.
    backend*: string         ## `c`, `cpp`, `objc` or `js`; empty means `c`.
    requires*: seq[string]   ## Every `requires` entry, as written.

proc stringLiterals*(s: string): seq[string] =
  ## All double-quoted string literals in `s`, in order.
  var i = 0
  while i < s.len:
    if s[i] != '"':
      inc i
      continue
    inc i
    var lit = ""
    while i < s.len:
      let c = s[i]
      if c == '\\' and i + 1 < s.len:
        lit.add s[i + 1]
        i += 2
        continue
      inc i
      if c == '"': break
      lit.add c
    result.add lit

proc stripComment(line: string): string =
  ## `#` inside a string literal is legitimate (e.g. `requires "foo#head"`).
  var inStr = false
  for i, c in line:
    if c == '"': inStr = not inStr
    elif c == '#' and not inStr: return line[0 ..< i]
  line

proc stripKeyword(line, kw: string): (bool, string) =
  if not line.startsWith(kw): return (false, "")
  let rest = line[kw.len .. ^1]
  if rest.len > 0 and rest[0] in {' ', '(', '"', '\t'}: (true, rest) else: (false, "")

proc parseNimble*(content, fileStem: string): NimblePackage =
  result.name = fileStem

  # Join continuation lines: a trailing comma or an unclosed bracket means
  # the statement continues on the next line.
  var logical: seq[string]
  var current = ""
  for raw in content.splitLines:
    let line = stripComment(raw).strip
    if line.len == 0: continue
    if current.len > 0: current.add ' '
    current.add line
    let open = current.count({'(', '['}) > current.count({')', ']'})
    if current.endsWith(',') or open: continue
    logical.add current
    current = ""
  if current.len > 0: logical.add current

  for line in logical:
    let (isRequires, rest) = stripKeyword(line, "requires")
    if isRequires:
      result.requires.add stringLiterals(rest)
      continue
    let eq = line.find('=')
    if eq < 0: continue
    let key = line[0 ..< eq].strip
    let value = line[eq + 1 .. ^1].strip
    # Ignore `==`, `>=` etc. that aren't assignments.
    if value.startsWith('=') or (key.len > 0 and key[^1] in {'<', '>', '!'}): continue
    let lits = stringLiterals(value)
    let first = if lits.len > 0: lits[0] else: ""
    if key.startsWith("namedBin[") and key.endsWith("]"):
      let k = stringLiterals(key)
      if k.len == 1 and first.len > 0: result.namedBin.add (k[0], first)
      continue
    case key
    of "packageName":
      if first.len > 0: result.name = first
    of "version": result.version = first
    of "author": result.author = first
    of "description": result.description = first
    of "license": result.license = first
    of "srcDir": result.srcDir = first
    of "binDir": result.binDir = first
    of "backend": result.backend = first
    of "bin": result.bin = lits
    else: discard

proc discoverNimble*(root: string, explicit = ""): NimblePackage =
  ## Locate and parse the `.nimble` file in `root`.
  var path: string
  if explicit.len > 0:
    path = if explicit.isAbsolute: explicit else: root / explicit
  else:
    var found: seq[string]
    for kind, p in walkDir(root):
      if kind in {pcFile, pcLinkToFile} and p.endsWith(".nimble"): found.add p
    found.sort()
    case found.len
    of 0: raise newException(NimbleError, "no `.nimble` file found in " & root)
    of 1: path = found[0]
    else:
      var names: seq[string]
      for f in found: names.add f.extractFilename
      raise newException(NimbleError, "found multiple `.nimble` files in " & root &
        ": " & names.join(", ") & ". Set `nimble-file` in the build config to pick one")
  if not fileExists(path):
    raise newException(NimbleError, "the `.nimble` file " & path & " does not exist")
  result = parseNimble(readFile(path), path.splitFile.name)
  result.path = path

proc nimbleSpecToConda*(spec: string): string =
  ## Convert a nimble version spec (`>= 2.0.0`, `>= 1.6 & < 3.0`, `== 2.2.4`)
  ## into a conda version spec. Returns "" for specs that can't be translated
  ## (`^=`, `~=`, `#head`, ...), in which case `nim` stays unconstrained.
  let spec = spec.strip
  if spec.len == 0: return ""
  var parts: seq[string]
  for rawPart in spec.split('&'):
    let part = rawPart.strip
    var matched = false
    for op in ["==", ">=", "<=", ">", "<"]:
      if part.startsWith(op):
        let ver = part[op.len .. ^1].strip
        if ver.len == 0 or not ver.allCharsInSet(Digits + {'.'}): return ""
        parts.add op & ver
        matched = true
        break
    if not matched: return ""
  parts.join(",")

proc nimConstraint*(pkg: NimblePackage): string =
  ## The version constraint on `nim` itself as a conda version spec, or "".
  for r in pkg.requires:
    let r = r.strip
    if not r.startsWith("nim"): continue
    let rest = r[3 .. ^1]
    if rest.len > 0 and (rest[0].isAlphaNumeric or rest[0] == '_'): continue  # e.g. nimcrypto
    return nimbleSpecToConda(rest)
  ""

proc requirementName(r: string): string =
  for c in r.strip:
    if c in Whitespace or c in {'<', '>', '=', '~', '^', '#'}: break
    result.add c

proc hasNimbleDependencies*(pkg: NimblePackage): bool =
  ## Whether the package depends on anything besides the compiler.
  for r in pkg.requires:
    let name = requirementName(r)
    if name.len > 0 and name != "nim": return true
  false

proc executableName*(pkg: NimblePackage, module: string): string =
  for (m, exe) in pkg.namedBin:
    if m == module: return exe
  let slash = module.rfind('/')
  if slash >= 0: module[slash + 1 .. ^1] else: module

proc buildTargets*(pkg: NimblePackage): seq[(string, string)] =
  ## (module, executable) pairs from `bin` and `namedBin`.
  for m in pkg.bin: result.add (m, pkg.executableName(m))
  for (m, exe) in pkg.namedBin:
    if m notin pkg.bin: result.add (m, exe)
