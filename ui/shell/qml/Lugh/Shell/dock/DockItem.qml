// One dock tile (docs/design/lugh-mode.md §3): app icon, ember (running
// indicator), attention ring, focus ring, press squish, launch hop. Used by
// Dock for apps and for the Trash. Purely visual plus pointer input; the Dock
// owns keyboard navigation, the hover label and the context menu.
//
// Geometry: the tile is a fixed slot: `iconSize` wide (plus a divider slot on
// the left when `leadingDivider`) and `topRoom + padding + iconSize +
// bottomPadding` tall, where `topRoom` is clear space above the pill for the
// magnified icon. Magnify never changes the slot: the Dock hands the tile a
// scale (`mag`) and a horizontal displacement (`shift`, `dividerShift`) and
// only the artwork moves, so the pointer hit areas stay put.
//
// The artwork is rasterised once at `iconSize × artScale` (the largest size
// magnify can ask for) and scaled down, so a magnified icon stays crisp
// without re-rasterising per frame.
import QtQuick
import Lugh.UI

Item {
    id: tile

    property string iconName: ""
    property string label: ""
    property int iconSize: 48
    property int padding: 6
    property int bottomPadding: 10
    property int topRoom: 0
    property real mag: 1
    property real artScale: 1
    property real shift: 0
    property real dividerShift: 0
    property bool leadingDivider: false
    // Plain hover plate instead of magnify (magnify off, or reduce motion).
    property bool hoverPlate: false

    property bool running: false
    property int windows: 0
    property bool focusedApp: false
    property bool launching: false
    property bool attention: false

    // Hover from the pointer or forced by the Dock (debug).
    property bool forceHover: false
    property string accessibleName: label

    // The square the icon rests in (menu origin, focus ring).
    readonly property Item iconBox: box
    readonly property bool hovered: mouse.containsMouse || forceHover
    readonly property bool pressed: mouse.pressed && (mouse.pressedButtons & Qt.LeftButton) !== 0
    readonly property int dividerSlot: leadingDivider ? 9 : 0
    // Icon centre x in the tile, un-magnified.
    readonly property real centerX: dividerSlot + iconSize / 2

    signal activated()
    signal middleClicked()
    signal contextRequested()

    width: dividerSlot + iconSize
    height: topRoom + padding + iconSize + bottomPadding

    activeFocusOnTab: false
    Accessible.role: Accessible.Button
    Accessible.name: accessibleName
    Accessible.focusable: true
    Accessible.onPressAction: tile.activated()

    component Snappy: SpringAnimation {
        spring: Theme.snappySpring; damping: Theme.snappyDamping; mass: Theme.snappyMass
    }

    // ---- divider hairline (pinned | running, apps | trash) ----------------
    Rectangle {
        visible: tile.leadingDivider
        x: 2 + tile.dividerShift
        y: tile.topRoom + tile.padding + Math.round((tile.iconSize - height) / 2)
        width: 1
        height: Math.round(tile.iconSize * 0.5)
        color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.14)
        Accessible.ignored: true
    }

    // ---- icon -------------------------------------------------------------
    Item {
        id: box
        readonly property real radius: Math.round(width * 0.26)
        x: tile.dividerSlot + tile.shift
        y: tile.topRoom + tile.padding
        width: tile.iconSize
        height: tile.iconSize

        // Hover / pressed plate when the icon does not magnify.
        Rectangle {
            anchors.fill: parent
            anchors.margins: -3
            radius: box.radius + 3
            visible: tile.hoverPlate && (tile.hovered || tile.pressed)
            color: tile.pressed ? Theme.pressedOverlay : Theme.hoverOverlay
        }

        Item {
            id: hopper
            width: parent.width
            height: parent.height
            opacity: tile._breath

            Item {
                id: scaler
                width: parent.width
                height: parent.height
                transformOrigin: Item.Bottom
                scale: tile.mag

                Squish {
                    anchors.centerIn: parent
                    pressed: tile.pressed
                    Item {
                        width: tile.iconSize
                        height: tile.iconSize
                        AppIcon {
                            size: Math.round(tile.iconSize * tile.artScale)
                            iconName: tile.iconName
                            fallbackText: tile.label
                            transformOrigin: Item.TopLeft
                            scale: tile.iconSize / size
                        }
                    }
                }

                // Needs attention: a ring badge on the corner (shape, not
                // color alone; the accessible name says it too).
                Rectangle {
                    id: ring
                    width: 10
                    height: 10
                    radius: 5
                    x: parent.width - width + 1
                    y: -1
                    color: Theme.surface
                    border.width: 3
                    border.color: Theme.focusRing
                    antialiasing: true
                    opacity: tile.attention ? 1 : 0
                    visible: opacity > 0
                    Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durSmall) } }
                }
            }
        }

        FocusRing {
            target: box
            show: tile.activeFocus
        }
    }

    // ---- launch: one soft hop, then breathe until the app has a window ----
    property real _breath: 1
    onLaunchingChanged: {
        if (launching) {
            if (!Theme.reduceMotion) hop.restart();
            breathe.restart();
        } else {
            breathe.stop();
            settle.restart();
        }
    }
    Component.onCompleted: if (launching) breathe.start()
    SequentialAnimation {
        id: hop
        NumberAnimation { target: hopper; property: "y"; to: -Math.min(10, tile.iconSize * 0.2); duration: 150; easing.type: Easing.OutCubic }
        SpringAnimation {
            target: hopper; property: "y"; to: 0
            spring: Theme.liquidSpring; damping: Theme.liquidDamping; mass: Theme.liquidMass; epsilon: 0.05
        }
    }
    SequentialAnimation {
        id: breathe
        loops: Animation.Infinite
        NumberAnimation { target: tile; property: "_breath"; to: 0.5; duration: 800; easing.type: Easing.InOutSine }
        NumberAnimation { target: tile; property: "_breath"; to: 1; duration: 800; easing.type: Easing.InOutSine }
    }
    NumberAnimation { id: settle; target: tile; property: "_breath"; to: 1; duration: Theme.durSmall }

    // ---- ember: running indicator ------------------------------------------
    // A 4 px dot when running, a 14 px capsule for the focused app, a second
    // dot for two or more windows: the shape carries the state.
    Row {
        id: ember
        x: tile.centerX + tile.shift - width / 2
        y: tile.topRoom + tile.padding + tile.iconSize + 3
        spacing: 3
        opacity: tile.running ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durSmall) } }

        Rectangle {
            id: lead
            width: tile.focusedApp ? 14 : 4
            height: 4
            radius: 2
            color: Theme.focusRing
            antialiasing: true
            Behavior on width { enabled: !Theme.reduceMotion; Snappy { epsilon: 0.05 } }
        }
        Rectangle {
            width: 4
            height: 4
            radius: 2
            color: Theme.focusRing
            antialiasing: true
            visible: tile.running && tile.windows >= 2
        }
    }
    // Attention: the ember pulses gently twice; the ring badge stays.
    onAttentionChanged: if (attention && running && !Theme.reduceMotion) pulse.restart()
    SequentialAnimation {
        id: pulse
        loops: 2
        NumberAnimation { target: ember; property: "scale"; to: 1.8; duration: 260; easing.type: Easing.InOutSine }
        NumberAnimation { target: ember; property: "scale"; to: 1; duration: 340; easing.type: Easing.InOutSine }
    }

    // ---- pointer ----------------------------------------------------------
    MouseArea {
        id: mouse
        x: tile.dividerSlot
        width: tile.iconSize
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
