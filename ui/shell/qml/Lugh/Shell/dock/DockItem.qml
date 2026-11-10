// One dock tile: app icon, running dots, attention dot, hover tooltip, focus
// ring, launch bounce. Used by Dock for apps and for the Trash. Purely visual
// plus pointer input; the Dock owns keyboard navigation and the context menu.
//
// Geometry: the item is as tall as the dock pill (iconSize + 2 × padding) and
// as wide as its icon slot (iconSize × mag), plus a divider slot on the left
// when `leadingDivider`. The icon grows upward from the pill's icon line when
// magnified, and the tooltip floats above it, outside the item.
import QtQuick
import Lugh.UI

Item {
    id: tile

    property string iconName: ""
    property string label: ""
    property int iconSize: 56
    property int padding: Theme.space8
    property int bottomPadding: Theme.space12
    // Magnification of this tile (1 = none) and the texture oversampling the
    // Dock picked so a magnified icon stays sharp (1, or the max magnify).
    property real mag: 1
    property real artScale: 1
    property bool magnifying: false
    property bool leadingDivider: false

    property bool running: false
    property int windows: 0
    property bool focusedApp: false
    property bool launching: false
    property bool attention: false

    // Hover from the pointer or forced by the Dock (debug / keyboard focus).
    property bool forceHover: false
    property bool tooltipAllowed: true
    property string accessibleName: label

    // The square the icon is drawn in (for anchoring menus, focus rings).
    readonly property Item iconBox: lift
    readonly property bool hovered: mouse.containsMouse || forceHover
    readonly property bool pressed: mouse.pressed && (mouse.pressedButtons & Qt.LeftButton) !== 0

    signal activated()
    signal middleClicked()
    signal contextRequested()

    readonly property int _dividerSlot: leadingDivider ? 1 + Theme.space8 : 0
    readonly property real _slot: iconSize * mag

    width: _dividerSlot + _slot
    height: iconSize + padding + bottomPadding
    z: hovered || activeFocus ? 2 : 0

    activeFocusOnTab: false
    Accessible.role: Accessible.Button
    Accessible.name: accessibleName
    Accessible.focusable: true
    Accessible.onPressAction: tile.activated()

    // ---- divider (pinned | running, apps | trash) -------------------------
    Rectangle {
        visible: tile.leadingDivider
        x: 0
        width: 1
        height: Math.round(tile.iconSize * 0.62)
        y: tile.padding + Math.round((tile.iconSize - height) / 2)
        color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.16)
        Accessible.ignored: true
    }

    // ---- icon -------------------------------------------------------------
    // Launch bounce lives on its own wrapper so it never fights the hover lift.
    Item {
        id: bounce
        x: tile._dividerSlot
        y: tile.padding + tile.iconSize - tile._slot
        width: tile._slot
        height: tile._slot

        Item {
            id: hopper
            width: parent.width
            height: parent.height

            Item {
                id: lift
                readonly property real radius: Math.round(width * 0.26)
                width: parent.width
                height: parent.height
                y: tile.hovered && !tile.magnifying && !Theme.reduceMotion ? -Theme.space4 : 0
                Behavior on y {
                    NumberAnimation { duration: Theme.durMicro; easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard }
                }

                AppIcon {
                    id: art
                    anchors.centerIn: parent
                    size: Math.round(tile.iconSize * tile.artScale)
                    iconName: tile.iconName
                    fallbackText: tile.label
                    // Rendered at size × artScale, shown at the slot size.
                    scale: (tile._slot / size) * (tile.pressed && !Theme.reduceMotion ? 0.94 : 1)
                    opacity: tile.pressed && Theme.reduceMotion ? 0.75 : 1
                    Behavior on scale {
                        enabled: !tile.magnifying
                        NumberAnimation { duration: Theme.durMicro; easing.type: Easing.OutCubic }
                    }
                }

                // Needs-attention dot: shape on the corner, not color alone; the
                // accessible name says it too.
                Badge {
                    dot: true
                    tone: "accent"
                    _outline: Theme.surface
                    x: parent.width - width * 0.75
                    y: -height * 0.25
                    opacity: tile.attention ? 1 : 0
                    visible: opacity > 0
                    scale: tile.attention || Theme.reduceMotion ? 1 : 0.4
                    Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durSmall) } }
                    Behavior on scale { NumberAnimation { duration: Theme.durSmall; easing.type: Easing.OutBack } }
                }

                FocusRing {
                    target: lift
                    show: tile.activeFocus
                }
            }
        }

        // Launching: a gentle hop (or, under reduce motion, a soft pulse)
        // until the app reports a window.
        SequentialAnimation {
            id: hop
            running: tile.launching && !Theme.reduceMotion
            loops: Animation.Infinite
            alwaysRunToEnd: true
            NumberAnimation { target: hopper; property: "y"; to: -10; duration: 260; easing.type: Easing.OutQuad }
            NumberAnimation { target: hopper; property: "y"; to: 0; duration: 420; easing.type: Easing.OutBounce }
            PauseAnimation { duration: 260 }
        }
        SequentialAnimation {
            running: tile.launching && Theme.reduceMotion
            loops: Animation.Infinite
            alwaysRunToEnd: true
            NumberAnimation { target: hopper; property: "opacity"; to: 0.5; duration: 600; easing.type: Easing.InOutSine }
            NumberAnimation { target: hopper; property: "opacity"; to: 1; duration: 600; easing.type: Easing.InOutSine }
        }
    }

    // ---- running indicator ------------------------------------------------
    // One dot per window, up to 3. The focused app's first dot is an accent
    // pill: wider (shape) and accent (color).
    Row {
        id: dots
        x: tile._dividerSlot + Math.round((tile._slot - width) / 2)
        y: tile.padding + tile.iconSize + 3
        spacing: 3
        opacity: tile.running ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durSmall) } }

        Repeater {
            model: tile.running ? Math.max(1, Math.min(tile.windows, 3)) : 0
            Rectangle {
                required property int index
                readonly property bool lead: tile.focusedApp && index === 0
                width: lead ? 10 : 4
                height: 4
                radius: 2
                color: lead ? Theme.accent : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.7)
                antialiasing: true
                Behavior on width { NumberAnimation { duration: Theme.dur(Theme.durSmall); easing.type: Easing.OutCubic } }
                Behavior on color { ColorAnimation { duration: Theme.durSmall } }
            }
        }
    }

    // ---- tooltip ----------------------------------------------------------
    Rectangle {
        id: tip
        readonly property bool shown: (tile.hovered || tile.activeFocus) && tile.tooltipAllowed && tile.label !== ""
        x: tile._dividerSlot + Math.round((tile._slot - width) / 2)
        y: bounce.y + hopper.y + lift.y - height - Theme.space8
        width: tipText.implicitWidth + 2 * Theme.space12
        height: tipText.implicitHeight + 2 * (Theme.space4 + 1)
        radius: height / 2
        color: Theme.text
        opacity: shown ? 1 : 0
        visible: opacity > 0
        Behavior on opacity {
            NumberAnimation { duration: Theme.dur(Theme.durMicro); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard }
        }
        Accessible.ignored: true

        Text {
            id: tipText
            anchors.centerIn: parent
            text: tile.label
            font: Theme.typeCaption
            color: Theme.bg
            Accessible.ignored: true
        }
    }

    // ---- pointer ----------------------------------------------------------
    MouseArea {
        id: mouse
        x: tile._dividerSlot
        width: tile._slot
        height: parent.height
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: event => {
            if (event.button === Qt.LeftButton) tile.activated();
            else if (event.button === Qt.MiddleButton) tile.middleClicked();
            else if (event.button === Qt.RightButton) tile.contextRequested();
        }
    }
}
