// Customize → Quick panel: the clock/calendar/controls panel opened from the
// tray — which sections it has and which toggle tiles, in what order.
import QtQuick
import QtQuick.Layouts
import Lugh.UI
import Lugh.Shell
import "util.js" as U

CustomizePage {
    id: page
    key: "quick"
    pageTitle: qsTr("Quick panel")
    iconName: "toggle-right"

    SettingGroup {
        title: qsTr("Sections")
        footnote: qsTr("Open the quick panel by clicking the clock in the tray.")

        ToggleRow {
            title: qsTr("Calendar")
            description: qsTr("The month, under the clock")
            iconName: "calendar"
            keywords: "calendar month date"
            checked: ShellSettings.quickShowCalendar
            onEdited: v => ShellSettings.quickShowCalendar = v
        }
        ToggleRow {
            title: qsTr("Fold calendar")
            description: qsTr("Show only the current week; the month unfolds on click")
            iconName: "fold-vertical"
            keywords: "calendar fold collapse week compact month"
            enabled: ShellSettings.quickShowCalendar
            disabledReason: qsTr("Show the calendar first")
            checked: ShellSettings.quickCalendarFolded
            onEdited: v => ShellSettings.quickCalendarFolded = v
        }
        ToggleRow {
            title: qsTr("Sliders")
            description: qsTr("Volume and brightness")
            iconName: "sliders-horizontal"
            keywords: "sliders volume brightness"
            checked: ShellSettings.quickShowSliders
            onEdited: v => ShellSettings.quickShowSliders = v
        }
        ToggleRow {
            title: qsTr("Media")
            description: qsTr("What's playing, with playback controls")
            iconName: "music"
            keywords: "media player music now playing"
            checked: ShellSettings.quickShowMedia
            onEdited: v => ShellSettings.quickShowMedia = v
        }
        ToggleRow {
            title: qsTr("Notifications")
            description: qsTr("Recent notifications at the bottom of the panel")
            iconName: "bell"
            keywords: "notifications alerts messages"
            checked: ShellSettings.quickShowNotifications
            onEdited: v => ShellSettings.quickShowNotifications = v
        }
    }

    SettingGroup {
        title: qsTr("Quick toggles")

        SettingRow {
            title: qsTr("Toggles")
            description: qsTr("The tiles at the top of the quick panel, in this order")
            keywords: "quick toggles tiles order wifi bluetooth do not disturb night light airplane power profile dark keep awake caffeine"
            stacked: true

            OrderedList {
                Layout.fillWidth: true
                items: ShellSettings.quickToggles
                catalog: U.quickToggles
                allIds: U.quickToggleIds
                emptyText: qsTr("No quick toggles. Add some below.")
                addLabel: qsTr("Add a toggle")
                onEdited: a => ShellSettings.quickToggles = a
            }
        }
    }
}
