// Inline launch-failure toast above the dock (shell spec §States: "Firefox
// couldn't start" + Details). An ErrorBanner-style row on an opaque card so it
// reads on any wallpaper; Details reveals the journal excerpt. Stays 5 s, held
// open while hovered, focused or expanded.
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

    implicitWidth: Math.min(440, Math.max(300, bannerRow.implicitWidth + Theme.space12 + Theme.space4))
    implicitHeight: card.height
    width: implicitWidth
    height: implicitHeight

    opacity: _shown ? 1 : 0
    visible: opacity > 0
    Behavior on opacity {
        NumberAnimation { duration: Theme.dur(Theme.durSmall); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard }
    }
    transform: Translate {
        y: toast._shown || Theme.reduceMotion ? 0 : 6
        Behavior on y { NumberAnimation { duration: Theme.durSmall; easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard } }
    }

    HoverHandler { id: hover }

    Timer {
        id: _timer
        interval: toast.timeout
        running: false
        onTriggered: {
            if (hover.hovered || toast._expanded || toast.activeFocus) restart();
            else toast._shown = false;
        }
    }

    Shadow { target: card; radius: Theme.radiusMd; elevation: "menu" }

    Rectangle {
        id: card
        width: parent.width
        height: col.implicitHeight
        radius: Theme.radiusMd
        color: Theme.surface
        antialiasing: true

        // Danger tint and hairline over the opaque surface (ErrorBanner look,
        // extended over the details).
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.10)
            border.width: 1
            border.color: Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.40)
            antialiasing: true
        }

        Column {
            id: col
            width: parent.width

            // ErrorBanner's anatomy (danger icon, cause, action, dismiss),
            // laid out compactly with the text centred on the 44 px row.
            Item {
                width: parent.width
                height: 44
                Accessible.role: Accessible.AlertMessage
                Accessible.name: title.text

                RowLayout {
                    id: bannerRow
                    anchors.fill: parent
                    anchors.leftMargin: Theme.space12
                    anchors.rightMargin: Theme.space4
                    spacing: Theme.space8

                    Icon { name: "circle-alert"; size: 18; color: Theme.danger }
                    Text {
                        id: title
                        Layout.fillWidth: true
                        text: qsTr("%1 couldn’t start").arg(toast.appName)
                        font: Theme.typeBodyStrong
                        color: Theme.text
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                    }
                    Button {
                        visible: toast.details !== ""
                        text: toast._expanded ? qsTr("Hide details") : qsTr("Details")
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

            Item {
                width: parent.width
                height: toast._expanded ? detailText.implicitHeight + Theme.space12 : 0
                clip: true
                visible: height > 0
                Behavior on height {
                    enabled: !Theme.reduceMotion
                    NumberAnimation { duration: Theme.durSmall; easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard }
                }

                Text {
                    id: detailText
                    x: Theme.space12 + 18 + Theme.space8
                    width: parent.width - x - Theme.space12
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
