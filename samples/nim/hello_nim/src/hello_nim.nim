const NimblePkgVersion {.strdefine.} = "unknown"
when isMainModule:
  echo "Hello from Nim ", NimVersion, " (hello_nim v", NimblePkgVersion, ")"
