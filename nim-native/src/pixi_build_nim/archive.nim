## Writers for the formats a `.conda` package is made of: an uncompressed
## zip holding `metadata.json` plus two zstd-compressed tarballs.
##
## zstd compression uses `libzstd` when it can be loaded at runtime (it is a
## run dependency of the conda package). Without it the tarballs are written
## as zstd frames made of raw (stored) blocks: valid zstd, just not smaller.

import std/[dynlib, os, strutils]
import hashing

type
  TarEntryKind* = enum tekFile, tekSymlink
  TarEntry* = object
    path*: string        ## Path inside the archive, `/`-separated.
    kind*: TarEntryKind
    mode*: int
    data*: string        ## File contents (files only).
    linkTarget*: string  ## Symlink target (symlinks only).

# --- tar --------------------------------------------------------------------

proc octal(value: int64, width: int): string =
  ## A NUL-terminated, zero-padded octal field of `width` bytes.
  result = toOct(value, width - 1)
  result.add '\0'

proc putField(header: var string, offset: int, value: string) =
  for i, c in value: header[offset + i] = c

proc ustarHeader(name: string, mode: int, size: int64, mtime: int64,
                 typeflag: char, linkname: string, prefix: string): string =
  result = newString(512)
  for i in 0 ..< 512: result[i] = '\0'
  result.putField(0, name)
  result.putField(100, octal(mode, 8))
  result.putField(108, octal(0, 8))   # uid
  result.putField(116, octal(0, 8))   # gid
  result.putField(124, octal(size, 12))
  result.putField(136, octal(mtime, 12))
  result.putField(148, "        ")    # checksum placeholder
  result[156] = typeflag
  result.putField(157, linkname)
  result.putField(257, "ustar\0")
  result.putField(263, "00")
  result.putField(345, prefix)
  var sum = 0
  for c in result: sum += ord(c)
  result.putField(148, toOct(sum, 6) & "\0 ")

proc padTo512(s: var string) =
  let rem = s.len mod 512
  if rem != 0: s.add repeat('\0', 512 - rem)

proc paxRecord(key, value: string): string =
  ## A pax record is "<len> <key>=<value>\n" where <len> counts itself.
  let body = " " & key & "=" & value & "\n"
  var length = body.len + 1
  while ($length).len + body.len != length: length = ($length).len + body.len
  $length & body

proc splitUstarName(path: string): (string, string, bool) =
  ## Split `path` into ustar (prefix, name). The bool is false when it can't fit.
  if path.len <= 100: return ("", path, true)
  var i = path.len - 1
  while i > 0:
    if path[i] == '/' and i <= 155 and path.len - i - 1 <= 100 and path.len - i - 1 > 0:
      return (path[0 ..< i], path[i + 1 .. ^1], true)
    dec i
  ("", "", false)

proc writeTar*(entries: openArray[TarEntry], mtime: int64): string =
  ## A POSIX (ustar + pax for long names) tar archive.
  for e in entries:
    let typeflag = if e.kind == tekSymlink: '2' else: '0'
    let size = if e.kind == tekFile: e.data.len.int64 else: 0'i64
    var (prefix, name, fits) = splitUstarName(e.path)
    var pax = ""
    if not fits:
      pax.add paxRecord("path", e.path)
      name = e.path[max(0, e.path.len - 100) .. ^1]
      prefix = ""
    var linkname = e.linkTarget
    if linkname.len > 100:
      pax.add paxRecord("linkpath", linkname)
      linkname = linkname[0 ..< 100]
    if pax.len > 0:
      let paxName = ("PaxHeaders/" & e.path)[0 ..< min(100, ("PaxHeaders/" & e.path).len)]
      result.add ustarHeader(paxName, 0o644, pax.len, mtime, 'x', "", "")
      result.add pax
      result.padTo512()
    result.add ustarHeader(name, e.mode and 0o7777, size, mtime, typeflag, linkname, prefix)
    if e.kind == tekFile:
      result.add e.data
      result.padTo512()
  result.add repeat('\0', 1024)

# --- zstd -------------------------------------------------------------------

type
  ZstdCompressBound = proc (srcSize: csize_t): csize_t {.cdecl, gcsafe.}
  ZstdCompress = proc (dst: pointer, dstCap: csize_t, src: pointer, srcSize: csize_t,
                       level: cint): csize_t {.cdecl, gcsafe.}
  ZstdIsError = proc (code: csize_t): cuint {.cdecl, gcsafe.}

