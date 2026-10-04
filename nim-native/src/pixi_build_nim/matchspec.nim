## Turns the structured match specs pixi sends in `conda/build_v1` into the
## string form used in a package's `info/index.json`.

import std/[json, strutils]

proc jsonText(v: JsonNode): string =
  case v.kind
  of JString: v.getStr
  of JInt: $v.getInt
  of JBool: $v.getBool
  of JArray:
    var parts: seq[string]
    for x in v: parts.add jsonText(x)
    parts.join(",")
  else: $v

proc quoteValue(s: string): string = "\"" & s.replace("\"", "\\\"") & "\""

proc matchSpecString*(spec: JsonNode): string =
  ## `name [version [build]]`, falling back to the bracket syntax for the
  ## fields that have no positional form.
  if spec.kind == JString: return spec.getStr
  let name = spec{"name"}.getStr
  let version = if spec.hasKey("version") and spec["version"].kind != JNull: jsonText(spec["version"]) else: ""
  let build = if spec.hasKey("build") and spec["build"].kind != JNull: jsonText(spec["build"]) else: ""
  var brackets: seq[string]
  for key, value in spec:
    if value.kind == JNull: continue
    case key
    of "name", "version", "build", "channel", "condition", "namespace": discard
    of "build_number", "file_name", "subdir", "md5", "sha256", "url", "license",
       "license_family", "extras", "flags", "track_features":
      let k = if key == "file_name": "fn" else: key
      brackets.add k & "=" & quoteValue(jsonText(value))
    else: discard
  if spec.hasKey("condition") and spec["condition"].kind == JString:
    brackets.add "when=" & quoteValue(spec["condition"].getStr)
  var channel = ""
  if spec.hasKey("channel"):
    let ch = spec["channel"]
    if ch.kind == JString: channel = ch.getStr
    elif ch.kind == JObject and ch.hasKey("name") and ch["name"].kind == JString:
      channel = ch["name"].getStr
  result = if channel.len > 0: channel & "::" & name else: name
  let simple = not version.contains(' ') and not build.contains(' ')
  if simple and brackets.len == 0:
    if version.len > 0: result.add " " & version
    if build.len > 0: result.add " " & (if version.len > 0: "" else: "* ") & build
    return
  if version.len > 0: brackets.insert("version=" & quoteValue(version), 0)
  if build.len > 0: brackets.insert("build=" & quoteValue(build), min(1, brackets.len))
  result.add "[" & brackets.join(", ") & "]"
