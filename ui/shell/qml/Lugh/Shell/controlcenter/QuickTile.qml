// One pill tile of the quick panel: icon, label and a one-line state; "on" is
// the accent fill plus a filled icon state and the state text (never color
// alone). A tile with a drawer has a chevron segment on its right that opens
// it (Enter does the same from the keyboard; Space toggles).
//
//   QuickTile { key: "dnd"; label: qsTr("Do Not Disturb"); iconName: "bell-off"
//               on: Services.notifications.dnd; sub: on ? qsTr("On") : qsTr("Off")
//               onActivated: Services.notifications.setDnd(!on) }
//
// Edit mode (`editing`): no toggling; a remove button, a grip, the tile drags
// (`dragging`, `dragOffset`; the owner reorders on `dropped`), Shift+arrows
// ask to move it (`moveRequested(step)`), Delete asks to remove it.
import QtQuick
import QtQuick.Templates as T
import Lugh.UI

T.AbstractButton {
    id: tile

    property string key: ""
    property string label: ""
    property string sub: ""
    property string iconName: ""
    property bool on: false
    property bool hasDrawer: false
    property bool drawerOpen: false
    property bool editing: false
    readonly property bool dragging: drag.active
    readonly property point dragOffset: Qt.point(drag.activeTranslation.x, drag.activeTranslation.y)
    readonly property real radius: height / 2

    signal activated()
    signal drawerRequested()
    signal removeRequested()
    signal moveRequested(int step)
    signal navigate(int dx, int dy)
    signal dropped()

    readonly property bool _lit: on && !editing
    readonly property color _fg: _lit ? Theme.onAccent : Theme.text
    readonly property color _fgMuted: _lit ? Qt.rgba(Theme.onAccent.r, Theme.onAccent.g, Theme.onAccent.b, 0.78)
                                           : Theme.textMuted

    implicitHeight: 48
    focusPolicy: Qt.StrongFocus
    hoverEnabled: true
    z: dragging ? 10 : 0

    Accessible.role: Accessible.Button
    Accessible.name: editing ? qsTr("%1, drag or Shift+arrow keys to move, Delete to remove").arg(label) : label
    Accessible.description: sub
    Accessible.checkable: !editing
    Accessible.checked: on
    Accessible.onPressAction: if (!editing) activated()

    onClicked: if (!editing) activated()
    Keys.onReturnPressed: event => { if (!editing && hasDrawer) drawerRequested(); else if (!editing) activated(); }
    Keys.onEnterPressed: event => { if (!editing && hasDrawer) drawerRequested(); else if (!editing) activated(); }
    Keys.onPressed: event => {
        const shift = event.modifiers & Qt.ShiftModifier;
        const dx = event.key === Qt.Key_Left ? -1 : event.key === Qt.Key_Right ? 1 : 0;
        const dy = event.key === Qt.Key_Up ? -1 : event.key === Qt.Key_Down ? 1 : 0;
        if (editing && (event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace)) {
            removeRequested();
        } else if (dx !== 0 || dy !== 0) {
            if (editing && shift) moveRequested(dx !== 0 ? dx : dy * 2);
            else navigate(dx, dy);
        } else {
            return;
        }
        event.accepted = true;
    }

    DragHandler {
        id: drag
        enabled: tile.editing
        target: null
        cursorShape: Qt.ClosedHandCursor
        onActiveChanged: if (!active) tile.dropped()
    }

    background: Item {
        Rectangle {
            id: fill
            anchors.fill: parent
            radius: tile.radius
            antialiasing: true
            color: tile._lit ? Theme.accent
                 : Theme.dark ? Qt.rgba(1, 1, 1, 0.07) : Qt.rgba(1, 1, 1, 0.6)
            border.width: tile._lit ? 0 : 1
            border.color: tile.editing ? Qt.rgba(Theme.focusRing.r, Theme.focusRing.g, Theme.focusRing.b, 0.55) : Theme.glassBorder
            Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durMicro) } }
        }
        Rectangle {
            anchors.fill: parent
            radius: tile.radius
            antialiasing: true
            color: tile.pressed || tile.dragging ? Theme.pressedOverlay : Theme.hoverOverlay
            visible: tile.enabled && (tile.pressed || tile.dragging || (tile.hovered && !chevron.containsMouse))
        }
        FocusRing { target: fill; show: tile.visualFocus }
    }

    contentItem: Item {
        Icon {
            id: icon
            x: 14
            anchors.verticalCenter: parent.verticalCenter
            name: tile.iconName
            size: 18
            color: tile._fg
        }
        Column {
            anchors.left: icon.right
            anchors.leftMargin: 10
            anchors.right: trailing.left
            anchors.rightMargin: Theme.space4
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0

            Text {
                width: parent.width
                text: tile.label
                font: Theme.typeLabel
                color: tile._fg
                elide: Text.ElideRight
                maximumLineCount: 1
            }
            Text {
                width: parent.width
                text: tile.editing ? qsTr("Drag to move") : tile.sub
                visible: text !== ""
                font: Theme.typeCaption
                color: tile._fgMuted
                elide: Text.ElideRight
                maximumLineCount: 1
            }
        }

        Item {
            id: trailing
            anchors.right: parent.right
            width: tile.editing ? 36 : tile.hasDrawer ? 30 : 10
            height: parent.height

            // Drawer chevron (normal mode).
            Rectangle {
                x: 0
                anchors.verticalCenter: parent.verticalCenter
                width: 1
                height: 20
                visible: tile.hasDrawer && !tile.editing
                color: tile._fg
                opacity: 0.18
            }
            MouseArea {
                id: chevron
                anchors.fill: parent
                visible: tile.hasDrawer && !tile.editing
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: tile.drawerRequested()
                Accessible.role: Accessible.Button
                Accessible.name: tile.drawerOpen ? qsTr("Hide %1 details").arg(tile.label) : qsTr("%1 details").arg(tile.label)
                Accessible.onPressAction: tile.drawerRequested()

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 4
                    anchors.leftMargin: 2
                    radius: height / 2
                    color: chevron.pressed ? Theme.pressedOverlay : Theme.hoverOverlay
                    visible: chevron.containsMouse
                }
                Icon {
                    anchors.centerIn: parent
                    anchors.horizontalCenterOffset: -1
                    name: tile.drawerOpen ? "chevron-up" : "chevron-down"
                    size: 14
                    color: tile._fg
                }
            }

            // Remove (edit mode).
            T.AbstractButton {
                id: remove
                objectName: "remove"
                anchors.centerIn: parent
                anchors.horizontalCenterOffset: -4
                visible: tile.editing
                width: 26
                height: 26
                focusPolicy: Qt.NoFocus
                hoverEnabled: true
                onClicked: tile.removeRequested()
                Accessible.role: Accessible.Button
                Accessible.name: qsTr("Remove %1").arg(tile.label)
                background: Rectangle {
                    radius: 13
                    antialiasing: true
                    color: remove.pressed ? Theme.pressedOverlay : remove.hovered ? Theme.hoverOverlay : "transparent"
                }
                contentItem: Item {
                    Icon {
                        anchors.centerIn: parent
                        name: "circle-minus"
                        size: 16
                        color: remove.hovered ? Theme.danger : Theme.textMuted
                    }
                }
            }
        }
    }
}
