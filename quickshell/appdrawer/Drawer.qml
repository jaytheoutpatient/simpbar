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
    // Overlay popups are mutually exclusive: opening one closes the other,
    // instead of letting a second one paint over an open menu.
    property bool optionsOpen: false
    // Wallpapers tab only: when true, the top search box asks wallhaven.cc
    // instead of filtering local tiles, and the grid below becomes a remote
    // preview feed until a tile is clicked.
    property bool whOnline: false

    // Which tab the body shows. Settable from outside via `appdrawer
    // wallpapers`, which is how the bar's wallpaper button lands straight here
    // -- so it is a plain string, not something inferred from the search box.
    property string tab: "apps"
    readonly property var tabs: [
        { id: "apps", label: "Apps" },
        { id: "wallpapers", label: "Wallpapers" }
    ]
    readonly property bool showingWallpapers: win.tab === "wallpapers"
    // Any wallpaper process in flight (apply, local random, fetch, or an
    // online preview search/apply). The footer's action buttons share one busy
    // state and one "Working…" label so they can never race each other for the
    // swaybg swap.
    readonly property bool wpBusy: WallpaperModel.applying || WallpaperModel.fetching
                                  || WallhavenSearch.searching || WallhavenSearch.applying

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
        win.optionsOpen = false
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

    // Flips the wallpapers-tab search box between filtering the local folder
    // and asking wallhaven.cc. Used by the mini tab in the strip and (as an
    // IPC target) by tests that cannot type into the box.
    function toggleSearchMode() {
        if (!win.open)
            openDrawer()
        win.whOnline = !win.whOnline
        if (!win.whOnline)
            win.activeModel.query = search.text
        search.forceActiveFocus()
    }

    function closeDrawer() {
        win.open = false
        win.powerOpen = ""
        win.optionsOpen = false
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
                    // updates live. In wallhaven mode the box is a query for
                    // the engine, launched on Enter -- there is nothing to
                    // filter locally until results come back and a tile is
                    // downloaded.
                    onTextChanged: {
                        if (win.showingWallpapers && win.whOnline)
                            return;
                        win.activeModel.query = text
                    }
                    Keys.onEscapePressed: win.closeDrawer()
                    Keys.onReturnPressed: {
                        // Enter acts on whatever the visible tab is: launch the
                        // first app, or apply the first wallpaper match. The
                        // drawer stays open for the wallpaper case so the
                        // recolour is visible. In wallhaven mode it runs the
                        // online search instead.
                        if (win.showingWallpapers && win.whOnline) {
                            if (search.text.trim().length > 0)
                                WallhavenSearch.search(search.text.trim());
                            return;
                        }
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
                    text: win.whOnline
                          ? "search wallhaven.cc…"
                          : (win.showingWallpapers ? "Search wallpapers"
                                                   : "Search apps")
                    color: Theme.dim
                    font.pixelSize: 16
                    elide: Text.ElideRight
                    rightPadding: 60
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

                // Source of the search box on the wallpapers tab: filter the
                // local folder vs ask wallhaven.cc. Presented as a mini tab so
                // the mode reads at a glance; the box's placeholder and the
                // grid below both change to match.
                Item {
                    visible: win.showingWallpapers
                    width: 132
                    height: 28

                    Rectangle {
                        anchors.fill: parent
                        radius: 9
                        color: "transparent"
                        border.width: 1
                        border.color: Theme.separator
                    }

                    // Local: the box filters tiles in the folder below.
                    Rectangle {
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        width: parent.width / 2
                        radius: 9
                        color: localHover.hovered ? Theme.hover
                                : (win.whOnline ? "transparent" : Theme.accent)
                        opacity: win.whOnline ? 1.0 : 0.22
                        border.width: 1
                        border.color: win.whOnline ? "transparent" : Theme.accent

                        Text {
                            anchors.centerIn: parent
                            text: "Local"
                            color: win.whOnline ? Theme.text : Theme.accent
                            font.pixelSize: 12
                        }
                        HoverHandler { id: localHover }
                        TapHandler { onTapped: win.whOnline = false }
                    }

                    // Wallhaven: the box searches wallhaven.cc on Enter, and
                    // the grid shows a remote preview feed below.
                    Rectangle {
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.right: parent.right
                        width: parent.width / 2
                        radius: 9
                        color: netHover.hovered ? Theme.hover
                                : (win.whOnline ? Theme.accent : "transparent")
                        opacity: win.whOnline ? 0.22 : 1.0
                        border.width: 1
                        border.color: win.whOnline ? Theme.accent : "transparent"

                        Text {
                            anchors.centerIn: parent
                            text: "Wallhaven"
                            color: win.whOnline ? Theme.accent : Theme.text
                            font.pixelSize: 12
                        }
                        HoverHandler { id: netHover }
                        TapHandler { onTapped: win.whOnline = true }
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

                // The two grids occupy the same rect, so exactly one of them may
                // be visible at a time -- `visible` (not `Loader`) so the hidden
                // one keeps its scroll position and delegates alive. Without
                // this the app grid stayed painted underneath the wallpaper grid
                // and the two interleaved, since their cell sizes differ.
                visible: !win.showingWallpapers

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
                // The wallhaven preview grid occupies the same rect and swaps
                // in on the wallpapers tab in online mode.
                visible: win.showingWallpapers && !win.whOnline
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

            // ---- wallhaven preview grid -------------------------------------
            // Remote results of an online search, shown while the search box is
            // in wallhaven mode. Thumbnails only, no downloads: clicking a tile
            // is what fetches the full wallpaper and applies it, and the file
            // then shows up in the local grid on the next refresh too.
            GridView {
                id: whGrid
                anchors.fill: parent
                visible: win.showingWallpapers && win.whOnline
                clip: true
                interactive: win.open
                model: WallhavenSearch.results
                cellWidth: 156
                cellHeight: 132
                boundsBehavior: Flickable.StopAtBounds

                delegate: Item {
                    required property var modelData
                    required property int index

                    width: 156
                    height: 132
                    x: 8
                    y: 8

                    Rectangle {
                        id: whTile
                        anchors.fill: parent
                        radius: 10
                        color: whTileHover.hovered ? Theme.hover : Theme.window
                        border.width: 1
                        border.color: whTileHover.hovered ? Theme.accent : Theme.separator
                        clip: true

                        Image {
                            id: thumb
                            anchors.fill: parent
                            anchors.margins: 1
                            source: modelData.thumb
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            sourceSize: Qt.size(312, 264)
                            cache: true

                            // Loading/error overlay so a slow thumb or a broken
                            // CDN link doesn't read as an empty tile.
                            Rectangle {
                                anchors.fill: parent
                                color: "transparent"
                                visible: thumb.status === Image.Loading
                                Text {
                                    anchors.centerIn: parent
                                    text: "…"
                                    color: Theme.dim
                                    font.pixelSize: 14
                                }
                            }
                            Rectangle {
                                anchors.fill: parent
                                color: "#00000080"
                                visible: thumb.status === Image.Error
                                Text {
                                    anchors.centerIn: parent
                                    text: "no preview"
                                    color: "#ffffff"
                                    font.pixelSize: 11
                                }
                            }
                        }

                        // Rating badge: the whole point of the purity config is
                        // being able to tell sfw from the rest at a glance.
                        Rectangle {
                            anchors.left: parent.left
                            anchors.bottom: parent.bottom
                            anchors.margins: 6
                            width: badge.implicitWidth + 12
                            height: 18
                            radius: 6
                            color: "#cc000000"
                            Text {
                                id: badge
                                anchors.centerIn: parent
                                text: ratingLabel()
                                color: ratingColor()
                                font.pixelSize: 10
                                font.bold: true
                            }
                        }
                    }
                    HoverHandler { id: whTileHover }
                    TapHandler {
                        onTapped: WallhavenSearch.applyResult(index)
                    }

                    function ratingLabel() {
                        var s = String(modelData.purity || "");
                        var i = s.indexOf("/");
                        return i >= 0 ? s.substring(i + 1).toUpperCase() : s.toUpperCase();
                    }
                    function ratingColor() {
                        var p = String(modelData.purity || "").toLowerCase();
                        if (p.indexOf("nsfw") >= 0) return "#ff8a8a";
                        if (p.indexOf("sketchy") >= 0) return "#ffc46b";
                        return "#9ed9a5";
                    }
                }

                Text {
                    anchors.centerIn: parent
                    visible: whGrid.count === 0 && !WallhavenSearch.searching
                    text: WallhavenSearch.results.length === 0
                          ? (WallhavenSearch.query.length > 0
                             ? "no results — try a different query"
                             : "type a query in the box above and press Enter")
                          : ""
                    color: Theme.dim
                    font.pixelSize: 15
                }
                Text {
                    anchors.centerIn: parent
                    visible: whGrid.count === 0 && WallhavenSearch.searching
                    text: "Searching wallhaven…"
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
                // the busy text is the only thing worth reading. In wallhaven
                // mode the online search's chatter wins over the folder's.
                text: win.showingWallpapers
                      ? (WallhavenSearch.status.length > 0
                         ? WallhavenSearch.status
                         : (WallpaperModel.status.length > 0
                            ? WallpaperModel.status
                            : (win.whOnline
                               ? (WallhavenSearch.results.length > 0
                                  ? WallhavenSearch.results.length + " results  ·  click a tile to download & apply"
                                  : "press Enter to search wallhaven.cc")
                               : WallpaperModel.visibleItems.length + " wallpapers  ·  Enter apply  ·  Esc close")))
                      : (AppModel.visibleApps.length + " apps  ·  Enter launch  ·  Esc close  ·  right-click a tile to pin")
                color: Theme.dim
                font.pixelSize: 12
            }

            // Wallpaper source actions, wallpapers tab only. Chained from the
            // right, in the same style as Power: an Item + Rectangle + labels +
            // HoverHandler + TapHandler, so they all read as one group.
            // Overlays close each other: tapping Power closes Options and vice
            // versa.
            //
            // [Bing] [Online] [Random]        [Options] [Power]

            // Today's Bing wallpaper, downloaded and applied.
            Item {
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: onlineBtn.left
                anchors.rightMargin: 8
                width: 72
                height: 26
                visible: win.showingWallpapers && !win.optionsOpen

                Rectangle {
                    anchors.fill: parent
                    radius: 8
                    color: bingHover.hovered ? Theme.hover : "transparent"
                    border.width: 1
                    border.color: Theme.separator
                    opacity: win.wpBusy ? 0.5 : 1.0

                    Text {
                        anchors.centerIn: parent
                        text: win.wpBusy ? "Working…" : "Bing"
                        color: Theme.text
                        font.pixelSize: 12
                    }
                }
                HoverHandler { id: bingHover }
                TapHandler {
                    enabled: !win.wpBusy && !win.optionsOpen
                    onTapped: WallpaperModel.fetchBing()
                }
            }

            // A random wallpaper from wallhaven.cc, fetched and applied.
            Item {
                id: onlineBtn
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: randBtn.left
                anchors.rightMargin: 8
                width: 76
                height: 26
                visible: win.showingWallpapers && !win.optionsOpen

                Rectangle {
                    anchors.fill: parent
                    radius: 8
                    color: onlineHover.hovered ? Theme.hover : "transparent"
                    border.width: 1
                    border.color: Theme.separator
                    opacity: win.wpBusy ? 0.5 : 1.0

                    Text {
                        anchors.centerIn: parent
                        text: win.wpBusy ? "Working…" : "Online"
                        color: Theme.text
                        font.pixelSize: 12
                    }
                }
                HoverHandler { id: onlineHover }
                TapHandler {
                    enabled: !win.wpBusy && !win.optionsOpen
                    onTapped: WallpaperModel.randomOnline()
                }
            }

            // Random pick from the local folder.
            Item {
                id: randBtn
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: optsBtn.left
                anchors.rightMargin: 8
                width: 92
                height: 26
                visible: win.showingWallpapers && !win.optionsOpen

                Rectangle {
                    anchors.fill: parent
                    radius: 8
                    color: randHover.hovered ? Theme.hover : "transparent"
                    border.width: 1
                    border.color: Theme.separator
                    opacity: win.wpBusy ? 0.5 : 1.0

                    Text {
                        anchors.centerIn: parent
                        text: win.wpBusy ? "Working…" : "Random"
                        color: Theme.text
                        font.pixelSize: 12
                    }
                }
                HoverHandler { id: randHover }
                TapHandler {
                    enabled: !win.wpBusy && !win.optionsOpen
                    onTapped: WallpaperModel.random()
                }
            }

            // Wallhaven options: paste the user's own API key (Sketchy/Explicit
            // need one), pick the content rating. The panel itself is painted
            // below; this button just owns the open/close state.
            Item {
                id: optsBtn
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: powerBtn.left
                anchors.rightMargin: 8
                width: 78
                height: 26
                visible: win.showingWallpapers

                Rectangle {
                    anchors.fill: parent
                    radius: 8
                    color: optsHover.hovered ? Theme.hover : "transparent"
                    border.width: 1
                    border.color: win.optionsOpen ? Theme.accent : Theme.separator

                    Text {
                        anchors.centerIn: parent
                        text: "Options"
                        color: win.optionsOpen ? Theme.accent : Theme.text
                        font.pixelSize: 12
                    }
                }
                HoverHandler { id: optsHover }
                TapHandler {
                    onTapped: win.toggleOptions()
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
                    opacity: win.powerOpen === "menu" ? 0.5 : 1.0

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

        // ---- wallhaven options (overlaid, inside the panel) -----------
        // Where the user's own wallhaven.cc API key goes, plus the content
        // rating. Both are written to ~/.config/simpbar/wallhaven -- the same
        // file the engine reads -- so a key pasted here is exactly a key typed
        // in a terminal: one file, one meaning, no second store to drift. The
        // form only commits on Save, so closing without saving changes nothing.
        Rectangle {
            id: whOpts
            visible: win.optionsOpen
            anchors.right: parent.right
            anchors.rightMargin: win.padX
            anchors.bottom: footer.top
            anchors.bottomMargin: 6
            width: 320
            height: 262
            radius: 12
            color: Theme.window
            border.width: 1
            border.color: Theme.separator
            z: 50

            // Current file contents, kept apart from the widgets so the widgets
            // can be edited freely and committed only by Save.
            property string fileKey: ""
            property string purity: "100"
            property string status: ""
            property bool saving: false

            readonly property string path: (Quickshell.env("XDG_CONFIG_HOME")
                                            || Quickshell.env("HOME") + "/.config")
                                        + "/simpbar/wallhaven"

            // Whether the key arrives from the environment instead of this
            // file. The engine prefers WALLHAVEN_APIKEY over the file, so an
            // input here would be silently ignored -- disable it and say so,
            // like noctalia does. Purity still comes from the file.
            readonly property bool envManaged: {
                var v = Quickshell.env("WALLHAVEN_APIKEY");
                return v !== undefined && v !== null && String(v).length > 0;
            }

            onVisibleChanged: {
                if (visible)
                    load();
            }

            function load() {
                whOpts.status = "";
                whOpts.saving = false;
                keyField.clear();
                whReader.command = ["sh", "-c",
                    "cat \"$1\" 2>/dev/null || true",
                    "simpbar-wallhaven-read",
                    whOpts.path];
                whReader.running = true;
            }

            function applyFile(text) {
                var key = "";
                var purity = "100";
                var lines = text.split("\n");
                for (var i = 0; i < lines.length; i++) {
                    var l = lines[i];
                    if (l.indexOf("key=") === 0)
                        key = l.substring(4).trim();
                    else if (l.indexOf("purity=") === 0) {
                        var v = l.substring(7).trim();
                        if (v.length > 0) purity = v;
                    }
                }
                whOpts.fileKey = key;
                whOpts.purity = purity;
                // Prefill the (masked) field with the current key, like
                // noctalia does: hitting Save without touching it writes the
                // same key back, so an empty-by-default field can never wipe a
                // configured key by accident. The environment-owned key is the
                // one case where the field stays deliberately blank.
                if (!whOpts.envManaged)
                    keyField.text = key;
                if (whOpts.envManaged)
                    whOpts.status = "engine key takes WALLHAVEN_APIKEY";
            }

            function save() {
                if (whOpts.saving)
                    return;
                whOpts.saving = true;
                whOpts.status = "Saving…";
                whWriter.command = ["sh", "-c",
                    "mkdir -p \"$HOME/.config/simpbar\" && printf 'key=%s\\npurity=%s\\n' \"$1\" \"$2\" > \"$HOME/.config/simpbar/wallhaven\"",
                    "simpbar-wallhaven-save",
                    keyField.text.trim(),
                    whOpts.purity];
                whWriter.running = true;
            }

            Column {
                anchors.fill: parent
                anchors.margins: 14
                spacing: 10

                // header
                Item {
                    width: parent.width
                    height: 20

                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Wallhaven"
                        color: Theme.text
                        font.pixelSize: 14
                        font.bold: true
                    }
                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 74
                        anchors.verticalCenter: parent.verticalCenter
                        text: "source"
                        color: Theme.dim
                        font.pixelSize: 11
                    }
                    Rectangle {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 22
                        height: 18
                        radius: 6
                        color: closeXHover.hovered ? Theme.hover : "transparent"

                        Text {
                            anchors.centerIn: parent
                            text: "×"
                            color: Theme.dim
                            font.pixelSize: 13
                        }

                        HoverHandler { id: closeXHover }
                        TapHandler { onTapped: win.optionsOpen = false }
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 1
                    color: Theme.separator
                }

                Text {
                    text: "API key (optional)"
                    color: Theme.dim
                    font.pixelSize: 11
                }

                Rectangle {
                    id: keyBox
                    width: parent.width
                    height: 32
                    radius: 8
                    border.width: 1
                    border.color: keyField.activeFocus ? Theme.accent : Theme.separator

                    TextInput {
                        id: keyField
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        verticalAlignment: TextInput.AlignVCenter
                        color: Theme.text
                        font.pixelSize: 13
                        echoMode: TextInput.Password
                        selectByMouse: true
                        enabled: !whOpts.envManaged
                        clip: true
                        Keys.onReturnPressed: whOpts.save()
                    }
                    Text {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        verticalAlignment: Text.AlignVCenter
                        visible: keyField.length === 0
                        text: whOpts.envManaged
                              ? "managed by WALLHAVEN_APIKEY"
                              : (whOpts.fileKey.length > 0
                                 ? "key set — paste to replace"
                                 : "paste your key…")
                        color: Theme.dim
                        font.pixelSize: 13
                        clip: true
                    }
                }

                Text {
                    width: parent.width
                    height: 28
                    text: "SFW needs no key. Sketchy and explicit content need your key from wallhaven.cc/user/settings/api."
                    color: Theme.dim
                    font.pixelSize: 10
                    wrapMode: Text.WordWrap
                    lineHeight: 1.3
                }

                Text {
                    text: "Content"
                    color: Theme.dim
                    font.pixelSize: 11
                }

                Row {
                    width: parent.width
                    height: 24
                    spacing: 6

                    Repeater {
                        model: [
                            { v: "100", l: "SFW" },
                            { v: "110", l: "Sketchy" },
                            { v: "111", l: "Explicit" }
                        ]

                        delegate: Rectangle {
                            required property var modelData
                            id: purityChip
                            width: chipLabel.implicitWidth + 20
                            height: 24
                            radius: 8
                            color: chipHover.hovered ? Theme.hover : "transparent"
                            opacity: whOpts.purity === modelData.v ? 0.22 : 1.0
                            border.width: 1
                            border.color: whOpts.purity === modelData.v
                                           ? Theme.accent : Theme.separator

                            Text {
                                id: chipLabel
                                anchors.centerIn: parent
                                text: modelData.l
                                color: whOpts.purity === modelData.v ? Theme.accent : Theme.text
                                font.pixelSize: 12
                            }
                            HoverHandler { id: chipHover }
                            TapHandler { onTapped: whOpts.purity = modelData.v }
                        }
                    }
                }

                // status + save
                Item {
                    width: parent.width
                    height: 26

                    Text {
                        anchors.left: parent.left
                        anchors.right: saveBtn.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: whOpts.status
                        color: Theme.dim
                        font.pixelSize: 11
                        elide: Text.ElideRight
                    }
                    Item {
                        id: saveBtn
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 76
                        height: 26

                        Rectangle {
                            anchors.fill: parent
                            radius: 8
                            color: saveHover.hovered ? Theme.hover : "transparent"
                            border.width: 1
                            border.color: Theme.accent

                            Text {
                                anchors.centerIn: parent
                                text: whOpts.saving ? "Saving…" : "Save"
                                color: Theme.accent
                                font.pixelSize: 12
                            }
                        }
                        HoverHandler { id: saveHover }
                        TapHandler {
                            enabled: !whOpts.saving
                            onTapped: whOpts.save()
                        }
                    }
                }
            }
        }
    }

    function toggleOptions() {
        if (win.optionsOpen) {
            win.optionsOpen = false;
            return;
        }
        if (!win.open)
            win.openDrawer();
        win.powerOpen = "";
        win.optionsOpen = true;
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
            + " wpFetching=" + WallpaperModel.fetching
            + " wpStatus='" + WallpaperModel.status + "'"
            // Popup state. The key itself is never dumped -- it is a secret,
            // and it lives in the log file; whether one is configured is
            // enough for a state dump.
            + " optsOpen=" + win.optionsOpen
            + " whEnv=" + whOpts.envManaged
            + " whHasKey=" + (whOpts.fileKey.length > 0)
            + " whPurity=" + whOpts.purity
            + " whSaving=" + whOpts.saving
            // Online search mode: whether the box is asking wallhaven.cc, and
            // what the last query turned up. Query text is not a secret, but it
            // does include anything the user typed -- which is fine for a
            // local debug dump.
            + " whOnline=" + win.whOnline
            + " whSearching=" + WallhavenSearch.searching
            + " whApplying=" + WallhavenSearch.applying
            + " whResults=" + WallhavenSearch.results.length
            + " whQuery='" + WallhavenSearch.query + "'"
            + " wpFirst='" + (WallpaperModel.visibleItems.length > 0
                             ? WallpaperModel.visibleItems[0].path : "") + "'"
            // The two grids are siblings occupying one rect, so "both visible"
            // is a real, silently-wrong state that a screenshot shows only as
            // something looking untidy. Worth asserting rather than eyeballing.
            + " appGridVisible=" + grid.visible
            + " wpGridVisible=" + wpGrid.visible
            + " sidebarVisible=" + side.visible);
    }

    Process {
        id: powerRunner
        stdout: StdioCollector {}
        stderr: StdioCollector {}
    }

    // Reads ~/.config/simpbar/wallhaven when the options popup opens. Read via
    // the same parse the widgets use, so the popup shows exactly what the
    // engine would see (missing file = no key, SFW).
    Process {
        id: whReader
        stdout: StdioCollector {
            onStreamFinished: {
                whOpts.applyFile(text);
                whReader.running = false;
            }
        }
        stderr: StdioCollector {
            onStreamFinished: whReader.running = false
        }
    }

    // Writes the wallhaven file on Save. Stderr carries a real problem (the
    // `printf >` failing, a permissions error); a clean run leaves it empty
    // and onExited flips the status to "Saved".
    Process {
        id: whWriter
        stdout: StdioCollector {}
        stderr: StdioCollector {
            onStreamFinished: {
                var msg = text.trim();
                if (msg.length > 0)
                    whOpts.status = msg;
            }
        }
        onExited: {
            whOpts.saving = false;
            if (whOpts.status === "Saving…")
                whOpts.status = "Saved";
        }
    }
}