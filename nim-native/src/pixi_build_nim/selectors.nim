## Evaluates the `if(<expression>)` conditions pixi attaches to conditional
## dependencies (e.g. `host_platform == 'linux-64'`, `unix`, `osx and arm64`).
## rattler-build evaluates these with minijinja; this handles the subset that
## pixi itself produces plus `and`/`or`/`not` combinations of it.

import std/strutils

type SelectorError* = object of CatchableError

proc archOf*(platform: string): string =
  case platform
  of "linux-64", "osx-64", "win-64": "x86_64"
  of "linux-aarch64": "aarch64"
  of "osx-arm64", "win-arm64": "arm64"
  of "linux-ppc64le": "ppc64le"
  of "linux-32", "win-32": "x86"
  else: ""

proc platformFamily*(platform: string): string =
  if platform.startsWith("linux"): "linux"
  elif platform.startsWith("osx"): "osx"
  elif platform.startsWith("win"): "win"
  else: platform.split('-')[0]

type Parser = object
  toks: seq[string]
  pos: int
  platform: string

proc tokenize(s: string): seq[string] =
  var i = 0
  while i < s.len:
    let c = s[i]
    if c in Whitespace: inc i
    elif c in {'(', ')'}:
      result.add $c
      inc i
    elif c in {'=', '!'} and i + 1 < s.len and s[i + 1] == '=':
      result.add s[i .. i + 1]
      i += 2
    elif c in {'\'', '"'}:
      let close = s.find(c, i + 1)
      if close < 0: raise newException(SelectorError, "unterminated string in `" & s & "`")
      result.add s[i .. close]
      i = close + 1
    elif c in IdentChars + {'-'}:
      var j = i
      while j < s.len and s[j] in IdentChars + {'-'}: inc j
      result.add s[i ..< j]
      i = j
    else:
      raise newException(SelectorError, "unexpected `" & $c & "` in `" & s & "`")

proc peek(p: Parser): string = (if p.pos < p.toks.len: p.toks[p.pos] else: "")
proc next(p: var Parser): string =
  result = p.peek
  inc p.pos

proc parseOr(p: var Parser): bool

proc value(p: Parser, ident: string): string =
  case ident
  of "host_platform", "target_platform", "build_platform", "subdir": p.platform
  else: raise newException(SelectorError, "unknown variable `" & ident & "`")

proc parseAtom(p: var Parser): bool =
  let t = p.next
  case t
  of "": raise newException(SelectorError, "unexpected end of condition")
  of "(":
    result = p.parseOr
    if p.next != ")": raise newException(SelectorError, "missing `)`")
  of "not": result = not p.parseAtom
  of "true", "True": result = true
  of "false", "False": result = false
  of "unix": result = p.platform.platformFamily in ["linux", "osx", "emscripten"]
  of "linux", "osx", "win": result = p.platform.platformFamily == t
  of "macos": result = p.platform.platformFamily == "osx"
  of "x86_64", "aarch64", "arm64", "ppc64le", "x86": result = archOf(p.platform) == t
  of "x86_64-linux": result = p.platform == "linux-64"
  else:
    let op = p.peek
    if op in ["==", "!="]:
      discard p.next
      let rhs = p.next
      if rhs.len < 2 or rhs[0] notin {'\'', '"'}:
        raise newException(SelectorError, "expected a string after `" & op & "`")
      let equal = p.value(t) == rhs[1 .. ^2]
      result = if op == "==": equal else: not equal
    else:
      raise newException(SelectorError, "unsupported condition `" & t & "`")

proc parseAnd(p: var Parser): bool =
  result = p.parseAtom
  while p.peek == "and":
    discard p.next
    let rhs = p.parseAtom
    result = result and rhs

proc parseOr(p: var Parser): bool =
  result = p.parseAnd
  while p.peek == "or":
    discard p.next
    let rhs = p.parseAnd
    result = result or rhs

proc evalCondition*(expr, platform: string): bool =
  var p = Parser(toks: tokenize(expr), platform: platform)
  result = p.parseOr
  if p.pos != p.toks.len:
    raise newException(SelectorError, "unexpected `" & p.peek & "` in `" & expr & "`")
