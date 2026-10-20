import QtQuick
import Quickshell.Bluetooth
import Quickshell.Io

// The drawer's Bluetooth module.
//
// Two columns, Noctalia-style: everything bonded on the left (connected first,
// then paired-but-idle), fresh discoveries on the right. The adapter card on
// top owns the radio switch. Scanning starts when the tab is actually on
// screen and stops when the drawer closes, so the radio is not left discovering
// for as long as the daemon runs.
//
// Pairing goes through bluetoothctl rather than Quickshell's device.pair():
// Quickshell talks to BlueZ directly and does not register an agent, and BlueZ
// refuses to bond without one. bluetoothctl registers a NoInputNoOutput agent
// for the length of the command, which is enough for headsets, mice, phones
// and anything else whose pairing is confirm-on-this-device. Devices that
// require a PIN typed on the host still need a manual bluetoothctl run; the
// failure hint says so instead of silently doing nothing.
Item {
    id: panel

    // Search-box text, written by Drawer.qml. Filters both lists.
    property string query: ""
    // True only while the Bluetooth tab is selected and the drawer is open.
    // Drives discovery and makes the lists wheel-scrollable.
    property bool active: false
    // Transient feedback for the footer ("Pairing failed…").
    property string status: ""

    Timer {
        id: statusTimer
        interval: 6000
        onTriggered: panel.status = ""
    }

    function notify(msg) {
        panel.status = msg;
        statusTimer.restart();
    }

    // ---- adapter ---------------------------------------------------------
    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property bool available: panel.adapter !== null && panel.adapter !== undefined
    readonly property bool powered: panel.available && panel.adapter.enabled
    readonly property string adapterState: {
        if (!panel.available)
            return "";
        try {
            return BluetoothAdapterState.toString(panel.adapter.state);
        } catch (e) {
            return "";
        }
    }
    readonly property bool transitioning: panel.adapterState === "Enabling"
                                          || panel.adapterState === "Disabling"
    readonly property bool discovering: panel.powered && panel.adapter.discovering

    readonly property string adapterSubtitle: {
        if (!panel.available)
            return "No adapter — is bluetoothd running?";
        if (panel.transitioning)
            return panel.adapterState === "Enabling" ? "Turning on…" : "Turning off…";
        if (panel.adapterState === "Blocked")
            return "Blocked by rfkill — unblock it to use Bluetooth";
        if (!panel.powered)
            return "Off — turn on to connect devices";
        var n = 0;
        for (var i = 0; i < panel.devices.length; i++)
            if (panel.devices[i].connected)
                n++;
        return "On · " + (n > 0 ? n + (n === 1 ? " device connected"
                                                : " devices connected")
                                : "no devices connected")
               + (panel.discovering ? " · scanning" : "");
    }

    // ---- devices ---------------------------------------------------------
    readonly property var devices: panel.available && panel.adapter.devices
                                   ? panel.adapter.devices.values : []

    function label(d) {
        return String(d.name || d.deviceName || d.address || "Unknown device");
    }

    function matches(d) {
        var q = panel.query.trim().toLowerCase();
        if (q.length === 0)
            return true;
        return String(d.name || d.deviceName || "").toLowerCase().indexOf(q) >= 0
               || String(d.address || "").toLowerCase().indexOf(q) >= 0;
    }

    // Named devices first, then by name; unnamed ones fall back to the address
    // so the order is stable while discovery fills in names.
    function byName(a, b) {
        var an = String(a.name || a.deviceName || "");
        var bn = String(b.name || b.deviceName || "");
        if ((an.length > 0) !== (bn.length > 0))
            return an.length > 0 ? -1 : 1;
        var ak = (an.length > 0 ? an : String(a.address || "")).toLowerCase();
        var bk = (bn.length > 0 ? bn : String(b.address || "")).toLowerCase();
        return ak < bk ? -1 : (ak > bk ? 1 : 0);
    }

    readonly property var mine: {
        var list = panel.devices.filter(function(d) {
            return (d.connected || d.paired || d.trusted) && !d.blocked
                   && panel.matches(d);
        });
        list.sort(function(a, b) {
            if (a.connected !== b.connected)
                return a.connected ? -1 : 1;
            return panel.byName(a, b);
        });
        return list;
    }

    readonly property var nearby: {
        var list = panel.devices.filter(function(d) {
            return !d.connected && !d.paired && !d.trusted && !d.blocked
                   && panel.matches(d);
        });
        list.sort(panel.byName);
        return list;
    }

    readonly property string footerText: {
        if (panel.status.length > 0)
            return panel.status;
        if (!panel.available)
            return "No Bluetooth adapter · bluetoothd is not running";
        if (!panel.powered)
            return "Bluetooth is off · click the toggle to turn it on";
        var n = panel.mine.length + panel.nearby.length;
        return n + (n === 1 ? " device" : " devices")
               + " · Enter connects the first idle one · Esc closes";
    }

    // ---- actions ---------------------------------------------------------
    function startScan() {
        // State, not the enabled flag: see the handler comment below. Also
        // covers calls from the IPC scan action while the radio is still
        // coming up — it simply does nothing until the adapter is ready.
        if (!panel.active || !panel.powered || panel.adapterState !== "Enabled")
            return;
        if (panel.adapter.discovering)
            return;
        panel.adapter.discovering = true;
        // BlueZ can report state "on" a moment before it accepts
        // StartDiscovery ("Resource Not Ready"). One retry covers that window;
        // further failures are real (blocked radio, another agent) and are left
        // to the user's next press of Scan.
        if (!scanRetry.running)
            scanRetry.restart();
    }

    Timer {
        id: scanRetry
        interval: 1200
        onTriggered: {
            if (panel.active && panel.powered && panel.adapterState === "Enabled"
                    && !panel.adapter.discovering)
                panel.adapter.discovering = true;
        }
    }

    function stopScan() {
        if (panel.available && panel.adapter.discovering)
            panel.adapter.discovering = false;
    }

    function toggleScan() {
        if (panel.discovering)
            panel.stopScan();
        else
            panel.startScan();
    }

    function togglePower() {
        if (!panel.available || panel.transitioning)
            return;
        // Discovery is started by onPoweredChanged once the radio reports on,
        // so switching off and on again picks up a fresh scan.
        panel.adapter.enabled = !panel.adapter.enabled;
    }

    function connectDevice(d) {
        if (d)
            d.connect();
    }

    function disconnectDevice(d) {
        if (d)
            d.disconnect();
    }

    function forgetDevice(d) {
        if (!d)
            return;
        var n = panel.label(d);
        d.forget();
        panel.notify("Forgot " + n);
    }

    // Enter in the search box acts on the first thing that can be acted on:
    // an idle bonded device is connected; otherwise the first discovery is
    // paired. Already-connected devices are skipped — Enter should not
    // disconnect the headset the user is listening through.
    function activateFirst() {
        if (!panel.powered)
            return;
        for (var i = 0; i < panel.mine.length; i++) {
            var d = panel.mine[i];
            if (!d.connected && !d.pairing)
                return panel.connectDevice(d);
        }
        if (panel.nearby.length > 0)
            panel.pairDevice(panel.nearby[0]);
    }

    // ---- pairing ---------------------------------------------------------
    property var pairingDevice: null

    Process {
        id: pairProc
        command: []
        onExited: panel.pairFinished()
    }

    function pairDevice(d) {
        if (!d || pairProc.running || pairSettle.running)
            return;
        panel.pairingDevice = d;
        panel.notify("Pairing with " + panel.label(d) + "…");
        pairProc.command = ["bluetoothctl", "--agent", "NoInputNoOutput",
                            "--timeout", "60", "pair", String(d.address)];
        pairProc.running = true;
    }

    // Matched by dbusPath rather than object identity: the var comes back
    // through QML's wrapper layer and the same device can be a different
    // wrapper instance across delegate updates.
    function isPairing(d) {
        if (!d || !panel.pairingDevice)
            return false;
        return panel.pairingDevice.dbusPath === d.dbusPath;
    }

    function cancelPair(d) {
        var owned = panel.isPairing(d);
        if (d && d.pairing)
            d.cancelPair();
        if (owned) {
            // Null first: the process exit handler then knows this run was
            // cancelled and must not show a pairing-failed message.
            panel.pairingDevice = null;
            if (pairProc.running)
                pairProc.signal(15);
        }
        panel.notify("Pairing cancelled");
    }

    function pairFinished() {
        var d = panel.pairingDevice;
        panel.pairingDevice = null;
        if (!d)
            return;
        // bluetoothctl can exit a beat before BlueZ publishes the new bonded
        // state on the device object; let it settle before judging the run.
        pairSettle.device = d;
        pairSettle.restart();
    }

    Timer {
        id: pairSettle
        interval: 700
        property var device: null
        onTriggered: {
            var d = pairSettle.device;
            pairSettle.device = null;
            if (!d)
                return;
            if (d.paired || d.trusted || d.bonded) {
                // Trusted means BlueZ may reconnect without re-pairing.
                d.trusted = true;
                d.connect();
                panel.notify("Paired with " + panel.label(d));
            } else {
                panel.notify("Could not pair with " + panel.label(d)
                             + " — a device showing a PIN needs a manual bluetoothctl run");
            }
        }
    }

    // Keep discovery tied to the tab's visibility. StartScan checks adapter
    // state, so these handlers can all call it unconditionally: whichever of
    // active/powered/state changes last is the one that actually starts the
    // scan. BlueZ flips Powered before the adapter is ready, so starting from
    // the powered event alone fails with "Resource Not Ready".
    onActiveChanged: {
        if (panel.active)
            panel.startScan();
        else
            panel.stopScan();
    }
    onAdapterStateChanged: panel.startScan()
    onPoweredChanged: panel.startScan()
    onAvailableChanged: panel.startScan()

    // ---- layout ----------------------------------------------------------
    Item {
        id: content
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        // A 1876px-wide row list would leave the action buttons a screen away
        // from the names; cap the reading width and centre it like the search
        // box above. (No horizontal anchors here: they would override width/x.)
        width: Math.min(parent.width, 1180)
        x: (parent.width - width) / 2

        // Adapter card ------------------------------------------------------
        Rectangle {
            id: header
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 62
            radius: 14
            color: Theme.window
            border.width: 1
            border.color: Theme.separator

            Rectangle {
                id: iconBox
                anchors.left: parent.left
                anchors.leftMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                width: 38
                height: 38
                radius: 11
                color: panel.powered
                       ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.16)
                       : Theme.hover

                Text {
                    anchors.centerIn: parent
                    // Same glyph either way; dimming it is the state cue.
                    text: "\uf294"
                    color: panel.powered ? Theme.accent : Theme.dim
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 21
                }
            }

            Column {
                anchors.left: iconBox.right
                anchors.leftMargin: 12
                anchors.right: powerSwitch.left
                anchors.rightMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                Text {
                    text: "Bluetooth"
                    color: Theme.text
                    font.pixelSize: 15
                }

                Text {
                    width: parent.width
                    text: panel.adapterSubtitle
                    color: Theme.dim
                    font.pixelSize: 12
                    elide: Text.ElideRight
                }
            }

            // A plain switch rather than a labelled button: the state is the
            // icon box and subtitle, this only needs to read as on/off.
            Item {
                id: powerSwitch
                anchors.right: parent.right
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                width: 52
                height: 30
                opacity: panel.available && !panel.transitioning ? 1.0 : 0.5

                Rectangle {
                    anchors.fill: parent
                    radius: 15
                    color: panel.powered
                           ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.85)
                           : Theme.hover
                    border.width: 1
                    border.color: panel.powered ? Theme.accent : Theme.separator
                    Behavior on color {
                        ColorAnimation { duration: 110 }
                    }
                }

                Rectangle {
                    width: 22
                    height: 22
                    radius: 11
                    anchors.verticalCenter: parent.verticalCenter
                    x: panel.powered ? 27 : 3
                    color: panel.powered ? Theme.bg : Theme.dim
                    Behavior on x {
                        NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
                    }
                }

                HoverHandler { id: switchHover }
                TapHandler {
                    enabled: panel.available && !panel.transitioning
                    onTapped: panel.togglePower()
                }
            }
        }

        // Columns -----------------------------------------------------------
        Item {
            id: columns
            anchors.top: header.bottom
            anchors.topMargin: 12
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom

            readonly property real colWidth: (width - 28) / 2

            // My devices ----------------------------------------------------
            Item {
                id: mineCol
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: columns.colWidth

                Item {
                    id: mineHeader
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 24

                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: "MY DEVICES"
                        color: Theme.dim
                        font.pixelSize: 10
                        font.letterSpacing: 1.0
                    }
                }

                ListView {
                    id: mineList
                    anchors.top: mineHeader.bottom
                    anchors.topMargin: 6
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    clip: true
                    interactive: panel.active
                    spacing: 4
                    boundsBehavior: Flickable.StopAtBounds
                    model: panel.mine

                    delegate: BluetoothDeviceRow {
                        required property var modelData
                        dev: modelData
                        pairInFlight: panel.isPairing(modelData)
                        width: mineList.width
                        onConnectRequested: panel.connectDevice(modelData)
                        onDisconnectRequested: panel.disconnectDevice(modelData)
                        onPairRequested: panel.pairDevice(modelData)
                        onCancelRequested: panel.cancelPair(modelData)
                        onForgetRequested: panel.forgetDevice(modelData)
                    }
                }

                Text {
                    anchors.top: mineHeader.bottom
                    anchors.topMargin: 26
                    anchors.left: parent.left
                    anchors.right: parent.right
                    visible: mineList.count === 0
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: !panel.available
                          ? "No adapter"
                          : (!panel.powered
                             ? "Bluetooth is off"
                             : (panel.query.length > 0
                                ? "No saved devices match"
                                : "Nothing paired yet — pair a device from the list on the right"))
                    color: Theme.dim
                    font.pixelSize: 12
                }
            }

            // Divider -------------------------------------------------------
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: 1
                color: Theme.separator
                opacity: 0.5
            }

            // Nearby devices ------------------------------------------------
            Item {
                id: nearCol
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: columns.colWidth

                Item {
                    id: nearHeader
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 24

                    Text {
                        id: nearTitle
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: "NEARBY DEVICES"
                        color: Theme.dim
                        font.pixelSize: 10
                        font.letterSpacing: 1.0
                    }

                    // Scan control lives with the discoveries it refills, not
                    // in the footer: the footer's right side already belongs
                    // to Power.
                    Item {
                        id: scanBtn
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 72
                        height: 24
                        visible: panel.powered

                        Rectangle {
                            anchors.fill: parent
                            radius: 7
                            color: scanHover.hovered ? Theme.hover : "transparent"
                            border.width: 1
                            border.color: panel.discovering ? Theme.accent : Theme.separator
                        }

                        Row {
                            anchors.centerIn: parent
                            spacing: 5
                            height: 24

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: !panel.discovering
                                text: "\uf021"
                                color: Theme.dim
                                font.family: "JetBrainsMono Nerd Font"
                                font.pixelSize: 12
                            }

                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: panel.discovering
                                width: 6
                                height: 6
                                radius: 3
                                color: Theme.accent

                                SequentialAnimation on opacity {
                                    running: panel.discovering
                                    loops: Animation.Infinite
                                    NumberAnimation { to: 0.25; duration: 550 }
                                    NumberAnimation { to: 1.0; duration: 550 }
                                }
                            }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: panel.discovering ? "Stop" : "Scan"
                                color: panel.discovering ? Theme.accent : Theme.text
                                font.pixelSize: 11
                            }
                        }

                        HoverHandler { id: scanHover }
                        TapHandler {
                            onTapped: panel.toggleScan()
                        }
                    }
                }

                ListView {
                    id: nearList
                    anchors.top: nearHeader.bottom
                    anchors.topMargin: 6
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    clip: true
                    interactive: panel.active
                    spacing: 4
                    boundsBehavior: Flickable.StopAtBounds
                    model: panel.nearby

                    delegate: BluetoothDeviceRow {
                        required property var modelData
                        dev: modelData
                        pairInFlight: panel.isPairing(modelData)
                        width: nearList.width
                        onConnectRequested: panel.connectDevice(modelData)
                        onDisconnectRequested: panel.disconnectDevice(modelData)
                        onPairRequested: panel.pairDevice(modelData)
                        onCancelRequested: panel.cancelPair(modelData)
                        onForgetRequested: panel.forgetDevice(modelData)
                    }
                }

                Text {
                    anchors.top: nearHeader.bottom
                    anchors.topMargin: 26
                    anchors.left: parent.left
                    anchors.right: parent.right
                    visible: nearList.count === 0
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: !panel.available
                          ? "The Bluetooth service is not running"
                          : (!panel.powered
                             ? "Turn Bluetooth on to look for devices"
                             : (panel.query.length > 0
                                ? "No nearby devices match"
                                : (panel.discovering ? "Scanning for devices…"
                                                     : "No nearby devices — click Scan")))
                    color: Theme.dim
                    font.pixelSize: 12
                }
            }
        }
    }
}
