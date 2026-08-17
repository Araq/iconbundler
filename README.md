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

Resizing is done by **ImageMagick** (`magick`, or `convert` off Windows) and,
when that is missing, by a **python3 that can `import PIL`** -- which is
checked for at the start, so a python without Pillow is reported as a sentence
rather than as a traceback halfway through. One of the two is required;
everything else is only needed for the platform that uses it:

| | |
|---|---|
| `windres` | the `.res`. MinGW, including `x86_64-w64-mingw32-windres` -- a cross build on Linux counts |
| `sips`, `iconutil` | the macOS `.icns`; both come with the Xcode command line tools |
| `rcedit` | stamping a built `.exe`; optional, and the `.res` is the better path anyway |

A missing `windres` is a skipped `.res` and a sentence saying so, not a
failure: the `.rc` is still written, and another machine can compile it.

Every tool is run without a shell, so a path with a space, a quote or a dollar
sign in it is passed on exactly as it is.

## Tests

```sh
nimble test
```

Derives the artifacts from a 16x16 PNG the test carries itself and checks their
shape -- the length and headers the systems reading them require. It skips
itself, rather than failing, on a machine with neither image tool.
