// A one-line note in a drawer (off / empty states), with an optional action:
// "Wi-Fi is off   [Turn on]". Compact stand-in for EmptyState.
import QtQuick
import Lugh.UI

Item {
    id: root

    property string text: ""
    property string iconName: ""
    property string actionText: ""
    readonly property Item actionButton: button

    signal action()

    implicitHeight: 40

    Icon {
        id: icon
        x: 10
        anchors.verticalCenter: parent.verticalCenter
        visible: root.iconName !== ""
        name: root.iconName
        size: 16
        color: Theme.textMuted
    }
    Text {
        anchors.left: parent.left
        anchors.leftMargin: icon.visible ? 36 : 10
        anchors.right: button.visible ? button.left : parent.right
        anchors.rightMargin: Theme.space8
        anchors.verticalCenter: parent.verticalCenter
        text: root.text
        font: Theme.typeLabel
        color: Theme.textMuted
        elide: Text.ElideRight
    }
    Button {
        id: button
        anchors.right: parent.right
        anchors.rightMargin: 4
        anchors.verticalCenter: parent.verticalCenter
        visible: root.actionText !== ""
        text: root.actionText
        size: "sm"
        onClicked: root.action()
    }
}
