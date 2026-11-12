// Customize → Clock & tray: clock format and which status items the tray shows.
import QtQuick
import QtQuick.Layouts
import Lugh.UI
import Lugh.Shell
import "util.js" as U

CustomizePage {
    id: page
    key: "clock"
    pageTitle: qsTr("Clock & tray")
    iconName: "clock"

    property date now: new Date()
    Timer {
        interval: 1000
        repeat: true
        running: page.visible
        onTriggered: page.now = new Date()
    }
    readonly property string sample: U.timeText(now, ShellSettings.clock24h, ShellSettings.clockShowSeconds)
        + (ShellSettings.clockShowDate ? " · " + Qt.formatDate(now, ShellSettings.clockDateFormat) : "")

    SettingGroup {
        title: qsTr("Clock")

        SettingRow {
            title: qsTr("Preview")
            description: qsTr("How the clock reads in the tray")
            keywords: "clock time sample preview"
            Rectangle {
                implicitWidth: sampleText.implicitWidth + 2 * Theme.space12
                implicitHeight: 32
                radius: 16
                color: Theme.hoverOverlay
                border.width: 1
                border.color: Theme.glassBorder
                Text {
                    id: sampleText
                    anchors.centerIn: parent
                    text: page.sample
                    font: Theme.typeLabelTnum
                    color: Theme.text
                }
                Accessible.role: Accessible.StaticText
                Accessible.name: page.sample
            }
        }
        ToggleRow {
            title: qsTr("24-hour time")
            description: qsTr("14:30 instead of 2:30 PM")
            keywords: "24h 12h am pm military hour format"
            checked: ShellSettings.clock24h
            onEdited: v => ShellSettings.clock24h = v
        }
        ToggleRow {
            title: qsTr("Show seconds")
            keywords: "seconds clock"
            checked: ShellSettings.clockShowSeconds
            onEdited: v => ShellSettings.clockShowSeconds = v
        }
        ToggleRow {
            title: qsTr("Show date")
            description: qsTr("The date next to the time")
            keywords: "date day calendar"
            checked: ShellSettings.clockShowDate
            onEdited: v => ShellSettings.clockShowDate = v
        }
        SettingRow {
            title: qsTr("Date format")
            description: qsTr("How the date is written")
            keywords: "date format day month year iso"
            stacked: true
            enabled: ShellSettings.clockShowDate

            Flow {
                Layout.fillWidth: true
                spacing: Theme.space8
                Repeater {
                    model: ["ddd d MMM", "d/M/yyyy", "yyyy-MM-dd", "MMM d"]
                    Chip {
                        required property string modelData
                        text: Qt.formatDate(page.now, modelData)
                        selected: ShellSettings.clockDateFormat === modelData
                        accessibleName: qsTr("Date format %1").arg(text)
                        onClicked: ShellSettings.clockDateFormat = modelData
                    }
                }
            }
        }
    }

    SettingGroup {
        title: qsTr("Tray")
        footnote: qsTr("Hidden items stay in the quick panel, one click on the clock away.")

        ToggleRow {
            title: qsTr("Network")
            keywords: "wifi wi-fi network ethernet internet tray"
            checked: ShellSettings.trayShowNetwork
            onEdited: v => ShellSettings.trayShowNetwork = v
            iconName: "wifi"
        }
        ToggleRow {
            title: qsTr("Bluetooth")
            keywords: "bluetooth tray"
            checked: ShellSettings.trayShowBluetooth
            onEdited: v => ShellSettings.trayShowBluetooth = v
            iconName: "bluetooth"
        }
        ToggleRow {
            title: qsTr("Volume")
            keywords: "volume sound audio speaker tray"
            checked: ShellSettings.trayShowVolume
            onEdited: v => ShellSettings.trayShowVolume = v
            iconName: "volume-2"
        }
        ToggleRow {
            title: qsTr("Battery")
            keywords: "battery power charge tray"
            checked: ShellSettings.trayShowBattery
            onEdited: v => ShellSettings.trayShowBattery = v
            iconName: "battery-medium"
        }
        ToggleRow {
            title: qsTr("Battery percentage")
            description: qsTr("The charge as a number next to the battery icon")
            keywords: "battery percent percentage number charge"
            enabled: ShellSettings.trayShowBattery
            disabledReason: qsTr("Show the battery first")
            checked: ShellSettings.showBatteryPercent
            onEdited: v => ShellSettings.showBatteryPercent = v
        }
        ToggleRow {
            title: qsTr("Keyboard layout")
            description: qsTr("The current layout, like EN or FR; click it to switch")
            keywords: "keyboard layout language input tray"
            checked: ShellSettings.trayShowKeyboard
            onEdited: v => ShellSettings.trayShowKeyboard = v
            iconName: "keyboard"
        }
        ToggleRow {
            title: qsTr("Media")
            description: qsTr("A play/pause control while something plays")
            keywords: "media music player playing tray"
            checked: ShellSettings.trayShowMedia
            onEdited: v => ShellSettings.trayShowMedia = v
            iconName: "music"
        }
    }
}
