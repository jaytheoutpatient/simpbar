import QtQuick
import Quickshell.Bluetooth

// One Bluetooth device in the drawer's Bluetooth panel.
//
// Presentation only: every action is bounced back to BluetoothPanel through a
// signal, because pairing spawns a helper process and the panel is the single
// owner of that process (two rows must not race for it).
Item {
    id: row

    required property var dev
    // True when this row is the target of the panel's bluetoothctl run. BlueZ
    // does not always report Pairing immediately (or at all, for a device not
    // in pairing mode), and without this the row would sit on "Pair" with no
    // way to cancel for the full 60s timeout.
    property bool pairInFlight: false

    signal connectRequested()
    signal disconnectRequested()
    signal pairRequested()
    signal cancelRequested()
    signal forgetRequested()

    // BlueZ's state arrives as an untyped enum. Stringify it through the
    // exported helper instead of comparing against enum members: their QML
    // spelling (BluetoothDeviceState.Connecting vs .Enum.Connecting) is not
    // stable across Quickshell releases, while toString() is exported.
    readonly property string stateName: {
        try {
            return BluetoothDeviceState.toString(row.dev.state);
        } catch (e) {
            return "";
        }
    }
    readonly property bool connecting: row.stateName === "Connecting"
    readonly property bool disconnecting: row.stateName === "Disconnecting"
    readonly property bool pairing: row.dev.pairing || row.pairInFlight
    // Bonded devices are the ones worth offering Connect for; "trusted" is
    // included because devices paired by another tool sometimes report it
    // without the paired bit being visible to BlueZ yet.
    readonly property bool known: row.dev.paired || row.dev.trusted
    readonly property bool busy: row.connecting || row.disconnecting
    readonly property string name: String(row.dev.name || row.dev.deviceName
                                          || row.dev.address || "Unknown device")

    implicitHeight: 54

    function actionLabel() {
        if (row.pairing)
            return "Cancel";
        if (row.connecting)
            return "Connecting…";
        if (row.disconnecting)
            return "Disconnecting…";
        if (row.dev.connected)
            return "Disconnect";
        if (row.known)
            return "Connect";
        return "Pair";
    }

    function subtitle() {
        if (row.pairing)
            return "Pairing…";
        if (row.connecting)
            return "Connecting…";
        if (row.disconnecting)
            return "Disconnecting…";
        if (row.dev.connected)
            return "Connected";
        if (row.known)
            return "Paired";
        return "Nearby";
    }

    // Devices are advertised with a family icon name ("audio-headset",
    // "input-keyboard", …) rather than a per-model one, so map families onto
    // Nerd Font glyphs: no image assets to ship, and one colour to tint.
    //
    // The codepoints below are Font Awesome 4's range rather than Material
    // Design Icons': Nerd Fonts ships a v3 MDI remap whose names do not line up
    // with this font's actual glyphs (md-bluetooth lands on a keyboard), while
    // FA4 has been stable across every Nerd Fonts release and is guaranteed to
    // render the shapes named here.
    function glyph() {
        var k = String(row.dev.icon || "").toLowerCase();
        var n = row.name.toLowerCase();
        if (k.indexOf("headset") >= 0 || k.indexOf("headphone") >= 0)
            return "\uf025";
        if (k.indexOf("audio") >= 0 || k.indexOf("speaker") >= 0
                || k.indexOf("sound") >= 0)
            return "\uf028";
        if (k.indexOf("keyboard") >= 0 || n.indexOf("keyboard") >= 0)
            return "\uf11c";
        if (k.indexOf("mouse") >= 0 || k.indexOf("pointing") >= 0
                || n.indexOf("mouse") >= 0)
            return "\uf245";
        if (k.indexOf("gaming") >= 0 || k.indexOf("joystick") >= 0
                || n.indexOf("controller") >= 0 || n.indexOf("xbox") >= 0
                || n.indexOf("gamepad") >= 0)
            return "\uf11b";
        if (k.indexOf("phone") >= 0) return "\uf10b";
        if (k.indexOf("laptop") >= 0 || k.indexOf("computer") >= 0) return "\uf109";
        if (k.indexOf("video") >= 0 || k.indexOf("display") >= 0
                || k.indexOf("monitor") >= 0)
            return "\uf108";
        if (k.indexOf("printer") >= 0) return "\uf02f";
        if (k.indexOf("camera") >= 0) return "\uf030";
        if (k.indexOf("watch") >= 0 || k.indexOf("wearable") >= 0) return "\uf017";
        if (k.indexOf("tablet") >= 0) return "\uf10a";
        if (k.indexOf("player") >= 0 || k.indexOf("music") >= 0) return "\uf001";
        return "\uf294";
    }

    Rectangle {
        anchors.fill: parent
        radius: 10
        color: rowHover.hovered ? Theme.hover : "transparent"
        Behavior on color {
            ColorAnimation { duration: 90 }
        }
    }

    HoverHandler { id: rowHover }

    Text {
        id: glyph
        anchors.left: parent.left
        anchors.leftMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        width: 26
        horizontalAlignment: Text.AlignHCenter
        text: row.glyph()
        color: row.dev.connected ? Theme.accent : Theme.dim
        font.family: "JetBrainsMono Nerd Font"
        font.pixelSize: 19
    }

    // Chain the right-hand controls from the right edge so the name column can
    // simply stretch to meet them, whatever combination is visible.
    Row {
        id: actions
        anchors.right: parent.right
        anchors.rightMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        spacing: 10

        // Battery is only published by devices that expose BlueZ's Battery1
        // (headsets, mice, phones) and only once they are connected.
        Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 5
            visible: row.dev.connected && row.dev.batteryAvailable

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 24
                height: 12
                radius: 3
                color: "transparent"
                border.width: 1
                border.color: Theme.dim

                Rectangle {
                    // Quickshell normalises the percentage to 0.0–1.0.
                    readonly property real level: Math.max(0.0, Math.min(1.0, row.dev.battery))

                    anchors.left: parent.left
                    anchors.leftMargin: 2
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.round((parent.width - 4) * level)
                    height: parent.height - 4
                    radius: 1
                    color: level <= 0.2 ? "#ff8a8a" : Theme.accent
                }
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: Math.round(row.dev.battery * 100) + "%"
                color: Theme.dim
                font.pixelSize: 11
            }
        }

        // Unpair lives next to Connect rather than inside a context menu: it is
        // rare enough to sit at the edge, and there is no menu system in the
        // drawer to hide it in.
        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: row.known && !row.dev.connected && !row.pairing
            text: "Forget"
            color: forgetHover.hovered ? "#ff8a8a" : Theme.dim
            font.pixelSize: 11

            HoverHandler { id: forgetHover }
            TapHandler {
                onTapped: row.forgetRequested()
            }
        }

        Item {
            id: actionBtn
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(74, actionMetrics.width + 24)
            height: 26
            opacity: row.busy ? 0.55 : 1.0

            TextMetrics {
                id: actionMetrics
                font.pixelSize: 12
                text: row.actionLabel()
            }

            Rectangle {
                anchors.fill: parent
                radius: 8
                color: actionHover.hovered && !row.busy ? Theme.hover : "transparent"
                border.width: 1
                border.color: row.pairing ? Theme.accent
                             : (row.known || row.dev.connected ? Theme.separator
                                                               : Theme.separator)

                Text {
                    anchors.centerIn: parent
                    text: row.actionLabel()
                    color: row.pairing ? Theme.accent : Theme.text
                    font.pixelSize: 12
                }
            }

            HoverHandler { id: actionHover }
            TapHandler {
                enabled: !row.busy
                onTapped: {
                    if (row.pairing)
                        row.cancelRequested();
                    else if (row.dev.connected)
                        row.disconnectRequested();
                    else if (row.known)
                        row.connectRequested();
                    else
                        row.pairRequested();
                }
            }
        }
    }

    Column {
        anchors.left: glyph.right
        anchors.leftMargin: 6
        anchors.right: actions.left
        anchors.rightMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2

        Text {
            width: parent.width
            text: row.name
            color: Theme.text
            font.pixelSize: 13
            elide: Text.ElideRight
        }

        Text {
            width: parent.width
            text: row.subtitle()
            color: row.dev.connected ? Theme.accent : Theme.dim
            font.pixelSize: 11
            elide: Text.ElideRight
        }
    }
}
