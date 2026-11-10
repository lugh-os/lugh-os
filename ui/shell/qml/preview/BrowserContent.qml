// Mock browser content: toolbar + a simple, real-looking page (lugh.space).
pragma ComponentBehavior: Bound
import QtQuick
import Lugh.UI

Item {
    id: root
    clip: true

    // ---- toolbar ------------------------------------------------------------
    Rectangle {
        id: toolbar
        width: parent.width
        height: 44
        color: Theme.bg
        Row {
            id: nav
            anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
            spacing: 4
            Repeater {
                model: ["arrow-left", "arrow-right", "rotate-cw"]
                delegate: Item {
                    id: navButton
                    required property string modelData
                    width: 30; height: 30
                    Optional {
                        anchors.centerIn: parent
                        type: "Icon"
                        props: ({ name: navButton.modelData, size: 16, color: navButton.modelData === "arrow-right" ? Theme.border : Theme.textMuted })
                    }
                }
            }
        }
        Rectangle {
            anchors { left: nav.right; leftMargin: 10; right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
            height: 30
            radius: 15
            color: Theme.surface2
            Row {
                anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                spacing: 8
                Optional {
                    anchors.verticalCenter: parent.verticalCenter
                    type: "Icon"
                    props: ({ name: "lock", size: 13, color: Theme.textMuted })
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "lugh.space"
                    font: Theme.typeBody
                    color: Theme.text
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "/release/0.1"
                    font: Theme.typeBody
                    color: Theme.textMuted
                }
            }
        }
        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            color: Theme.border
        }
    }

    // ---- page ---------------------------------------------------------------
    Rectangle {
        anchors { top: toolbar.bottom; left: parent.left; right: parent.right; bottom: parent.bottom }
        // The window frame is already `surface` and rounds the bottom corners.
        color: "transparent"

        Column {
            id: page
            anchors { fill: parent; leftMargin: 44; rightMargin: 44; topMargin: 22 }
            spacing: 0

            // site nav
            Item {
                width: parent.width
                height: 28
                Text {
                    text: "Lugh"
                    font: Theme.typeTitle3
                    color: Theme.text
                    anchors.verticalCenter: parent.verticalCenter
                }
                Row {
                    anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                    spacing: 22
                    Repeater {
                        model: ["Download", "Docs", "Store", "Community"]
                        delegate: Text {
                            required property string modelData
                            text: modelData
                            font: Theme.typeBody
                            color: Theme.textMuted
                        }
                    }
                }
            }
            Item { width: 1; height: 44 }

            Text {
                text: "Release 0.1 · Phase 1 preview"
                font: Theme.typeCaption
                color: Theme.accentText
            }
            Item { width: 1; height: 10 }
            Text {
                width: parent.width
                text: "A calm, bright desktop\nthat feels familiar on day one."
                font: Theme.typeDisplay
                lineHeight: Theme.lineHeading
                color: Theme.text
                wrapMode: Text.WordWrap
            }
            Item { width: 1; height: 14 }
            Text {
                width: Math.min(parent.width, 520)
                text: "Lugh is a Debian-based desktop for people coming from Windows or macOS. "
                      + "It starts fast on older laptops, keeps your data on your machine and "
                      + "snapshots the system before every update."
                font: Theme.typeBody
                lineHeight: Theme.lineBody
                color: Theme.textMuted
                wrapMode: Text.WordWrap
            }
            Item { width: 1; height: 22 }
            Row {
                spacing: 10
                Rectangle {
                    width: dl.implicitWidth + 32; height: 36
                    radius: Theme.radiusSm
                    color: Theme.accent
                    Text { id: dl; anchors.centerIn: parent; text: "Download Lugh 0.1"; font: Theme.typeBodyStrong; color: Theme.onAccent }
                }
                Rectangle {
                    width: notes.implicitWidth + 32; height: 36
                    radius: Theme.radiusSm
                    color: Theme.surface
                    border.width: 1
                    border.color: Theme.border
                    Text { id: notes; anchors.centerIn: parent; text: "Release notes"; font: Theme.typeBodyStrong; color: Theme.text }
                }
            }
            Item { width: 1; height: 36 }

            Row {
                id: cards
                spacing: 14
                readonly property real cardWidth: (page.width - 2 * spacing) / 3
                Repeater {
                    model: [
                        { icon: "layout-grid", title: "Familiar layouts", body: "Lugh, Classic or Focus mode. Switch any time, windows stay put." },
                        { icon: "shield-check", title: "Private by default", body: "No telemetry. Search and history stay on this computer." },
                        { icon: "gauge", title: "Light on memory", body: "The whole shell fits in under 150 MB, even with ten windows open." }
                    ]
                    delegate: Rectangle {
                        id: card
                        required property var modelData
                        width: cards.cardWidth
                        height: 128
                        radius: Theme.radiusMd
                        color: Theme.bg
                        border.width: 1
                        border.color: Theme.border
                        Column {
                            anchors { fill: parent; margins: Theme.space16 }
                            spacing: 6
                            Optional {
                                type: "Icon"
                                props: ({ name: card.modelData.icon, size: 18, color: Theme.text })
                            }
                            Text { text: card.modelData.title; font: Theme.typeBodyStrong; color: Theme.text }
                            Text {
                                width: parent.width
                                text: card.modelData.body
                                font: Theme.typeCaption
                                lineHeight: 1.35
                                color: Theme.textMuted
                                wrapMode: Text.WordWrap
                                maximumLineCount: 3
                                elide: Text.ElideRight
                            }
                        }
                    }
                }
            }
        }
    }
}
