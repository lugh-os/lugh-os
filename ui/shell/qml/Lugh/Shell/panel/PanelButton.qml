// A hit target in the bottom Panel (start, search, workspaces, tray): a plate
// that lights on hover, darkens on press and stays lit while `active` (its
// overlay is open), a squish on press and a FocusRing on keyboard focus.
// `label` is what the Panel's gliding hover label says above it.
//
//   PanelButton {
//       label: qsTr("Search")
//       active: ShellState.launcherOpen
//       contentItem: Icon { name: "search"; size: 18 }
//       onClicked: ShellState.toggleLauncher()
//   }
//
// Right click emits contextRequested(); Return/Enter/Space click.
import QtQuick
import QtQuick.Templates as T
import Lugh.UI

T.AbstractButton {
    id: control

    property string label: ""
    property bool active: false
    property real radius: Math.min(height / 2, Theme.radiusMd)
    // Centre x of the label, in this item (the Panel reads it).
    readonly property real centerX: width / 2

    signal contextRequested()

    implicitWidth: implicitContentWidth + leftPadding + rightPadding
    implicitHeight: 32
    leftPadding: Theme.space8
    rightPadding: Theme.space8
    topPadding: 0
    bottomPadding: 0
    hoverEnabled: true
    focusPolicy: Qt.TabFocus

    Accessible.role: Accessible.Button
    Accessible.name: label
    Keys.onReturnPressed: clicked()
    Keys.onEnterPressed: clicked()

    TapHandler {
        acceptedButtons: Qt.RightButton
        // Exclusive grab: the Panel's background menu underneath never sees it.
        gesturePolicy: TapHandler.WithinBounds
        onTapped: control.contextRequested()
    }

    background: Rectangle {
        radius: control.radius
        antialiasing: true
        // Dark glass darkens instead of lightening, so muted text over a
        // bright wallpaper keeps its contrast (as Island does).
        color: control.down ? (Theme.dark ? Qt.rgba(0, 0, 0, 0.26) : Theme.pressedOverlay)
             : control.active ? (Theme.dark ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(0, 0, 0, 0.07))
             : control.hovered ? (Theme.dark ? Qt.rgba(1, 1, 1, 0.07) : Theme.hoverOverlay)
             : "transparent"
        Behavior on color { ColorAnimation { duration: Theme.durMicro } }

        // The open overlay's anchor: a short accent tick under the plate.
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            y: parent.height - height - 1
            width: control.active ? 12 : 0
            height: 2
            radius: 1
            color: Theme.focusRing
            opacity: control.active ? 1 : 0
            Behavior on width { enabled: !Theme.reduceMotion; NumberAnimation { duration: Theme.dur(Theme.durSmall); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard } }
            Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durMicro) } }
        }

        FocusRing { show: control.visualFocus }
    }

    // The content squishes, the plate stays put.
    property real _squish: down && !Theme.reduceMotion ? Theme.squishScale : 1
    Behavior on _squish {
        enabled: !Theme.reduceMotion
        SpringAnimation { spring: Theme.snappySpring; damping: Theme.snappyDamping; mass: Theme.snappyMass; epsilon: 0.0005 }
    }
    function _bindSquish() { if (contentItem) contentItem.scale = Qt.binding(() => control._squish); }
    onContentItemChanged: _bindSquish()
    Component.onCompleted: _bindSquish()
}
