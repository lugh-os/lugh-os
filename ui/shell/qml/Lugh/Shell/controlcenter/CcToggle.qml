// One round toggle of the control-center grid: an IconToggle that follows a
// service flag (`on`), reports itself to the caption line and takes part in
// the grid's arrow-key navigation (one Tab stop for the whole grid).
//
//   CcToggle { cc: root; key: "dnd"; label: qsTr("Do Not Disturb")
//              iconName: "bell"; checkedIconName: "bell-off"
//              on: Services.notifications.dnd; caption: on ? qsTr("On") : qsTr("Off")
//              onAct: Services.notifications.setDnd(!on) }
//
// `glyph` draws a short text (keyboard layout code) instead of an icon.
import QtQuick
import Lugh.UI

IconToggle {
    id: t

    property var cc
    property string key: ""
    property bool on: false
    property bool present: true
    property string caption: ""
    property string glyph: ""
    readonly property bool hot: _hover || visualFocus

    signal act()

    visible: present
    size: 48
    checked: on
    focusPolicy: cc && cc.gridKey === key ? Qt.StrongFocus : Qt.ClickFocus

    // A user toggle replaces the `checked` binding: act, then follow the
    // service again (setters are optimistic, so this does not flicker).
    onToggled: {
        act();
        checked = Qt.binding(() => t.on);
        cc.touched = key;
    }
    onDetailRequested: cc.openPage(key, visualFocus)
    onHotChanged: {
        if (hot) { cc.hot = key; cc.touched = key; }
        else if (cc.hot === key) cc.hot = "";
    }
    onActiveFocusChanged: if (activeFocus) cc.gridFocus = key

    Keys.onLeftPressed: cc.moveInGrid(t, -1, 0)
    Keys.onUpPressed: cc.moveInGrid(t, 0, -1)
    Keys.onDownPressed: cc.moveInGrid(t, 0, 1)
    // On a toggle with a drawer, → opens it (IconToggle); elsewhere it moves on.
    Keys.onRightPressed: if (!hasDetail) cc.moveInGrid(t, 1, 0)

    Text {
        anchors.centerIn: parent
        visible: t.glyph !== ""
        text: t.glyph
        font: Theme.typeLabel
        color: Theme.text
    }
}
