// Notification center + calendar (Super+N; docs/design/lugh-mode.md §2, §3).
// Full-screen overlay: the frame anchors this item to the whole screen and
// maps it while `shown`. It sits where the quick panel does: bottom-right,
// right edge on the tray's (ShellState.statusIsland), bottom edge
// ShellState.panelReserved + 8 px above the screen bottom, 360 px wide, at
// most up to 16 px from the top; the history scrolls inside it. It pops out
// of the tray like the quick panel (PopSurface: scale + fade, reduce motion =
// fade). Opens on ShellState.notificationCenterOpen; Esc or a click outside
// closes it (ShellState.closeAll()).
//
// Content: the long date + week, a compact month calendar, then one slim row
// ("Notifications" + count, Do Not Disturb, Clear) and the history grouped by
// app. Each notification is a one-line capsule that expands on click / Enter
// to its body and actions (one at a time). Groups with more than 3 show the
// newest 3 and an "N more" row; the header's chevron toggles them.
// Empty: a quiet "No notifications".
//
// Keys: ↑/↓ move between cards, Enter expands (again: default action, or
// collapses), Delete dismisses the current card, Esc closes.
//
// The content only exists while the panel is on screen.
import QtQuick
import QtQuick.Templates as T
import Lugh.UI
import Lugh.Shell
import "notify.js" as N
import "../controlcenter" as Cc

