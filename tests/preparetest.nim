## Runs `iconbundler --prepare` on a PNG of known size and checks the files it
## derives -- not that they look right, which no test can say, but that they
## have the shape the systems that read them require: the `_NET_WM_ICON` blob
## is exactly as long as its three sizes make it and starts with the first
## one's dimensions, every `.ico` frame is where its directory entry says and
## in the format that size is supposed to be in, and the `.rc` names the icon
## beside it.
##
## Nothing external is involved: the picture work is pixie's, so this runs on
## any machine that can build the tool.

import std/[base64, os, osproc, strutils, tempfiles]

const TinyPng = # 16x16 RGBA, made once and kept, so this needs no image tool
  "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAaElEQVR42mNgGGjA" &
  "CGOIyGn8vxRFvEapjhuMDAwMDEwwgUtRDAx6y0h3ARMyhxxDmNAFSDWECZsgKYYw" &
  "4ZIg1hAmfJLEGMJEyAZChjAR4098hjARG9q4DGEiJc6xGcJEasojN8XSDgAA/Fca" &
  "GFwb71YAAAAASUVORK5CYII="

var failures = 0

proc check(name: string; cond: bool; detail = "") =
  if cond:
    echo "  PASS  ", name
  else:
    inc failures
    echo "  FAIL  ", name, (if detail.len > 0: "  -- " & detail else: "")

proc u32le(s: string; at: int): uint32 =
  uint32(s[at].uint8) or (uint32(s[at+1].uint8) shl 8) or
  (uint32(s[at+2].uint8) shl 16) or (uint32(s[at+3].uint8) shl 24)

proc u16le(s: string; at: int): int =
  s[at].uint8.int or (s[at+1].uint8.int shl 8)

let src = "src" / "iconbundler.nim"
if not fileExists(src):
  quit "run this from the project root; " & src & " is not here"

let work = createTempDir("iconbundlertest_", "")
let exe = work / "iconbundler".addFileExt(ExeExt)
if execShellCmd("nim c --hints:off -o:" & quoteShell(exe) & " " &
                quoteShell(src)) != 0:
  quit "cannot build " & src

writeFile(work / "demo-icon.png", decode(TinyPng))

# No PNG argument: it is found under the name an app icon usually has.
let (outp, code) = execCmdEx(quoteShell(exe) & " --prepare demo",
                             workingDir = work)
check("--prepare succeeds", code == 0, outp)

echo "netwm:"
block:
  let blob = readFile(work / "demo-icon.netwm")
  # Three sizes, each two CARD32s of header and one per pixel.
  var want = 0
  for px in [32, 64, 128]: want += 8 + px * px * 4
  check("as long as its three sizes make it", blob.len == want,
        $blob.len & " vs " & $want)
  check("the first size says 32 by 32",
        blob.u32le(0) == 32'u32 and blob.u32le(4) == 32'u32)
  check("the second one starts where the first one ends",
        blob.u32le(8 + 32*32*4) == 64'u32)
  # The source is opaque in the middle, so the middle pixel must be too: a
  # blob of the right length full of zeroes would pass everything above.
  check("and the pixels are the picture, not padding",
        (blob.u32le(8 + 4 * (16 * 32 + 16)) shr 24) == 255'u32)

echo "ico:"
block:
  const
    Sizes = [16, 32, 48, 64, 128, 256]
    PngMagic = "\x89PNG\r\n\x1a\n"
  let ico = readFile(work / "demo.ico")
  check("has the icon directory header",
        ico.len > 6 and ico.u16le(0) == 0 and ico.u16le(2) == 1)
  check("holding six frames", ico.u16le(4) == Sizes.len, $ico.u16le(4))
  var seen: seq[string] = @[]
  var ok = true
  for i, px in Sizes:
    let e = 6 + i * 16
    # 256 does not fit in a byte and is spelled 0; every other size is itself.
    let want = if px == 256: 0 else: px
    if ico[e].uint8.int != want or ico[e+1].uint8.int != want: ok = false
    let size = ico.u32le(e + 8).int
    let off = ico.u32le(e + 12).int
    if off + size > ico.len:
      ok = false
      seen.add "past the end"
      continue
    let payload = ico[off ..< off + size]
    if payload.startsWith(PngMagic):
      seen.add "PNG"
    else:
      seen.add "DIB"
      # The mask doubles the height in the header; a reader that trusts it and
      # finds the pixels the other way up draws the icon upside down.
      if payload.u32le(4).int != px or payload.u32le(8).int != px * 2 or
         payload.u16le(14) != 32:
        ok = false
  check("every entry names its own size and points inside the file", ok)
  check("the small frames are bitmaps, the big ones PNG",
        seen == @["DIB", "DIB", "DIB", "DIB", "PNG", "PNG"], seen.join(" "))

echo "rc:"
block:
  check("names the icon file beside it",
        readFile(work / "demo.rc").strip == "1 ICON \"demo.ico\"")

removeDir(work)
if failures == 0:
  echo "ALL PASS"
else:
  quit "FAILURE: " & $failures & " test(s)"
