// Month calendar card for the notification center: month title, previous /
// next month, a "Today" shortcut when away from the current month, weekday
// initials (locale's first day of week) and a fixed 6-row day grid with
// tabular numerals. Today is an accent-filled circle with bold Theme.onAccent
// numerals (not color alone). Read-only: days are not interactive.
// Internal to notifications/ (not exported in the qmldir).
import QtQuick
import QtQuick.Layouts
import Lugh.UI
import Lugh.Shell

Rectangle {
    id: root

    property date today: Services.clock.now
    property color fill: "transparent"
    // First day of the month shown.
    property date viewMonth: new Date(today.getFullYear(), today.getMonth(), 1)
    readonly property bool onCurrentMonth: viewMonth.getFullYear() === today.getFullYear()
                                           && viewMonth.getMonth() === today.getMonth()
    readonly property int firstDay: Qt.locale().firstDayOfWeek % 7   // 0 = Sunday

    function reset() { viewMonth = new Date(today.getFullYear(), today.getMonth(), 1); }
    function shift(months) { viewMonth = new Date(viewMonth.getFullYear(), viewMonth.getMonth() + months, 1); }

    // 42 dates starting on the week that holds the 1st.
    readonly property var cells: {
        const first = new Date(viewMonth.getFullYear(), viewMonth.getMonth(), 1);
        const lead = (first.getDay() - firstDay + 7) % 7;
        const out = [];
        for (let i = 0; i < 42; ++i)
            out.push(new Date(first.getFullYear(), first.getMonth(), 1 - lead + i));
        return out;
    }

    implicitHeight: col.implicitHeight + 2 * Theme.space12
    radius: Theme.radiusMd
    color: fill
    border.width: 1
    border.color: Theme.glassBorder

    Accessible.role: Accessible.Table
    Accessible.name: Qt.formatDate(viewMonth, "MMMM yyyy")

    ColumnLayout {
        id: col
        x: Theme.space12
        y: Theme.space12
        width: parent.width - 2 * Theme.space12
        spacing: Theme.space4

        RowLayout {
            Layout.fillWidth: true
            Layout.bottomMargin: Theme.space4
            spacing: Theme.space4

            Text {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space4
                text: Qt.formatDate(root.viewMonth, "MMMM yyyy")
                font: Theme.typeBodyStrong
                color: Theme.text
                elide: Text.ElideRight
            }
            Button {
                visible: !root.onCurrentMonth
                text: qsTr("Today")
                size: "sm"
                variant: "ghost"
                onClicked: root.reset()
            }
            IconButton {
                iconName: "chevron-left"
                tooltip: qsTr("Previous month")
                size: 28
                iconSize: 16
                onClicked: root.shift(-1)
            }
            IconButton {
                iconName: "chevron-right"
                tooltip: qsTr("Next month")
                size: 28
                iconSize: 16
                onClicked: root.shift(1)
            }
        }

        Grid {
            id: grid
            Layout.fillWidth: true
            columns: 7
            readonly property real cellW: width / 7

            Repeater {
                model: 7
                Text {
                    required property int index
                    width: grid.cellW
                    height: 22
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: Qt.locale().dayName((root.firstDay + index) % 7, Locale.NarrowFormat)
                    font: Theme.typeCaption
                    color: Theme.textMuted
                    Accessible.ignored: true
                }
            }

            Repeater {
                model: root.cells
                Item {
                    id: cell
                    required property var modelData
                    readonly property bool inMonth: modelData.getMonth() === root.viewMonth.getMonth()
                    readonly property bool isToday: modelData.getFullYear() === root.today.getFullYear()
                                                    && modelData.getMonth() === root.today.getMonth()
                                                    && modelData.getDate() === root.today.getDate()
                    width: grid.cellW
                    height: 30

                    Accessible.role: Accessible.Cell
                    Accessible.name: Qt.formatDate(modelData, "dddd d MMMM yyyy") + (isToday ? ", " + qsTr("today") : "")

                    Rectangle {
                        anchors.centerIn: parent
                        width: 28
                        height: 28
                        radius: 14
                        visible: cell.isToday
                        color: Theme.accent
                    }
                    Text {
                        anchors.centerIn: parent
                        text: cell.modelData.getDate()
                        font.family: Theme.fontUi
                        font.pixelSize: 13
                        font.weight: cell.isToday ? Font.Bold : Font.Normal
                        font.features: { "tnum": 1 }
                        color: cell.isToday ? Theme.onAccent : cell.inMonth ? Theme.text : Theme.textMuted
                    }
                }
            }
        }
    }
}
