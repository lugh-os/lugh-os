// A recent-app tile on the launcher's empty state: AppIcon 40 + name.
// Hover lifts the icon, press squishes it (Squish). The keyboard-current
// pill is drawn once by LauncherBody behind the tiles; the tile only turns
// its name to the accent text color and weight.
import QtQuick
import Lugh.UI

Item {
    id: tile

    required property int index
    required property string appId
    required property string name
    required property string icon

    property bool current: false

    signal clicked(int index)

    implicitWidth: 96
    implicitHeight: 78

    Accessible.role: Accessible.Button
    Accessible.name: name
    Accessible.focused: current

    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: 1
        anchors.rightMargin: 1
        radius: Theme.radiusLg
        color: mouse.pressed ? Theme.pressedOverlay : Theme.hoverOverlay
        visible: !tile.current && (mouse.containsMouse || mouse.pressed)
    }

    Squish {
        id: art
        anchors.horizontalCenter: parent.horizontalCenter
        y: Theme.space8
        pressed: mouse.pressed
        hovered: mouse.containsMouse
        lift: 2

        AppIcon {
            iconName: tile.icon
            fallbackText: tile.name
            size: 40
        }
    }

    Text {
        y: Theme.space8 + 40 + 6
        anchors.horizontalCenter: parent.horizontalCenter
        width: parent.width - Theme.space12
        horizontalAlignment: Text.AlignHCenter
        text: tile.name
        font.family: Theme.fontUi
        font.pixelSize: Theme.typeCaption.pixelSize
        font.weight: tile.current ? Font.DemiBold : Theme.typeCaption.weight
        color: tile.current ? Theme.accentText : Theme.text
        elide: Text.ElideRight
        maximumLineCount: 1
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: tile.clicked(tile.index)
    }
}
