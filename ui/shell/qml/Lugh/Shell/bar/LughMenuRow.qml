// One action row in the LughMenu: a Lugh.UI MenuItem driven by the menu's own
// keyboard/hover "current" index (it lives outside a T.Menu). A row with a
// `disabledReason` is dimmed and explains itself in a tooltip on hover and in
// its accessible description.
import QtQuick
import Lugh.UI

Item {
    id: row

    property alias text: item.text
    property alias iconName: item.iconName
    property alias shortcutText: item.shortcutText
    property string disabledReason: ""
    property bool current: false
    readonly property bool actionable: disabledReason === ""

    signal triggered()
    signal hoveredIn()

    implicitWidth: item.implicitWidth
    implicitHeight: item.implicitHeight

    MenuItem {
        id: item
        anchors.fill: parent
        enabled: row.actionable
        highlighted: row.current
        focusPolicy: Qt.NoFocus
        Accessible.description: row.disabledReason !== "" ? row.disabledReason : shortcutText
        onHoveredChanged: if (hovered) row.hoveredIn()
        onClicked: row.triggered()
    }

    HoverHandler {
        id: reasonHover
        enabled: !row.actionable
    }
    Tooltip {
        text: row.disabledReason
        visible: reasonHover.hovered && row.disabledReason !== ""
        // Beside the menu rather than over the rows above.
        x: row.width + Theme.space12
        y: Math.round((row.height - implicitHeight) / 2)
    }
}
