## Makes ELF binaries relocatable: RPATH/RUNPATH entries that point into
## the host prefix are rewritten to `$ORIGIN`-relative paths, in place.
## The new value is never longer than the old one (the host prefix is a
## long placeholder path), so only the string table entry changes.

import std/[os, strutils]

proc u16(d: string, o: int): int = int(uint8(d[o])) or (int(uint8(d[o+1])) shl 8)
proc u32(d: string, o: int): int64 =
  for i in 0 ..< 4: result = result or (int64(uint8(d[o+i])) shl (8*i))
proc u64(d: string, o: int): int64 =
  for i in 0 ..< 8: result = result or (int64(uint8(d[o+i])) shl (8*i))

proc isElf*(data: string): bool =
  data.len >= 64 and data.startsWith("\x7fELF")

proc relocateRpath(entry, filePath, hostPrefix, buildPrefix: string): string =
  ## One RPATH entry, made relative to the binary's location when it points
  ## into the host prefix; entries pointing into the build prefix are dropped.
  if entry.startsWith(hostPrefix):
    let target = hostPrefix & entry[hostPrefix.len .. ^1]
    let rel = relativePath(target, filePath.parentDir)
    return if rel == ".": "$ORIGIN" else: "$ORIGIN/" & rel
  if buildPrefix.len > 0 and entry.startsWith(buildPrefix): return ""
  entry

proc relocateElf*(data: var string, filePath, hostPrefix, buildPrefix: string): bool =
  ## Rewrite RPATH/RUNPATH in `data` (the contents of `filePath`, which lives
  ## in `hostPrefix`). Returns true when something changed. Only 64-bit
  ## little-endian ELF files are handled; anything else is left alone.
  if not data.isElf or data[4] != '\x02' or data[5] != '\x01': return false
  let shoff = u64(data, 0x28)
  let shentsize = u16(data, 0x3A)
  let shnum = u16(data, 0x3C)
  if shoff <= 0 or shentsize < 64 or shoff + int64(shnum * shentsize) > data.len: return false
  for i in 0 ..< shnum:
    let sh = int(shoff) + i * shentsize
    if u32(data, sh + 4) != 6: continue  # SHT_DYNAMIC
    let dynOff = int(u64(data, sh + 0x18))
    let dynSize = int(u64(data, sh + 0x20))
    let link = int(u32(data, sh + 0x28))
    if link >= shnum: return false
    let strOff = int(u64(data, int(shoff) + link * shentsize + 0x18))
    var pos = dynOff
    while pos + 16 <= dynOff + dynSize and pos + 16 <= data.len:
      let tag = u64(data, pos)
      if tag == 0: break
      if tag == 15 or tag == 29:  # DT_RPATH, DT_RUNPATH
        let start = strOff + int(u64(data, pos + 8))
        var stop = start
        while stop < data.len and data[stop] != '\0': inc stop
        let old = data[start ..< stop]
        var entries: seq[string]
        for e in old.split(':'):
          let r = relocateRpath(e, filePath, hostPrefix, buildPrefix)
          if r.len > 0 and r notin entries: entries.add r
        let replacement = entries.join(":")
        if replacement != old and replacement.len <= old.len:
          for j in 0 ..< old.len:
            data[start + j] = if j < replacement.len: replacement[j] else: '\0'
          result = true
      pos += 16
