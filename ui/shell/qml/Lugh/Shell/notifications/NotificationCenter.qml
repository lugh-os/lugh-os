// Notification center + calendar (shell spec §Notifications, §States).
// Full-screen overlay: the frame anchors this item to the whole screen and
// maps it while `shown`. The panel sits top-right below the bar (right 8,
// top 36), 380 px wide, at most screen height − 120 tall; the history list
// scrolls inside it. Opens on ShellState.notificationCenterOpen; Esc or a
// click outside the panel closes it (ShellState.closeAll()).
//
// Content: today's date, a month calendar, then "Notifications" with
// Do Not Disturb (always visible) and "Clear all", and the history grouped by
// app (newest group first). Groups with more than 2 notifications collapse
// to the newest one over a stack hint; the header toggles them.
// Empty: "No notifications" (EmptyState with `bell-off`).
import QtQuick
import QtQuick.Layouts
import QtQuick.Templates as T
import Lugh.UI
import Lugh.Shell
import "notify.js" as N

Item {
    id: root

    readonly property bool open: ShellState.notificationCenterOpen
    readonly property bool shown: open || panel.opacity > 0
    readonly property bool wantsKeyboard: open

    readonly property int panelWidth: 380
    readonly property color cardFill: Theme.dark ? Qt.rgba(1, 1, 1, 0.05) : Qt.rgba(1, 1, 1, 0.62)

    // Relative times: one shared timer, only while open.
    property double now: Date.now()
    Timer {
        interval: 30000
        repeat: true
        running: root.open
        onTriggered: root.now = Date.now()
    }

    // History grouped by app; rebuilt when the model changes.
    property int _rev: 0
    readonly property var groups: { _rev; return N.groupByApp(Services.notifications.history); }
    property var _expanded: ({})
    Connections {
        target: Services.notifications.history
        function onCountChanged() { root._rev++; }
        function onDataChanged() { root._rev++; }
    }

    focus: true
    Keys.onEscapePressed: ShellState.closeAll()
    onOpenChanged: if (open) {
        now = Date.now();
        calendar.reset();
        _expanded = ({});
        forceActiveFocus();
        list.positionViewAtBeginning();
    }

    // Outside click closes.
    MouseArea {
        anchors.fill: parent
        enabled: root.open
        onPressed: ShellState.closeAll()
    }

    GlassPanel {
        id: panel
        anchors { top: parent.top; topMargin: 36; right: parent.right; rightMargin: 8 }
        width: root.panelWidth
        height: Math.min(body.implicitHeight + 2 * Theme.space16, root.height - 120)
        radius: Theme.radiusLg
        elevation: "popover"

        opacity: root.open ? 1 : 0
        visible: opacity > 0
        Behavior on opacity {
            NumberAnimation {
                duration: Theme.dur(root.open ? Theme.durMedium : Theme.durSmall)
                easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
            }
        }
        transform: Translate {
            y: root.open || Theme.reduceMotion ? 0 : -8
            Behavior on y {
                NumberAnimation {
                    duration: Theme.dur(Theme.durMedium)
                    easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
                }
            }
        }

        Accessible.role: Accessible.Pane
        Accessible.name: qsTr("Notifications and calendar")

        // Swallow clicks on the panel so they don't close it.
        MouseArea { anchors.fill: parent }

        ColumnLayout {
            id: body
            x: Theme.space16
            y: Theme.space16
            width: parent.width - 2 * Theme.space16
            height: parent.height - 2 * Theme.space16
            spacing: Theme.space12

            // ---- date --------------------------------------------------------
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space4
                spacing: Theme.space2
                Text {
                    Layout.fillWidth: true
                    text: Services.clock.longDate
                    font: Theme.typeTitle3
                    color: Theme.text
                    elide: Text.ElideRight
                    Accessible.role: Accessible.Heading
                }
                Text {
                    readonly property date d: Services.clock.now
                    readonly property int week: {
                        // ISO 8601 week number.
                        const t = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()));
                        const day = t.getUTCDay() || 7;
                        t.setUTCDate(t.getUTCDate() + 4 - day);
                        const y0 = new Date(Date.UTC(t.getUTCFullYear(), 0, 1));
                        return Math.ceil(((t - y0) / 86400000 + 1) / 7);
                    }
                    text: qsTr("Week %1 · %2").arg(week).arg(d.getFullYear())
                    font: Theme.typeCaptionTnum
                    color: Theme.textMuted
                }
            }

            MonthCalendar {
                id: calendar
                Layout.fillWidth: true
                fill: root.cardFill
            }

            // ---- notifications header ---------------------------------------
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Theme.space4
                Layout.leftMargin: Theme.space4
                spacing: Theme.space8
                Text {
                    text: qsTr("Notifications")
                    font: Theme.typeBodyStrong
                    color: Theme.text
                    Accessible.role: Accessible.Heading
                }
                Badge {
                    visible: Services.notifications.count > 0
                    text: Services.notifications.count > 99 ? "99+" : String(Services.notifications.count)
                    tone: "neutral"
                }
                Item { Layout.fillWidth: true }
                Button {
                    visible: Services.notifications.count > 0
                    text: qsTr("Clear all")
                    size: "sm"
                    variant: "ghost"
                    onClicked: Services.notifications.clearAll()
                }
            }

            // Do Not Disturb stays visible, also when empty.
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: dndCol.implicitHeight + 2 * Theme.space8
                radius: Theme.radiusMd
                color: root.cardFill
                border.width: 1
                border.color: Theme.glassBorder

                ColumnLayout {
                    id: dndCol
                    x: Theme.space12
                    y: Theme.space8
                    width: parent.width - 2 * Theme.space12
                    spacing: 0
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.space8
                        Icon {
                            name: Services.notifications.dnd ? "bell-off" : "bell"
                            size: 16
                            color: Services.notifications.dnd ? Theme.accentText : Theme.textMuted
                        }
                        Toggle {
                            Layout.fillWidth: true
                            text: qsTr("Do Not Disturb")
                            checked: Services.notifications.dnd
                            onToggled: Services.notifications.dnd = checked
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        Layout.leftMargin: 16 + Theme.space8
                        Layout.bottomMargin: Theme.space4
                        visible: Services.notifications.dnd
                        text: qsTr("Only urgent notifications pop up.")
                        font: Theme.typeCaption
                        color: Theme.textMuted
                        wrapMode: Text.Wrap
                    }
                }
            }

            // ---- empty -------------------------------------------------------
            EmptyState {
                visible: Services.notifications.count === 0
                Layout.fillWidth: true
                Layout.preferredHeight: implicitHeight + Theme.space32
                iconName: "bell-off"
                title: qsTr("No notifications")
                body: qsTr("You're all caught up. New notifications will show up here.")
            }

            // ---- history ----------------------------------------------------
            ListView {
                id: list
                objectName: "notificationHistory"
                visible: Services.notifications.count > 0
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: contentHeight
                Layout.minimumHeight: Math.min(contentHeight, 140)
                clip: true
                spacing: Theme.space16
                boundsBehavior: Flickable.StopAtBounds
                model: root.groups
                reuseItems: false

                T.ScrollIndicator.vertical: T.ScrollIndicator {
                    id: indicator
                    padding: 2
                    contentItem: Rectangle {
                        implicitWidth: 3
                        radius: 1.5
                        color: Theme.textMuted
                        opacity: indicator.active ? 0.5 : 0
                        Behavior on opacity { NumberAnimation { duration: Theme.durSmall } }
                    }
                }

                delegate: ColumnLayout {
                    id: group
                    required property var modelData
                    required property int index
                    readonly property var g: modelData
                    readonly property bool collapsible: g.items.length > 2
                    readonly property bool expanded: !collapsible || root._expanded[g.appName] === true
                    readonly property var visibleItems: expanded ? g.items : g.items.slice(0, 1)

                    function toggle() {
                        const e = Object.assign({}, root._expanded);
                        e[g.appName] = !expanded;
                        root._expanded = e;
                    }
                    function clearGroup() {
                        const ids = g.items.map(x => x.nid);
                        for (const id of ids) Services.notifications.dismiss(id);
                    }

                    width: ListView.view.width
                    spacing: Theme.space8

                    // Group header: app icon, name, count, expand, clear.
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: Theme.space4
                        spacing: Theme.space8
                        AppIcon {
                            iconName: group.g.appIcon
                            fallbackText: group.g.appName
                            size: 20
                        }
                        Text {
                            Layout.fillWidth: true
                            text: group.g.appName
                            font: Theme.typeCaption
                            color: Theme.textMuted
                            elide: Text.ElideRight
                            Accessible.role: Accessible.Heading
                        }
                        Button {
                            visible: group.collapsible
                            text: group.expanded ? qsTr("Show less") : qsTr("%1 more").arg(group.g.items.length - 1)
                            iconName: group.expanded ? "chevron-up" : "chevron-down"
                            size: "sm"
                            variant: "ghost"
                            Accessible.name: group.expanded ? qsTr("Show fewer %1 notifications").arg(group.g.appName)
                                                            : qsTr("Show all %1 %2 notifications").arg(group.g.items.length).arg(group.g.appName)
                            onClicked: group.toggle()
                        }
                        IconButton {
                            iconName: "x"
                            size: 24
                            iconSize: 14
                            tooltip: qsTr("Clear %1 notifications").arg(group.g.appName)
                            onClicked: group.clearGroup()
                        }
                    }

                    Repeater {
                        model: group.visibleItems
                        NotificationCard {
                            required property var modelData
                            Layout.fillWidth: true
                            n: modelData
                            now: root.now
                            fill: root.cardFill
                        }
                    }

                    // Stack hint under a collapsed group (also expands it).
                    Item {
                        visible: !group.expanded
                        Layout.fillWidth: true
                        Layout.topMargin: -Theme.space8
                        Layout.preferredHeight: 12
                        Rectangle {
                            x: 8; width: parent.width - 16; height: 6
                            radius: 0
                            bottomLeftRadius: Theme.radiusMd; bottomRightRadius: Theme.radiusMd
                            color: root.cardFill
                            border.width: 1
                            border.color: Theme.glassBorder
                        }
                        Rectangle {
                            x: 16; y: 6; width: parent.width - 32; height: 6
                            bottomLeftRadius: Theme.radiusMd; bottomRightRadius: Theme.radiusMd
                            color: root.cardFill
                            border.width: 1
                            border.color: Theme.glassBorder
                            visible: group.g.items.length > 2
                        }
                        TapHandler { onTapped: group.toggle(); cursorShape: Qt.PointingHandCursor }
                    }
                }
            }
        }
    }
}
