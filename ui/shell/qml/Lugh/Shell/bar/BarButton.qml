// One clickable item in the top bar: full bar height for the hit area (the
// pointer can be thrown at the screen edge), a 22 px rounded pill for hover,
// pressed and "open" (its overlay is showing) states.
//
//   BarButton {
//       active: ShellState.controlCenterOpen
//       Accessible.name: qsTr("Quick settings")
//       contentItem: Row { ... }
//       onClicked: ShellState.toggleControlCenter()
//   }
//
// The pill sits 4 px below the bar's top and above its bottom, so the
// keyboard focus ring (2 px offset + 2 px width) exactly fills the 30 px bar.
import QtQuick
import QtQuick.Templates as T
import Lugh.UI

T.AbstractButton {
    id: control

    // Its overlay is open: hold the pressed fill so the bar shows where it came from.
    property bool active: false
    readonly property alias pill: pill

    implicitWidth: Math.max(Theme.hitTarget, implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: 30
    leftPadding: Theme.space8
    rightPadding: Theme.space8
    topPadding: 0
    bottomPadding: 0

    hoverEnabled: true
    focusPolicy: Qt.TabFocus
    opacity: enabled ? 1 : Theme.disabledOpacity

    Accessible.role: Accessible.Button
    Keys.onReturnPressed: control.clicked()
    Keys.onEnterPressed: control.clicked()

    background: Item {
        Rectangle {
            id: pill
            y: 4
            width: parent.width
            height: parent.height - 8
            radius: Theme.radiusSm
            color: control.down || control.active ? Theme.pressedOverlay
                 : control.hovered ? Theme.hoverOverlay
                 : "transparent"
            Behavior on color {
                ColorAnimation { duration: Theme.durMicro; easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard }
            }
        }
        FocusRing {
            target: pill
            show: control.visualFocus
        }
    }
}
