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
## Image conversions call ImageMagick (`magick`, else `convert` off Windows).
## If that is missing, a `python3` that can `import PIL` is accepted. Windows
## `.res` needs `windres` (MinGW, including `x86_64-w64-mingw32-windres`).
## macOS `.icns` needs `sips` and `iconutil`. Stamping a built `.exe` uses
## `rcedit` when it is on PATH.
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

import std/[os, osproc, streams, strutils, strformat, tempfiles]

# ---------------------------------------------------------------------------
# The tools this borrows from the machine, looked up once
# ---------------------------------------------------------------------------

type
  Tools = object
    magick: string      ## ImageMagick: the first choice for every conversion
    python: string      ## a python3 that has Pillow: the fallback for all of them
    windres: string     ## MinGW resource compiler, for the Windows `.res`
    rcedit: string      ## stamps an icon into an already-built `.exe`
    sips, iconutil: string  ## macOS, for the `.icns`

var tools: Tools
  ## Filled in by `detectTools` before any work starts. A global because PATH
  ## does not change while this program runs, and because a conversion would
  ## otherwise scan it again for every single size.

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

proc pythonWithPillow(): string =
  ## A python3 is only of use here if it can `import PIL`. One that cannot is
  ## no better than no python at all, and finding that out now is what turns a
  ## traceback halfway through into a sentence before anything is written.
  for n in ["python3", "python"]:
    let exe = findExe(n)
    if exe.len > 0 and run(exe, ["-c", "import PIL"]).code == 0:
      return exe
  result = ""

proc detectTools() =
  # ImageMagick 7 is `magick`. IM6 is `convert`, but on Windows that name is
  # the filesystem converter -- never use it there.
  tools.magick =
    when defined(windows): findOnPath("magick")
    else: findOnPath("magick", "convert")
  if tools.magick.len == 0:
    tools.python = pythonWithPillow()
  tools.windres = findOnPath("windres", "x86_64-w64-mingw32-windres",
                             "i686-w64-mingw32-windres", "llvm-windres")
  tools.rcedit = findOnPath("rcedit", "rcedit.exe", "rcedit-x64",
                            "rcedit-x64.exe")
  tools.sips = findOnPath("sips")
  tools.iconutil = findOnPath("iconutil")

proc requireImageTool() =
  if tools.magick.len == 0 and tools.python.len == 0:
    quit("need ImageMagick (`magick`) or a python3 that can `import PIL`")

template withTempDir(dir, body: untyped) =
  ## `dir` is the temporary directory inside `body`, and is gone after it.
  block:
    let dir = createTempDir("iconbundler_", "")
    try:
      body
    finally:
      removeDir(dir)

# ---------------------------------------------------------------------------
# PNG conversions (ImageMagick, else Pillow)
# ---------------------------------------------------------------------------

proc pyStr(s: string): string =
  ## `s` as a Python string literal. Escaped rather than the `r'''…'''` that
  ## suggests itself: a raw literal cannot hold a run of three quotes and
  ## cannot end in a backslash, and a path is free to do both.
  result = newStringOfCap(s.len + 2)
  result.add '\''
  for c in s:
    if c in {'\\', '\''}: result.add '\\'
    result.add c
  result.add '\''

proc runPython(script: string) =
  ## The script goes through a file rather than `python -c`: quoting a
  ## multi-line program differs from shell to shell, a file name does not.
  if tools.python.len == 0: quit("python3 with Pillow not found")
  let (f, path) = createTempFile("iconbundler_", ".py")
  try:
    f.write script
  finally:
    f.close()
  try:
    runOrQuit(tools.python, [path])
  finally:
    removeFile(path)

proc pillowResized(src: string; px: int): string =
  ## The head every Pillow script here shares: the source, resized to `px`.
  &"""
from PIL import Image
im = Image.open({pyStr(src)}).convert('RGBA')
im = im.resize(({px}, {px}), Image.Resampling.LANCZOS)
"""

proc resizePng(src, dst: string; px: int) =
  createDir(dst.parentDir)
  if tools.magick.len > 0:
    runOrQuit(tools.magick,
              [src, "-alpha", "on", "-resize", &"{px}x{px}!", dst])
  else:
    runPython(pillowResized(src, px) & &"im.save({pyStr(dst)})" & "\n")

