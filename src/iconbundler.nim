## iconbundler -- one PNG in, every icon artifact a desktop application is
## expected to ship out, made with the tools that are already on the machine.
##
##   iconbundler <app-id> <exec> [png]
##   iconbundler --prepare <app-id> [png]
##
## `app-id` is the icon name / StartupWMClass / CFBundle stem -- it has to be
## the same name the application gives its own window class, or the desktop
## will not connect the two. The PNG defaults to `<app-id>-icon.png` and then
## `<app-id>.png` in the current directory.
##
## Decoding, resizing, PNG and ICO are pixie's and happen in this process, so
## nothing has to be installed to derive the icons. What is left are the three
## jobs that are somebody else's format: `windres` (MinGW, including
## `x86_64-w64-mingw32-windres`) compiles the `.rc` into a `.res`, `iconutil`
## turns an `.iconset` into an `.icns` on macOS, and `rcedit` stamps an icon
## into an already-built `.exe` if it is on PATH.
##
## `--prepare` only writes derived files next to the PNG:
##   <stem>.netwm   X11 `_NET_WM_ICON` blob (`staticRead` this from the app)
##   <app-id>.ico   multi-size Windows icon
##   <app-id>.rc    resource script (`1 ICON "….ico"`)
##   <app-id>.res   COFF object for `{.link: "<app-id>.res".}`
##
## Those four are build inputs, so they belong next to the source they are
## built into, and this is the half of the job that runs on a build machine.
## Without `--prepare` they are still written, and then the host OS is
## installed as well: FreeDesktop on Linux, a `.app` on macOS, `rcedit` on
## Windows.
##
## Optional flags:
##   --name <Name>             display name (default: app-id)
##   --generic-name <text>     Linux GenericName=
##   --comment <text>          Comment= / CFBundleGetInfoString
##   --categories <Cats>       Linux Categories= (default: Utility;)
##   --bundle-id <id>          macOS CFBundleIdentifier (default: org.<app-id>)
##   --out <path>              macOS bundle (default: ~/Applications/<Name>.app)

import std/[os, osproc, streams, strutils]
import pixie

# ---------------------------------------------------------------------------
# The tools this borrows from the machine, looked up once
# ---------------------------------------------------------------------------

type
  Tools = object
    ## Only what cannot be done in this process. The picture work -- decoding,
    ## resizing, PNG, ICO -- is pixie's, so nothing has to be installed for
    ## `--prepare` to work on a build machine.
    windres: string     ## MinGW resource compiler, for the Windows `.res`
    rcedit: string      ## stamps an icon into an already-built `.exe`
    iconutil: string    ## macOS, for turning an `.iconset` into an `.icns`

var tools: Tools
  ## Filled in by `detectTools` before any work starts. A global because PATH
  ## does not change while this program runs.

proc run(exe: string; args: openArray[string];
         workingDir = ""): tuple[output: string, code: int] =
  ## Every tool is run without a shell: the arguments are file names the user
  ## chose, and a shell would want them quoted differently on every platform --
  ## `windres` even builds a preprocessor command line of its own out of them.
  let p = startProcess(exe, workingDir, args, options = {poStdErrToStdOut})
  result.output = p.outputStream.readAll()   # drained before the wait
  result.code = p.waitForExit()
  p.close()

proc runOrQuit(exe: string; args: openArray[string]; workingDir = "") =
  let (outp, code) = run(exe, args, workingDir)
  if code != 0:
    stderr.write outp
    quit("command failed (" & $code & "): " & exe & " " & args.join(" "))

proc findOnPath(names: varargs[string]): string =
  for n in names:
    result = findExe(n)
    if result.len > 0: return
  result = ""

proc detectTools() =
  tools.windres = findOnPath("windres", "x86_64-w64-mingw32-windres",
                             "i686-w64-mingw32-windres", "llvm-windres")
  tools.rcedit = findOnPath("rcedit", "rcedit.exe", "rcedit-x64",
                            "rcedit-x64.exe")
  tools.iconutil = findOnPath("iconutil")

# ---------------------------------------------------------------------------
# The picture work, all of it in this process
# ---------------------------------------------------------------------------

