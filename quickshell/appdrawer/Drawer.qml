import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// The drawer.
//
// Sits directly above the bar as a real layer-shell surface (anchored to the
// bottom, margin = bar height), so it overlays every window instead of being
// tiled, and grabs the keyboard exclusively while open so the search box
// receives real key events.
PanelWindow {
    id: win

    // Screen-wide surface. Being full-height is what makes click-anywhere-to-
    // dismiss work: the transparent area above the drawer is still ours, so a
    // click outside it hits this surface instead of the wallpaper behind.
    anchors {
        top: true
        left: true
        right: true
    }
    implicitHeight: screen.height
    color: "transparent"
    focusable: true

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "appdrawer"
    // Exclusive while open: the drawer owns the keyboard, which the search box
    // needs. None while closed so the terminal keeps its keyboard.
    WlrLayershell.keyboardFocus: win.open ? WlrKeyboardFocus.Exclusive
                                         : WlrKeyboardFocus.None

    property bool open: false
    property string powerOpen: ""

    // Which tab the body shows. Settable from outside via `appdrawer
    // wallpapers`, which is how the bar's wallpaper button lands straight here
    // -- so it is a plain string, not something inferred from the search box.
    property string tab: "apps"
    readonly property var tabs: [
        { id: "apps", label: "Apps" },
        { id: "wallpapers", label: "Wallpapers" }
    ]
    readonly property bool showingWallpapers: win.tab === "wallpapers"

    // Session actions. loginctl is used rather than systemctl because
    // systemd-logind is what arbitrates suspend against inhibitors; calling
    // systemctl suspend from a shell can return before the machine sleeps,
    // which reads as a no-op to the user.
    readonly property var powerActions: [
        { label: "Lock",     cmd: ["loginctl", "lock-session"] },
        { label: "Suspend",  cmd: ["loginctl", "suspend"] },
        // Hyprland 0.56 wraps `hyprctl dispatch` in a Lua `return`, so the plain
        // two-word form is a Lua syntax error. Its argument has to be a Lua
        // dispatcher expression, hence the single argv entry below. Same form as
        // the logout bind in the user's own hyprland.lua.
        { label: "Log out",  cmd: ["hyprctl", "dispatch", "hl.dsp.exit()"] },
        { label: "Restart",  cmd: ["systemctl", "reboot"] },
        { label: "Power off", cmd: ["systemctl", "poweroff"] }
    ]

    // Slide progress: 0 = hidden below the screen edge, 1 = presented.
    // Written from onOpenChanged rather than bound to `open`, because Behavior
    // cannot animate a readonly property.
    property real t: 0
    onOpenChanged: t = open ? 1 : 0
    Behavior on t {
        NumberAnimation {
            duration: 190
            easing.type: Easing.OutCubic
        }
    }

    readonly property int cols: 7
    readonly property int gridW: Theme.tileWidth * win.cols
    readonly property int gridH: 292
    readonly property int padX: 22
    readonly property int padY: 16
    readonly property int sidebarW: 168
    readonly property int bodyH: win.gridH
    // +42 for the tab strip between the search box and the body.
    readonly property int panelH: win.padY * 2 + 46 + 42 + win.bodyH + 30

    function toggle() {
        if (win.open) {
            closeDrawer()
        } else {
            openDrawer()
        }
    }

    // The search field's text and the model's query are two separate stores, and
    // the only binding between them runs TextInput -> query. Clearing the query
    // alone therefore leaves stale text sitting in the box, and the next
    // keystroke is appended to it, so successive searches silently concatenate
    // ("firefox" then "gpu" becomes "firefoxgpu"). Always go through here.
    //
    // Both models are cleared, not just the visible one: switching tabs and back
    // would otherwise restore a filter the user forgot they typed.
    function resetSearch() {
        AppModel.query = ""
        WallpaperModel.query = ""
        search.text = ""
    }

    // The tab's own model, so the search box and Enter do not branch on the tab
    // at every call site.
    readonly property var activeModel: win.showingWallpapers ? WallpaperModel
                                                             : AppModel

    function setTab(id) {
        if (win.tab === id)
            return
        win.tab = id
        win.powerOpen = ""
        resetSearch()
        // Refresh on entry: the wallpaper list and the current wallpaper can
        // both change underneath us (a random pick from a terminal, a file added
        // in a file manager), and a stale "current" badge would point at an
        // image that is no longer on screen.
        if (id === "wallpapers") {
            WallpaperModel.refresh()
            WallpaperModel.refreshCurrent()
        }
        search.forceActiveFocus()
    }

    function openDrawer() {
        resetSearch()
        win.open = true
        win.visible = true
        search.forceActiveFocus()
    }

    // Land straight on one tab. This is how the bar's wallpaper button reaches
    // the picker without going through the Apps grid first.
    function openTab(id) {
        win.setTab(id)
        win.openDrawer()
        if (id === "wallpapers") {
            WallpaperModel.refresh()
            WallpaperModel.refreshCurrent()
        }
    }

    function closeDrawer() {
        win.open = false
        win.powerOpen = ""
        resetSearch()
        // Unmap once the slide-out finishes, otherwise the full-screen
        // invisible surface would keep swallowing clicks and the keyboard.
        collapseTimer.restart()
    }

    Timer {
        id: collapseTimer
        interval: 200
        onTriggered: if (!win.open) win.visible = false
    }

    // Dim the desktop behind the drawer.
    Rectangle {
        anchors.fill: parent
        color: "#000000"
        opacity: win.t * 0.35
        visible: opacity > 0.01
    }

    // Click anywhere outside the drawer to dismiss.
    MouseArea {
        anchors.fill: parent
        onClicked: win.closeDrawer()
    }

    Rectangle {
        id: panel

        width: parent.width
        height: win.panelH
        // Rest on top of the bar rather than the screen bottom: the bar is
        // layer Top and we are Overlay, so a panel flush with the screen edge
        // would cover it. Slide up from below that resting position.
        y: (parent.height - Theme.barHeight - height) + (1 - win.t) * (parent.height + height)
        color: Theme.bg
        radius: Theme.radius
        border.width: 1
        border.color: Theme.separator
        clip: true

        // ---- search -------------------------------------------------------
        Item {
            id: searchRow
            anchors.top: parent.top
            anchors.topMargin: win.padY
            anchors.horizontalCenter: parent.horizontalCenter
            width: 520
            height: 46

            Rectangle {
                anchors.fill: parent
                radius: 14
                color: Theme.window
                border.width: 1
                border.color: search.activeFocus ? Theme.accent : Theme.separator

                TextInput {
                    id: search
                    anchors.fill: parent
                    anchors.leftMargin: 16
                    anchors.rightMargin: 16
                    verticalAlignment: TextInput.AlignVCenter
                    color: Theme.text
                    font.pixelSize: 16
                    selectByMouse: true
                    clip: true
                    focus: true

                    // Rewritten on every keystroke so the active tab's grid
                    // updates live.
                    onTextChanged: win.activeModel.query = text
                    Keys.onEscapePressed: win.closeDrawer()
                    Keys.onReturnPressed: {
                        // Enter acts on whatever the visible tab is: launch the
                        // first app, or apply the first wallpaper match. The
                        // drawer stays open for the wallpaper case so the
                        // recolour is visible.
                        if (win.showingWallpapers) {
                            if (WallpaperModel.visibleItems.length > 0)
                                WallpaperModel.apply(
                                    WallpaperModel.visibleItems[0].path);
                        } else if (AppModel.visibleApps.length > 0) {
                            AppModel.launch(AppModel.visibleApps[0]);
                            win.closeDrawer();
                        }
                    }
                }

                Text {
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    leftPadding: 16
                    visible: search.text.length === 0
                    text: win.showingWallpapers ? "Search wallpapers"
                                                : "Search apps"
                    color: Theme.dim
                    font.pixelSize: 16
                }
            }
        }

        // ---- tab strip -----------------------------------------------------
        Row {
            id: tabStrip
            anchors.top: searchRow.bottom
            anchors.topMargin: 10
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 6

            Repeater {
                model: win.tabs

                delegate: Rectangle {
                    required property var modelData

                    width: tabLabel.implicitWidth + 26
                    height: 28
                    radius: 9
                    color: win.tab === modelData.id ? Theme.accent
                                                    : (tabHover.hovered ? Theme.hover
                                                                        : "transparent")
                    opacity: win.tab === modelData.id ? 0.22 : 1.0
                    border.width: 1
                    border.color: win.tab === modelData.id ? Theme.accent
                                                            : Theme.separator
                    Behavior on color {
                        ColorAnimation { duration: 80 }
                    }

                    Text {
                        id: tabLabel
                        anchors.centerIn: parent
                        text: modelData.label
                        color: win.tab === modelData.id ? Theme.accent : Theme.text
                        font.pixelSize: 13
                    }

                    HoverHandler { id: tabHover }
                    TapHandler {
                        onTapped: win.setTab(modelData.id)
                    }
                }
            }
        }

        // ---- body: categories + grid --------------------------------------
        Item {
            id: body
            anchors.top: tabStrip.bottom
            anchors.topMargin: 10
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: footer.top
            anchors.leftMargin: win.padX
            anchors.rightMargin: win.padX

            // category sidebar
            Item {
                id: side
                // No categories apply to wallpapers, so the whole column is
                // dropped and the grid below takes the full width.
                visible: !win.showingWallpapers
                width: win.showingWallpapers ? 0 : win.sidebarW
                anchors.top: parent.top
                anchors.bottom: parent.bottom

                ListView {
                    id: catList
                    anchors.fill: parent
                    spacing: 2
                    clip: true
                    interactive: win.open

                    model: AppModel.categories

                    delegate: Item {
                        required property string modelData
                        required property int index

                        width: catList.width
                        height: 32

                        Rectangle {
                            anchors.fill: parent
                            radius: 9
                            color: AppModel.category === modelData ? Theme.accent
                                                                  : (catHover.hovered ? Theme.hover : "transparent")
                            opacity: AppModel.category === modelData ? 0.20 : 1.0
                            Behavior on color { ColorAnimation { duration: 80 } }
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            x: 12
                            width: parent.width - 20
                            text: AppModel.labelFor(modelData)
                            color: AppModel.category === modelData ? Theme.accent : Theme.text
                            font.pixelSize: 13
                            elide: Text.ElideRight
                        }

                        // count badge
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.right: parent.right
                            anchors.rightMargin: 12
                            text: {
                                if (modelData === "All")
                                    return String(AppModel.apps.length);
                                if (modelData === "Favourites")
                                    return String(AppModel.favIds.length);
                                var n = 0;
                                for (var i = 0; i < AppModel.apps.length; i++)
                                    if (AppModel.apps[i].cat === modelData) n++;
                                return String(n);
                            }
                            color: Theme.dim
                            font.pixelSize: 11
                        }

                        HoverHandler { id: catHover }
                        TapHandler {
                            onTapped: {
                                AppModel.category = modelData;
                                win.resetSearch();
                                search.forceActiveFocus();
                            }
                        }
                    }
                }
            }

            // app grid
            GridView {
                id: grid
                anchors.left: win.showingWallpapers ? parent.left : side.right
                anchors.leftMargin: win.showingWallpapers ? 0 : 18
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom

                clip: true
                interactive: win.open
                model: AppModel.visibleApps
                cellWidth: Theme.tileWidth
                cellHeight: Theme.tileHeight
                boundsBehavior: Flickable.StopAtBounds

                delegate: AppTile {
                    required property var modelData
                    app: modelData
                    width: Theme.tileWidth
                    height: Theme.tileHeight
                    onTriggered: {
                        AppModel.launch(app);
                        win.closeDrawer();
                    }
                    onToggleFavourite: AppModel.toggleFav(app.id)
                }

                Text {
                    anchors.centerIn: parent
                    visible: grid.count === 0
                    text: AppModel.ready ? "No apps match" : "Loading apps…"
                    color: Theme.dim
                    font.pixelSize: 15
                }
            }

            // ---- wallpaper grid --------------------------------------------
            // A sibling of the app grid rather than a swap inside it: the two
            // have unrelated models and delegate types, and keeping them as
            // separate views means an app scroll position survives a trip to
            // the wallpapers tab and back.
            GridView {
                id: wpGrid
                anchors.fill: parent
                visible: win.showingWallpapers
                clip: true
                interactive: win.open
                model: WallpaperModel.visibleItems
                cellWidth: 156
                cellHeight: 132
                boundsBehavior: Flickable.StopAtBounds

                delegate: WallpaperTile {
                    required property var modelData
                    wp: modelData
                    active: WallpaperModel.isCurrent(modelData.path)
                    onPicked: (path) => WallpaperModel.apply(path)
                }

                Text {
                    anchors.centerIn: parent
                    visible: wpGrid.count === 0
                    text: WallpaperModel.ready
                          ? (WallpaperModel.items.length === 0
                             ? "No wallpapers found in ~/Pictures/Wallpaper"
                             : "No wallpapers match")
                          : "Loading wallpapers…"
                    color: Theme.dim
                    font.pixelSize: 15
                }
            }
        }

        // ---- footer --------------------------------------------------------
        Item {
            id: footer
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: win.padX
            anchors.rightMargin: win.padX
            height: 30

            Text {
                anchors.verticalCenter: parent.verticalCenter
                // Status takes precedence: while a wallpaper is being applied
                // the busy text is the only thing worth reading.
                text: win.showingWallpapers
                      ? (WallpaperModel.status.length > 0
                         ? WallpaperModel.status
                         : WallpaperModel.visibleItems.length + " wallpapers  ·  Enter apply  ·  Esc close")
                      : (AppModel.visibleApps.length + " apps  ·  Enter launch  ·  Esc close  ·  right-click a tile to pin")
                color: Theme.dim
                font.pixelSize: 12
            }

            // Random pick, wallpapers tab only. Sits left of the Power button,
            // which is right-anchored, so the two never overlap.
            Item {
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: powerBtn.left
                anchors.rightMargin: 8
                width: 92
                height: 26
                visible: win.showingWallpapers

                Rectangle {
                    anchors.fill: parent
                    radius: 8
                    color: randHover.hovered ? Theme.hover : "transparent"
                    border.width: 1
                    border.color: Theme.separator
                    opacity: WallpaperModel.applying ? 0.5 : 1.0

                    Text {
                        anchors.centerIn: parent
                        text: WallpaperModel.applying ? "Working…" : "Random"
                        color: Theme.text
                        font.pixelSize: 12
                    }
                }
                HoverHandler { id: randHover }
                TapHandler {
                    enabled: !WallpaperModel.applying
                    onTapped: WallpaperModel.random()
                }
            }

            // system actions
            Item {
                id: powerBtn
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: parent.right
                width: 96
                height: 26

                Rectangle {
                    anchors.fill: parent
                    radius: 8
                    color: pwrHover.hovered ? Theme.hover : "transparent"
                    border.width: 1
                    border.color: Theme.separator

                    Text {
                        anchors.centerIn: parent
                        text: "Power"
                        color: Theme.text
                        font.pixelSize: 12
                    }
                }
                HoverHandler { id: pwrHover }
                TapHandler {
                    onTapped: win.powerOpen = win.powerOpen === "" ? "menu" : ""
                }
            }
        }

        // ---- power menu (overlaid, inside the panel) ------------------------
        Rectangle {
            id: power
            visible: win.powerOpen === "menu"
            anchors.right: parent.right
            anchors.rightMargin: win.padX
            anchors.bottom: footer.top
            anchors.bottomMargin: 6
            width: 168
            // Derived from the model so the popup can never drift out of sync
            // with the number of rows (a hardcoded value silently left dead
            // space at the bottom).
            height: win.powerActions.length * 34 + 12
            radius: 12
            color: Theme.window
            border.width: 1
            border.color: Theme.separator
            z: 50

            Column {
                anchors.fill: parent
                anchors.margins: 6

                Repeater {
                    model: win.powerActions

                    delegate: Item {
                        required property var modelData
                        width: power.width - 12
                        height: 34

                        Rectangle {
                            anchors.fill: parent
                            radius: 8
                            color: pwHover.hovered ? Theme.hover : "transparent"
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            x: 12
                            text: modelData.label
                            color: Theme.text
                            font.pixelSize: 13
                        }

                        HoverHandler { id: pwHover }
                        TapHandler {
                            onTapped: {
                                runPower(modelData.cmd);
                                win.closeDrawer();
                            }
                        }
                    }
                }
            }
        }
    }

    function runPower(argv) {
        var p = powerRunner;
        p.command = argv;
        p.running = true;
    }

    // State dump for debugging. Being mapped as a layer surface proves nothing
    // about whether the panel is actually painting: `visible` owns the surface,
    // `t` drives the slide offset, and panelH decides how much of it is on
    // screen. A wrong panelH puts the panel behind the bar, which looks
    // identical to "the drawer is broken" in a screenshot.
    function debugState() {
        console.log("DRAWER-STATE"
            + " open=" + win.open
            + " t=" + win.t
            + " visible=" + win.visible
            + " panelH=" + win.panelH
            + " padY=" + win.padY
            + " bodyH=" + win.bodyH
            + " gridH=" + win.gridH
            + " tileW=" + Theme.tileWidth
            + " barH=" + Theme.barHeight
            + " bg=" + Theme.bg
            + " icons=" + Icons.ready
            + " apps=" + AppModel.visibleApps.length
            + " winH=" + win.height
            + " winW=" + win.width
            + " panelY=" + panel.y
            + " panelH_actual=" + panel.height
            + " panelW=" + panel.width
            + " panelVisible=" + panel.visible
            + " query='" + AppModel.query + "'"
            + " searchText='" + search.text + "'"
            + " matches=" + AppModel.visibleApps.length
            // Tab + wallpaper state, so the picker can be verified over IPC
            // without reading pixels: a click test cannot tell "the grid is
            // empty" from "the model never loaded".
            + " tab=" + win.tab
            + " wpReady=" + WallpaperModel.ready
            + " wpTotal=" + WallpaperModel.items.length
            + " wpMatches=" + WallpaperModel.visibleItems.length
            + " wpCurrent='" + WallpaperModel.current + "'"
            + " wpApplying=" + WallpaperModel.applying
            + " wpStatus='" + WallpaperModel.status + "'"
            + " wpFirst='" + (WallpaperModel.visibleItems.length > 0
                             ? WallpaperModel.visibleItems[0].path : "") + "'");
    }

    Process {
        id: powerRunner
        stdout: StdioCollector {}
        stderr: StdioCollector {}
    }
}