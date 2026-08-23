# Protocol XML

`wlr-layer-shell-unstable-v1.xml` is a wlroots protocol extension, not part
of upstream `wayland-protocols`, so it isn't installed system-wide on most
distros the way `xdg-shell.xml` is. Fetch it once:

```sh
curl -o wlr-layer-shell-unstable-v1.xml \
  https://gitlab.freedesktop.org/wlroots/wlr-protocols/-/raw/master/unstable/wlr-layer-shell-unstable-v1/wlr-layer-shell-unstable-v1.xml
```

Place the resulting file in this directory (`protocols/`) — `build.zig`
already points `scanner.addCustomProtocol` at it.

If you'd rather not depend on a live URL, most distros ship it as a package:

- Arch: `wlr-protocols` (installs to `/usr/share/wlr-protocols/...`)
- Debian/Ubuntu: often bundled with `wayland-protocols` or available via the
  `wlroots` source tree under `protocol/`

Either way, just copy the XML file into this folder with the exact name
above and `zig build` will pick it up.
