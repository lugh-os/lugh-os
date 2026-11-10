// Text button (DESIGN-SYSTEM §7).
//
//   Button { text: qsTr("Install"); variant: "primary"; iconName: "download" }
//   Button { text: qsTr("Delete"); variant: "danger"; loading: busy }
//   Button { text: qsTr("Apply"); enabled: false; disabledReason: qsTr("Nothing changed") }
//
// variant: primary (accent fill) | secondary (surface + hairline) | ghost
// (no fill) | danger (danger fill). size: md (36 px) | sm (28 px visual,
// 32 px hit target). `loading` swaps the icon for a Spinner (or covers the
// label when there is no icon), keeps the width, ignores input and is not
// dimmed.
import QtQuick
import QtQuick.Templates as T

T.Button {
    id: control

    property string iconName: ""
    property string variant: "secondary"
    property string size: "md"
    property bool loading: false
    property string disabledReason: ""

    readonly property bool _sm: size === "sm"
    readonly property int _visualHeight: _sm ? 28 : 36
    readonly property bool _filled: variant === "primary" || variant === "danger"
    readonly property bool _hot: enabled && !loading
    readonly property color _fg: variant === "primary" ? Theme.onAccent
        : variant === "danger" ? Theme.onDanger : Theme.text
    readonly property color _baseFill: variant === "primary" ? Theme.accent
        : variant === "danger" ? Theme.danger
        : variant === "secondary" ? Theme.surface : "transparent"

    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset,
                            implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(Theme.hitTarget, _visualHeight)

    leftPadding: _sm ? Theme.space12 : Theme.space16
    rightPadding: leftPadding
    topInset: (implicitHeight - _visualHeight) / 2
    bottomInset: topInset
    spacing: _sm ? 6 : Theme.space8
    focusPolicy: Qt.StrongFocus
    hoverEnabled: true

    font: _sm ? Theme.typeCaption : Theme.typeBodyStrong

    // pressed: scale 0.98 (skipped under reduce motion)
    scale: down && _hot && !Theme.reduceMotion ? 0.98 : 1
    Behavior on scale {
        NumberAnimation {
            duration: Theme.durMicro
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Theme.easeStandard
        }
    }
    opacity: enabled ? 1 : Theme.disabledOpacity

    // loading: swallow keys; the mouse is swallowed by _blocker below
    Keys.onPressed: event => { if (loading) event.accepted = true }
    Keys.onReleased: event => { if (loading) event.accepted = true }

    Accessible.role: Accessible.Button
    Accessible.name: text
    Accessible.description: loading ? qsTr("Working…") : (!enabled ? disabledReason : "")

    background: Rectangle {
        implicitWidth: control._sm ? 64 : 80
        implicitHeight: control._visualHeight
        radius: Theme.radiusSm + (control._sm ? 0 : 2)
        antialiasing: true
        color: {
            const base = control._baseFill;
            if (!control._hot)
                return base;
            if (control.variant === "secondary")
                return control.down ? Theme.surface3 : control.hovered ? Theme.surface2 : base;
            if (control.variant === "ghost")
                return control.down ? Theme.pressedOverlay : control.hovered ? Theme.hoverOverlay : base;
            return control.down ? Qt.tint(base, Theme.pressedOverlay)
                 : control.hovered ? Qt.tint(base, Theme.hoverOverlay) : base;
        }
        Behavior on color { ColorAnimation { duration: Theme.durMicro } }

        // 1 px hairline: neutral on secondary, a deeper edge of the fill on
        // primary/danger so the shape stays crisp on any background.
        border.width: control.variant === "ghost" ? 0 : 1
        border.color: control._filled ? Qt.tint(control._baseFill, Theme.pressedOverlay) : Theme.border

        FocusRing { show: control.visualFocus }
    }

    contentItem: Item {
        id: body
        implicitWidth: (iconSlot.visible ? iconSlot.width + control.spacing : 0) + label.implicitWidth
        implicitHeight: row.implicitHeight

        Row {
            id: row
            anchors.centerIn: parent
            spacing: control.spacing
            // label fades out when loading without an icon; width stays
            opacity: control.loading && control.iconName === "" ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durMicro) } }

            Item {
                id: iconSlot
                visible: control.iconName !== ""
                width: control._sm ? 14 : 16
                height: width
                anchors.verticalCenter: parent.verticalCenter

                Icon {
                    anchors.centerIn: parent
                    name: control.iconName
                    size: iconSlot.width
                    color: control._fg
                    opacity: control.loading ? 0 : 1
                    Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durMicro) } }
                }
                Spinner {
                    anchors.centerIn: parent
                    size: iconSlot.width
                    color: control._fg
                    running: control.loading
                }
            }

            Text {
                id: label
                // never wider than the button: long labels elide
                width: Math.min(implicitWidth, Math.max(0, body.width
                    - (iconSlot.visible ? iconSlot.width + control.spacing : 0)))
                text: control.text
                font: control.font
                color: control._fg
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                Behavior on color { ColorAnimation { duration: Theme.durMicro } }
            }
        }

        Spinner {
            anchors.centerIn: parent
            size: control._sm ? 14 : 16
            color: control._fg
            running: control.loading && control.iconName === ""
        }
    }

    // Eats pointer input while loading (the control stays enabled, so it is
    // not dimmed and keeps focus).
    MouseArea {
        id: _blocker
        anchors.fill: parent
        enabled: control.loading
        visible: enabled
        acceptedButtons: Qt.AllButtons
        hoverEnabled: true
    }

    // Explains why the button is disabled. HoverHandler still reports hover
    // on a disabled control; T.Button's own `hovered` does not.
    HoverHandler { id: _hover }
    Tooltip {
        text: control.disabledReason
        visible: !control.enabled && control.disabledReason !== "" && _hover.hovered
    }
}
