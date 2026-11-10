// One notification in the notification center: a flat translucent card with
// the relative time (swapped for a dismiss button on hover / keyboard focus),
// the shared NotificationContent and, for critical ones, a danger bar.
// Dismissing fades the card out, then removes it from Services.
// Internal to notifications/ (not exported in the qmldir).
import QtQuick
import Lugh.UI
import Lugh.Shell
import "notify.js" as N

Rectangle {
    id: card

    property var n: ({})           // row: nid, appName, summary, body, urgency, time, actions, image
    property double now: Date.now()
    property color fill: "transparent"

    readonly property bool critical: n.urgency === 2
    property bool _leaving: false

    function dismiss() {
        if (_leaving) return;
        _leaving = true;
        leave.start();
    }

    implicitHeight: content.implicitHeight + 2 * Theme.space12
    radius: Theme.radiusMd
    color: hover.hovered && N.hasDefaultAction(n.actions) ? Qt.tint(fill, Theme.hoverOverlay) : fill
    border.width: 1
    border.color: Theme.glassBorder
    Behavior on color { ColorAnimation { duration: Theme.durMicro } }

    Accessible.role: Accessible.ListItem
    Accessible.name: (critical ? qsTr("Urgent: ") : "") + (n.summary || "")
    Accessible.description: N.plain(n.body)

    SequentialAnimation {
        id: leave
        ParallelAnimation {
            NumberAnimation { target: card; property: "opacity"; to: 0; duration: Theme.dur(Theme.durSmall) }
            NumberAnimation {
                target: card; property: "x"; to: Theme.reduceMotion ? 0 : 24
                duration: Theme.dur(Theme.durSmall)
                easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
            }
        }
        ScriptAction { script: Services.notifications.dismiss(card.n.nid) }
    }

    HoverHandler { id: hover }
    TapHandler {
        enabled: N.hasDefaultAction(card.n.actions)
        cursorShape: Qt.PointingHandCursor
        onTapped: Services.notifications.invokeAction(card.n.nid, "default")
    }

    Rectangle {
        visible: card.critical
        x: 4
        y: Theme.space12
        width: 3
        height: parent.height - 2 * Theme.space12
        radius: 1.5
        color: Theme.danger
    }

    NotificationContent {
        id: content
        x: Theme.space12
        y: Theme.space12
        width: parent.width - 2 * Theme.space12
        nid: card.n.nid !== undefined ? card.n.nid : -1
        summary: card.n.summary || ""
        body: card.n.body || ""
        urgency: card.n.urgency !== undefined ? card.n.urgency : 1
        actions: card.n.actions || "[]"
        image: card.n.image || ""
        bodyLines: 4
        summaryTrailing: image !== "" ? 0 : Math.max(timeText.implicitWidth, 24) + Theme.space8
        imageTopMargin: image !== "" ? timeText.implicitHeight + Theme.space8 : 0
    }

    Text {
        id: timeText
        anchors { top: parent.top; topMargin: Theme.space12 + 1; right: parent.right; rightMargin: Theme.space12 }
        text: N.relativeTime(card.n.time, card.now)
        font: Theme.typeCaptionTnum
        color: Theme.textMuted
        opacity: closeBtn.opacity > 0.5 ? 0 : 1
    }
    IconButton {
        id: closeBtn
        anchors { top: parent.top; topMargin: Theme.space4; right: parent.right; rightMargin: Theme.space4 }
        iconName: "x"
        size: 24
        iconSize: 14
        variant: "filled"
        tooltip: qsTr("Dismiss")
        opacity: hover.hovered || activeFocus ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.durMicro } }
        onClicked: card.dismiss()
    }
}
