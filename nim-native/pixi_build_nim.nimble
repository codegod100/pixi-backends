# Package

version       = "0.2.0"
author        = "V"
description   = "A pixi build backend for Nim packages, written in Nim"
license       = "BSD-3-Clause"
srcDir        = "src"
namedBin["pixi_build_nim"] = "pixi-build-nim"

# Dependencies

requires "nim >= 2.0.0"
