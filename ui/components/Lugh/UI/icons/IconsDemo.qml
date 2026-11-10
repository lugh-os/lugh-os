// Visual check for Icon / AppIcon:
//   QT_QPA_PLATFORM=offscreen scripts/qml-shot.sh ui/components/Lugh/UI/icons/IconsDemo.qml /tmp/lugh-shots/icons/light.png 1200 800
//   ... /tmp/lugh-shots/icons/dark.png 1200 800 900 -- --dark
import QtQuick
import Lugh.UI

Rectangle {
    id: demo
    anchors.fill: parent
    color: Theme.bg

    Component.onCompleted: Theme.dark = Qt.application.arguments.indexOf("--dark") >= 0

    readonly property var shellIcons: [
        "wifi", "wifi-off", "wifi-low", "wifi-high", "bluetooth", "bluetooth-off",
        "volume", "volume-1", "volume-2", "volume-x", "mic", "mic-off",
        "sun", "moon", "sun-medium", "battery", "battery-low", "battery-medium",
        "battery-full", "battery-charging", "bell", "bell-off", "bell-dot", "search",
        "power", "lock", "log-out", "rotate-ccw", "settings", "chevron-right",
        "chevron-left", "chevron-down", "x", "check", "plus", "minus",
        "shield", "shield-check", "plane", "monitor", "speaker", "headphones",
        "keyboard", "play", "pause", "skip-forward", "skip-back", "calculator",
        "terminal", "file", "folder", "image", "trash-2", "download",
        "circle-alert", "info", "eye", "eye-off", "gauge", "leaf",
        "zap", "user", "calendar", "layout-grid", "app-window", "arrow-right",
        "corner-down-left", "sunset", "moon-star", "airplay"
    ]
    readonly property var apps: [
        { icon: "firefox", name: "Firefox" },
        { icon: "utilities-terminal", name: "Terminal" },
        { icon: "system-file-manager", name: "Files" },
        { icon: "vlc", name: "VLC" },
        { icon: "preferences-system", name: "Settings" },
        { icon: "org.kde.dolphin", name: "Dolphin" },
        { icon: "/usr/share/icons/hicolor/128x128/apps/firefox.png", name: "Firefox (path)" },
        { icon: "lugh-does-not-exist", name: "Lughfile" },
        { icon: "", name: "" }
    ]

    Column {
        x: 24; y: 20
        spacing: 14

        Text {
            text: "Lucide " + IconNames.version + " · " + IconNames.count + " glyphs · family \"" + IconNames.fontFamily + "\" · " + (Theme.dark ? "dark" : "light")
            font: Theme.typeTitle3
            color: Theme.text
        }

        Repeater {
            model: [ { s: 16, c: "text" }, { s: 20, c: "text" }, { s: 24, c: "text" }, { s: 20, c: "accent" } ]
            delegate: Column {
                required property var modelData
                spacing: 4
                Text {
                    text: modelData.s + " px · Theme." + modelData.c
                    font: Theme.typeCaption
                    color: Theme.textMuted
                }
                Flow {
                    width: 1152
                    spacing: modelData.s >= 24 ? 8 : 6
                    Repeater {
                        model: demo.shellIcons
                        delegate: Icon {
                            required property string modelData
                            name: modelData
                            size: parent.parent.modelData.s
                            color: parent.parent.modelData.c === "accent" ? Theme.accentText : Theme.text
                        }
                    }
                }
            }
        }

        // Alignment check: icon centered in a 32 px box next to body text.
        Row {
            spacing: 12
            Repeater {
                model: ["wifi", "bell", "search", "settings", "power", "x"]
                delegate: Row {
                    required property string modelData
                    spacing: 6
                    Rectangle {
                        width: 32; height: 32; radius: Theme.radiusSm
                        color: Theme.surface2
                        border.color: Theme.border
                        Icon { anchors.centerIn: parent; name: modelData; size: 18 }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData
                        font: Theme.typeBody
                        color: Theme.text
                    }
                }
            }
            Icon { name: "no-such-icon"; size: 20 }   // must render nothing + warn once
            Icon { name: "no-such-icon"; size: 20 }
        }

        Text { text: "AppIcon (48 / 32)"; font: Theme.typeCaption; color: Theme.textMuted }
        Row {
            spacing: 16
            Repeater {
                model: demo.apps
                delegate: Column {
                    required property var modelData
                    spacing: 6
                    width: 96
                    AppIcon {
                        anchors.horizontalCenter: parent.horizontalCenter
                        iconName: modelData.icon
                        fallbackText: modelData.name
                        size: 48
                    }
                    AppIcon {
                        anchors.horizontalCenter: parent.horizontalCenter
                        iconName: modelData.icon
                        fallbackText: modelData.name
                        size: 32
                    }
                    Text {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                        text: modelData.name || "(empty)"
                        font: Theme.typeCaption
                        color: Theme.textMuted
                    }
                }
            }
        }
    }
}
