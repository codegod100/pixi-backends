import std/[json, os, strutils, tempfiles, unittest]
import ../src/pixi_build_nim/[archive, buildscript, config, elf, hashing, matchspec,
                              nimble, recipe, selectors]

const sample = """
# Package

version       = "0.3.1"
author        = "Someone"
description   = "A tool # with a hash"
license       = "MIT"
srcDir        = "src"
bin           = @["hello", "tools/other"]
backend       = "c"

# Dependencies

requires "nim >= 2.0.0 & < 3.0", "cligen >= 1.7"
requires "https://github.com/foo/bar#head"

task test, "Run tests":
  exec "nim c -r tests/all"
"""

suite "nimble parser":
  test "parses declarative fields":
    let pkg = parseNimble(sample, "hello_world")
    check pkg.name == "hello_world"
    check pkg.version == "0.3.1"
    check pkg.description == "A tool # with a hash"
    check pkg.license == "MIT"
    check pkg.srcDir == "src"
    check pkg.bin == @["hello", "tools/other"]
    check pkg.backend == "c"
    check pkg.requires == @["nim >= 2.0.0 & < 3.0", "cligen >= 1.7",
                            "https://github.com/foo/bar#head"]
    check pkg.nimConstraint == ">=2.0.0,<3.0"
    check pkg.hasNimbleDependencies
    check pkg.buildTargets == @[("hello", "hello"), ("tools/other", "other")]

  test "packageName overrides the stem and requires can span lines":
    let pkg = parseNimble("packageName = \"real\"\nrequires \"nim >= 1.6\",\n  \"nimcrypto\"\n", "stem")
    check pkg.name == "real"
    check pkg.requires == @["nim >= 1.6", "nimcrypto"]
    check pkg.nimConstraint == ">=1.6"

  test "nim-only requires has no dependencies":
    check not parseNimble("requires \"nim >= 2.0\"", "x").hasNimbleDependencies
    check parseNimble("requires \"nim ^= 2.0\"", "x").nimConstraint == ""
    check parseNimble("requires \"nimcrypto\"", "x").nimConstraint == ""

  test "namedBin renames executables":
    let pkg = parseNimble("bin = @[\"a\"]\nnamedBin[\"b\"] = \"b-tool\"\nnamedBin[\"a\"] = \"a-tool\"", "x")
    check pkg.buildTargets == @[("a", "a-tool"), ("b", "b-tool")]

suite "config":
  test "parses and merges target config":
    let base = parseConfig(%*{"extra-args": ["--base"], "env": {"A": "1", "B": "1"}})
    let target = parseConfig(%*{"env": {"B": "2"}, "compilers": ["cxx"]})
    let merged = base.merge(target)
    check merged.extraArgs == @["--base"]
    check merged.env == @[("A", "1"), ("B", "2")]
    check merged.compilers == @["cxx"]

  test "rejects unknown fields":
    expect ConfigError: discard parseConfig(%*{"nope": 1})

  test "target selectors":
    check selectorMatches("unix", "osx-arm64")
    check selectorMatches("linux", "linux-aarch64")
    check not selectorMatches("win", "linux-64")
    check selectorMatches("linux-64", "linux-64")

suite "selectors":
  test "conditions pixi generates":
    check evalCondition("host_platform == 'linux-64'", "linux-64")
    check not evalCondition("host_platform == 'linux-64'", "osx-64")
    check evalCondition("unix", "osx-arm64")
    check evalCondition("osx and arm64", "osx-arm64")
    check evalCondition("not win", "linux-64")
    check evalCondition("(win or linux) and x86_64", "linux-64")
    expect SelectorError: discard evalCondition("cuda", "linux-64")

suite "hashing":
  test "known digests":
    check sha1Hex("abc") == "a9993e364706816aba3e25717850c26c9cd0d89d"
    check sha256Hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    check sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    check sha256Hex(repeat('a', 1000)) == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3"
    check crc32("123456789") == 0xCBF43926'u32

  test "build string matches rattler-build":
    let variant: Variant = @[("c_stdlib", %"sysroot"), ("c_stdlib_version", %"2.28"),
                             ("target_platform", %"linux-64")]
    check hashInput(variant) == """{"c_stdlib": "sysroot", "c_stdlib_version": "2.28", "target_platform": "linux-64"}"""
    check buildString(variant, 0) == "ha35fb5c_0"
    check buildString(variant, 3, "dev") == "dev_ha35fb5c_3"

suite "match specs":
  test "structured specs become strings":
    check matchSpecString(%*{"name": "libgcc", "version": ">=16"}) == "libgcc >=16"
    check matchSpecString(%*{"name": "foo"}) == "foo"
    check matchSpecString(%*{"name": "foo", "version": "1.2", "build": "h1_0"}) == "foo 1.2 h1_0"
    check matchSpecString(%*{"name": "foo", "build": "h1_0"}) == "foo * h1_0"
    check matchSpecString(%*{"name": "foo", "version": ">=1", "sha256": "ab"}) ==
      "foo[version=\">=1\", sha256=\"ab\"]"

suite "build script":
  test "binary build":
    let script = BuildScriptContext(sourceDir: "/pkg", srcDir: "/pkg/src", backend: "c",
      bins: @[BinTarget(module: "hello", name: "hello")], hasNimbleDeps: true,
      version: "0.1.0", extraArgs: @["--opt:size"]).render
    check "nimble install --depsOnly" in script
    check "-d:NimblePkgVersion=0.1.0 \\" in script
    check "    --opt:size \\\n    \"/pkg/src/hello.nim\"" in script
    check "--out:\"$PREFIX/bin/hello\"" in script

  test "library install":
    let script = BuildScriptContext(sourceDir: "/pkg", srcDir: "/pkg/src", backend: "c",
                                    isLibrary: true).render
    check "nimble install -y --useSystemNim --nimbleDir:\"$PREFIX/share/nimble\"" in script
    check "--depsOnly" notin script

