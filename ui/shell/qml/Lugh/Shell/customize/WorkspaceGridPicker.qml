// Pick the workspace grid (rows × columns, up to 4 × 4) by pointing at a
// cell, KDE-style: the cells from the top-left to the hovered one light up,
// a click sets them. Arrows grow/shrink it by one (Left/Right columns,
// Up/Down rows). Chosen cells carry their workspace number (not color alone).
import QtQuick
import Lugh.UI

Item {
    id: picker

    property int rows: 2
    property int cols: 2
    readonly property int max: 4
    signal picked(int rows, int cols)

    property int _hr: -1
    property int _hc: -1
    readonly property int _cell: 30
    readonly property int _gap: 4
    readonly property bool previewing: _hr >= 0
    readonly property int shownRows: previewing ? _hr + 1 : rows
    readonly property int shownCols: previewing ? _hc + 1 : cols

    implicitWidth: max * _cell + (max - 1) * _gap + 8
    implicitHeight: implicitWidth * 0.8
    activeFocusOnTab: true

    Accessible.role: Accessible.Table
    Accessible.name: qsTr("Workspace grid")
    Accessible.description: qsTr("%1 rows by %2 columns. Arrow keys change it.").arg(rows).arg(cols)

    Keys.onPressed: event => {
        let r = rows, c = cols;
        if (event.key === Qt.Key_Left) c = Math.max(1, c - 1);
        else if (event.key === Qt.Key_Right) c = Math.min(max, c + 1);
        else if (event.key === Qt.Key_Up) r = Math.max(1, r - 1);
        else if (event.key === Qt.Key_Down) r = Math.min(max, r + 1);
        else return;
        event.accepted = true;
        if (r !== rows || c !== cols) picked(r, c);
    }

    Rectangle {
        anchors.fill: parent
        radius: Theme.radiusMd
        color: Theme.hoverOverlay
        border.width: 1
        border.color: Theme.glassBorder
        FocusRing { show: picker.activeFocus && picker._kbd }
    }
    property bool _kbd: true

    Grid {
        id: grid
        anchors.centerIn: parent
        columns: picker.max
        rowSpacing: picker._gap
        columnSpacing: picker._gap
        readonly property real cellH: (picker.height - 8 - (picker.max - 1) * picker._gap) / picker.max

        Repeater {
            model: picker.max * picker.max
            Rectangle {
                required property int index
                readonly property int r: Math.floor(index / picker.max)
                readonly property int c: index % picker.max
                readonly property bool on: r < picker.shownRows && c < picker.shownCols
                width: picker._cell
                height: grid.cellH
                radius: 5
                color: on ? (picker.previewing ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.55) : Theme.accent)
                          : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, Theme.dark ? 0.10 : 0.08)
                border.width: on ? 0 : 1
                border.color: Theme.glassBorder
                Behavior on color { ColorAnimation { duration: Theme.durMicro } }
                Text {
                    anchors.centerIn: parent
                    visible: parent.on
                    text: parent.r * picker.shownCols + parent.c + 1
                    font: Theme.typeCaptionTnum
                    color: Theme.onAccent
                }
            }
        }
    }

    MouseArea {
        anchors.fill: grid
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        function cellAt(x, y) {
            const c = Math.min(picker.max - 1, Math.max(0, Math.floor(x / (picker._cell + picker._gap))));
            const r = Math.min(picker.max - 1, Math.max(0, Math.floor(y / (grid.cellH + picker._gap))));
            return [r, c];
        }
        onPositionChanged: mouse => { const rc = cellAt(mouse.x, mouse.y); picker._hr = rc[0]; picker._hc = rc[1]; }
        onExited: { picker._hr = -1; picker._hc = -1; }
        onPressed: { picker._kbd = false; picker.forceActiveFocus(Qt.MouseFocusReason); }
        onClicked: mouse => { const rc = cellAt(mouse.x, mouse.y); picker.picked(rc[0] + 1, rc[1] + 1); }
    }
    Keys.onReleased: _kbd = true
    onActiveFocusChanged: if (!activeFocus) _kbd = true
}
