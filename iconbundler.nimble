# Package

version       = "0.1.0"
author        = "Araq"
description   = "One PNG in, every icon artifact a desktop application ships out: _NET_WM_ICON, .ico/.rc/.res, hicolor sizes, .desktop entry, .icns and a macOS .app bundle."
license       = "MIT"
srcDir        = "src"
bin           = @["iconbundler"]


# Dependencies

requires "nim >= 2.0.0"

task test, "Runs the test suite":
  exec "nim c -r tests/preparetest.nim"
