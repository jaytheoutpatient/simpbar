pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Theme tokens.
//
// Colours come from matugen's generated file -- the same source simpbar's bar
// already follows -- so the drawer and the bar repaint together when the
// wallpaper changes. JsonAdapter maps each declared property to a JSON key of
// the same name, so these are live bindings rather than a parsed blob.
//
// Defaults are the values matugen currently generates, so a missing or
// malformed file degrades to the correct palette instead of an unstyled or
// invisible window.
Singleton {
    id: root

    FileView {
        id: view
        // Quickshell.env("HOME") rather than a literal path: the installer
        // drops this config into every user's ~/.config/quickshell, so a
        // hardcoded home directory would point at the wrong user's matugen
        // output (or nothing at all) on every install but the developer's.
        path: Quickshell.env("HOME") + "/.config/simpbar/matugen.json"
        // matugen rewrites this file on wallpaper change.
        watchChanges: true
        blockLoading: true
        onFileChanged: reload()

        JsonAdapter {
            property string bg_color: "#0a0f14"
            property string text_color: "#dee3eb"
            property string border_color: "#c5cd71"
            property string hover_color: "#454b00"
            property string popup_bg_color: "#1b2026"
            property string popup_hover_color: "#454b00"
            property string popup_separator_color: "#3f4852"
            property string popup_disabled_color: "#bec7d5"
        }
    }

    // Pull the adapter's values out into plain properties so the rest of the
    // config binds to one stable name per colour.
    readonly property color window: view.adapter.bg_color
    readonly property color text: view.adapter.text_color
    readonly property color accent: view.adapter.border_color
    readonly property color bg: view.adapter.popup_bg_color
    readonly property color hover: view.adapter.popup_hover_color
    readonly property color separator: view.adapter.popup_separator_color
    readonly property color dim: view.adapter.popup_disabled_color

    readonly property bool themeLoaded: view.loaded

    // Metrics. barHeight must match simpbar's appearance.bar_height so the panel
    // sits flush above the bar instead of overlapping or leaving a gap.
    readonly property int barHeight: 25
    readonly property int radius: 18
    readonly property int iconSize: 40
    readonly property int tileWidth: 100
    readonly property int tileHeight: 88
}