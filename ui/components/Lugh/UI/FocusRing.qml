// Keyboard focus ring (DESIGN-SYSTEM §7): a 2 px accent ring drawn 2 px
// outside its target. Shown only for keyboard focus (`visualFocus`) on
// controls; plain Items fall back to `activeFocus`.
//
//   T.Button { id: b; FocusRing {} }                    // ring around b
//   FocusRing { target: track; radius: track.radius + 4 } // around a child
//
// Concentric by default: the ring's outer radius is the target's radius plus
// the offset and the ring width, so the gap reads even all the way round.
import QtQuick

Rectangle {
    id: ring

    property Item target: parent
    property bool show: target ? (target.visualFocus ?? target.activeFocus) : false

    readonly property int _outset: Theme.focusRingOffset + Theme.focusRingWidth

    x: target ? (target === parent ? 0 : target.x) - _outset : 0
    y: target ? (target === parent ? 0 : target.y) - _outset : 0
    width: target ? target.width + 2 * _outset : 0
    height: target ? target.height + 2 * _outset : 0
    radius: (target && target.radius !== undefined ? target.radius : 0) + _outset
    z: 100

    color: "transparent"
    border.width: Theme.focusRingWidth
    border.color: Theme.focusRing
    antialiasing: true

    opacity: show ? 1 : 0
    visible: opacity > 0
    Behavior on opacity {
        NumberAnimation {
            duration: Theme.dur(Theme.durMicro)
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Theme.easeStandard
        }
    }

    Accessible.ignored: true
}
