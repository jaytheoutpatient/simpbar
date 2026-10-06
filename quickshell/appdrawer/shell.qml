import QtQuick
import Quickshell
import Quickshell.Io

// Entry point.
//
//   Run the daemon:      qs -c appdrawer
//   Toggle the drawer:   qs -c appdrawer ipc call drawer toggle
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