Item {
    id: root

    readonly property bool open: ShellState.notificationCenterOpen
    readonly property bool shown: morph.shown
    readonly property bool wantsKeyboard: open

    readonly property int panelWidth: 360
    readonly property int pad: Theme.space12
    readonly property int groupLimit: 3
    property int edgeMargin: 10
    readonly property real restBottom: height - ShellState.panelReserved - 8
    readonly property real maxPanelHeight: Math.max(240, restBottom - Theme.space16)
    readonly property color cardFill: Theme.dark ? Qt.rgba(1, 1, 1, 0.055) : Qt.rgba(1, 1, 1, 0.55)

    // History grouped by app (newest group first); rebuilt when it changes.
    property int _rev: 0
    readonly property var groups: { _rev; return shown ? N.groupByApp(Services.notifications.history) : []; }
    property var _expanded: ({})    // appName → true: group shows everything
    property int _openNid: -1       // the expanded card
    property bool _kbd: false       // current card was reached by keyboard
    Connections {
        target: Services.notifications.history
        enabled: root.shown
        function onCountChanged() { root._rev++; }
        function onDataChanged() { root._rev++; }
    }

    // Relative times: one shared timer, only while open.
    property double now: Date.now()
    Timer {
        interval: 30000
        repeat: true
        running: root.open
        onTriggered: root.now = Date.now()
    }

    focus: true
    Keys.onEscapePressed: ShellState.closeAll()
    Keys.onPressed: event => { if (body.item) body.item.key(event); }
    onOpenChanged: if (open) {
        now = Date.now();
        _rev++;
        _expanded = ({});
        _openNid = -1;
        _kbd = false;
        forceActiveFocus();
    }

    // Outside click closes (the panel swallows its own).
    MouseArea {
        anchors.fill: parent
        enabled: root.open
        acceptedButtons: Qt.AllButtons
        onPressed: ShellState.closeAll()
    }

    Cc.PopSurface {
        id: morph
        anchors.fill: parent
        open: root.open
        origin: Qt.point(ShellState.statusIsland.x + ShellState.statusIsland.width / 2, ShellState.statusIsland.y)
        radius: Theme.radiusXl
        targetRect: {
            const isl = ShellState.statusIsland;
            const want = isl.width > 0 ? isl.x + isl.width - root.panelWidth : root.width - root.edgeMargin - root.panelWidth;
            const x = Math.max(root.edgeMargin, Math.min(root.width - root.edgeMargin - root.panelWidth, want));
            const h = Math.round(Math.min(root.maxPanelHeight, body.item ? body.item.wantedHeight : 320));
            return Qt.rect(Math.round(x), Math.round(root.restBottom - h), root.panelWidth, h);
        }

        Accessible.role: Accessible.Pane
        Accessible.name: qsTr("Notifications and calendar")

        Loader {
            id: body
            anchors.fill: parent
            active: root.open || morph.shown
            sourceComponent: centerBody
        }
    }

    component Liquid: SpringAnimation {
        spring: Theme.liquidSpring; damping: Theme.liquidDamping
        mass: Theme.liquidMass; epsilon: Theme.springEpsilon
    }
    component Fade: NumberAnimation {
        duration: Theme.dur(Theme.durSmall)
        easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
    }

    Component {
        id: centerBody

        Item {
            id: content

            readonly property real _fixed: root.pad + top.height + Theme.space8 + root.pad
            readonly property real _listMax: Math.max(80, root.maxPanelHeight - _fixed)
            readonly property bool _empty: rows.count === 0
            // The list's content height, taken after the fact: the panel's
            // height feeds the list's, whose contentHeight is an estimate that
            // depends on it (a binding would loop).
            property real _listH: 0
            function _measure() { _listH = list.contentHeight; }
            readonly property real wantedHeight: _fixed + (_empty ? emptyState.height : Math.min(_listH, _listMax))

            // ---- rows ------------------------------------------------------
            ListModel { id: rows }
            function sync() {
                const y = list.contentY;
                if (!N.syncRows(rows, N.flatten(root.groups, root._expanded, root.groupLimit)))
                    list.contentY = Math.max(0, Math.min(y, list.contentHeight - list.height));
            }
            Connections {
                target: root
                function onGroupsChanged() { Qt.callLater(content.sync); }
                function on_ExpandedChanged() { Qt.callLater(content.sync); }
            }
            Component.onCompleted: { N.syncRows(rows, N.flatten(root.groups, root._expanded, root.groupLimit)); list.currentIndex = -1; _measure(); }

            function toggleGroup(appName) {
                const e = Object.assign({}, root._expanded);
                e[appName] = !e[appName];
                root._expanded = e;
            }
            function clearGroup(appName) {
                const m = Services.notifications.history, ids = [];
                for (let i = 0; i < m.count; ++i) if (m.get(i).appName === appName) ids.push(m.get(i).nid);
                for (const id of ids) Services.notifications.dismiss(id);
            }
            function toggleCard(nid) { root._openNid = root._openNid === nid ? -1 : nid; }

            // ---- keyboard --------------------------------------------------
            function move(step) {
                let i = list.currentIndex;
                if (i < 0 && step < 0) return;
                for (i += step; i >= 0 && i < rows.count; i += step)
                    if (rows.get(i).kind !== "header") { list.currentIndex = i; root._kbd = true; return; }
            }
            function key(event) {
                const cur = list.currentIndex >= 0 && list.currentIndex < rows.count ? rows.get(list.currentIndex) : null;
                switch (event.key) {
                case Qt.Key_Down: move(1); break;
                case Qt.Key_Up: move(-1); break;
                case Qt.Key_Delete:
                case Qt.Key_Backspace:
                    if (!cur || cur.kind !== "item") return;
                    Services.notifications.dismiss(cur.nid);
                    break;
                case Qt.Key_Return:
                case Qt.Key_Enter:
                case Qt.Key_Space:
                    if (!cur) return;
                    if (cur.kind === "more") toggleGroup(cur.appName);
                    else if (root._openNid !== cur.nid) root._openNid = cur.nid;
                    else if (N.hasDefaultAction(cur.actions)) Services.notifications.invokeAction(cur.nid, "default");
                    else root._openNid = -1;
                    break;
                default: return;
                }
                event.accepted = true;
            }

            // ---- date, calendar, notifications row -------------------------
            Column {
                id: top
                x: root.pad
                y: root.pad
                width: parent.width - 2 * root.pad
                spacing: Theme.space8

                Item {
                    width: parent.width
                    height: 26
                    Text {
                        id: dateText
                        x: Theme.space8
                        width: Math.min(implicitWidth, parent.width - x - weekText.width - Theme.space16)
                        anchors.verticalCenter: parent.verticalCenter
                        text: Services.clock.longDate
                        font: Theme.typeTitle3
                        color: Theme.text
                        elide: Text.ElideRight
                        Accessible.role: Accessible.Heading
                    }
                    Text {
                        id: weekText
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.space8
                        anchors.baseline: dateText.baseline
                        text: qsTr("Week %1 · %2").arg(N.isoWeek(new Date(calendar._year, calendar._month, calendar.todayKey % 100)))
                                                  .arg(calendar._year)
                        font: Theme.typeCaptionTnum
                        color: Theme.textMuted
                    }
                }

                MonthCalendar {
                    id: calendar
                    width: parent.width
                    fill: root.cardFill
                }

                Item {
                    width: parent.width
                    height: 32
                    Text {
                        id: heading
                        x: Theme.space8
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Notifications")
                        font: Theme.typeLabel
                        color: Theme.text
                        Accessible.role: Accessible.Heading
                    }
                    Badge {
                        anchors.left: heading.right
                        anchors.leftMargin: Theme.space8
                        anchors.verticalCenter: parent.verticalCenter
                        visible: Services.notifications.count > 0
                        text: Services.notifications.count > 99 ? "99+" : String(Services.notifications.count)
                        tone: "neutral"
                    }
                    Button {
                        id: clearBtn
                        anchors.right: dnd.left
                        anchors.rightMargin: Theme.space4
                        anchors.verticalCenter: parent.verticalCenter
                        visible: Services.notifications.count > 0
                        text: qsTr("Clear")
                        size: "sm"
                        variant: "ghost"
                        Accessible.name: qsTr("Clear all notifications")
                        onClicked: Services.notifications.clearAll()
                    }
                    IconToggle {
                        id: dnd
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        size: 30
                        iconName: "moon"
                        checkedIconName: "bell-off"
                        label: qsTr("Do Not Disturb")
                        stateText: checked ? qsTr("only urgent notifications pop up") : ""
                        checked: Services.notifications.dnd
                        onToggled: {
                            Services.notifications.setDnd(checked);
                            checked = Qt.binding(() => Services.notifications.dnd);
                        }
                    }
                }
            }

            // ---- empty -----------------------------------------------------
            Item {
                id: emptyState
                x: root.pad
                y: top.y + top.height + Theme.space8
                width: parent.width - 2 * root.pad
                height: 64
                visible: content._empty
                Row {
                    anchors.centerIn: parent
                    anchors.verticalCenterOffset: -Theme.space4
                    spacing: Theme.space8
                    Icon { name: "bell"; size: 16; color: Theme.textMuted; anchors.verticalCenter: parent.verticalCenter }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("No notifications")
                        font: Theme.typeCaption
                        color: Theme.textMuted
                    }
                }
            }

            // ---- history ---------------------------------------------------
            ListView {
                id: list
                objectName: "notificationHistory"
                onContentHeightChanged: Qt.callLater(content._measure)
                x: root.pad
                y: top.y + top.height + Theme.space8
                width: parent.width - 2 * root.pad
                height: Math.max(0, parent.height - y - root.pad)
                visible: !content._empty
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: rows
                reuseItems: false
                currentIndex: -1
                highlightFollowsCurrentItem: true
                highlightMoveDuration: Theme.dur(Theme.durMedium)
                preferredHighlightBegin: 40
                preferredHighlightEnd: height - 40
                highlightRangeMode: ListView.ApplyRange

                remove: Transition {
                    ParallelAnimation {
                        Fade { property: "opacity"; to: 0 }
                        Fade { property: "x"; to: Theme.reduceMotion ? 0 : 28 }
                    }
                }
                add: Transition { Fade { property: "opacity"; from: 0; to: 1 } }
                displaced: Theme.reduceMotion ? null : reflow
                Transition {
                    id: reflow
                    ParallelAnimation {
                        Liquid { property: "y" }
                        Fade { property: "opacity"; to: 1 }
                        Fade { property: "x"; to: 0 }
                    }
                }

                T.ScrollIndicator.vertical: T.ScrollIndicator {
                    id: indicator
                    padding: 1
                    contentItem: Rectangle {
                        implicitWidth: 3
                        radius: 1.5
                        color: Theme.textMuted
                        opacity: indicator.active ? 0.5 : 0
                        Behavior on opacity { NumberAnimation { duration: Theme.durSmall } }
                    }
                }

                delegate: Loader {
                    id: slot
                    required property int index
                    required property string kind
                    required property string appName
                    required property string appIcon
                    required property int count
                    required property bool collapsible
                    required property bool open
                    required property int more
                    required property int nid
                    required property string summary
                    required property string body
                    required property int urgency
                    required property double time
                    required property string actions
                    required property string image
                    readonly property bool current: ListView.isCurrentItem && root._kbd

                    width: ListView.view ? ListView.view.width : 0
                    sourceComponent: kind === "header" ? headerRow : kind === "more" ? moreRow : cardRow

                    // Group header: app icon, name, count, expand, clear.
                    Component {
                        id: headerRow
                        Item {
                            implicitHeight: (slot.index > 0 ? Theme.space8 : 0) + 28
                            Item {
                                anchors.bottom: parent.bottom
                                width: parent.width
                                height: 28
                                AppIcon {
                                    id: groupIcon
                                    x: Theme.space8
                                    anchors.verticalCenter: parent.verticalCenter
                                    iconName: slot.appIcon
                                    fallbackText: slot.appName
                                    size: 16
                                }
                                Text {
                                    id: groupName
                                    anchors.left: groupIcon.right
                                    anchors.leftMargin: Theme.space8
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Math.min(implicitWidth, parent.width - x - 96)
                                    text: slot.appName
                                    font: Theme.typeCaption
                                    color: Theme.textMuted
                                    elide: Text.ElideRight
                                    Accessible.role: Accessible.Heading
                                }
                                Text {
                                    anchors.left: groupName.right
                                    anchors.leftMargin: Theme.space4
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: slot.count > 1
                                    text: "· " + slot.count
                                    font: Theme.typeCaptionTnum
                                    color: Theme.textMuted
                                    Accessible.name: qsTr("%n notification(s)", "", slot.count)
                                }
                                IconButton {
                                    anchors.right: clearGroupBtn.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: slot.collapsible
                                    iconName: slot.open ? "chevron-up" : "chevron-down"
                                    size: 24
                                    iconSize: 14
                                    tooltip: slot.open ? qsTr("Show fewer %1 notifications").arg(slot.appName)
                                                       : qsTr("Show all %1 %2 notifications").arg(slot.count).arg(slot.appName)
                                    onClicked: content.toggleGroup(slot.appName)
                                }
                                IconButton {
                                    id: clearGroupBtn
                                    anchors.right: parent.right
                                    anchors.rightMargin: Theme.space4
                                    anchors.verticalCenter: parent.verticalCenter
                                    iconName: "x"
                                    size: 24
                                    iconSize: 14
                                    tooltip: qsTr("Clear %1 notifications").arg(slot.appName)
                                    onClicked: content.clearGroup(slot.appName)
                                }
                            }
                        }
                    }

                    Component {
                        id: cardRow
                        Item {
                            implicitHeight: card.height + Theme.space4
                            HoverHandler { id: cardHover }
                            NotificationCard {
                                id: card
                                width: parent.width
                                height: implicitHeight
                                fill: root.cardFill
                                showIcon: false
                                collapsedHeight: 36
                                padding: Theme.space12
                                bodyLines: 4
                                includeDefault: true
                                nid: slot.nid
                                appName: slot.appName
                                summary: slot.summary
                                body: slot.body
                                urgency: slot.urgency
                                time: slot.time
                                actions: slot.actions
                                image: slot.image
                                now: root.now
                                expanded: root._openNid === slot.nid
                                closeVisible: cardHover.hovered || slot.current
                                hovered: cardHover.hovered
                                pressed: cardTap.pressed
                                selected: slot.current
                                onCloseRequested: Services.notifications.dismiss(slot.nid)
                                Accessible.onPressAction: content.toggleCard(slot.nid)

                                TapHandler {
                                    id: cardTap
                                    onTapped: { root._kbd = false; list.currentIndex = slot.index; content.toggleCard(slot.nid); }
                                }
                            }
                        }
                    }

                    // "N more" under a collapsed group.
                    Component {
                        id: moreRow
                        Item {
                            implicitHeight: 28 + Theme.space2
                            Chip {
                                id: moreChip
                                x: Theme.space4
                                text: qsTr("%n more", "", slot.more)
                                iconName: "chevron-down"
                                Accessible.name: qsTr("Show all %1 %2 notifications").arg(slot.count).arg(slot.appName)
                                onClicked: content.toggleGroup(slot.appName)
                                FocusRing { show: slot.current }
                            }
                        }
                    }
                }
            }
        }
    }
}
