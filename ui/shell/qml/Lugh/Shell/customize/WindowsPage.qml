// Customize → Windows: title-bar buttons (which, in what order) and density.
import QtQuick
import QtQuick.Layouts
import Lugh.UI
import Lugh.Shell
import "util.js" as U

CustomizePage {
    id: page
    key: "windows"
    pageTitle: qsTr("Windows")
    iconName: "app-window"

    readonly property var buttons: ShellSettings.titlebarButtons.split(",")
        .map(s => s.trim()).filter(s => U.titlebarButtons[s] !== undefined)

    SettingGroup {
        title: qsTr("Title bars")

        SettingRow {
            title: qsTr("Preview")
            keywords: "title bar titlebar preview window buttons"
            stacked: true

            // mock window top: title on the left, the buttons in order on the right
            Rectangle {
                id: mock
                Layout.fillWidth: true
                Layout.maximumWidth: 420
                implicitHeight: bar.height + 36
                radius: ShellSettings.cornerRadius
                color: Theme.surface
                border.width: 1
                border.color: Theme.border
                Accessible.role: Accessible.Graphic
                Accessible.name: qsTr("Title bar preview: %1").arg(page.buttons.map(b => U.name(U.titlebarButtons, b)).join(", "))

                Rectangle {
                    id: bar
                    width: parent.width
                    height: ShellSettings.titlebarCompact ? 32 : 42
                    radius: parent.radius
                    color: Theme.surface2
                    Behavior on height { enabled: !Theme.reduceMotion; NumberAnimation { duration: Theme.durSmall } }
                    Rectangle {     // square off the bottom corners
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: parent.radius
                        color: parent.color
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        x: Theme.space12
                        width: parent.width - btns.width - 3 * Theme.space12
                        text: qsTr("Files — Home")
                        font: ShellSettings.titlebarCompact ? Theme.typeLabel : Theme.typeBodyStrong
                        color: Theme.text
                        elide: Text.ElideRight
                    }
                    Row {
                        id: btns
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.space8
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: ShellSettings.titlebarCompact ? 4 : 6
                        Repeater {
                            model: page.buttons
                            Rectangle {
                                required property string modelData
                                readonly property int d: ShellSettings.titlebarCompact ? 22 : 28
                                width: d; height: d; radius: d / 2
                                color: modelData === "close" ? Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.16)
                                                             : Theme.hoverOverlay
                                Icon {
                                    anchors.centerIn: parent
                                    name: U.titlebarButtons[modelData].icon
                                    size: ShellSettings.titlebarCompact ? 12 : 14
                                    color: modelData === "close" ? Theme.danger : Theme.text
                                }
                            }
                        }
                    }
                }
                Column {
                    x: Theme.space12
                    anchors.top: bar.bottom
                    anchors.topMargin: Theme.space12
                    spacing: 6
                    Rectangle { width: mock.width * 0.4; height: 6; radius: 3; color: Theme.surface3 }
                    Rectangle { width: mock.width * 0.25; height: 6; radius: 3; color: Theme.surface3 }
                }
            }
        }

        SettingRow {
            title: qsTr("Buttons")
            description: qsTr("Shown at the right end of every title bar, left to right in this order")
            keywords: "title bar titlebar buttons minimize maximize close order"
            stacked: true

            OrderedList {
                Layout.fillWidth: true
                items: page.buttons
                catalog: U.titlebarButtons
                allIds: U.titlebarButtonIds
                locked: ["close"]
                lockedReason: qsTr("Every window keeps its close button")
                addLabel: qsTr("Add a button")
                onEdited: a => ShellSettings.titlebarButtons = a.join(",")
            }
        }

        ToggleRow {
            title: qsTr("Compact title bars")
            description: qsTr("Thinner title bars with smaller buttons, more room for content")
            keywords: "compact thin dense title bar titlebar height"
            checked: ShellSettings.titlebarCompact
            onEdited: v => ShellSettings.titlebarCompact = v
        }
    }
}
