// A recent-app tile on the launcher's empty state: AppIcon 48 + name.
// current (keyboard) = selected tint + 2 px accent ring (a shape cue, not
// color alone); hover = hover overlay; pressed = pressed overlay.
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

    implicitWidth: 92
    implicitHeight: 96

    Accessible.role: Accessible.Button
    Accessible.name: name
    Accessible.focused: current

    Rectangle {
        anchors.fill: parent
        radius: Theme.radiusLg
        color: tile.current ? Theme.selectedBg
            : mouse.pressed ? Theme.pressedOverlay
            : mouse.containsMouse ? Theme.hoverOverlay
            : "transparent"
        border.width: tile.current ? 2 : 0
        border.color: Theme.accent
        Behavior on color { ColorAnimation { duration: Theme.durMicro } }
    }

    AppIcon {
        id: art
        anchors.horizontalCenter: parent.horizontalCenter
        y: Theme.space12
        iconName: tile.icon
        fallbackText: tile.name
        size: 48
        scale: mouse.pressed && !Theme.reduceMotion ? 0.96 : 1
        Behavior on scale { NumberAnimation { duration: Theme.durMicro } }
    }

    Text {
        anchors.top: art.bottom
        anchors.topMargin: Theme.space8
        anchors.horizontalCenter: parent.horizontalCenter
        width: parent.width - Theme.space12
        horizontalAlignment: Text.AlignHCenter
        text: tile.name
        font: Theme.typeCaption
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
