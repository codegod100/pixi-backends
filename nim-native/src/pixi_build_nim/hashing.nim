## SHA-1, SHA-256 and CRC-32, implemented here so the backend has no
## dependencies outside the Nim standard library.
##
## SHA-1 is only used for the build string hash (to match rattler-build),
## SHA-256 for `paths.json`, CRC-32 for the `.conda` zip container.

import std/strutils

proc rotl32(x: uint32, n: int): uint32 {.inline.} = (x shl n) or (x shr (32 - n))
proc rotr32(x: uint32, n: int): uint32 {.inline.} = (x shr n) or (x shl (32 - n))

proc toHexString(bytes: openArray[uint8]): string =
  result = newStringOfCap(bytes.len * 2)
  for b in bytes:
    result.add toHex(b.int, 2).toLowerAscii

proc padMessage(data: openArray[char]): seq[uint8] =
  ## Merkle–Damgård padding shared by SHA-1 and SHA-256 (big endian length).
  let bitLen = uint64(data.len) * 8
  result = newSeqOfCap[uint8](data.len + 72)
  for c in data: result.add uint8(c)
  result.add 0x80'u8
  while result.len mod 64 != 56: result.add 0'u8
  for i in countdown(7, 0):
    result.add uint8((bitLen shr (i * 8)) and 0xff)

proc be32(buf: openArray[uint8], i: int): uint32 {.inline.} =
  (uint32(buf[i]) shl 24) or (uint32(buf[i+1]) shl 16) or
    (uint32(buf[i+2]) shl 8) or uint32(buf[i+3])

proc sha1Hex*(data: openArray[char]): string =
  var h = [0x67452301'u32, 0xEFCDAB89'u32, 0x98BADCFE'u32, 0x10325476'u32, 0xC3D2E1F0'u32]
  let msg = padMessage(data)
  var w: array[80, uint32]
  for chunk in countup(0, msg.len - 1, 64):
    for i in 0 ..< 16: w[i] = be32(msg, chunk + i * 4)
    for i in 16 ..< 80: w[i] = rotl32(w[i-3] xor w[i-8] xor w[i-14] xor w[i-16], 1)
    var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
    for i in 0 ..< 80:
      var f, k: uint32
      if i < 20: (f, k) = ((b and c) or ((not b) and d), 0x5A827999'u32)
      elif i < 40: (f, k) = (b xor c xor d, 0x6ED9EBA1'u32)
      elif i < 60: (f, k) = ((b and c) or (b and d) or (c and d), 0x8F1BBCDC'u32)
      else: (f, k) = (b xor c xor d, 0xCA62C1D6'u32)
      let t = rotl32(a, 5) + f + e + k + w[i]
      e = d; d = c; c = rotl32(b, 30); b = a; a = t
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e
  var digest: array[20, uint8]
  for i in 0 ..< 5:
    for j in 0 ..< 4: digest[i*4 + j] = uint8((h[i] shr (24 - j*8)) and 0xff)
  toHexString(digest)

const sha256K = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32, 0x3956c25b'u32,
  0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32, 0xd807aa98'u32, 0x12835b01'u32,
  0x243185be'u32, 0x550c7dc3'u32, 0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32,
  0xc19bf174'u32, 0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
  0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32, 0x983e5152'u32,
  0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32, 0xc6e00bf3'u32, 0xd5a79147'u32,
  0x06ca6351'u32, 0x14292967'u32, 0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32,
  0x53380d13'u32, 0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
  0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32, 0xd192e819'u32,
  0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32, 0x19a4c116'u32, 0x1e376c08'u32,
  0x2748774c'u32, 0x34b0bcb5'u32, 0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32,
  0x682e6ff3'u32, 0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
  0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]

proc sha256Hex*(data: openArray[char]): string =
  var h = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
           0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]
  let msg = padMessage(data)
  var w: array[64, uint32]
  for chunk in countup(0, msg.len - 1, 64):
    for i in 0 ..< 16: w[i] = be32(msg, chunk + i * 4)
    for i in 16 ..< 64:
      let s0 = rotr32(w[i-15], 7) xor rotr32(w[i-15], 18) xor (w[i-15] shr 3)
      let s1 = rotr32(w[i-2], 17) xor rotr32(w[i-2], 19) xor (w[i-2] shr 10)
      w[i] = w[i-16] + s0 + w[i-7] + s1
    var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
    for i in 0 ..< 64:
      let S1 = rotr32(e, 6) xor rotr32(e, 11) xor rotr32(e, 25)
      let ch = (e and f) xor ((not e) and g)
      let t1 = hh + S1 + ch + sha256K[i] + w[i]
      let S0 = rotr32(a, 2) xor rotr32(a, 13) xor rotr32(a, 22)
      let maj = (a and b) xor (a and c) xor (b and c)
      let t2 = S0 + maj
      hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2
    h[0] += a; h[1] += b; h[2] += c; h[3] += d
    h[4] += e; h[5] += f; h[6] += g; h[7] += hh
  var digest: array[32, uint8]
  for i in 0 ..< 8:
    for j in 0 ..< 4: digest[i*4 + j] = uint8((h[i] shr (24 - j*8)) and 0xff)
  toHexString(digest)

proc makeCrcTable(): array[256, uint32] =
  for n in 0 ..< 256:
    var c = uint32(n)
    for _ in 0 ..< 8:
      c = if (c and 1) != 0: 0xEDB88320'u32 xor (c shr 1) else: c shr 1
    result[n] = c

const crcTable = makeCrcTable()

proc crc32*(data: openArray[char]): uint32 =
  var c = 0xFFFFFFFF'u32
  for ch in data:
    c = crcTable[(c xor uint32(ch)) and 0xff] xor (c shr 8)
  c xor 0xFFFFFFFF'u32
