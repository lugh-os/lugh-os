// Workspace indicator for the bar (Lugh mode, right side). One cell per
// workspace; the shape tells the state, so it never relies on color alone:
//   current  → wide accent pill
//   occupied → filled muted dot
//   empty    → hollow muted ring
// Click a cell to switch; the wheel steps through workspaces. The current
// pill's width springs between cells (cross-fade only under reduce motion).
import QtQuick
import QtQuick.Templates as T
import Lugh.UI
import Lugh.Shell

Row {
    id: root

    readonly property int dotSize: 8
    readonly property int pillWidth: 20

    spacing: 0
    Accessible.role: Accessible.Grouping
    Accessible.name: qsTr("Workspaces")

    Repeater {
        model: Services.wm.workspaces

        delegate: T.AbstractButton {
            id: cell

            required property int index
            required property int wsId
            required property string name
            required property bool occupied

            readonly property bool current: Services.wm.activeWorkspace === wsId
            property real dotWidth: current ? root.pillWidth : root.dotSize
            Behavior on dotWidth {
                enabled: !Theme.reduceMotion
                SpringAnimation {
                    spring: Theme.springSpring
                    damping: Theme.springDamping
                    epsilon: Theme.springEpsilon
                }
            }

            implicitWidth: Math.round(dotWidth) + 2 * (Theme.space4 + Theme.space2)
            implicitHeight: 30
            hoverEnabled: true
            focusPolicy: Qt.TabFocus
            objectName: "workspace-" + wsId

            Accessible.role: Accessible.RadioButton
            Accessible.checkable: true
            Accessible.checked: current
            Accessible.name: qsTr("Workspace %1").arg(name)
            Accessible.description: current ? qsTr("Current workspace")
                : occupied ? qsTr("Has open windows") : qsTr("Empty")

            onClicked: Services.wm.switchWorkspace(wsId)
            Keys.onReturnPressed: Services.wm.switchWorkspace(wsId)
            Keys.onEnterPressed: Services.wm.switchWorkspace(wsId)

            background: Item {
                Rectangle {
                    id: hoverPill
                    x: 2
                    y: 4
                    width: parent.width - 4
                    height: parent.height - 8
                    radius: Theme.radiusSm
                    color: cell.down ? Theme.pressedOverlay : cell.hovered ? Theme.hoverOverlay : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.durMicro } }
                }
                FocusRing {
                    target: hoverPill
                    show: cell.visualFocus
                }
            }

            contentItem: Item {
                Rectangle {
                    // Centered with whole-pixel geometry so the 8 px dot stays crisp.
                    x: Math.round((parent.width - width) / 2)
                    y: Math.round((parent.height - height) / 2)
                    width: Math.round(cell.dotWidth)
                    height: root.dotSize
                    radius: height / 2
                    antialiasing: true
                    readonly property bool filled: cell.current || cell.occupied
                    color: cell.current ? Theme.accent
                         : cell.occupied ? Theme.textMuted
                         : "transparent"
                    border.width: filled ? 0 : 1.5
                    border.color: Theme.textMuted
                    Behavior on color {
                        ColorAnimation { duration: Theme.dur(Theme.durSmall); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard }
                    }
                }
            }
        }
    }

    // Wheel / two-finger scroll steps one workspace per notch.
    WheelHandler {
        property real _acc: 0
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: event => {
            _acc += event.angleDelta.y !== 0 ? event.angleDelta.y : -event.angleDelta.x;
            if (Math.abs(_acc) < 120)
                return;
            const step = _acc > 0 ? -1 : 1;
            _acc = 0;
            const m = Services.wm.workspaces;
            let i = 0;
            for (; i < m.count; ++i)
                if (m.get(i).wsId === Services.wm.activeWorkspace) break;
            const next = Math.max(0, Math.min(m.count - 1, i + step));
            if (next !== i)
                Services.wm.switchWorkspace(m.get(next).wsId);
        }
    }
}