proc loadSource(path: string): Image =
  try:
    result = readImage(path)
  except PixieError:
    quit("cannot read " & path & ": " & getCurrentExceptionMsg())
  if result.width < 1 or result.height < 1:
    quit("empty image: " & path)

proc scaled(src: Image; px: int): Image =
  ## `px` by `px`, however far that is from the source. pixie's draw halves
  ## the image while it is more than twice the target and interpolates only
  ## the last step, so 1024 reaches 16 through box filters rather than by
  ## point-sampling every 64th pixel.
  if src.width == px and src.height == px: src else: src.resize(px, px)

proc writePng(src: Image; dst: string; px: int) =
  createDir(dst.parentDir)
  try:
    src.scaled(px).writeFile(dst)
  except PixieError:
    quit("cannot write " & dst & ": " & getCurrentExceptionMsg())

proc addU16LE(s: var string; v: uint16) =
  s.add char(v and 0xff)
  s.add char((v shr 8) and 0xff)

proc addU32LE(s: var string; v: uint32) =
  s.add char(v and 0xff)
  s.add char((v shr 8) and 0xff)
  s.add char((v shr 16) and 0xff)
  s.add char((v shr 24) and 0xff)

proc writeNetWm(src: Image; dest: string) =
  ## `_NET_WM_ICON`: for each size, CARD32 width, height, then width*height
  ## pixels as 0xAARRGGBB. The app copies the blob into CARD32s as it is, so
  ## what is written here is the little-endian order the machines that read it
  ## back use. `rgba()` unpremultiplies -- pixie keeps its pixels premultiplied
  ## and the property is not.
  const sizes = [32, 64, 128]
  var total = 0
  for px in sizes: total += 8 + px * px * 4
  var blob = newStringOfCap(total)
  for px in sizes:
    let img = src.scaled(px)
    blob.addU32LE uint32(px)
    blob.addU32LE uint32(px)
    for c in img.data:
      let s = c.rgba()
      blob.addU32LE (uint32(s.a) shl 24) or (uint32(s.r) shl 16) or
                    (uint32(s.g) shl 8) or uint32(s.b)
  writeFile(dest, blob)
  echo "netwm -> ", dest

const
  IcoSizes = [16, 32, 48, 64, 128, 256]
  IcoPngFrom = 128
    ## From this size up a frame goes in as a PNG, below it as a DIB. Windows
    ## has read PNG frames since Vista and they are a fraction of the size,
    ## but the small ones are what an older shell reaches for, so those stay
    ## in the format that has always worked.