var
  zstdTried = false
  zstdBound: ZstdCompressBound
  zstdCompressFn: ZstdCompress
  zstdIsErrorFn: ZstdIsError

proc loadZstd(): bool =
  if zstdTried: return zstdCompressFn != nil
  zstdTried = true
  let names = when defined(macosx): @["libzstd.1.dylib", "libzstd.dylib"]
              else: @["libzstd.so.1", "libzstd.so"]
  var candidates: seq[string]
  for n in names: candidates.add getAppDir() / ".." / "lib" / n
  candidates.add names
  for path in candidates:
    let lib = loadLib(path)
    if lib == nil: continue
    zstdBound = cast[ZstdCompressBound](lib.symAddr("ZSTD_compressBound"))
    zstdCompressFn = cast[ZstdCompress](lib.symAddr("ZSTD_compress"))
    zstdIsErrorFn = cast[ZstdIsError](lib.symAddr("ZSTD_isError"))
    if zstdBound != nil and zstdCompressFn != nil and zstdIsErrorFn != nil:
      return true
    zstdCompressFn = nil
  false

proc zstdAvailable*(): bool = loadZstd()

proc zstdStored*(data: string): string =
  ## A zstd frame containing `data` in raw blocks (no compression).
  const blockMax = 128 * 1024
  result = "\x28\xB5\x2F\xFD"  # magic, little endian 0xFD2FB528
  result.add '\x00'            # frame header descriptor: no FCS, no checksum
  result.add char(7 shl 3)     # window descriptor: 2^(10+7) = 128 KiB
  var pos = 0
  while true:
    let n = min(blockMax, data.len - pos)
    let last = pos + n >= data.len
    let header = (uint32(n) shl 3) or (0'u32 shl 1) or (if last: 1'u32 else: 0'u32)
    result.add char(header and 0xff)
    result.add char((header shr 8) and 0xff)
    result.add char((header shr 16) and 0xff)
    result.add data[pos ..< pos + n]
    pos += n
    if last: break

proc zstdCompress*(data: string, level: int): string =
  if not loadZstd(): return zstdStored(data)
  let cap = zstdBound(csize_t(data.len))
  result = newString(int(cap))
  let src = if data.len > 0: unsafeAddr data[0] else: nil
  let written = zstdCompressFn(addr result[0], cap, src, csize_t(data.len), cint(level))
  if zstdIsErrorFn(written) != 0: return zstdStored(data)
  result.setLen(int(written))

# --- zip (stored) ---------------------------------------------------------------

proc le16(v: int): string = result = newString(2); result[0] = char(v and 0xff); result[1] = char((v shr 8) and 0xff)
proc le32(v: uint32): string =
  result = newString(4)
  for i in 0 ..< 4: result[i] = char((v shr (8 * i)) and 0xff)

proc writeStoredZip*(files: openArray[(string, string)]): string =
  ## An uncompressed zip, as required for the outer `.conda` container.
  var central = ""
  for (name, data) in files:
    if data.len.int64 >= 0xFFFFFFFF'i64:
      raise newException(ValueError, "zip member too large: " & name)
    let offset = uint32(result.len)
    let crc = crc32(data)
    let size = uint32(data.len)
    # local file header
    result.add le32(0x04034b50'u32) & le16(20) & le16(0) & le16(0) &
      le16(0) & le16(0x21) & le32(crc) & le32(size) & le32(size) &
      le16(name.len) & le16(0) & name
    result.add data
    central.add le32(0x02014b50'u32) & le16(20) & le16(20) & le16(0) & le16(0) &
      le16(0) & le16(0x21) & le32(crc) & le32(size) & le32(size) &
      le16(name.len) & le16(0) & le16(0) & le16(0) & le16(0) & le32(0) &
      le32(offset) & name
  let cdOffset = uint32(result.len)
  result.add central
  result.add le32(0x06054b50'u32) & le16(0) & le16(0) & le16(files.len) &
    le16(files.len) & le32(uint32(central.len)) & le32(cdOffset) & le16(0)

proc writeConda*(stem: string, info, pkg: openArray[TarEntry], mtime: int64,
                 level: int): string =
  ## A `.conda` (v2) package. `stem` is `<name>-<version>-<build>`.
  writeStoredZip([
    ("metadata.json", """{"conda_pkg_format_version":2}"""),
    ("pkg-" & stem & ".tar.zst", zstdCompress(writeTar(pkg, mtime), level)),
    ("info-" & stem & ".tar.zst", zstdCompress(writeTar(info, mtime), level)),
  ])
