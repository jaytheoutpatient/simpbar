import QtQuick
import Quickshell
import Quickshell.Io

// Entry point.
//
//   Run the daemon:      qs -c appdrawer
//   Toggle the drawer:   qs -c appdrawer ipc call drawer toggle
//   Open wallpapers:     qs -c appdrawer ipc call drawer wallpapers
//
// The toggle goes through IPC rather than Quickshell.GlobalShortcut because
// GlobalShortcut needs a Hyprland `global` bind, and that dispatcher does not
// exist in Hyprland 0.56.2 (verified against the binary's dispatcher table).
// A plain `exec` bind that calls the IPC handler works on this version.
ShellRoot {
    IpcHandler {
        target: "drawer"

        function toggle() {
            drawer.toggle()
        }

        function open() {
            drawer.openDrawer()
        }

        function close() {
            drawer.closeDrawer()
        }

        // Open straight onto a tab, skipping the Apps grid. This is what the
        // bar's wallpaper button calls (`appdrawer wallpapers`), so the picker
        // is the first thing on screen rather than something you tab across to.
        function wallpapers() {
            drawer.openTab("wallpapers")
        }

        function apps() {
            drawer.openTab("apps")
        }

        // Apply a random wallpaper with the drawer staying shut. Note there is
        // deliberately no `setWallpaper(path)`: Quickshell's IPC cannot marshal
        // a string argument across the boundary, and `simpbar-wallpaper set <img>`
        // is a better entry point for that anyway -- it owns the swaybg swap,
        // the matugen run and the state file, and needs no daemon running.
        function randomWallpaper() {
            WallpaperModel.random()
        }

        // Fetch today's Bing wallpaper (download + apply), or a random one from
        // wallhaven.cc. Exposed over IPC so a keybind can do in one call what
        // the footer buttons do with a click.
        function fetchBing() {
            WallpaperModel.fetchBing()
        }

        function randomOnlineWallpaper() {
            WallpaperModel.randomOnline()
        }

        // Open (or close) the Wallhaven options popup. No keyboard equivalent
        // exists today; this is also how the popup is verified over IPC.
        function openOptions() {
            drawer.toggleOptions()
        }

        // Switches the wallpapers-tab search box between the local folder and
        // wallhaven.cc. Takes no argument, so it works over IPC; the box's own
        // text is the query once Enter sends it.
        function toggleSearchMode() {
            drawer.toggleSearchMode()
        }

        // Delegates to Drawer so the Theme/Icons/AppModel singletons are
        // resolved in a scope where they actually exist: they are registered in
        // this directory's synthesised qmldir, but shell.qml does not import
        // that module, so referencing them here throws a ReferenceError.
        function debug() {
            drawer.debugState()
        }
    }

    Drawer {
        id: drawer
        // Start unmapped: an invisible full-screen layer surface would otherwise
        // swallow every click on the desktop and hold the keyboard grab.
        visible: false
    }
}