proc dibFrame(img: Image): string =
  ## A frame in the shape an `.ico` inherited from the bitmap format: a
  ## BITMAPINFOHEADER whose height counts the mask as well, the pixels bottom
  ## up as BGRA, and then the 1bpp AND mask. What draws a 32-bit frame reads
  ## the alpha channel and ignores that mask, but what does not read alpha has
  ## only the mask to go on -- so it is made to say the same thing, one bit per
  ## pixel, set where the picture is see-through.
  let
    w = img.width
    h = img.height
    maskRow = ((w + 31) div 32) * 4
  result = newStringOfCap(40 + w * h * 4 + maskRow * h)
  result.addU32LE 40'u32           # header size
  result.addU32LE uint32(w)
  result.addU32LE uint32(h * 2)    # pixels and mask
  result.addU16LE 1'u16            # planes
  result.addU16LE 32'u16           # bits per pixel
  result.addU32LE 0'u32            # BI_RGB, no compression
  result.addU32LE uint32(w * h * 4 + maskRow * h)
  result.addU32LE 0'u32            # pixels per meter, x and y
  result.addU32LE 0'u32
  result.addU32LE 0'u32            # colors used, colors important
  result.addU32LE 0'u32
  for y in countdown(h - 1, 0):
    for x in 0 ..< w:
      let c = img.data[y * w + x].rgba()
      result.add char(c.b)
      result.add char(c.g)
      result.add char(c.r)
      result.add char(c.a)
  for y in countdown(h - 1, 0):
    var row = newString(maskRow)          # the padding stays zero: opaque
    for x in 0 ..< w:
      if img.data[y * w + x].rgba().a < 128:
        # The top bit of a byte is its leftmost pixel.
        row[x div 8] = char(row[x div 8].uint8 or (0x80'u8 shr (x mod 8)))
    result.add row

proc writeIco(src: Image; dest: string) =
  ## One file holding a frame at each of `IcoSizes`. An `.ico` is a directory
  ## of independent pictures, so the small ones are not scaled from the big
  ## one at display time -- which is the whole reason to ship six of them.
  createDir(dest.parentDir)
  var frames: seq[string] = @[]
  for px in IcoSizes:
    let img = src.scaled(px)
    frames.add(
      if px >= IcoPngFrom:
        try: img.encodeImage(PngFormat)
        except PixieError: quit("cannot encode " & $px & "px frame: " &
                                getCurrentExceptionMsg())
      else: dibFrame(img))
  var ico = ""
  ico.addU16LE 0'u16                     # reserved
  ico.addU16LE 1'u16                     # 1 = icon, 2 = cursor
  ico.addU16LE uint16(IcoSizes.len)
  var offset = 6 + 16 * IcoSizes.len
  for i, px in IcoSizes:
    # 256 does not fit in the byte, and is written as 0 -- the one number the
    # format spells differently from every other.
    ico.add char(if px >= 256: 0 else: px)
    ico.add char(if px >= 256: 0 else: px)
    ico.add '\0'                         # colors in the palette: none
    ico.add '\0'                         # reserved
    ico.addU16LE 1'u16                   # planes
    ico.addU16LE 32'u16                  # bits per pixel
    ico.addU32LE uint32(frames[i].len)
    ico.addU32LE uint32(offset)
    offset += frames[i].len
  writeFile(dest, ico & frames.join())
  echo "ico -> ", dest

proc writeRes(ico, rc, res, appId: string) =
  ## All three live in one directory -- the `.rc` refers to the icon by bare
  ## name. The `.rc` is written either way: it is a source file, and a machine
  ## without a resource compiler can still hand it to one that has it.
  writeFile(rc, "1 ICON \"" & ico.extractFilename & "\"\n")
  echo "rc -> ", rc
  if tools.windres.len == 0:
    echo "windres not found; skip .res (install mingw-w64, then run again)"
    return
  # The .rc names the icon file and no directory, so windres is run *in* that
  # directory -- as the child's working directory, not by moving this process's
  # own. `-I` would do as well until a path holds a quote: windres pastes it
  # into a preprocessor command line and quotes nothing.
  runOrQuit(tools.windres,
            ["-O", "coff", rc.extractFilename, "-o", res.extractFilename],
            workingDir = ico.parentDir)
  echo "res -> ", res
  echo "  compile with: when defined(windows): {.link: \"", appId, ".res\".}"

# ---------------------------------------------------------------------------
# paths
# ---------------------------------------------------------------------------

proc sourcePng(appId, iconsArg: string): string =
  ## The source art. Named or, when it is not, looked for under the two names
  ## an application's icon tends to have -- in the current directory, because
  ## that is where the project whose icon this is has been checked out.
  if iconsArg.len > 0:
    if not fileExists(iconsArg):
      quit("no such file: " & iconsArg)
    if not iconsArg.toLowerAscii.endsWith(".png"):
      quit("need a PNG, got: " & iconsArg)
    return expandFilename(iconsArg)
  let tried = [appId & "-icon.png", appId & ".png"]
  for p in tried:
    if fileExists(p): return expandFilename(p)
  quit("no PNG given, and none of these is here: " & tried.join(", "))

proc resolveExec(arg: string): string =
  if arg.len == 0:
    quit("missing <exec> path")
  if fileExists(arg) or symlinkExists(arg):
    return expandFilename(arg)
  result = findExe(arg)
  if result.len == 0:
    quit("cannot find executable: " & arg)

proc prepareFromPng(appId, png: string; src: Image): string =
  ## Everything that is derived from the PNG, written next to it. Returns the
  ## `.ico`, which is the one an installation may still have a use for.
  let dir = png.parentDir
  writeNetWm(src, dir / (png.splitFile.name & ".netwm"))
  result = dir / (appId & ".ico")
  writeIco(src, result)
  writeRes(result, dir / (appId & ".rc"), dir / (appId & ".res"), appId)

# ---------------------------------------------------------------------------
# Linux -- FreeDesktop
# ---------------------------------------------------------------------------

proc xdgDataHome(): string =
  getEnv("XDG_DATA_HOME", getHomeDir() / ".local" / "share")

proc desktopExec(path: string): string =
  if path.find({' ', '\t', '"', '\\', '$', '`'}) >= 0:
    '"' & path.replace("\\", "\\\\").replace("\"", "\\\"") & '"'
  else:
    path

proc writeDesktop(appId, execPath, name, genericName, comment,
                  categories: string) =
  var body = "[Desktop Entry]\n"
  body.add "Type=Application\n"
  body.add "Version=1.0\n"
  body.add "Name=" & name & "\n"
  if genericName.len > 0:
    body.add "GenericName=" & genericName & "\n"
  if comment.len > 0:
    body.add "Comment=" & comment & "\n"
  body.add "Exec=" & desktopExec(execPath) & "\n"
  body.add "Icon=" & appId & "\n"
  body.add "Terminal=false\n"
  body.add "Categories=" & categories & "\n"
  body.add "StartupNotify=true\n"
  body.add "StartupWMClass=" & appId & "\n"

  let desktopPath = xdgDataHome() / "applications" / (appId & ".desktop")
  createDir(desktopPath.parentDir)
  writeFile(desktopPath, body)
  echo "desktop -> ", desktopPath, " (Exec=", execPath, ")"

proc installLinux(appId, execPath, name, genericName, comment,
                  categories: string; src: Image) =
  let icons = xdgDataHome() / "icons" / "hicolor"
  for px in [32, 48, 64, 128, 256]:
    let target = icons / ($px & "x" & $px) / "apps" / (appId & ".png")
    writePng(src, target, px)
    echo "  ", target
  writeDesktop(appId, execPath, name, genericName, comment, categories)
  # Refreshing the caches is what makes the entry show up now rather than after
  # the next login. Neither tool has to be installed, and neither failing is a
  # reason to call the installation failed -- so the output goes nowhere.
  for (exe, args) in {
      "update-desktop-database": @[xdgDataHome() / "applications"],
      "gtk-update-icon-cache": @["-f", "-t", icons]}:
    let path = findExe(exe)
    if path.len > 0: discard run(path, args)

# ---------------------------------------------------------------------------
# macOS -- .app bundle
# ---------------------------------------------------------------------------

proc xmlEscape(s: string): string =
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    else: result.add c

proc writeInfoPlist(path, name, execName, bundleId, comment: string) =
  var s = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$EXEC</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>$ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>11.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
"""
  s = s.replace("$EXEC", xmlEscape(execName))
    .replace("$ID", xmlEscape(bundleId))
    .replace("$NAME", xmlEscape(name))
  if comment.len > 0:
    s.add "\t<key>CFBundleGetInfoString</key>\n"
    s.add "\t<string>" & xmlEscape(comment) & "</string>\n"
  s.add "</dict>\n</plist>\n"
  writeFile(path, s)

proc buildIcns(src: Image; icnsPath: string) =
  let iconset = icnsPath & ".iconset"
  removeDir(iconset)
  createDir(iconset)
  # (pixel size, the name `iconutil` insists on). Every size but the smallest
  # and the largest appears twice: once as itself, once as the @2x of the size
  # below it -- the file for a retina display and the file for a plain one are
  # the same pixels under two names.
  const entries = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
  ]
  for (px, fname) in entries:
    writePng(src, iconset / fname, px)
  if tools.iconutil.len == 0:
    quit("iconutil not found (comes with Xcode / the command line tools)")
  runOrQuit(tools.iconutil, ["-c", "icns", iconset, "-o", icnsPath])
  removeDir(iconset)

proc installMacos(appId, execPath, name, comment, bundleId,
                  outArg: string; src: Image) =
  let bundlePath =
    # Made absolute without asking the file system anything: this is where the
    # bundle is about to be built, so it is the one path here that is expected
    # *not* to exist yet, and `expandFilename` would refuse it.
    if outArg.len > 0: absolutePath(expandTilde(outArg))
    else: getHomeDir() / "Applications" / (name & ".app")
  if not bundlePath.endsWith(".app"):
    quit("--out must end in .app, got: " & bundlePath)

  let contents = bundlePath / "Contents"
  let macosDir = contents / "MacOS"
  let resources = contents / "Resources"
  createDir(macosDir)
  createDir(resources)

  let destBin = macosDir / appId
  copyFile(execPath, destBin)
  inclFilePermissions(destBin, {fpUserExec, fpGroupExec, fpOthersExec})
  echo "binary -> ", destBin

  let icnsPath = resources / "AppIcon.icns"
  buildIcns(src, icnsPath)
  echo "icon -> ", icnsPath

  writeInfoPlist(contents / "Info.plist", name, appId, bundleId, comment)
  echo "plist -> ", contents / "Info.plist"
  echo "bundle -> ", bundlePath

# ---------------------------------------------------------------------------
# Windows -- PE resource + optional rcedit
# ---------------------------------------------------------------------------

proc installWindows(execPath, ico: string) =
  if tools.rcedit.len == 0:
    echo "rcedit not found; the .res next to the PNG is what `{.link:}` consumes."
    echo "  to stamp an already-built exe: install rcedit and run again."
    return
  if not fileExists(execPath):
    echo "no exe to stamp at ", execPath
    return
  runOrQuit(tools.rcedit, [execPath, "--set-icon", ico])
  echo "stamped ", execPath, " with ", ico

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

proc usage() =
  stderr.write """usage: iconbundler <app-id> <exec> [png] [options]
       iconbundler --prepare <app-id> [png] [options]

  --prepare                 only write .netwm / .ico / .rc / .res next to the PNG
  --name <Name>
  --generic-name <text>     (Linux)
  --comment <text>
  --categories <Cats>       (Linux)
  --bundle-id <id>          (macOS, default org.<app-id>)
  --out <path.app>          (macOS, default ~/Applications/<Name>.app)
"""
  quit(1)

proc main =
  var
    appId, execArg, iconsArg = ""
    name, genericName, comment = ""
    categories = "Utility;"
    bundleId, outArg = ""
    prepareOnly = false
    positional: seq[string]

  var i = 1
  template valueOf(flag: string): string =
    ## The word after a flag. A flag that ends the command line is a mistake
    ## worth a sentence; taking the next thing as a file name would not be one.
    inc i
    if i > paramCount(): quit("missing value for " & flag)
    paramStr(i)

  while i <= paramCount():
    let a = paramStr(i)
    case a
    of "--prepare": prepareOnly = true
    of "--name": name = valueOf(a)
    of "--generic-name": genericName = valueOf(a)
    of "--comment": comment = valueOf(a)
    of "--categories": categories = valueOf(a)
    of "--bundle-id": bundleId = valueOf(a)
    of "--out": outArg = valueOf(a)
    of "-h", "--help": usage()
    else:
      if a.startsWith("-"): quit("unknown option: " & a)
      positional.add a
    inc i

  if prepareOnly:
    if positional.len < 1 or positional.len > 2: usage()
    appId = positional[0]
    if positional.len == 2: iconsArg = positional[1]
  else:
    if positional.len < 2 or positional.len > 3: usage()
    appId = positional[0]
    execArg = positional[1]
    if positional.len == 3: iconsArg = positional[2]
  if name.len == 0:
    name = appId
  if bundleId.len == 0:
    bundleId = "org." & appId

  detectTools()
  let png = sourcePng(appId, iconsArg)
  let src = loadSource(png)
  let ico = prepareFromPng(appId, png, src)
  if not prepareOnly:
    let execPath = resolveExec(execArg)
    case hostOS
    of "linux":
      installLinux(appId, execPath, name, genericName, comment, categories,
                   src)
    of "macosx":
      installMacos(appId, execPath, name, comment, bundleId, outArg, src)
    of "windows":
      installWindows(execPath, ico)
    else:
      quit("unsupported host OS: " & hostOS)
  echo "done."

main()
