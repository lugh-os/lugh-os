// Customize → Workspaces: the workspace grid and how navigation behaves.
import QtQuick
import QtQuick.Layouts
import Lugh.UI
import Lugh.Shell

CustomizePage {
    id: page
    key: "workspaces"
    pageTitle: qsTr("Workspaces")
    iconName: "layout-grid"

    SettingGroup {
        title: qsTr("Grid")

        SettingRow {
            title: qsTr("Layout")
            description: qsTr("Point at a cell to pick how many rows and columns of workspaces you have")
            keywords: "workspaces grid rows columns desktops virtual number count"
            stacked: true

            RowLayout {
                spacing: Theme.space20
                Layout.fillWidth: true

                WorkspaceGridPicker {
                    id: picker
                    rows: ShellSettings.workspaceRows
                    cols: ShellSettings.workspaceCols
                    onPicked: (r, c) => { ShellSettings.workspaceRows = r; ShellSettings.workspaceCols = c; }
                }
                ColumnLayout {
                    spacing: 2
                    Layout.fillWidth: true
                    Text {
                        text: qsTr("%1 × %2").arg(picker.shownRows).arg(picker.shownCols)
                        font: Theme.typeTitle2
                        color: Theme.text
                    }
                    Text {
                        text: (picker.shownRows * picker.shownCols === 1 ? qsTr("1 workspace")
                               : qsTr("%1 workspaces").arg(picker.shownRows * picker.shownCols))
                              + (picker.previewing ? " · " + qsTr("click to apply") : "")
                        font: Theme.typeCaption
                        color: Theme.textMuted
                        wrapMode: Text.Wrap
                        Layout.fillWidth: true
                    }
                }
            }
        }
    }

    SettingGroup {
        title: qsTr("Navigation")

        ToggleRow {
            title: qsTr("Wrap around")
            description: qsTr("Moving past the last workspace in a row or column returns to the first")
            keywords: "wrap navigation cycle edges loop"
            checked: ShellSettings.workspaceWrap
            onEdited: v => ShellSettings.workspaceWrap = v
        }
        ToggleRow {
            title: qsTr("Show empty workspaces in the overview")
            description: qsTr("Off shows only workspaces that have windows")
            keywords: "overview empty workspaces expose"
            checked: ShellSettings.overviewShowEmpty
            onEdited: v => ShellSettings.overviewShowEmpty = v
        }
    }

    SettingGroup {
        title: qsTr("Shortcuts")

        Repeater {
            model: [
                { keys: [qsTr("Super"), qsTr("Tab")], what: qsTr("Open the workspace overview") },
                { keys: [qsTr("Super"), qsTr("Ctrl"), "←↑↓→"], what: qsTr("Go to the neighbouring workspace") },
                { keys: [qsTr("Super"), qsTr("Ctrl"), qsTr("Shift"), "←↑↓→"], what: qsTr("Take the focused window along") },
                { keys: [qsTr("Ctrl"), "1…9"], what: qsTr("Jump to a workspace by number") }
            ]
            SettingRow {
                required property var modelData
                title: modelData.what
                keywords: "shortcut keyboard keys hotkey arrows " + modelData.keys.join(" ")
                Row {
                    spacing: 4
                    Accessible.role: Accessible.StaticText
                    Accessible.name: modelData.keys.join(" + ")
                    Repeater {
                        model: modelData.keys
                        Rectangle {
                            required property string modelData
                            width: Math.max(26, cap.implicitWidth + 12)
                            height: 24
                            radius: Theme.radiusSm
                            color: Theme.hoverOverlay
                            border.width: 1
                            border.color: Theme.border
                            Text {
                                id: cap
                                anchors.centerIn: parent
                                text: modelData
                                font: Theme.typeCaption
                                color: Theme.text
                            }
                        }
                    }
                }
            }
        }
    }
}
