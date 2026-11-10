// Small status/count badge.
//
//   Badge { text: "3" }                     // accent count
//   Badge { text: qsTr("New"); tone: "info" }
//   Badge { dot: true; tone: "danger" }     // 8 px dot, no text
//
// tone: accent | neutral | danger | success | info. Solid fills with a text
// color that passes AA on each (onAccent / onDanger pair). Pair a tone with a
// word or an icon nearby: color alone carries no meaning (DESIGN-SYSTEM §10).
import QtQuick

Item {
    id: root

    property string text: ""
    property string tone: "accent"
    property bool dot: false

    // Private: a ring in the color of what the badge sits on (e.g. a dock
    // icon) so it reads as cut out of it. Transparent = no ring.
    property color _outline: "transparent"
    readonly property int _ring: _outline.a > 0 ? 2 : 0

    readonly property color _fill: tone === "neutral" ? Theme.surface3
        : tone === "danger" ? Theme.danger
        : tone === "success" ? Theme.success
        : tone === "info" ? Theme.info : Theme.accent
    readonly property color _fg: tone === "neutral" ? Theme.text
        : tone === "accent" ? Theme.onAccent : Theme.onDanger

    implicitWidth: (dot ? 8 : Math.max(18, label.implicitWidth + 12)) + 2 * _ring
    implicitHeight: (dot ? 8 : 18) + 2 * _ring

    Accessible.role: Accessible.StaticText
    Accessible.name: text

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: root._outline
        visible: root._ring > 0
        antialiasing: true
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: root._ring
        radius: height / 2
        color: root._fill
        antialiasing: true
        Behavior on color { ColorAnimation { duration: Theme.durMicro } }

        Text {
            id: label
            anchors.centerIn: parent
            visible: !root.dot
            text: root.text
            color: root._fg
            font.family: Theme.fontUi
            font.pixelSize: 11
            font.weight: 600
            font.features: { "tnum": 1 }
        }
    }
}
