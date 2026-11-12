// Live mini preview of the bottom panel, drawn from ShellSettings: height,
// floating pill vs. edge strip, corner radius, alignment, icon size, which
// buttons and tray items show, running dots, magnify and the clock format.
// A mock built from Rectangles/Icons/Text at 0.62 scale over the current
// wallpaper — not the real Panel. Hidden while the panel is searching.
// Corners follow the card on both renderers without a rounded clip: the
// wallpaper is a RoundedImage, the window sits inside the card, and the edge
// strip rounds its own bottom corners to the card's radius.
import QtQuick
import Lugh.UI
import Lugh.Shell
import "util.js" as U

Rectangle {
    id: root

    readonly property Item _ctx: U.ancestor(root.parent, "customizeQuery")
    readonly property real s: 0.62           // logical px → preview px
    property date now: new Date()

    visible: !_ctx || _ctx.customizeQuery === ""
    implicitHeight: 168
    radius: Theme.radiusMd + 2
    color: Theme.surface3
    Accessible.role: Accessible.Graphic
    Accessible.name: qsTr("Panel preview")

    Timer {
        interval: 1000
        repeat: true
        running: root.visible && root.Window.window !== null && root.Window.window.visible
        onTriggered: root.now = new Date()
    }

    Item {
        id: scene
        anchors.fill: parent
        clip: true

        // ---- the desktop behind -------------------------------------------------
        // The bundled art from the resolved dir (the frame sets wallpaperDir
        // to the repo's branding/wallpapers/ in the dev tree), or the user's
        // own picture.
        RoundedImage {
            id: wall
            anchors.fill: parent
            radius: root.radius
            sourceSize: Qt.size(640, 400)
            source: {
                const v = Theme.dark ? Services.appearance.wallpaperDark : Services.appearance.wallpaperLight;
                const variant = "-" + (Theme.dark ? "dark" : "light") + "-2560x1600.jpg";
                const dir = Services.appearance.wallpaperDir || "file:///usr/share/backgrounds/lugh/";
                if (!v || v === "")
                    return dir + "dawn" + variant;
                if (v.startsWith("lugh://wallpapers/"))
                    return dir + v.slice(18) + variant;
                return v.startsWith("/") ? "file://" + v : v;
            }
        }
        // a window, so the floating margin and the strip read as such
        Rectangle {
            x: parent.width * 0.16
            y: 40
            width: parent.width * 0.5
            height: parent.height - y - (ShellSettings.panelHeight + (ShellSettings.panelFloating ? 8 : 0) + 10) * root.s
            radius: ShellSettings.cornerRadius * root.s
            color: Theme.surface
            opacity: 0.9
            border.width: 1
            border.color: Theme.glassBorder
            Row {
                x: 8; y: 7
                spacing: 4
                Repeater {
                    model: 3
                    Rectangle { width: 6; height: 6; radius: 3; color: Theme.surface3 }
                }
            }
        }

        // ---- the panel at logical size, scaled ------------------------------------
        Item {
            id: stage
            width: root.width / root.s
            height: root.height / root.s
            scale: root.s
            transformOrigin: Item.TopLeft

            readonly property bool floating: ShellSettings.panelFloating
            readonly property int margin: floating ? 8 : 0
            readonly property int h: ShellSettings.panelHeight
            readonly property int icon: ShellSettings.panelIconSize
            readonly property int btn: Math.min(h - 8, 40)

            Rectangle {
                id: panel
                x: stage.margin
                width: stage.width - 2 * stage.margin
                height: stage.h
                y: stage.height - height - stage.margin
                radius: stage.floating ? Math.min(ShellSettings.cornerRadius + 6, height / 2) : 0
                // edge to edge: the strip's bottom corners follow the card
                bottomLeftRadius: stage.floating ? radius : root.radius / root.s
                bottomRightRadius: stage.floating ? radius : root.radius / root.s
                color: Theme.glass
                border.width: 1
                border.color: Theme.glassBorder
                opacity: ShellSettings.panelAutohide ? 0.55 : 1
                Behavior on height { enabled: !Theme.reduceMotion; NumberAnimation { duration: Theme.durSmall } }
                Behavior on radius { NumberAnimation { duration: Theme.durSmall } }

                // left: start, search, workspaces
                Row {
                    id: left
                    x: Math.max(10, (panel.height - stage.btn) / 2 + 2)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6

                    Rectangle {
                        visible: ShellSettings.panelShowStart
                        width: stage.btn; height: stage.btn
                        radius: stage.btn / 2.6
                        color: Theme.hoverOverlay
                        Image {
                            anchors.centerIn: parent
                            width: stage.btn * 0.62; height: width
                            sourceSize.width: 48; sourceSize.height: 48
                            source: Theme.dark ? "../bar/assets/lugh-logo-dark.svg" : "../bar/assets/lugh-logo.svg"
                        }
                    }
                    Rectangle {
                        visible: ShellSettings.panelShowSearch
                        width: stage.btn; height: stage.btn
                        radius: stage.btn / 2.6
                        color: Theme.hoverOverlay
                        Icon { anchors.centerIn: parent; name: "search"; size: stage.btn * 0.5; color: Theme.text }
                    }
                    // workspace grid indicator: rows × cols cells, the first active
                    Rectangle {
                        visible: ShellSettings.panelShowWorkspaces
                        width: wsGrid.width + 14; height: stage.btn
                        radius: stage.btn / 2.6
                        color: Theme.hoverOverlay
                        Grid {
                            id: wsGrid
                            anchors.centerIn: parent
                            rows: ShellSettings.workspaceRows
                            columns: ShellSettings.workspaceCols
                            spacing: 3
                            readonly property real cell: Math.min(10, (stage.btn - 14 - (rows - 1) * 3) / rows)
                            Repeater {
                                model: ShellSettings.workspaceCount
                                Rectangle {
                                    required property int index
                                    width: wsGrid.cell * 1.4; height: wsGrid.cell
                                    radius: 2
                                    color: index === 0 ? Theme.accent : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.28)
                                }
                            }
                        }
                    }
                }

                // apps
                Row {
                    id: apps
                    spacing: Math.round(stage.icon * 0.3)
                    anchors.verticalCenter: parent.verticalCenter
                    x: ShellSettings.panelAlignment === "left"
                       ? left.x + (left.width > 0 ? left.width + 14 : 0)
                       : Math.round((panel.width - width) / 2)
                    Behavior on x { enabled: !Theme.reduceMotion; NumberAnimation { duration: Theme.durSmall; easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard } }

                    Repeater {
                        model: [
                            { icon: "firefox", name: "Firefox", running: true, active: true },
                            { icon: "system-file-manager", name: qsTr("Files"), running: true, active: false },
                            { icon: "utilities-terminal", name: qsTr("Terminal"), running: false, active: false },
                            { icon: "vlc", name: "VLC", running: true, active: false },
                            { icon: "accessories-text-editor", name: qsTr("Text Editor"), running: false, active: false },
                            { icon: "preferences-system", name: qsTr("Settings"), running: false, active: false }
                        ]
                        Item {
                            required property var modelData
                            required property int index
                            readonly property bool big: ShellSettings.panelMagnify && index === 1
                            width: stage.icon
                            height: panel.height
                            AppIcon {
                                anchors.centerIn: parent
                                anchors.verticalCenterOffset: parent.big ? -stage.icon * 0.2 : 0
                                size: stage.icon
                                scale: parent.big ? 1.35 : 1
                                iconName: modelData.icon
                                fallbackText: modelData.name
                                Behavior on scale { enabled: !Theme.reduceMotion; NumberAnimation { duration: Theme.durSmall } }
                            }
                            Rectangle {
                                visible: ShellSettings.panelShowRunningIndicator && modelData.running
                                anchors.horizontalCenter: parent.horizontalCenter
                                y: parent.height - height - Math.max(2, (panel.height - stage.icon) / 2 - 7)
                                width: modelData.active ? 12 : 4
                                height: 4
                                radius: 2
                                color: modelData.active ? Theme.accent : Theme.textMuted
                            }
                            Icon {
                                visible: parent.big
                                x: parent.width * 0.62
                                y: parent.height * 0.5
                                name: "mouse-pointer-2"
                                size: 18
                                color: Theme.text
                            }
                        }
                    }
                }

                // tray: status icons + clock
                Row {
                    id: tray
                    anchors.right: parent.right
                    anchors.rightMargin: Math.max(12, (panel.height - stage.btn) / 2 + 4)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 12

                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 10
                        Icon { visible: ShellSettings.trayShowMedia; name: "music"; size: 18; color: Theme.text; anchors.verticalCenter: parent.verticalCenter }
                        Text { visible: ShellSettings.trayShowKeyboard; text: "EN"; font: Theme.typeLabel; color: Theme.text; anchors.verticalCenter: parent.verticalCenter }
                        Icon { visible: ShellSettings.trayShowNetwork; name: "wifi"; size: 18; color: Theme.text; anchors.verticalCenter: parent.verticalCenter }
                        Icon { visible: ShellSettings.trayShowBluetooth; name: "bluetooth"; size: 18; color: Theme.text; anchors.verticalCenter: parent.verticalCenter }
                        Icon { visible: ShellSettings.trayShowVolume; name: "volume-2"; size: 18; color: Theme.text; anchors.verticalCenter: parent.verticalCenter }
                        Row {
                            visible: ShellSettings.trayShowBattery
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 3
                            Icon { name: "battery-medium"; size: 18; color: Theme.text; anchors.verticalCenter: parent.verticalCenter }
                            Text {
                                visible: ShellSettings.showBatteryPercent
                                text: qsTr("%1%").arg(76)
                                font: Theme.typeLabelTnum
                                color: Theme.text
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                    }

                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        readonly property bool twoLines: ShellSettings.clockShowDate && panel.height >= 44
                        Text {
                            anchors.right: parent.right
                            text: U.timeText(root.now, ShellSettings.clock24h, ShellSettings.clockShowSeconds)
                                  + (ShellSettings.clockShowDate && !parent.twoLines
                                     ? "  " + Qt.formatDate(root.now, ShellSettings.clockDateFormat) : "")
                            font: Theme.typeLabelTnum
                            color: Theme.text
                        }
                        Text {
                            visible: parent.twoLines
                            anchors.right: parent.right
                            text: Qt.formatDate(root.now, ShellSettings.clockDateFormat)
                            font: Theme.typeCaptionTnum
                            color: Theme.textMuted
                        }
                    }
                }
            }
        }
    }

    // ---- labels (unscaled) -------------------------------------------------------
    Row {
        x: Theme.space8
        y: Theme.space8
        spacing: Theme.space4
        Repeater {
            model: [qsTr("Live preview")].concat(ShellSettings.panelAutohide ? [qsTr("Auto-hides")] : [])
            Rectangle {
                required property string modelData
                width: tag.implicitWidth + 2 * Theme.space8
                height: 22
                radius: 11
                color: Theme.glass
                border.width: 1
                border.color: Theme.glassBorder
                Text {
                    id: tag
                    anchors.centerIn: parent
                    text: modelData
                    font: Theme.typeCaption
                    color: Theme.text
                }
            }
        }
    }

    // hairline over the wallpaper edge
    Rectangle {
        anchors.fill: parent
        radius: parent.radius
        color: "transparent"
        border.width: 1
        border.color: Theme.glassBorder
    }
}
