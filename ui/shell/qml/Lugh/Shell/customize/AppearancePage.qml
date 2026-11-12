// Customize → Appearance: style, accent, glass, corner radius, wallpaper.
import QtQuick
import QtQuick.Layouts
import QtQuick.Templates as T
import Lugh.UI
import Lugh.Shell

CustomizePage {
    id: page
    key: "appearance"
    pageTitle: qsTr("Appearance")
    iconName: "palette"

    // Readable accent names (Theme.accentNames ids).
    readonly property var accentTitles: ({
        amber: qsTr("Amber"), teal: qsTr("Teal"), green: qsTr("Green"),
        blue: qsTr("Blue"), red: qsTr("Red"), graphite: qsTr("Graphite")
    })
    // Bundled art: the frame points wallpaperDir at the repo's
    // branding/wallpapers/ in the dev tree, so no missing path is requested.
    readonly property string wallpaperDir: Services.appearance.wallpaperDir || "file:///usr/share/backgrounds/lugh/"

    SettingGroup {
        title: qsTr("Style")

        ChoiceRow {
            title: qsTr("Style")
            description: qsTr("Light or dark surfaces across the shell")
            keywords: "theme dark light mode night"
            value: ShellSettings.dark
            options: [{ text: qsTr("Light"), iconName: "sun", value: false },
                      { text: qsTr("Dark"), iconName: "moon", value: true }]
            onEdited: v => ShellSettings.dark = v
        }

        SettingRow {
            id: accentRow
            title: qsTr("Accent color")
            description: qsTr("Toggles, highlights and focus rings")
            keywords: "color colour accent highlight amber teal green blue red graphite"

            Row {
                spacing: Theme.space4
                Repeater {
                    id: swatches
                    model: Theme.accentNames
                    T.AbstractButton {
                        id: sw
                        required property string modelData
                        required property int index
                        readonly property bool sel: ShellSettings.accent === modelData
                        width: 32; height: 32
                        focusPolicy: Qt.StrongFocus
                        hoverEnabled: true
                        text: page.accentTitles[modelData] || modelData
                        Accessible.role: Accessible.RadioButton
                        Accessible.name: qsTr("%1 accent").arg(text)
                        Accessible.checkable: true
                        Accessible.checked: sel
                        onClicked: ShellSettings.accent = modelData
                        // arrows move and pick within the swatches
                        function step(d) {
                            const it = swatches.itemAt(index + d);
                            if (!it) return;
                            it.forceActiveFocus(Qt.TabFocusReason);
                            ShellSettings.accent = it.modelData;
                        }
                        Keys.onLeftPressed: step(-1)
                        Keys.onRightPressed: step(1)

                        background: Item {
                            // selected: a ring around the swatch + check (not color alone)
                            Rectangle {
                                anchors.fill: parent
                                radius: width / 2
                                color: "transparent"
                                border.width: 2
                                border.color: Theme.accentSwatch(sw.modelData)
                                opacity: sw.sel ? 1 : sw.hovered ? 0.35 : 0
                                Behavior on opacity { NumberAnimation { duration: Theme.durMicro } }
                            }
                            Rectangle {
                                anchors.centerIn: parent
                                width: 22; height: 22
                                radius: 11
                                color: Theme.accentSwatch(sw.modelData)
                                border.width: 1
                                border.color: Qt.rgba(0, 0, 0, 0.12)
                                scale: sw.down && !Theme.reduceMotion ? 0.9 : 1
                                Behavior on scale { NumberAnimation { duration: Theme.durMicro } }
                                Icon {
                                    anchors.centerIn: parent
                                    visible: sw.sel
                                    name: "check"
                                    size: 14
                                    // the swatch's own on-accent color (Theme._accents)
                                    color: Theme.dark ? Theme.bg : sw.modelData === "amber" ? Theme.text : Theme.surface
                                }
                            }
                            FocusRing { show: sw.visualFocus; radius: width / 2 + Theme.focusRingOffset }
                        }
                        Tooltip { text: sw.text; visible: sw.hovered }
                    }
                }
            }
        }
    }

    SettingGroup {
        title: qsTr("Surfaces")

        ToggleRow {
            title: qsTr("Transparency")
            description: qsTr("Frosted glass behind the panel, menus and overlays. Off uses solid surfaces")
            keywords: "glass blur translucent opaque transparency"
            checked: ShellSettings.transparency
            onEdited: v => ShellSettings.transparency = v
        }

        SliderRow {
            title: qsTr("Corner radius")
            description: qsTr("Roundness of shell panels and windows")
            keywords: "corners rounded radius shape"
            from: 8; to: 22; stepSize: 1
            value: ShellSettings.cornerRadius
            valueText: Math.round(value) + " px"
            onEdited: v => ShellSettings.cornerRadius = Math.round(v)

            Rectangle {     // live sample of the radius
                width: 36; height: 28
                radius: ShellSettings.cornerRadius * 0.6
                color: Theme.selectedBg
                border.width: 1
                border.color: Theme.accent
                Accessible.ignored: true
            }
        }
    }

    SettingGroup {
        title: qsTr("Wallpaper")

        SettingRow {
            title: qsTr("Wallpaper")
            description: qsTr("Each picture has a light and a dark version that follows the style")
            keywords: "background wallpaper picture desktop dawn tide ember"
            stacked: true

            Flow {
                Layout.fillWidth: true
                spacing: Theme.space12
                Repeater {
                    // branding/wallpapers/wallpapers.json
                    model: [{ name: "dawn", title: qsTr("Dawn") },
                            { name: "tide", title: qsTr("Tide") },
                            { name: "ember", title: qsTr("Ember") }]
                    T.AbstractButton {
                        id: wp
                        required property var modelData
                        readonly property string uri: "lugh://wallpapers/" + modelData.name
                        readonly property bool sel: {
                            const cur = (Theme.dark ? Services.appearance.wallpaperDark : Services.appearance.wallpaperLight)
                                        || "lugh://wallpapers/dawn";
                            return cur === uri;
                        }
                        width: 136; height: 112
                        focusPolicy: Qt.StrongFocus
                        hoverEnabled: true
                        text: modelData.title
                        Accessible.role: Accessible.RadioButton
                        Accessible.name: qsTr("%1 wallpaper").arg(text)
                        Accessible.checkable: true
                        Accessible.checked: sel
                        onClicked: Services.appearance.setWallpaper(uri, uri)

                        contentItem: Column {
                            spacing: 6
                            Rectangle {
                                width: wp.width; height: 84
                                radius: Theme.radiusMd
                                color: Theme.surface3
                                border.width: wp.sel ? 2 : 1
                                border.color: wp.sel ? Theme.accent : Theme.glassBorder
                                RoundedImage {
                                    id: thumb
                                    anchors.fill: parent
                                    anchors.margins: wp.sel ? 4 : 1
                                    radius: parent.radius - anchors.margins
                                    sourceSize: Qt.size(272, 170)
                                    source: page.wallpaperDir + wp.modelData.name + "-" + (Theme.dark ? "dark" : "light") + "-2560x1600.jpg"
                                    opacity: wp.down ? 0.85 : 1
                                }
                                Rectangle {
                                    visible: wp.sel
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    anchors.margins: 8
                                    width: 20; height: 20; radius: 10
                                    color: Theme.accent
                                    Icon { anchors.centerIn: parent; name: "check"; size: 13; color: Theme.onAccent }
                                }
                                Rectangle {
                                    anchors.fill: parent
                                    radius: parent.radius
                                    color: Theme.hoverOverlay
                                    opacity: wp.hovered && !wp.sel ? 1 : 0
                                    Behavior on opacity { NumberAnimation { duration: Theme.durMicro } }
                                }
                                FocusRing { show: wp.visualFocus }
                            }
                            Text {
                                width: wp.width
                                text: wp.text
                                font: wp.sel ? Theme.typeLabel : Theme.typeCaption
                                color: wp.sel ? Theme.text : Theme.textMuted
                                elide: Text.ElideRight
                            }
                        }
                    }
                }
            }
        }
    }
}
