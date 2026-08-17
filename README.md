# iconbundler

One PNG in, every icon artifact a desktop application is expected to ship out.

A program that wants an icon in the taskbar, in the launcher, in the window
list and on the dock needs the same picture in half a dozen formats, each with
its own tool and its own filename convention. `iconbundler` derives all of them
from a single PNG, using whatever is already installed on the machine.

```sh
nimble install iconbundler
iconbundler --prepare focim focim-icon.png
```

## What it makes

`--prepare` writes the four **build inputs** next to the PNG, because that is
where the source they get built into lives:

| | |
|---|---|
| `<stem>.netwm` | X11 `_NET_WM_ICON` blob -- `staticRead` it and hand it to the window |
| `<app-id>.ico` | Windows icon, 16 to 256 pixels in one file |
| `<app-id>.rc` | resource script, `1 ICON "….ico"` |
| `<app-id>.res` | the compiled COFF object, for `{.link: "<app-id>.res".}` |

Without `--prepare` it writes those as well and then **installs** for the host
system it runs on:

- **Linux** -- `hicolor` PNGs in 32 to 256 pixels under `XDG_DATA_HOME`, a
  FreeDesktop `.desktop` entry, and a refresh of the desktop and icon caches.
- **macOS** -- an `AppIcon.icns` built through an `.iconset`, an `Info.plist`,
  and a `<Name>.app` bundle in `~/Applications` with the binary copied in.
- **Windows** -- the icon stamped into an already-built `.exe` with `rcedit`,
  for when rebuilding with the `.res` is not the point.

```sh
iconbundler focim ./focim focim-icon.png \
  --generic-name "Text Editor" --comment "Focussed Nim Editor" \
  --categories "Development;TextEditor;"
```

`app-id` is the icon name, the `StartupWMClass` and the bundle stem all at
once. It has to be the same name the application gives its own window class,
or the desktop has no way to connect a running window to the entry that
launched it. The PNG argument may be left out, and then `<app-id>-icon.png`
and `<app-id>.png` are looked for in the current directory.

| flag | |
|---|---|
| `--prepare` | only write the build inputs, install nothing |
| `--name <Name>` | display name (default: the app-id) |
| `--generic-name <text>` | Linux `GenericName=` |
| `--comment <text>` | `Comment=` / `CFBundleGetInfoString` |
| `--categories <Cats>` | Linux `Categories=` (default: `Utility;`) |
| `--bundle-id <id>` | macOS `CFBundleIdentifier` (default: `org.<app-id>`) |
| `--out <path.app>` | macOS bundle path (default: `~/Applications/<Name>.app`) |

## What it needs installed

Nothing, to derive the icons. Decoding the PNG, resizing it and writing the
PNG and ICO frames is [pixie](https://github.com/treeform/pixie), which is
pure Nim and comes in with the package -- so `--prepare` works on a build
machine that has a Nim compiler and not one thing more.

Downscaling goes through pixie's `resize`, which halves the image while it is
more than twice the target and interpolates only the last step. A 1024 pixel
source reaches 16 pixels through box filters rather than by point-sampling
every 64th pixel, and lands within about 1% of what ImageMagick's Lanczos
makes of it.

What is left is the work in somebody else's format, each needed only by the
platform that asks for it:

| | |
|---|---|
| `windres` | the `.res`. MinGW, including `x86_64-w64-mingw32-windres` -- a cross build on Linux counts |
| `iconutil` | the macOS `.icns`; comes with the Xcode command line tools |
| `rcedit` | stamping a built `.exe`; optional, and the `.res` is the better path anyway |

A missing `windres` is a skipped `.res` and a sentence saying so, not a
failure: the `.rc` is still written, and another machine can compile it.

Those three are run without a shell, so a path with a space, a quote or a
dollar sign in it is passed on exactly as it is.

## The .ico

An `.ico` is a directory of independent pictures, not one picture the shell
scales -- which is the whole point of shipping six of them. The frames are
written the way Windows expects to find them: 16, 32, 48 and 64 as 32-bit
BGRA bitmaps with the 1bpp mask the format still wants after it, 128 and 256
as PNG, which Windows has read since Vista and which keeps the file a third
of the size it would otherwise be.

## Tests

```sh
nimble test
```

Derives the artifacts from a 16x16 PNG the test carries itself and checks their
shape -- the length and headers the systems reading them require, and that
each `.ico` frame is in the format its size is supposed to be in.
