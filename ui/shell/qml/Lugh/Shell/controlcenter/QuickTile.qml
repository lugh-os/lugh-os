// Control-center quick tile: a rounded rect with an icon, a title and the
// current state as a subtitle. On = accent fill + onAccent content, and the
// state is spelled out in the subtitle (never color alone).
//
//   QuickTile { title: qsTr("Wi-Fi"); subtitle: ssid; iconName: "wifi"; on: wifiOn
//               hasDetail: true; detailName: qsTr("Wi-Fi networks")
//               onActivated: toggle(); onDetailRequested: kb => openPage("wifi", kb) }
//
// With `hasDetail` the right 40 px is a separate button (chevron) that opens a
// sub-page; the body still toggles. Both are in the Tab chain; Space/Enter
// activate either.
import QtQuick
import QtQuick.Templates as T
import Lugh.UI

Item {
    id: tile

    property string title: ""
    property string subtitle: ""
    property string iconName: ""
    property bool on: false
    // false: the body is an action (cycles, opens) rather than an on/off switch
    property bool checkable: true
    property bool hasDetail: false
    property string detailName: ""
    property string detailIcon: "chevron-right"
    // Spoken after the title, e.g. "on, connected to Kigali Heights 5G".
    property string accessibleState: subtitle
    property string disabledReason: ""

    // The chevron button, so the panel can hand focus back to it.
    readonly property Item detailButton: chevron
    readonly property Item bodyButton: body

    signal activated()
    signal detailRequested(bool viaKeyboard)

    implicitWidth: 160
    implicitHeight: 56
    opacity: enabled ? 1 : Theme.disabledOpacity

    readonly property color _fg: on ? Theme.onAccent : Theme.text
    readonly property int _detailW: hasDetail ? 30 : 0

    scale: (body.down || chevron.down) && !Theme.reduceMotion ? 0.98 : 1
    Behavior on scale {
        NumberAnimation { duration: Theme.durMicro; easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard }
    }

    Rectangle {
        id: bg
        anchors.fill: parent
        radius: Theme.radiusLg
        antialiasing: true
        color: tile.on ? Theme.accent
                       : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, Theme.dark ? 0.07 : 0.05)
        border.width: 1
        border.color: tile.on ? Qt.tint(Theme.accent, Theme.pressedOverlay) : Theme.glassBorder
        Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durSmall) } }
        Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durSmall) } }

        // hover / pressed overlays, one per half (clipped so the inner edge is straight)
        Item {
            width: body.width
            height: parent.height
            clip: tile.hasDetail
            Rectangle {
                width: bg.width
                height: bg.height
                radius: bg.radius
                color: body.down ? Theme.pressedOverlay : Theme.hoverOverlay
                opacity: body.enabled && (body.hovered || body.down) ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Theme.durMicro } }
            }
        }
        Item {
            visible: tile.hasDetail
            x: chevron.x
            width: chevron.width
            height: parent.height
            clip: true
            Rectangle {
                x: -chevron.x
                width: bg.width
                height: bg.height
                radius: bg.radius
                color: chevron.down ? Theme.pressedOverlay : Theme.hoverOverlay
                opacity: chevron.hovered || chevron.down ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Theme.durMicro } }
            }
        }
    }

    T.AbstractButton {
        id: body
        width: tile.width - tile._detailW
        height: tile.height
        focusPolicy: Qt.StrongFocus
        hoverEnabled: true
        onClicked: tile.activated()
        Keys.onReturnPressed: tile.activated()
        Keys.onEnterPressed: tile.activated()

        Accessible.role: Accessible.Button
        Accessible.name: tile.title + (tile.accessibleState !== "" ? ", " + tile.accessibleState : "")
        Accessible.checkable: tile.checkable
        Accessible.checked: tile.checkable && tile.on
        Accessible.description: !tile.enabled ? tile.disabledReason : ""
        Accessible.onPressAction: tile.activated()

        contentItem: Item {
            Rectangle {
                id: plate
                x: Theme.space8 + 2
                anchors.verticalCenter: parent.verticalCenter
                width: 28
                height: 28
                radius: width / 2
                antialiasing: true
                color: tile.on ? Qt.rgba(Theme.onAccent.r, Theme.onAccent.g, Theme.onAccent.b, 0.12)
                               : Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, Theme.dark ? 0.6 : 0.9)
                Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durSmall) } }

                Icon {
                    anchors.centerIn: parent
                    name: tile.iconName
                    size: 16
                    color: tile._fg
                    Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durSmall) } }
                }
            }

            Column {
                anchors.left: plate.right
                anchors.leftMargin: Theme.space8
                anchors.right: parent.right
                anchors.rightMargin: tile.hasDetail ? 0 : Theme.space8 + 2
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1

                Text {
                    width: parent.width
                    text: tile.title
                    font: Theme.typeBodyStrong
                    color: tile._fg
                    elide: Text.ElideRight
                    Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durSmall) } }
                }
                Text {
                    width: parent.width
                    visible: text !== ""
                    text: tile.subtitle
                    font: Theme.typeCaption
                    color: tile.on ? Theme.onAccent : Theme.textMuted
                    elide: Text.ElideRight
                    Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durSmall) } }
                }
            }
        }
    }

    T.AbstractButton {
        id: chevron
        visible: tile.hasDetail
        enabled: tile.hasDetail
        x: tile.width - width
        width: tile._detailW
        height: tile.height
        focusPolicy: Qt.StrongFocus
        hoverEnabled: true
        property bool _kb: false
        onClicked: tile.detailRequested(_kb)
        onPressed: _kb = false
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space
                || event.key === Qt.Key_Right) {
                tile.detailRequested(true);
                event.accepted = true;
            }
        }

        Accessible.role: Accessible.Button
        Accessible.name: tile.detailName !== "" ? tile.detailName : tile.title
        Accessible.onPressAction: tile.detailRequested(false)

        contentItem: Item {
            Icon {
                anchors.centerIn: parent
                anchors.horizontalCenterOffset: -2
                name: tile.detailIcon
                size: 16
                color: tile._fg
                Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durSmall) } }
            }
        }
    }

    // Rings live on the tile so their geometry is in tile coordinates.
    FocusRing {
        show: body.visualFocus
        radius: Theme.radiusLg + _outset
    }
    FocusRing {
        target: chevron
        show: chevron.visualFocus
        radius: Theme.radiusSm + _outset
    }
}
