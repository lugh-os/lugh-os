// Workspace dots for the logo island. The shape tells the state (never color
// alone):
//   current  → wide accent capsule
//   occupied → filled dot
//   empty    → hollow ring
// Click a dot to switch; the wheel steps through workspaces. The group is one
// Tab stop: Left/Right (or Up/Down) switch workspace, Home/End jump. Widths
// move with the liquid spring; the two that change are mirror images, so the
// group (and the island around it) keeps its width while switching.
import QtQuick
import Lugh.UI
import Lugh.Shell

Item {
    id: root

    readonly property int dotSize: 6
    readonly property int pillWidth: 18
    readonly property int gap: 6

    function _index() {
        const m = Services.wm.workspaces;
        for (let i = 0; i < m.count; ++i)
            if (m.get(i).wsId === Services.wm.activeWorkspace) return i;
        return -1;
    }
    function go(i) {
        const m = Services.wm.workspaces;
        if (m.count === 0) return;
        i = Math.max(0, Math.min(m.count - 1, i));
        if (m.get(i).wsId !== Services.wm.activeWorkspace)
            Services.wm.switchWorkspace(m.get(i).wsId);
    }
    function step(d) { go(Math.max(0, _index()) + d); }

    implicitWidth: row.width + 2 * Theme.space4
    implicitHeight: Theme.islandHeight
    visible: Services.wm.workspaces.count > 0
    activeFocusOnTab: true

    Accessible.role: Accessible.Grouping
    Accessible.name: qsTr("Workspaces")
    Accessible.description: qsTr("Left and right arrows switch workspace")
    Accessible.focusable: true

    Keys.onLeftPressed: step(-1)
    Keys.onRightPressed: step(1)
    Keys.onUpPressed: step(-1)
    Keys.onDownPressed: step(1)
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Home) { go(0); event.accepted = true; }
        else if (event.key === Qt.Key_End) { go(Services.wm.workspaces.count - 1); event.accepted = true; }
    }

    HoverHandler { id: groupHover }

    Rectangle {
        y: Theme.space4
        width: parent.width
        height: parent.height - 2 * Theme.space4
        radius: height / 2
        antialiasing: true
        color: groupHover.hovered ? Theme.hoverOverlay : "transparent"
        Behavior on color { ColorAnimation { duration: Theme.durMicro } }

        FocusRing { show: root.activeFocus }
    }

    Row {
        id: row
        x: Theme.space4
        height: parent.height

        Repeater {
            model: Services.wm.workspaces

            delegate: Item {
                id: cell

                required property int wsId
                required property string name
                required property bool occupied

                readonly property bool current: Services.wm.activeWorkspace === wsId
                property real dotWidth: current ? root.pillWidth : root.dotSize
                Behavior on dotWidth {
                    enabled: !Theme.reduceMotion
                    SpringAnimation {
                        spring: Theme.liquidSpring; damping: Theme.liquidDamping
                        mass: Theme.liquidMass; epsilon: 0.05
                    }
                }

                objectName: "workspace-" + wsId
                width: dotWidth + root.gap
                height: row.height

                Accessible.role: Accessible.RadioButton
                Accessible.checkable: true
                Accessible.checked: current
                Accessible.name: qsTr("Workspace %1").arg(name)
                Accessible.description: current ? qsTr("Current workspace")
                    : occupied ? qsTr("Has open windows") : qsTr("Empty")
                Accessible.onPressAction: Services.wm.switchWorkspace(wsId)

                HoverHandler { id: hover }
                TapHandler {
                    id: tap
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: Services.wm.switchWorkspace(cell.wsId)
                }

                Rectangle {
                    x: root.gap / 2
                    y: Math.round((parent.height - height) / 2)
                    width: cell.dotWidth
                    height: root.dotSize
                    radius: height / 2
                    antialiasing: true
                    readonly property bool filled: cell.current || cell.occupied
                    color: cell.current ? Theme.accent
                         : cell.occupied ? (hover.hovered ? Theme.text : Theme.textMuted)
                         : "transparent"
                    border.width: filled ? 0 : 1.5
                    border.color: hover.hovered ? Theme.text : Theme.textMuted
                    scale: Theme.reduceMotion ? 1 : tap.pressed ? 0.8 : hover.hovered && !cell.current ? 1.35 : 1
                    Behavior on scale {
                        enabled: !Theme.reduceMotion
                        SpringAnimation {
                            spring: Theme.snappySpring; damping: Theme.snappyDamping
                            mass: Theme.snappyMass; epsilon: 0.005
                        }
                    }
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
            root.step(_acc > 0 ? -1 : 1);
            _acc = 0;
        }
    }
}
