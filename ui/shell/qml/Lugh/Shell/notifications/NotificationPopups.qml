// Notification toasts (shell spec §Notifications): up to 3 stacked, newest
// on top, top-right below the bar. Content-sized: the frame anchors this item
// top-right (top 38, right 8) and sizes its layer window from implicitWidth /
// implicitHeight, which include room on the left and below for the toast
// shadows.
//
// Behaviour
//   - normal/low toasts expire after 5 s (Services.notifications.expire: the
//     notification stays in history); the timers pause while the pointer is
//     over the stack. Critical toasts stay until dismissed.
//   - close button (on hover or keyboard focus) dismisses the notification
//     (gone from history too); swiping a toast to the right expires it (it
//     stays in the notification center), like the macOS banner.
//   - a "default" action (freedesktop) is invoked by clicking the toast.
//   - more than 3: a "+N more" pill opens the notification center.
//   - critical: a danger bar on the left and a `circle-alert` glyph.
//   - while the notification center is open the stack hides; normal toasts
//     expire into it, critical ones return when it closes.
import QtQuick
import QtQuick.Layouts
import Lugh.UI
import Lugh.Shell
import "notify.js" as N

Item {
    id: root

    readonly property int toastWidth: 360
    readonly property int maxVisible: 3
    readonly property int timeoutMs: 5000
    // Shadow room (Shadow "popover" level reaches ~30 px left, ~36 px below).
    // Right and top fall into the frame's padding / the bar.
    readonly property int padLeft: 30
    readonly property int padBottom: 36

    // Any toast visible or still animating out.
    readonly property bool shown: (list.count > 0 || _heldHeight > 0) && (!_centerOpen || opacity > 0)
    readonly property int hiddenCount: Math.max(0, list.count - maxVisible)
    readonly property bool paused: stackHover.hovered || _centerOpen

    // While the notification center is open the toasts step aside: normal
    // ones expire into it, critical ones come back when it closes.
    readonly property bool _centerOpen: ShellState.notificationCenterOpen
    on_CenterOpenChanged: if (_centerOpen) {
        const m = Services.notifications.popups, ids = [];
        for (let i = 0; i < m.count; ++i) if (m.get(i).urgency !== 2) ids.push(m.get(i).nid);
        for (const id of ids) Services.notifications.expire(id);
    }
    opacity: _centerOpen ? 0 : 1
    Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durSmall) } }

    implicitWidth: padLeft + toastWidth
    implicitHeight: _heldHeight > 0 ? _heldHeight + padBottom : 0

    // ---- relative times: one shared timer ---------------------------------
    property double _now: Date.now()
    Timer {
        interval: 30000
        repeat: true
        running: root.shown
        onTriggered: root._now = Date.now()
    }

    // ---- height that shrinks only after exit animations finish -----------
    readonly property real _stackHeight: list.count === 0 ? 0
        : list.contentHeight + (root.hiddenCount > 0 ? morePill.height : 0)
    property real _heldHeight: 0
    on_StackHeightChanged: {
        if (_stackHeight >= _heldHeight) { _heldHeight = _stackHeight; _shrink.stop(); }
        else _shrink.restart();
    }
    Timer {
        id: _shrink
        interval: Theme.durLarge + 60
        onTriggered: root._heldHeight = root._stackHeight
    }

    function _announce(text) {
        // Accessible.announce() is Qt 6.8+; guard so older runtimes only lose
        // the announcement.
        if (typeof announcer.Accessible.announce === "function")
            announcer.Accessible.announce(text);
    }
    Item { id: announcer; Accessible.role: Accessible.StaticText; Accessible.name: "" }

    HoverHandler { id: stackHover }


    ListView {
        id: list
        x: root.padLeft
        width: root.toastWidth
        // Never sized from contentHeight: a 0-high view would create no
        // delegates. The root's implicitHeight follows contentHeight instead.
        height: Math.max(contentHeight, 600)
        interactive: false
        boundsBehavior: Flickable.StopAtBounds
        model: Services.notifications.popups
        cacheBuffer: 0

        remove: Transition {
            ParallelAnimation {
                NumberAnimation {
                    property: "opacity"
                    to: 0
                    duration: Theme.dur(Theme.durSmall)
                    easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
                }
                NumberAnimation {
                    property: "x"
                    to: Theme.reduceMotion ? 0 : 32
                    duration: Theme.dur(Theme.durMedium)
                    easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
                }
            }
        }
        displaced: Transition {
            ParallelAnimation {
                NumberAnimation {
                    property: "y"
                    duration: Theme.reduceMotion ? 0 : Theme.durLarge
                    easing.type: Easing.OutBack
                    easing.overshoot: 0.6
                }
                // Finish an interrupted remove / enter cleanly.
                NumberAnimation { property: "opacity"; to: 1; duration: Theme.dur(Theme.durSmall) }
                NumberAnimation { property: "x"; to: 0; duration: Theme.dur(Theme.durSmall) }
            }
        }

        delegate: Item {
            id: toast

            required property int index
            required property int nid
            required property string appName
            required property string appIcon
            required property string summary
            required property string body
            required property int urgency
            required property double time
            required property string actions
            required property string image

            readonly property bool inStack: index < root.maxVisible
            readonly property bool critical: urgency === 2
            readonly property bool hasDefault: N.hasDefaultAction(actions)
            readonly property int gap: Theme.space8

            width: ListView.view ? ListView.view.width : root.toastWidth
            height: inStack ? panel.height + gap : 0
            z: -index

            // Enter: slide in from the right + fade. Done here, not as a ListView
            // `add` transition: ListView ignores height changes of delegates in
            // an add transition (the text wraps one polish after creation), which
            // left toasts overlapping.
            ParallelAnimation {
                id: enter
                NumberAnimation {
                    target: slot; property: "x"
                    from: Theme.reduceMotion ? 0 : 24; to: 0
                    duration: Theme.dur(Theme.durLarge + 60)
                    easing.type: Easing.OutBack; easing.overshoot: 0.9
                }
                NumberAnimation {
                    target: slot; property: "opacity"
                    from: 0; to: 1
                    duration: Theme.dur(Theme.durMedium)
                    easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
                }
            }

            Component.onCompleted: {
                enter.start();
                if (index === 0) root._announce((critical ? qsTr("Urgent notification from %1: %2") : qsTr("Notification from %1: %2"))
                               .arg(appName).arg(summary !== "" ? summary : N.plain(body)));
            }

            Timer {
                interval: root.timeoutMs
                running: toast.inStack && !toast.critical && !root.paused && !swipe.active
                onTriggered: Services.notifications.expire(toast.nid)
            }

            HoverHandler { id: toastHover }

            // Moved by the enter animation; the panel inside moves on swipe.
            Item {
                id: slot
                width: parent.width
                height: panel.height

                GlassPanel {
                    id: panel
                    width: parent.width
                    height: content.implicitHeight + Theme.space12 + Theme.space16
                    radius: Theme.radiusLg
                    elevation: "popover"
                    // Beyond the 3rd: fade out in place (it is at the bottom).
                    opacity: (toast.inStack ? 1 : 0) * Math.max(0, 1 - Math.max(0, x) / 220)
                    visible: opacity > 0
                    Behavior on opacity {
                        enabled: !swipe.active
                        NumberAnimation { duration: Theme.dur(Theme.durSmall) }
                    }

                    Accessible.role: Accessible.AlertMessage
                    Accessible.name: toast.appName + ": " + toast.summary
                    Accessible.description: N.plain(toast.body)

                    // Swipe right to send it to the notification center.
                    DragHandler {
                        id: swipe
                        target: panel
                        yAxis.enabled: false
                        xAxis.minimum: 0
                        xAxis.maximum: root.toastWidth
                        onActiveChanged: {
                            if (active) return;
                            if (panel.x > 96) swipeOut.start();
                            else settle.start();
                        }
                    }
                    NumberAnimation {
                        id: settle
                        target: panel; property: "x"; to: 0
                        duration: Theme.dur(Theme.durMedium)
                        easing.type: Easing.OutBack; easing.overshoot: 0.8
                    }
                    SequentialAnimation {
                        id: swipeOut
                        NumberAnimation {
                            target: panel; property: "x"; to: root.toastWidth * 0.75
                            duration: Theme.dur(Theme.durSmall)
                            easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
                        }
                        ScriptAction { script: Services.notifications.expire(toast.nid) }
                    }
                    TapHandler {
                        enabled: toast.hasDefault
                        cursorShape: Qt.PointingHandCursor
                        onTapped: Services.notifications.invokeAction(toast.nid, "default")
                    }

                    // Critical: a danger bar (paired with the glyph in the summary).
                    Rectangle {
                        visible: toast.critical
                        x: 5
                        y: Theme.space12
                        width: 3
                        height: parent.height - 2 * Theme.space12
                        radius: 1.5
                        color: Theme.danger
                    }

                    ColumnLayout {
                        id: content
                        x: Theme.space16
                        y: Theme.space12
                        width: parent.width - 2 * Theme.space16
                        spacing: Theme.space8

                        // Header: app icon, app name, relative time / close.
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 20
                            spacing: Theme.space8

                            AppIcon {
                                iconName: toast.appIcon
                                fallbackText: toast.appName
                                size: 20
                            }
                            Text {
                                Layout.fillWidth: true
                                text: toast.appName
                                font: Theme.typeCaption
                                color: Theme.textMuted
                                elide: Text.ElideRight
                            }
                            Item {
                                Layout.preferredWidth: Math.max(timeText.implicitWidth, 20)
                                Layout.preferredHeight: 20

                                Text {
                                    id: timeText
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: N.relativeTime(toast.time, root._now)
                                    font: Theme.typeCaptionTnum
                                    color: Theme.textMuted
                                    opacity: closeBtn.opacity > 0.5 ? 0 : 1
                                }
                                IconButton {
                                    id: closeBtn
                                    anchors.right: parent.right
                                    anchors.rightMargin: -6
                                    anchors.verticalCenter: parent.verticalCenter
                                    iconName: "x"
                                    size: 24
                                    iconSize: 14
                                    variant: "filled"
                                    tooltip: qsTr("Dismiss")
                                    opacity: toastHover.hovered || activeFocus ? 1 : 0
                                    Behavior on opacity { NumberAnimation { duration: Theme.durMicro } }
                                    onClicked: Services.notifications.dismiss(toast.nid)
                                }
                            }
                        }

                        NotificationContent {
                            Layout.fillWidth: true
                            nid: toast.nid
                            summary: toast.summary
                            body: toast.body
                            urgency: toast.urgency
                            actions: toast.actions
                            image: toast.image
                            bodyLines: 2
                        }
                    }
                }
            }
        }
    }

    // ---- "+N more" -------------------------------------------------------
    Item {
        id: morePill
        readonly property bool active: root.hiddenCount > 0
        anchors.right: list.right
        y: list.contentHeight
        width: pillPanel.width
        height: 28 + Theme.space8
        opacity: active ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durSmall) } }

        Accessible.role: Accessible.Button
        Accessible.name: qsTr("%n more notification(s), open the notification center", "", root.hiddenCount)

        GlassPanel {
            id: pillPanel
            anchors.right: parent.right
            width: pillRow.implicitWidth + 2 * Theme.space12
            height: 28
            radius: height / 2
            elevation: "menu"

            Rectangle {
                anchors.fill: parent
                radius: pillPanel.radius
                color: pillTap.pressed ? Theme.pressedOverlay : pillHover.hovered ? Theme.hoverOverlay : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.durMicro } }
            }
            Row {
                id: pillRow
                anchors.centerIn: parent
                spacing: Theme.space4
                Icon { name: "bell"; size: 14; color: Theme.textMuted; anchors.verticalCenter: parent.verticalCenter }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("+%1 more").arg(root.hiddenCount)
                    font: Theme.typeCaptionTnum
                    color: Theme.text
                }
            }
            HoverHandler { id: pillHover; cursorShape: Qt.PointingHandCursor }
            TapHandler {
                id: pillTap
                onTapped: if (!ShellState.notificationCenterOpen) ShellState.toggleNotificationCenter()
            }
        }
    }
}
