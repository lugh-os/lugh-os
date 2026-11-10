// A small keyboard key, for launcher hints: Keycap { text: "↵" }.
import QtQuick
import Lugh.UI

Rectangle {
    id: root

    property string text: ""

    implicitWidth: Math.max(20, label.implicitWidth + Theme.space8 + 2)
    implicitHeight: 20
    radius: 5
    color: Theme.dark ? Qt.rgba(1, 1, 1, 0.06) : Qt.rgba(1, 1, 1, 0.7)
    border.width: 1
    border.color: Theme.border
    Accessible.ignored: true

    // Key-bottom lip: a 1 px darker line along the lower edge.
    Rectangle {
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 1 }
        anchors.leftMargin: root.radius
        anchors.rightMargin: root.radius
        height: 1
        color: Theme.border
    }

    Text {
        id: label
        anchors.centerIn: parent
        anchors.verticalCenterOffset: -0.5
        text: root.text
        font.family: Theme.fontUi
        font.pixelSize: 11
        font.weight: Font.DemiBold
        color: Theme.textMuted
    }
}
