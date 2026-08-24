# simpbar — a waybar-alike, in Zig

Minimal scaffold: connects to Wayland, opens a `wlr-layer-shell` surface
anchored to the top edge, reserves screen space for it, and paints it a
solid color via `wl_shm`. No text yet, no modules yet — this is the
"hello, layer-shell" milestone described earlier.

## Setup

1. **Get the layer-shell protocol XML** — see `protocols/README.md`.

2. **Pin the zig-wayland dependency:**

   ```sh
   zig fetch --save git+https://codeberg.org/ifreund/zig-wayland#main
   ```

   This fills in the `.hash` field in `build.zig.zon`. (I left it blank
   since I don't have network access in this sandbox — you need to run this
   from a machine that does.)

3. **Build and run** (from a Wayland session running a wlroots-based
   compositor — Sway, Hyprland, River, etc.; layer-shell isn't supported by
   every compositor):

   ```sh
   zig build run
   ```

   You should see a ~30px dark strip pinned to the top of your screen,
   reserving space so other windows tile below it.

## Known rough edges to expect

I wrote this without being able to compile it here, so budget time for:

- **API drift.** `zig-wayland`'s Zig-facing API (error unions on requests,
  exact `bind`/`getRegistry` signatures) has changed across Zig versions.
  If something doesn't match, check the examples in the `zig-wayland` repo
  itself (`example/` directory) against whatever commit `zig fetch` pinned.
- **`Scanner.addCSource`** — some zig-wayland versions need this, some
  don't, some name it differently. If `build.zig` errors here, check the
  `Scanner` struct in the fetched dependency's source for the current name,
  or just delete the line — it's a no-op shim in most versions.
- **`zwlr` naming.** The scanner generates a module namespace derived from
  the protocol's XML; I'm assuming it lands at `wayland.client.zwlr` per
  convention (matching `wl` for core protocols), but double check the
  generated output if the import fails to resolve — you can `zig build`
  with a stray `@compileLog` to inspect what's actually in the module.

## Where this goes next

Per the build order from before:

1. ✅ Blank bar on screen (this scaffold)
2. Text rendering — pull in FreeType via `linkSystemLibrary("freetype2")` +
   a C interop `@cImport`, or write a minimal bitmap-font rasterizer to
   avoid the C dependency entirely
3. Clock module — `std.time` + a `timerfd` merged into the poll loop
   alongside the Wayland display fd
4. Left/center/right module layout + compositing into the shm buffer
5. `custom/*` modules — spawn via `std.process.Child`, parse stdout
6. System modules — battery (`/sys/class/power_supply`), network, etc., all
   plain file/syscall reads

The event loop is the main structural thing to fix before adding modules:
right now `main()` just calls `display.dispatch()` in a blocking loop. To
add timers and subprocess pipes, you'll want to switch to `std.posix.poll`
(or `libxev`) watching multiple fds: the Wayland display fd
(`display.getFd()`... check the current zig-wayland API for the exact
accessor), a `timerfd_create` per periodic module, and a pipe fd per
running `custom/*` script.
