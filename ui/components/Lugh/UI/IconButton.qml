// Square icon-only button with a tooltip (which is also its accessible name).
//
//   IconButton { iconName: "settings"; tooltip: qsTr("Settings") }
//   IconButton { iconName: "wifi"; variant: "glass"; size: 44; iconSize: 20
//                checkable: true; checked: net.on; tooltip: qsTr("Wi-Fi") }
//   IconButton { iconName: "bell"; badge: 3; tooltip: qsTr("Notifications") }
//
// variant: ghost (no fill) | filled (surface2) | glass (shell glass, round) |
// accent (accent fill). checked = selected: accent tint, accent icon and an
// accent hairline (not color alone); a checked `accent` button shows an inset
// on-accent ring. badge > 0 shows a count (99+ caps; 9+ on sizes ≤ 32 so the
// badge never covers the icon).
import QtQuick
import QtQuick.Templates as T

T.Button {
    id: control

    // Screen-reader name; empty = derived from the visible label.
    property string accessibleName: ""
    property string iconName: ""
    property string tooltip: ""
    property int size: 32
    property int iconSize: 18
    property string variant: "ghost"
    property int badge: 0
    // Private: why it is disabled (shown instead of the tooltip).
    property string disabledReason: ""

    readonly property bool _round: variant === "glass"
    readonly property bool _sel: checked && variant !== "accent"
    readonly property color _base: variant === "accent" ? Theme.accent
        : variant === "filled" ? Theme.surface2
        : variant === "glass" ? Theme.glass : "transparent"

    implicitWidth: Math.max(size, Theme.hitTarget)
    implicitHeight: implicitWidth
    padding: 0
    focusPolicy: Qt.StrongFocus
    hoverEnabled: true
    display: T.AbstractButton.IconOnly

    scale: down && enabled && !Theme.reduceMotion ? 0.94 : 1
    Behavior on scale {
        NumberAnimation {
            duration: Theme.durMicro
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Theme.easeStandard
        }
    }
    opacity: enabled ? 1 : Theme.disabledOpacity

    Accessible.role: Accessible.Button
    Accessible.name: accessibleName !== "" ? accessibleName : (tooltip !== "" ? tooltip : text)
    Accessible.checkable: checkable
    Accessible.checked: checked
    Accessible.description: !enabled ? disabledReason : ""

    background: Item {
        implicitWidth: control.size
        implicitHeight: control.size

        Rectangle {
            id: bg
            anchors.centerIn: parent
            width: control.size
            height: control.size
            radius: control._round ? width / 2 : (control.size > 36 ? Theme.radiusMd : Theme.radiusSm + 2)
            antialiasing: true
            color: {
                if (control._sel)
                    return Qt.tint(control.variant === "ghost" ? Theme.surface : control._base, Theme.selectedBg);
                const base = control._base;
                if (!control.enabled)
                    return base;
                if (control.variant === "ghost")
                    return control.down ? Theme.pressedOverlay : control.hovered ? Theme.hoverOverlay : base;
                if (control.variant === "filled")
                    return control.down ? Theme.surface3 : control.hovered ? Qt.tint(base, Theme.hoverOverlay) : base;
                return control.down ? Qt.tint(base, Theme.pressedOverlay)
                     : control.hovered ? Qt.tint(base, Theme.hoverOverlay) : base;
            }
            Behavior on color { ColorAnimation { duration: Theme.durMicro } }

            border.width: control._sel || control.variant === "glass" ? 1 : 0
            border.color: control._sel ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.55)
                                       : Theme.glassBorder

            // checked accent: inset ring (the fill is already accent)
            Rectangle {
                anchors.fill: parent
                anchors.margins: 3
                radius: Math.max(0, parent.radius - 3)
                visible: control.checked && control.variant === "accent"
                color: "transparent"
                border.width: 2
                border.color: Theme.onAccent
                opacity: 0.75
                antialiasing: true
            }

            FocusRing { show: control.visualFocus }
        }
    }

    contentItem: Item {
        implicitWidth: control.iconSize
        implicitHeight: control.iconSize

        Icon {
            anchors.centerIn: parent
            name: control.iconName
            size: control.iconSize
            color: control.variant === "accent" ? Theme.onAccent
                 : control._sel ? Theme.accentText : Theme.text
            Behavior on color { ColorAnimation { duration: Theme.durMicro } }
        }
    }

    Badge {
        visible: control.badge > 0
        text: control.size <= 32 ? (control.badge > 9 ? "9+" : String(control.badge))
            : control.badge > 99 ? "99+" : String(control.badge)
        tone: "danger"
        _outline: Theme.surface
        // top-right corner of the visual square, nudged out a little
        x: (control.width + control.size) / 2 - width + 6
        y: (control.height - control.size) / 2 - 6
        z: 2
    }

    HoverHandler { id: _hover }
    Tooltip {
        readonly property string _text: control.enabled ? control.tooltip
            : (control.disabledReason !== "" ? control.disabledReason : control.tooltip)
        text: _text
        visible: _text !== "" && _hover.hovered && !control.pressed
        y: control.height + Theme.space4
    }
}
