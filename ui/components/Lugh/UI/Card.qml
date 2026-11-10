// Content card (API.md): surface + 1 px border, radiusMd, padded content.
//
//   Card { ColumnLayout { width: parent.width; ... } }
//   Card { elevated: true; interactive: true; onClicked: open(); ... }
//
// `elevated` adds a menu-level Shadow. `interactive` makes it a button:
// hover/pressed overlays, keyboard focus ring, Space/Enter/click → clicked().
import QtQuick

Rectangle {
    id: root

    property int padding: Theme.space16
    property bool elevated: false
    property bool interactive: false
    default property alias content: contentArea.data

    signal clicked()

    // Keyboard focus only (the ring never shows for mouse clicks).
    readonly property bool visualFocus: activeFocus && _keyboardFocus
    property bool _keyboardFocus: false

    implicitWidth: _childMax("implicitWidth") + 2 * padding
    implicitHeight: _childMax("implicitHeight") + 2 * padding
    function _childMax(prop) {
        let m = 0;
        for (let i = 0; i < contentArea.children.length; ++i)
            m = Math.max(m, contentArea.children[i][prop] || 0);
        return m;
    }

    radius: Theme.radiusMd
    color: Theme.surface
    border.width: 1
    border.color: Theme.border
    antialiasing: true

    activeFocusOnTab: interactive
    property bool _mouseFocus: false
    onActiveFocusChanged: {
        _keyboardFocus = activeFocus && !_mouseFocus;
        _mouseFocus = false;
    }

    Accessible.role: interactive ? Accessible.Button : Accessible.Pane
    Accessible.focusable: interactive
    Accessible.onPressAction: if (interactive) root.clicked()

    Keys.onPressed: event => {
        if (interactive && !event.isAutoRepeat && (event.key === Qt.Key_Space
                || event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
            event.accepted = true;
            root.clicked();
        }
    }

    Shadow {
        target: root
        radius: root.radius
        elevation: root.elevated ? "menu" : "none"
    }

    // hover / pressed overlay (DESIGN-SYSTEM §7), under the content
    Rectangle {
        anchors.fill: parent
        anchors.margins: 1
        radius: Math.max(0, root.radius - 1)
        visible: root.interactive
        color: mouse.pressed ? Theme.pressedOverlay
            : mouse.containsMouse ? Theme.hoverOverlay : "transparent"
        Behavior on color { ColorAnimation { duration: Theme.durMicro } }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        enabled: root.interactive
        hoverEnabled: root.interactive
        cursorShape: root.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
        onPressed: {
            root._mouseFocus = !root.activeFocus;
            root._keyboardFocus = false;
            root.forceActiveFocus(Qt.MouseFocusReason);
        }
        onClicked: root.clicked()
    }

    Item {
        id: contentArea
        anchors.fill: parent
        anchors.margins: root.padding
    }

    FocusRing {
        target: root
        show: root.interactive && root.visualFocus
    }
}
