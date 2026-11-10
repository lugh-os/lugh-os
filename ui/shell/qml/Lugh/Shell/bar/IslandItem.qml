// A hit target inside a non-interactive Island (the Lugh mark, …): full island
// height for the pointer, a capsule 4 px inside the island for hover, pressed
// and `active` (its overlay is open), squish on press. The focus ring (2 px
// offset + 2 px ring around the capsule) lands exactly on the island's edge.
//
//   IslandItem {
//       active: ShellState.lughMenuOpen
//       Accessible.name: qsTr("Lugh menu")
//       contentItem: Item { implicitWidth: 16; ... }
//       onClicked: ShellState.toggleLughMenu()
//   }
import QtQuick
import QtQuick.Templates as T
import Lugh.UI

T.AbstractButton {
    id: control

    property bool active: false

    implicitWidth: implicitContentWidth + leftPadding + rightPadding
    implicitHeight: Theme.islandHeight
    leftPadding: Theme.space8
    rightPadding: Theme.space8
    topPadding: 0
    bottomPadding: 0
    hoverEnabled: true
    focusPolicy: Qt.TabFocus

    scale: down && !Theme.reduceMotion ? Theme.squishScale : 1
    Behavior on scale {
        enabled: !Theme.reduceMotion
        SpringAnimation {
            spring: Theme.snappySpring; damping: Theme.snappyDamping
            mass: Theme.snappyMass; epsilon: 0.0005
        }
    }

    Accessible.role: Accessible.Button
    Keys.onReturnPressed: clicked()
    Keys.onEnterPressed: clicked()

    background: Item {
        Rectangle {
            y: Theme.space4
            width: parent.width
            height: parent.height - 2 * Theme.space4
            radius: height / 2
            antialiasing: true
            color: control.down || control.active ? Theme.pressedOverlay
                 : control.hovered ? Theme.hoverOverlay : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.durMicro } }

            FocusRing { show: control.visualFocus }
        }
    }
}
