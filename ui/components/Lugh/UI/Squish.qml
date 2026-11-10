// Liquid press/hover feel for any content (docs/design/lugh-mode.md §2).
//
//   Squish { pressed: area.pressed; hovered: area.containsMouse; lift: 2
//            AppIcon { iconName: "firefox"; size: 48 } }
//
// A wrapper sized to its content child (give the child its own size; do not
// anchor it to the Squish). `pressed` scales the content to `pressScale`,
// `hovered` raises it by `lift` px; both settle with the snappy spring. Under
// reduce motion nothing moves. It takes no input itself.
import QtQuick

Item {
    id: root

    property bool pressed: false
    property bool hovered: false
    property real lift: 0
    property real pressScale: Theme.squishScale
    default property alias content: holder.data

    implicitWidth: holder.childrenRect.width
    implicitHeight: holder.childrenRect.height

    Item {
        id: holder
        width: root.width
        height: root.height
        scale: root.pressed && !Theme.reduceMotion ? root.pressScale : 1
        y: root.hovered && !root.pressed && !Theme.reduceMotion ? -root.lift : 0

        Behavior on scale {
            enabled: !Theme.reduceMotion
            SpringAnimation {
                spring: Theme.snappySpring; damping: Theme.snappyDamping
                mass: Theme.snappyMass; epsilon: 0.0005
            }
        }
        Behavior on y {
            enabled: !Theme.reduceMotion
            SpringAnimation {
                spring: Theme.snappySpring; damping: Theme.snappyDamping
                mass: Theme.snappyMass; epsilon: 0.05
            }
        }
    }
}
