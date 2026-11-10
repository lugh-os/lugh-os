// Surface popup (API.md): radiusLg, popover-level Shadow, 16 px padding.
//
//   Popover { id: pop; y: button.height + 4; glass: true; ColumnLayout { ... } }
//   pop.open()
//
// Enter: fade + scale 0.96 → 1 + a 4 px slide toward its resting place
// (down when it opens below its parent, up when it opens above), durMedium.
// Exit: fade, durSmall. Reduce motion: fades only, durReduced.
// Closes on Esc and on a press outside.
import QtQuick
import QtQuick.Templates as T

T.Popup {
    id: control

    property bool glass: false
    // Current slide offset (px), driven by the enter transition.
    property real _slide: 0

    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset,
                            implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset,
                             implicitContentHeight + topPadding + bottomPadding)

    padding: Theme.space16
    closePolicy: T.Popup.CloseOnEscape | T.Popup.CloseOnPressOutside
    focus: true

    background: GlassPanel {
        radius: Theme.radiusLg
        elevation: "popover"
        _opaque: !control.glass || !Theme.transparency
        transform: Translate { y: control._slide }
    }

    contentItem: Item {
        transform: Translate { y: control._slide }
    }

    enter: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "opacity"; from: 0; to: 1
                duration: Theme.dur(Theme.durMedium)
                easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
            }
            NumberAnimation {
                property: "scale"; from: Theme.reduceMotion ? 1 : 0.96; to: 1
                duration: Theme.dur(Theme.durMedium)
                easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
            }
            NumberAnimation {
                property: "_slide"
                from: Theme.reduceMotion ? 0 : (control.y < 0 ? 4 : -4); to: 0
                duration: Theme.dur(Theme.durMedium)
                easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
            }
        }
    }

    exit: Transition {
        NumberAnimation {
            property: "opacity"; to: 0
            duration: Theme.dur(Theme.durSmall)
            easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
        }
    }
}
