// Inline launch-failure toast above the dock (shell spec §States: "Firefox
// couldn't start" + Details): a glass capsule with a danger hairline; Details
// opens a drawer with the journal excerpt and the capsule grows with the
// liquid spring. Stays 5 s, held open while hovered, focused or expanded.
//
//   DockToast { id: toast }
//   toast.show(qsTr("Firefox"), "firefox.service: Main process exited, code=exited, status=1")
import QtQuick
import QtQuick.Layouts
import Lugh.UI

Item {
    id: toast

    property string appName: ""
    property string details: ""
    property int timeout: 5000
    readonly property bool shown: _shown
    property bool _shown: false
    property bool _expanded: false

    function show(name, message) {
        appName = name;
        details = (message || "").trim();
        _expanded = false;
        _shown = true;
        _timer.restart();
    }
    function hide() { _shown = false; _timer.stop(); }

    implicitWidth: Math.min(440, Math.max(280, bannerRow.implicitWidth + Theme.space12 + Theme.space4))
    implicitHeight: 40 + drawer.implicitHeight
    width: implicitWidth
    height: implicitHeight

    opacity: _shown ? 1 : 0
    visible: opacity > 0
    Behavior on opacity {
        NumberAnimation { duration: Theme.dur(Theme.durSmall); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard }
    }
    // Rises out of the dock and settles.
    transform: Translate {
        y: toast._shown || Theme.reduceMotion ? 0 : 14
        Behavior on y {
            enabled: !Theme.reduceMotion
            SpringAnimation { spring: Theme.liquidSpring; damping: Theme.liquidDamping; mass: Theme.liquidMass; epsilon: 0.05 }
        }
    }

    HoverHandler { id: hover }

    Timer {
        id: _timer
        interval: toast.timeout
        onTriggered: {
            if (hover.hovered || toast._expanded || toast.activeFocus) restart();
            else toast._shown = false;
        }
    }

    GlassPanel {
        id: glass
        anchors.fill: parent
        radius: Math.min(20, height / 2)
        elevation: "menu"

        // Danger tint and hairline: the capsule reads as an error at a glance
        // (with the icon and the text, never the color alone).
        Rectangle {
            anchors.fill: parent
            radius: glass.radius
            color: Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.08)
            border.width: 1
            border.color: Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.45)
            antialiasing: true
        }

        Item {
            width: parent.width
            height: 40
            Accessible.role: Accessible.AlertMessage
            Accessible.name: title.text

            RowLayout {
                id: bannerRow
                anchors.fill: parent
                anchors.leftMargin: Theme.space12
                anchors.rightMargin: Theme.space4
                spacing: Theme.space8

                Icon { name: "circle-alert"; size: 16; color: Theme.danger }
                Text {
                    id: title
                    Layout.fillWidth: true
                    text: qsTr("%1 couldn’t start").arg(toast.appName)
                    font: Theme.typeLabel
                    color: Theme.text
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                }
                Button {
                    visible: toast.details !== ""
                    text: toast._expanded ? qsTr("Hide") : qsTr("Details")
                    variant: "ghost"
                    size: "sm"
                    onClicked: toast._expanded = !toast._expanded
                }
                IconButton {
                    iconName: "x"
                    tooltip: qsTr("Dismiss")
                    size: 32
                    iconSize: 16
                    onClicked: toast.hide()
                }
            }
        }

        Drawer {
            id: drawer
            y: 40
            width: parent.width
            height: implicitHeight
            expanded: toast._expanded

            Item {
                width: parent.width
                implicitHeight: detailText.implicitHeight + Theme.space12
                Text {
                    id: detailText
                    x: Theme.space12 + 16 + Theme.space8
                    width: parent.width - x - Theme.space16
                    text: toast.details
                    font.family: Theme.fontMono
                    font.pixelSize: 12
                    color: Theme.textMuted
                    wrapMode: Text.WrapAnywhere
                    maximumLineCount: 5
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                }
            }
        }
    }
}
