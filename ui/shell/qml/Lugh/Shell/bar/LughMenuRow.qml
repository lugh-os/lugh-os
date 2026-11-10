// One compact row in the LughMenu (36 px: icon + label + shortcut hint),
// driven by the menu's own keyboard/hover "current" index. A row with a
// `disabledReason` is dimmed, says "Soon" where the shortcut would be, and
// explains itself in a tooltip on hover and in its accessible description.
import QtQuick
import QtQuick.Templates as T
import Lugh.UI

T.AbstractButton {
    id: row

    property string iconName: ""
    property string shortcutText: ""
    property string disabledReason: ""
    property bool current: false
    readonly property bool actionable: disabledReason === ""

    signal triggered()
    signal hoveredIn()

    implicitHeight: 36
    leftPadding: Theme.space12 - Theme.space2
    rightPadding: Theme.space12 - Theme.space2
    hoverEnabled: true
    focusPolicy: Qt.NoFocus

    Accessible.role: Accessible.MenuItem
    Accessible.name: text
    Accessible.description: disabledReason !== "" ? disabledReason : shortcutText
    Accessible.focused: current

    onHoveredChanged: if (hovered && actionable) hoveredIn()
    onClicked: if (actionable) triggered()

    background: Rectangle {
        radius: Theme.radiusLg
        antialiasing: true
        color: !row.actionable ? "transparent"
             : row.down ? Theme.pressedOverlay
             : row.current ? Theme.hoverOverlay : "transparent"
        Behavior on color { ColorAnimation { duration: Theme.durMicro } }
    }

    contentItem: Item {
        opacity: row.actionable ? 1 : Theme.disabledOpacity
        scale: row.down && row.actionable && !Theme.reduceMotion ? Theme.squishScale : 1
        Behavior on scale {
            enabled: !Theme.reduceMotion
            SpringAnimation {
                spring: Theme.snappySpring; damping: Theme.snappyDamping
                mass: Theme.snappyMass; epsilon: 0.0005
            }
        }

        Icon {
            id: icon
            anchors.verticalCenter: parent.verticalCenter
            name: row.iconName
            size: 16
            color: row.current && row.actionable ? Theme.text : Theme.textMuted
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            x: icon.width + Theme.space12 - Theme.space2
            width: hint.x - Theme.space8 - x
            text: row.text
            font: Theme.typeLabel
            color: Theme.text
            elide: Text.ElideRight
            Accessible.ignored: true
        }
        Text {
            id: hint
            anchors.verticalCenter: parent.verticalCenter
            x: parent.width - width
            text: row.actionable ? row.shortcutText : qsTr("Soon")
            font: Theme.typeCaption
            color: Theme.textMuted
            Accessible.ignored: true
        }
    }

    Tooltip {
        text: row.disabledReason
        visible: row.hovered && row.disabledReason !== ""
        // Beside the menu rather than over the rows above.
        x: row.width + Theme.space12
        y: Math.round((row.height - implicitHeight) / 2)
    }
}
