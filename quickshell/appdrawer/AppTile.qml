import QtQuick

// One app in the grid. Falls back to a lettered tile when no icon file could
// be resolved, so a missing theme entry degrades instead of leaving a hole.
Item {
    id: tile

    required property var app
    property bool selected: false

    signal triggered()
    signal toggleFavourite()

    implicitWidth: Theme.tileWidth
    implicitHeight: Theme.tileHeight

    Rectangle {
        id: bg
        anchors.fill: parent
        radius: 14
        color: tile.selected ? Theme.accent
                              : (hover.hovered ? Theme.hover : "transparent")
        Behavior on color {
            ColorAnimation { duration: 90 }
        }

        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: "transparent"
            border.width: 1
            border.color: Theme.accent
            opacity: tile.selected ? 0.9 : 0.0
        }
    }

    HoverHandler { id: hover }

    Column {
        anchors.centerIn: parent
        spacing: 6
        width: parent.width

        Item {
            width: Theme.iconSize
            height: Theme.iconSize
            anchors.horizontalCenter: parent.horizontalCenter

            // app.icon is already an absolute filesystem path (Icons.path),
            // because Qt's Image cannot resolve freedesktop theme names.
            Image {
                anchors.fill: parent
                visible: tile.app.icon !== ""
                source: tile.app.icon
                asynchronous: true
                fillMode: Image.PreserveAspectFit
                sourceSize.width: Theme.iconSize * 2
                sourceSize.height: Theme.iconSize * 2

                Rectangle {
                    anchors.fill: parent
                    visible: parent.status === Image.Error || parent.status === Image.Null
                    radius: 10
                    color: Theme.accent
                    opacity: 0.22

                    Text {
                        anchors.centerIn: parent
                        text: tile.app.name.length > 0 ? tile.app.name.charAt(0).toUpperCase() : "?"
                        color: Theme.accent
                        font.pixelSize: 20
                        font.bold: true
                    }
                }
            }
        }

        Text {
            width: parent.width - 10
            horizontalAlignment: Text.AlignHCenter
            text: tile.app.name
            color: Theme.text
            font.pixelSize: 12
            elide: Text.ElideRight
            maximumLineCount: 2
            wrapMode: Text.WordWrap
        }
    }

    TapHandler {
        acceptedButtons: Qt.LeftButton
        onTapped: tile.triggered()
    }

    TapHandler {
        acceptedButtons: Qt.RightButton
        onTapped: tile.toggleFavourite()
    }
}