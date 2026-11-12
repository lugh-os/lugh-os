// Customize → Panel: the bottom taskbar, with a live preview on top.
import QtQuick
import QtQuick.Layouts
import Lugh.UI
import Lugh.Shell

CustomizePage {
    id: page
    key: "panel"
    pageTitle: qsTr("Panel")
    iconName: "panel-bottom"

    PanelPreview { Layout.fillWidth: true }

    SettingGroup {
        title: qsTr("Layout")

        ChoiceRow {
            title: qsTr("Style")
            description: qsTr("A floating pill, or a strip along the screen edge")
            keywords: "floating edge strip dock taskbar margin"
            value: ShellSettings.panelFloating
            options: [{ text: qsTr("Floating"), value: true },
                      { text: qsTr("Edge to edge"), value: false }]
            onEdited: v => ShellSettings.panelFloating = v
        }
        ChoiceRow {
            title: qsTr("App alignment")
            description: qsTr("Where the app icons sit")
            keywords: "align center left position taskbar icons"
            value: ShellSettings.panelAlignment
            options: [{ text: qsTr("Center"), iconName: "align-center", value: "center" },
                      { text: qsTr("Left"), iconName: "align-left", value: "left" }]
            onEdited: v => ShellSettings.panelAlignment = v
        }
        SliderRow {
            title: qsTr("Height")
            description: qsTr("Thickness of the panel")
            keywords: "size height thickness"
            from: 40; to: 64; stepSize: 2
            value: ShellSettings.panelHeight
            valueText: Math.round(value) + " px"
            onEdited: v => ShellSettings.panelHeight = Math.round(v)
        }
        SliderRow {
            title: qsTr("Icon size")
            description: qsTr("Size of the app icons")
            keywords: "icons size scale apps"
            from: 24; to: 44; stepSize: 2
            value: ShellSettings.panelIconSize
            valueText: Math.round(value) + " px"
            onEdited: v => ShellSettings.panelIconSize = Math.round(v)
        }
    }

    SettingGroup {
        title: qsTr("Buttons")

        ToggleRow {
            title: qsTr("Start button")
            description: qsTr("The Lugh button that opens the menu and the launcher")
            keywords: "start lugh logo menu launcher button"
            checked: ShellSettings.panelShowStart
            onEdited: v => ShellSettings.panelShowStart = v
        }
        ToggleRow {
            title: qsTr("Search button")
            description: qsTr("Opens search next to the start button. Super+Space works either way")
            keywords: "search find launcher button"
            checked: ShellSettings.panelShowSearch
            onEdited: v => ShellSettings.panelShowSearch = v
        }
        ToggleRow {
            title: qsTr("Workspace indicator")
            description: qsTr("A small map of your workspaces; click it for the overview")
            keywords: "workspaces desktops virtual indicator grid pager"
            checked: ShellSettings.panelShowWorkspaces
            onEdited: v => ShellSettings.panelShowWorkspaces = v
        }
    }

    SettingGroup {
        title: qsTr("Behavior")

        ToggleRow {
            title: qsTr("Auto-hide")
            description: qsTr("Slide the panel away until the pointer reaches the bottom edge")
            keywords: "autohide hide reveal dodge"
            checked: ShellSettings.panelAutohide
            onEdited: v => ShellSettings.panelAutohide = v
        }
        ToggleRow {
            title: qsTr("Magnify on hover")
            description: qsTr("App icons grow under the pointer, dock-style")
            keywords: "magnify zoom hover dock grow"
            checked: ShellSettings.panelMagnify
            onEdited: v => ShellSettings.panelMagnify = v
        }
        ToggleRow {
            title: qsTr("Running indicator")
            description: qsTr("A dot under apps with open windows; a bar under the focused one")
            keywords: "running open dot indicator active"
            checked: ShellSettings.panelShowRunningIndicator
            onEdited: v => ShellSettings.panelShowRunningIndicator = v
        }
    }
}
