// Workspace indicator for the Panel: a tiny rows × cols grid of cells
// (ShellSettings.workspaceRows/Cols), workspace n at cell n − 1, row-major.
// The shape tells the state, never color alone:
//   current  → solid accent cell
//   occupied → outline with a filled core
//   empty    → hollow outline
// Click opens the overview; the wheel and PageUp/PageDown step through
// workspaces (wrapping when ShellSettings.workspaceWrap).
import QtQuick
import Lugh.UI
import Lugh.Shell

PanelButton {
    id: grid

    readonly property int rows: Math.max(1, Math.min(4, ShellSettings.workspaceRows))
    readonly property int cols: Math.max(1, Math.min(4, ShellSettings.workspaceCols))
    readonly property int count: rows * cols
    // Cell size fits the button height: 2 rows → 8 px cells, 4 rows → 4 px.
    readonly property int gap: 2
    readonly property int cellH: Math.max(4, Math.floor((height - 2 * Theme.space8 - (rows - 1) * gap) / rows))
    readonly property int cellW: Math.round(cellH * 1.35)

    function _occupied(wsId) {
        const m = Services.wm.workspaces;
        for (let i = 0; i < m.count; ++i) {
            const w = m.get(i);
            if (w.wsId === wsId) return w.occupied === true;
        }
        return false;
    }
    function step(d) {
        let i = Services.wm.activeWorkspace - 1 + d;
        if (ShellSettings.workspaceWrap) i = (i + count) % count;
        else i = Math.max(0, Math.min(count - 1, i));
        if (i + 1 !== Services.wm.activeWorkspace) Services.wm.switchWorkspace(i + 1);
    }

    label: qsTr("Workspace %1 of %2").arg(Services.wm.activeWorkspace).arg(count)
    active: ShellState.overviewOpen
    Accessible.description: qsTr("Open the workspace overview; Page Up and Page Down switch workspace")
    leftPadding: Theme.space8 + 2
    rightPadding: Theme.space8 + 2
    onClicked: ShellState.toggleOverview()

    Keys.onPressed: event => {
        if (event.key === Qt.Key_PageUp) { step(-1); event.accepted = true; }
        else if (event.key === Qt.Key_PageDown) { step(1); event.accepted = true; }
    }

    // Wheel / two-finger scroll steps one workspace per notch.
    WheelHandler {
        property real _acc: 0
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: event => {
            _acc += event.angleDelta.y !== 0 ? event.angleDelta.y : -event.angleDelta.x;
            if (Math.abs(_acc) < 120) return;
            grid.step(_acc > 0 ? -1 : 1);
            _acc = 0;
        }
    }

    contentItem: Item {
        implicitWidth: grid.cols * grid.cellW + (grid.cols - 1) * grid.gap
        implicitHeight: grid.rows * grid.cellH + (grid.rows - 1) * grid.gap

        Grid {
            anchors.centerIn: parent
            rows: grid.rows
            columns: grid.cols
            spacing: grid.gap

            Repeater {
                model: grid.count
                Item {
                    id: cell
                    required property int index
                    readonly property int wsId: index + 1
                    readonly property bool current: Services.wm.activeWorkspace === wsId
                    // Re-read when the model changes.
                    readonly property bool occupied: Services.wm.workspaces.count >= 0 && grid._occupied(wsId)
                    width: grid.cellW
                    height: grid.cellH

                    Rectangle {
                        anchors.fill: parent
                        radius: Math.min(2.5, height / 2)
                        antialiasing: true
                        color: cell.current ? Theme.focusRing : "transparent"
                        border.width: cell.current ? 0 : 1
                        border.color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, cell.occupied ? 0.7 : 0.45)
                        Behavior on color {
                            ColorAnimation { duration: Theme.dur(Theme.durSmall); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard }
                        }
                        // Occupied: a filled core inside the outline.
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 2
                            radius: 1
                            visible: cell.occupied && !cell.current
                            color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.7)
                        }
                    }
                }
            }
        }
    }
}
