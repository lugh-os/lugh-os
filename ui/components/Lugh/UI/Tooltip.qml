// Tooltip (API.md): caption text, inverted colors for contrast, radiusSm.
//
//   IconButton { id: b; ... Tooltip { text: b.tooltip; visible: b.hovered || b.visualFocus } }
//
// Shows above its parent, centered, after `delay` (600 ms); wraps past 280 px.
// Fades in/out (durMicro; durReduced under reduce motion).
import QtQuick
import QtQuick.Templates as T

T.ToolTip {
    id: control

    readonly property int _maxWidth: 280

    x: parent ? Math.round((parent.width - implicitWidth) / 2) : 0
    y: -implicitHeight - Theme.space8

    implicitWidth: Math.min(_maxWidth, Math.max(implicitBackgroundWidth + leftInset + rightInset,
                                                implicitContentWidth + leftPadding + rightPadding))
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset,
                             implicitContentHeight + topPadding + bottomPadding)

    delay: 600
    timeout: -1
    margins: Theme.space8
    leftPadding: Theme.space8
    rightPadding: Theme.space8
    topPadding: Theme.space4 + 1
    bottomPadding: Theme.space4 + 1
    font: Theme.typeCaption
    closePolicy: T.Popup.CloseOnEscape | T.Popup.CloseOnPressOutsideParent | T.Popup.CloseOnReleaseOutsideParent

    contentItem: Text {
        text: control.text
        font: control.font
        color: Theme.bg
        wrapMode: Text.Wrap
        Accessible.ignored: true
    }

    background: Rectangle {
        radius: Theme.radiusSm
        color: Theme.text
    }

    enter: Transition {
        NumberAnimation {
            property: "opacity"; from: 0; to: 1
            duration: Theme.dur(Theme.durMicro)
            easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
        }
    }
    exit: Transition {
        NumberAnimation {
            property: "opacity"; from: 1; to: 0
            duration: Theme.dur(Theme.durMicro)
            easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
        }
    }
}