suite "archives":
  test "stored zstd frame layout":
    let frame = zstdStored("hello")
    check frame[0 .. 3] == "\x28\xB5\x2F\xFD"
    check frame.len == 4 + 2 + 3 + 5
    check frame[^5 .. ^1] == "hello"

  test "tar uses pax headers for long names":
    let long = repeat("dir/", 70) & "file.txt"
    let tar = writeTar([TarEntry(path: long, kind: tekFile, mode: 0o644, data: "x")], 0)
    check tar.len mod 512 == 0
    check ("path=" & long & "\n") in tar

  test "zip is readable as a stored archive":
    let zip = writeStoredZip([("a.txt", "hello")])
    check zip.startsWith("PK\x03\x04")
    check "PK\x05\x06" in zip

suite "elf":
  test "non-ELF data is left alone":
    var data = "not an elf file"
    check not relocateElf(data, "/p/bin/x", "/p", "/b")

proc model(node: JsonNode): JsonNode = node

suite "outputs":
  setup:
    let dir = createTempDir("pbn", "")
  teardown:
    removeDir(dir)

  test "reads metadata and adds nim":
    writeFile(dir / "hello_nim.nimble", "version = \"1.2.3\"\nlicense = \"MIT\"\n" &
      "description = \"says hi\"\nsrcDir = \"src\"\nbin = @[\"hello\"]\n" &
      "requires \"nim >= 2.0.0\", \"cligen\"\n")
    let project = Project(manifestPath: dir / "pixi.toml", sourceDir: dir,
                          model: model(%*{"targets": {}}))
    let outputs = generateOutputs(project, "linux-64", @[("c_stdlib", @[%"sysroot"]),
                                                        ("c_stdlib_version", @[%"2.28"])])
    check outputs.len == 1
    let o = outputs[0]
    check o.name == "hello_nim"
    check o.version == "1.2.3"
    check o.license == "MIT"
    check o.summary == "says hi"
    check o.buildString == "ha35fb5c_0"
    var names: seq[string]
    for d in o.buildDeps: names.add d["name"].getStr
    check names == @["gcc_linux-64", "sysroot_linux-64", "nim", "git"]
    check o.buildDeps[1]["binary"]["version"].getStr == "2.28.*"
    check o.buildDeps[2]["binary"]["version"].getStr == ">=2.0.0"
    check o.metadataInputGlobs == @["hello_nim.nimble"]

  test "model overrides and conditional dependencies":
    writeFile(dir / "x.nimble", "version = \"0.1.0\"\nbin = @[\"x\"]\n")
    let project = Project(manifestPath: dir / "pixi.toml", sourceDir: dir, model: model(%*{
      "name": "renamed", "version": "2.0.0",
      "targets": {
        "defaultTarget": {"hostDependencies": {"lib": {"source": {"path": {"path": "../lib"}}}}},
        "conditional": {
          "host_platform == 'osx-64'": {"runDependencies": {"macdep": {"binary": {}}}},
          "linux": {"runDependencies": {"linuxdep": {"binary": {"version": ">=1"}}}}}}}))
    let o = generateOutputs(project, "linux-64", @[])[0]
    check o.name == "renamed"
    check o.version == "2.0.0"
    check o.hostDeps == @[%*{"source": {"path": {"path": "../lib"}}, "name": "lib"}]
    check o.runDeps.len == 1
    check o.runDeps[0]["name"].getStr == "linuxdep"

  test "nim-only package needs no git":
    writeFile(dir / "x.nimble", "bin = @[\"x\"]\n")
    let project = Project(manifestPath: dir, sourceDir: dir,
                          model: model(%*{"name": "x", "version": "0.1.0"}))
    let o = generateOutputs(project, "linux-64", @[])[0]
    for d in o.buildDeps: check d["name"].getStr != "git"

  test "variants multiply outputs":
    writeFile(dir / "x.nimble", "version = \"1.0\"\nbin = @[\"x\"]\n")
    let project = Project(manifestPath: dir, sourceDir: dir, model: model(%*{}))
    let outputs = generateOutputs(project, "linux-64",
      @[("c_compiler_version", @[%"13", %"14"])])
    check outputs.len == 2
    check outputs[0].buildString != outputs[1].buildString
    check outputs[1].buildDeps[0]["binary"]["version"].getStr == "14.*"

  test "missing nimble file is an error":
    let project = Project(manifestPath: dir, sourceDir: dir,
                          model: model(%*{"name": "x", "version": "1"}))
    try:
      discard generateOutputs(project, "linux-64", @[])
      fail()
    except NimbleError as e:
      check "no `.nimble` file" in e.msg

  test "windows is rejected":
    writeFile(dir / "x.nimble", "bin = @[\"x\"]\n")
    let project = Project(manifestPath: dir, sourceDir: dir, model: model(%*{}))
    expect RecipeError: discard generateOutputs(project, "win-64", @[])

  test "pin-subpackage on itself resolves to a version range":
    writeFile(dir / "x.nimble", "version = \"1.2.3\"\nbin = @[\"x\"]\n")
    let project = Project(manifestPath: dir, sourceDir: dir, model: model(%*{
      "targets": {"defaultTarget": {"runExports": {"weak": {"x": {"pinSubpackage": {}}}}}}}))
    let o = generateOutputs(project, "linux-64", @[])[0]
    check o.runExports.weak[0]["binary"]["version"].getStr == ">=1.2.3,<2.0a0"
