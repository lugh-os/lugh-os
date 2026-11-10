// Full-width top bar, kept for the later Mac-like mode (Lugh mode uses the
// islands in Bar.qml; this file is not in the qmldir). The frame sets
// the width (screen width) and maps it as a 30 px layer-shell surface; the
// compositor blurs what is behind the glass.
//
//   left:  Lugh logo (→ LughMenu) · focused app name
//   right: workspaces · keyboard layout (if > 1) · status cluster (→ control
//          center) · notifications bell (→ notification center) · date + time
//          (→ notification center)
//
// Cheap to keep up all day: no layers or effects; the clock binding only
// touches its two Text items, and status icons re-evaluate only when the
// Services property they read changes.
import QtQuick
import QtQuick.Window
import Lugh.UI
import Lugh.Shell
import "status.js" as Status

Item {
    id: bar

    // Show the battery percentage next to its icon (Settings, later). It is
    // always shown when the battery is low.
    property bool showBatteryPercent: false

    implicitWidth: 1440
    implicitHeight: 30

    Accessible.role: Accessible.ToolBar
    Accessible.name: qsTr("Top bar")

    component AppLabel: Text {
        id: label
        property bool shownNow: false
        // Natural width from metrics (an elided Text's implicitWidth would loop).
        TextMetrics { id: metrics; font: label.font; text: label.text }
        width: Math.min(Math.ceil(metrics.advanceWidth), appName.maxWidth)
        height: parent.height
        verticalAlignment: Text.AlignVCenter
        font: Theme.typeBodyStrong
        color: Theme.text
        elide: Text.ElideRight
        textFormat: Text.PlainText
        opacity: shownNow ? 1 : 0
        visible: opacity > 0
        Accessible.ignored: true
        Behavior on opacity {
            NumberAnimation { duration: Theme.dur(Theme.durSmall); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard }
        }
    }

    // ---- glass strip -------------------------------------------------------
    Rectangle {
        anchors.fill: parent
        color: Theme.glass
    }
    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 1
        color: Theme.glassBorder
    }

    // ---- left: logo + app name --------------------------------------------
    BarButton {
        id: logoButton
        objectName: "logo"
        x: Theme.space4
        leftPadding: Theme.space12 - Theme.space2
        rightPadding: Theme.space12 - Theme.space2
        active: ShellState.lughMenuOpen
        Accessible.name: qsTr("Lugh menu")
        Accessible.description: qsTr("About Lugh, settings, lock, log out, restart and shut down")
        onClicked: ShellState.toggleLughMenu()

        contentItem: Item {
            implicitWidth: 16
            implicitHeight: 16
            Image {
                x: Math.round((parent.width - width) / 2)
                y: Math.round((parent.height - height) / 2)
                width: 26  // the mark fills ~60% of the SVG box: ~16 px visible
                height: 26
                source: Theme.dark ? "assets/lugh-logo-dark.svg" : "assets/lugh-logo.svg"
                sourceSize: Qt.size(width * Screen.devicePixelRatio, height * Screen.devicePixelRatio)
                smooth: true
                mipmap: false
            }
        }
    }

    // Focused app name: cross-fades between two labels when focus moves.
    Item {
        id: appName
        objectName: "appName"

        property bool _flip: false
        readonly property string current: Services.wm.focusedAppName
        readonly property Text _shown: _flip ? nameB : nameA
        onCurrentChanged: {
            (_flip ? nameA : nameB).text = current;
            _flip = !_flip;
        }

        anchors.left: logoButton.right
        anchors.leftMargin: Theme.space4 + Theme.space2
        height: parent.height
        // Room left before the right-hand items; long names elide.
        readonly property real maxWidth: Math.max(0, right.x - x - Theme.space24)
        width: _shown.width

        Accessible.role: Accessible.StaticText
        Accessible.name: current !== "" ? qsTr("Active app: %1").arg(current) : qsTr("No active app")

        AppLabel { id: nameA; shownNow: !appName._flip }
        AppLabel { id: nameB; shownNow: appName._flip }
        Component.onCompleted: nameA.text = current
    }

    // ---- right ---------------------------------------------------------------
    Row {
        id: right
        anchors.right: parent.right
        anchors.rightMargin: Theme.space4
        height: parent.height
        spacing: Theme.space2

        WorkspaceDots {
            id: workspaces
        }

        // Breathing room between the workspaces and the status items.
        Item { width: Theme.space8 - Theme.space2; height: 1 }

        // Keyboard layout, only when there is more than one to switch between.
        BarButton {
            id: layoutButton
            objectName: "layout"
            visible: Services.keyboard.layouts.length > 1
            leftPadding: Theme.space4 + Theme.space2
            rightPadding: Theme.space4 + Theme.space2
            Accessible.name: qsTr("Keyboard layout: %1").arg(Services.keyboard.current.toUpperCase())
            Accessible.description: qsTr("Switch to the next layout")
            onClicked: Services.keyboard.next()

            contentItem: Item {
                implicitWidth: Math.max(layoutText.implicitWidth + 2 * Theme.space4 + 2, 26)
                implicitHeight: 18
                Rectangle {
                    x: 0
                    y: Math.round((parent.height - height) / 2)
                    width: parent.width
                    height: 18
                    radius: Theme.radiusSm - 1
                    color: "transparent"
                    border.width: 1
                    border.color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.45)
                }
                Text {
                    id: layoutText
                    anchors.fill: parent
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: Services.keyboard.current.toUpperCase()
                    font: Theme.typeCaptionTnum
                    color: Theme.text
                    Accessible.ignored: true
                }
            }
        }

        // Network · volume · battery → control center.
        BarButton {
            id: cluster
            objectName: "cluster"
            active: ShellState.controlCenterOpen
            leftPadding: Theme.space8 + Theme.space2
            rightPadding: Theme.space8 + Theme.space2
            Accessible.name: qsTr("Quick settings")
            Accessible.description: {
                const parts = [Status.networkDescription(Services.network), Status.volumeDescription(Services.audio)];
                if (Services.power.hasBattery)
                    parts.push(Status.batteryDescription(Services.power));
                return parts.join(". ");
            }
            onClicked: ShellState.toggleControlCenter()

            contentItem: Row {
                spacing: Theme.space12 - Theme.space2

                Icon {
                    id: netIcon
                    anchors.verticalCenter: parent.verticalCenter
                    size: 16
                    name: Status.networkIcon(Services.network)
                    color: Theme.text
                    // Gentle pulse while joining a network.
                    SequentialAnimation on opacity {
                        running: Services.network.connectingSsid !== "" && !Theme.reduceMotion
                        loops: Animation.Infinite
                        alwaysRunToEnd: true
                        NumberAnimation { from: 1; to: 0.35; duration: 700; easing.type: Easing.InOutSine }
                        NumberAnimation { from: 0.35; to: 1; duration: 700; easing.type: Easing.InOutSine }
                    }
                }
                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    size: 16
                    name: Status.volumeIcon(Services.audio)
                    color: Theme.text
                }
                Row {
                    visible: Services.power.hasBattery
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.space4
                    Text {
                        readonly property bool low: Status.batteryLow(Services.power)
                        visible: bar.showBatteryPercent || low
                        anchors.verticalCenter: parent.verticalCenter
                        text: Services.power.batteryPercent + "%"
                        font: Theme.typeBodyTnum
                        color: low ? Theme.danger : Theme.text
                        Accessible.ignored: true
                    }
                    Icon {
                        anchors.verticalCenter: parent.verticalCenter
                        size: 16
                        name: Status.batteryIcon(Services.power)
                        color: Status.batteryLow(Services.power) ? Theme.danger : Theme.text
                    }
                }
            }
        }

        // Notifications bell: dot = unread, slashed = do not disturb.
        BarButton {
            id: bell
            objectName: "bell"
            active: ShellState.notificationCenterOpen
            Accessible.name: qsTr("Notifications")
            Accessible.description: Services.notifications.dnd ? qsTr("Do not disturb is on")
                : Services.notifications.count > 0 ? qsTr("%n notification(s)", "", Services.notifications.count)
                : qsTr("No notifications")
            onClicked: ShellState.toggleNotificationCenter()

            contentItem: Item {
                implicitWidth: 16
                implicitHeight: 16
                Icon {
                    anchors.centerIn: parent
                    size: 16
                    name: Services.notifications.dnd ? "bell-off"
                        : Services.notifications.count > 0 ? "bell-dot" : "bell"
                    color: Theme.text
                }
            }
        }

        // Date + time → notification center (with calendar).
        BarButton {
            id: clock
            objectName: "clock"
            active: ShellState.notificationCenterOpen
            leftPadding: Theme.space8 + Theme.space2
            rightPadding: Theme.space8 + Theme.space2
            Accessible.name: Services.clock.longDate + ", " + Services.clock.time
            Accessible.description: qsTr("Open notifications and calendar")
            onClicked: ShellState.toggleNotificationCenter()

            contentItem: Row {
                spacing: Theme.space8
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: Services.clock.date
                    font: Theme.typeBody
                    color: Theme.text
                    Accessible.ignored: true
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: Services.clock.time
                    font: Theme.typeBodyTnum
                    color: Theme.text
                    Accessible.ignored: true
                }
            }
        }
    }
}
