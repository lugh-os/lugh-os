// A glass panel that pops out of a point (the tray that opened it): the quick
// panel and the notification center.
//
//   PopSurface {
//       anchors.fill: parent                     // full-screen overlay
//       open: ShellState.controlCenterOpen
//       origin: Qt.point(isl.x + isl.width / 2, isl.y)   // scene coords
//       targetRect: Qt.rect(x, y, 360, body.implicitHeight + 28)
//       Column { id: body; ... }                 // laid out at the final size
//   }
//
// The panel always sits at targetRect with its content laid out at full size:
// it scales (0.92 → 1) towards `origin` and fades in together, so it looks
// complete from the first frame (shape and content move as one, nothing
// slides in before the shape exists). Open: Theme.durMedium decelerating;
// close: Theme.durSmall accelerating; both interruptible. Reduce motion: a
// fade only (Theme.dur → durReduced), no scale.
//
// `shown` (open, or still fading out) is what a window's `visible` binds to;
// `settled` is true once fully open. The panel swallows clicks and wheel on
// itself, so an outside-click catcher can sit below it in the overlay.
import QtQuick
import Lugh.UI

Item {
    id: root

    property bool open: false
    property rect targetRect: Qt.rect(0, 0, 0, 0)
    property point origin: Qt.point(targetRect.x + targetRect.width, targetRect.y + targetRect.height)
    property real radius: Theme.radiusXl
    property string elevation: "popover"
    default property alias content: holder.data

    readonly property bool shown: open || _t > 0
    readonly property bool settled: open && _t === 1
    readonly property real progress: _t
    readonly property alias panel: glass

    property real _t: open ? 1 : 0
    Behavior on _t {
        NumberAnimation {
            duration: root.open ? Theme.dur(Theme.durMedium) : Theme.dur(Theme.durSmall)
            easing.type: Easing.BezierSpline
            easing.bezierCurve: root.open ? Theme.easeStandard : [0.3, 0, 1, 1, 1, 1]
        }
    }

    GlassPanel {
        id: glass

        readonly property real s: Theme.reduceMotion ? 1 : 0.92 + 0.08 * root._t

        x: root.targetRect.x
        y: root.targetRect.y
        width: root.targetRect.width
        height: root.targetRect.height
        radius: root.radius
        elevation: root.elevation
        visible: root._t > 0
        opacity: root._t
        transform: Scale {
            origin.x: root.origin.x - glass.x
            origin.y: root.origin.y - glass.y
            xScale: glass.s
            yScale: glass.s
        }

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onWheel: wheel => { wheel.accepted = true }
        }

        Item {
            id: holder
            anchors.fill: parent
        }
    }
}