proc writeRgbaRaw(src, dst: string; px: int) =
  ## `px`×`px` raw RGBA (4 bytes/pixel, no header).
  if tools.magick.len > 0:
    runOrQuit(tools.magick, [src, "-alpha", "on", "-resize", &"{px}x{px}!",
                             "-depth", "8", "rgba:" & dst])
  else:
    runPython(pillowResized(src, px) &
              &"open({pyStr(dst)}, 'wb').write(im.tobytes())" & "\n")

proc addU32LE(s: var string; v: uint32) =
  s.add char(v and 0xff)
  s.add char((v shr 8) and 0xff)
  s.add char((v shr 16) and 0xff)
  s.add char((v shr 24) and 0xff)

proc writeNetWm(png, dest: string) =
  ## `_NET_WM_ICON`: for each size, CARD32 width, height, then width*height
  ## pixels as 0xAARRGGBB. ImageMagick and Pillow both hand over RGBA. The app
  ## copies the blob into CARD32s as it is, so what is written here is the
  ## little-endian order the machines that read it back use.
  const sizes = [32, 64, 128]
  var total = 0
  for px in sizes: total += 8 + px * px * 4
  var blob = newStringOfCap(total)
  withTempDir dir:
    for px in sizes:
      let rawPath = dir / ($px & ".rgba")
      writeRgbaRaw(png, rawPath, px)
      let raw = readFile(rawPath)
      let want = px * px * 4
      if raw.len != want:
        quit(&"expected {want} RGBA bytes at {px}px, got {raw.len}")
      blob.addU32LE uint32(px)
      blob.addU32LE uint32(px)
      var i = 0
      while i < raw.len:
        blob.addU32LE (uint32(raw[i+3].uint8) shl 24) or
                      (uint32(raw[i].uint8) shl 16) or
                      (uint32(raw[i+1].uint8) shl 8) or
                       uint32(raw[i+2].uint8)
        inc i, 4
  writeFile(dest, blob)
  echo "netwm -> ", dest

proc writeIco(png, dest: string) =
  ## One file holding 16, 32, 48, 64, 128 and 256 pixel frames; both tools are
  ## told that set, only in their own spelling of it.
  createDir(dest.parentDir)
  if tools.magick.len > 0:
    runOrQuit(tools.magick, [png, "-background", "none", "-define",
                             "icon:auto-resize=256,128,64,48,32,16", dest])
  else:
    runPython(&"""
from PIL import Image
src = Image.open({pyStr(png)}).convert('RGBA')
sizes = [16, 32, 48, 64, 128, 256]
imgs = [src.resize((s, s), Image.Resampling.LANCZOS) for s in sizes]
imgs[-1].save({pyStr(dest)}, format='ICO', sizes=[(s, s) for s in sizes],
              append_images=imgs[:-1])
""")
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

proc prepareFromPng(appId, png: string): string =
  ## Everything that is derived from the PNG, written next to it. Returns the
  ## `.ico`, which is the one an installation may still have a use for.
  requireImageTool()
  let dir = png.parentDir
  writeNetWm(png, dir / (png.splitFile.name & ".netwm"))
  result = dir / (appId & ".ico")
  writeIco(png, result)
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

proc installLinux(appId, execPath, png, name, genericName, comment,
                  categories: string) =
  let icons = xdgDataHome() / "icons" / "hicolor"
  for px in [32, 48, 64, 128, 256]:
    let target = icons / ($px & "x" & $px) / "apps" / (appId & ".png")
    resizePng(png, target, px)
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

proc buildIcns(pngPath, icnsPath: string) =
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
    let outPng = iconset / fname
    if tools.sips.len > 0:
      runOrQuit(tools.sips, ["-z", $px, $px, pngPath, "--out", outPng])
    else:
      resizePng(pngPath, outPng, px)
  if tools.iconutil.len == 0:
    quit("iconutil not found (comes with Xcode / the command line tools)")
  runOrQuit(tools.iconutil, ["-c", "icns", iconset, "-o", icnsPath])
  removeDir(iconset)

proc installMacos(appId, execPath, png, name, comment, bundleId,
                  outArg: string) =
  let bundlePath =
    if outArg.len > 0: expandFilename(outArg)
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
  buildIcns(png, icnsPath)
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
  let ico = prepareFromPng(appId, png)
  if not prepareOnly:
    let execPath = resolveExec(execArg)
    case hostOS
    of "linux":
      installLinux(appId, execPath, png, name, genericName, comment, categories)
    of "macosx":
      installMacos(appId, execPath, png, name, comment, bundleId, outArg)
    of "windows":
      installWindows(execPath, ico)
    else:
      quit("unsupported host OS: " & hostOS)
  echo "done."

main()
