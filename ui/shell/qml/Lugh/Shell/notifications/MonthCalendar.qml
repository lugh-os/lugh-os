// Compact month calendar for the notification center: month title, a "Today"
// chip when away from the current month, previous / next, weekday initials
// (locale's first day of week) and 28 px day cells with tabular numerals.
// Only the weeks the month needs are shown (4–6): the panel glides when that
// changes. Today is an accent circle with bold Theme.onAccent numerals (not
// color alone). Read-only: days are not interactive.
// Internal to notifications/ (not exported in the qmldir).
import QtQuick
import Lugh.UI
import Lugh.Shell

Rectangle {
    id: root

    property color fill: "transparent"
    // yyyymmdd: changes once a day, not with every clock tick.
    readonly property int todayKey: {
        const d = Services.clock.now;
        return d.getFullYear() * 10000 + d.getMonth() * 100 + d.getDate();
    }
    readonly property int _year: Math.floor(todayKey / 10000)
    readonly property int _month: Math.floor(todayKey / 100) % 100
    // First day of the month shown.
    property date viewMonth: new Date(_year, _month, 1)
    readonly property bool onCurrentMonth: viewMonth.getFullYear() === _year && viewMonth.getMonth() === _month
    readonly property int firstDay: Qt.locale().firstDayOfWeek % 7   // 0 = Sunday
    readonly property int cellHeight: 28
    readonly property int pad: Theme.space8

    function reset() { viewMonth = new Date(_year, _month, 1); }
    function shift(months) { viewMonth = new Date(viewMonth.getFullYear(), viewMonth.getMonth() + months, 1); }

    // Whole weeks covering the month, starting on the week that holds the 1st.
    readonly property var cells: {
        const y = viewMonth.getFullYear(), m = viewMonth.getMonth();
        const lead = (new Date(y, m, 1).getDay() - firstDay + 7) % 7;
        const weeks = Math.ceil((lead + new Date(y, m + 1, 0).getDate()) / 7);
        const out = [];
        for (let i = 0; i < weeks * 7; ++i) {
            const d = new Date(y, m, 1 - lead + i);
            out.push({ day: d.getDate(), inMonth: d.getMonth() === m,
                       key: d.getFullYear() * 10000 + d.getMonth() * 100 + d.getDate(), date: d });
        }
        return out;
    }

    implicitHeight: pad + 28 + Theme.space2 + 20 + (cells.length / 7) * cellHeight + pad
    radius: Theme.radiusLg
    color: fill
    border.width: 1
    border.color: Theme.glassBorder

    Accessible.role: Accessible.Table
    Accessible.name: Qt.formatDate(viewMonth, "MMMM yyyy")

    // ---- title row --------------------------------------------------------
    Item {
        id: titleRow
        x: root.pad
        y: root.pad
        width: parent.width - 2 * root.pad
        height: 28

        Text {
            x: Theme.space8
            width: Math.max(0, todayChip.x - Theme.space8 - x)
            anchors.verticalCenter: parent.verticalCenter
            text: Qt.formatDate(root.viewMonth, "MMMM yyyy")
            font: Theme.typeLabel
            color: Theme.text
            elide: Text.ElideRight
        }
        Chip {
            id: todayChip
            anchors.right: prev.left
            anchors.rightMargin: Theme.space4
            anchors.verticalCenter: parent.verticalCenter
            text: qsTr("Today")
            opacity: root.onCurrentMonth ? 0 : 1
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durSmall) } }
            onClicked: root.reset()
        }
        IconButton {
            id: prev
            anchors.right: next.left
            anchors.verticalCenter: parent.verticalCenter
            iconName: "chevron-left"
            tooltip: qsTr("Previous month")
            size: 28
            iconSize: 16
            onClicked: root.shift(-1)
        }
        IconButton {
            id: next
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconName: "chevron-right"
            tooltip: qsTr("Next month")
            size: 28
            iconSize: 16
            onClicked: root.shift(1)
        }
    }

    // ---- weekday initials + days -----------------------------------------
    Item {
        id: grid
        x: root.pad
        y: titleRow.y + titleRow.height + Theme.space2
        width: parent.width - 2 * root.pad
        readonly property real cellW: width / 7

        Repeater {
            model: 7
            Text {
                required property int index
                x: index * grid.cellW
                width: grid.cellW
                height: 20
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: Qt.locale().dayName((root.firstDay + index) % 7, Locale.NarrowFormat)
                font: Theme.typeCaption
                color: Theme.textMuted
                opacity: 0.85
                Accessible.ignored: true
            }
        }

        Repeater {
            model: root.cells
            Item {
                id: cell
                required property var modelData
                required property int index
                readonly property bool isToday: modelData.key === root.todayKey
                x: (index % 7) * grid.cellW
                y: 20 + Math.floor(index / 7) * root.cellHeight
                width: grid.cellW
                height: root.cellHeight

                Accessible.role: Accessible.Cell
                Accessible.name: Qt.formatDate(modelData.date, "dddd d MMMM yyyy") + (isToday ? ", " + qsTr("today") : "")

                Rectangle {
                    anchors.centerIn: parent
                    width: 26
                    height: 26
                    radius: 13
                    visible: cell.isToday
                    color: Theme.accent
                    antialiasing: true
                }
                Text {
                    anchors.centerIn: parent
                    text: cell.modelData.day
                    font.family: Theme.fontUi
                    font.pixelSize: Theme.typeCaption.pixelSize
                    font.weight: cell.isToday ? Font.Bold : Font.Medium
                    font.features: { "tnum": 1 }
                    color: cell.isToday ? Theme.onAccent : cell.modelData.inMonth ? Theme.text : Theme.textMuted
                    opacity: cell.isToday || cell.modelData.inMonth ? 1 : 0.7
                }
            }
        }
    }
}
