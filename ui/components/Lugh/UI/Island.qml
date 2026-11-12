// Floating glass capsule (docs/design/lugh-mode.md §1): the bar islands,
// toasts, the OSD.
//
//   Island {
//       text: qsTr("Control center")          // accessible name
//       active: ShellState.controlCenterOpen
//       onClicked: ShellState.toggleControlCenter()
//       Icon { name: "wifi"; size: 16; anchors.verticalCenter: parent.verticalCenter }
//       Text { text: "64"; font: Theme.typeLabelTnum; color: Theme.text
//              anchors.verticalCenter: parent.verticalCenter }
//   }
//
// Children go into a Row (spacing = `spacing`, 8 px) centered vertically, with
// `padding` left and right; children of different heights center themselves
// with `anchors.verticalCenter: parent.verticalCenter`. The width follows the
// content and glides with the liquid spring when the content changes size
// (`animateWidth`; never under reduce motion, never on first show: the
// spring arms 150 ms after creation, once fonts, icons and late children
// have settled the width, so islands never slide open at startup). Anchor the
// island by an edge or its center and it grows from there.
//
// Press = squish, hover = brighten, `active` = held highlight (its panel is
// open), FocusRing on keyboard focus. `interactive: false` makes it a plain
// surface: no hover/press/focus, clicks on it are swallowed, children still
// work. `sceneRect` is its rect in scene (window) coordinates for
// MorphPanel.originRect; it follows the island and its ancestors' x/y — call
// updateSceneRect() after anything else moves it (reparenting an ancestor).
import QtQuick
import QtQuick.Templates as T

T.Button {
    id: control

    property real radius: height / 2
    property string elevation: "menu"
    property bool active: false
    property bool interactive: true
    property bool animateWidth: true
    default property alias content: row.data
    readonly property rect sceneRect: _sceneRect

    property rect _sceneRect: Qt.rect(0, 0, 0, 0)
    readonly property real _targetW: row.implicitWidth + leftPadding + rightPadding
    property real _w: _targetW
    property bool _ready: false
    property var _watched: []
    readonly property bool _down: interactive && down

    function updateSceneRect() {
        const p = parent ? parent.mapToItem(null, x, y) : Qt.point(x, y);
        _sceneRect = Qt.rect(p.x, p.y, width, height);
    }
    function _watch() {
        for (const a of _watched) {
            try { a.xChanged.disconnect(updateSceneRect); a.yChanged.disconnect(updateSceneRect); } catch (e) {}
        }
        const list = [];
        for (let a = parent; a; a = a.parent) {
            a.xChanged.connect(updateSceneRect);
            a.yChanged.connect(updateSceneRect);
            list.push(a);
        }
        _watched = list;
        updateSceneRect();
    }

    Behavior on _w {
        enabled: control.animateWidth && control._ready && control.visible && !Theme.reduceMotion
        SpringAnimation {
            spring: Theme.liquidSpring; damping: Theme.liquidDamping
            mass: Theme.liquidMass; epsilon: Theme.springEpsilon
        }
    }

    implicitWidth: _w
    implicitHeight: Theme.islandHeight
    padding: Theme.space12
    topPadding: 0
    bottomPadding: 0
    spacing: Theme.space8
    focusPolicy: interactive ? Qt.StrongFocus : Qt.NoFocus
    hoverEnabled: interactive

    scale: _down && !Theme.reduceMotion ? Theme.squishScale : 1
    Behavior on scale {
        enabled: !Theme.reduceMotion
        SpringAnimation {
            spring: Theme.snappySpring; damping: Theme.snappyDamping
            mass: Theme.snappyMass; epsilon: 0.0005
        }
    }

    onXChanged: updateSceneRect()
    onYChanged: updateSceneRect()
    onWidthChanged: updateSceneRect()
    onHeightChanged: updateSceneRect()
    onParentChanged: _watch()
    Component.onCompleted: { _watch(); _readyTimer.start(); }

    property Timer _readyTimer: Timer {
        interval: 150
        onTriggered: control._ready = true
    }

    Keys.onReturnPressed: clicked()
    Keys.onEnterPressed: clicked()

    Accessible.role: Accessible.Button
    Accessible.name: text

    background: Item {
        GlassPanel {
            anchors.fill: parent
            radius: control.radius
            elevation: control.elevation
        }
        Rectangle {
            anchors.fill: parent
            radius: control.radius
            antialiasing: true
            // Dark glass must not get lighter on hover/active (muted text over a
            // bright wallpaper would fall below AA), so dark mode darkens instead.
            color: control.active || control._down ? (Theme.dark ? Qt.rgba(0, 0, 0, 0.22) : Theme.pressedOverlay)
                 : control.interactive && control.hovered ? (Theme.dark ? Qt.rgba(0, 0, 0, 0.12) : Theme.hoverOverlay)
                 : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durMicro) } }

            FocusRing { show: control.visualFocus }
        }
    }

    contentItem: Item {
        implicitWidth: row.implicitWidth
        implicitHeight: row.implicitHeight
        clip: control._w !== control._targetW

        MouseArea {
            x: -control.leftPadding
            width: control.width
            height: parent.height
            enabled: !control.interactive
            visible: enabled
            acceptedButtons: Qt.AllButtons
        }
        Row {
            id: row
            anchors.verticalCenter: parent.verticalCenter
            spacing: control.spacing
        }
    }
}
