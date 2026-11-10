// Mock file manager content: sidebar + folder grid.
pragma ComponentBehavior: Bound
import QtQuick
import Lugh.UI

Item {
    id: root

    // ---- sidebar (bottom-left corner follows the window radius) -------------
    Rectangle {
        id: sidebar
        width: 176
        height: parent.height
        color: Theme.surface2
        radius: Theme.radiusLg - 1
        // square the top and right edges
        Rectangle { width: parent.width; height: parent.radius; color: parent.color }
        Rectangle { anchors.right: parent.right; width: parent.radius; height: parent.height; color: parent.color }
        Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.border }

        Column {
            anchors { fill: parent; margins: 10; topMargin: 12 }
            spacing: 2
            Text {
                leftPadding: 8
                bottomPadding: 6
                text: "Places"
                font: Theme.typeCaption
                color: Theme.textMuted
            }
            Repeater {
                model: [
                    { icon: "house", name: "Home" },
                    { icon: "file-text", name: "Documents" },
                    { icon: "download", name: "Downloads" },
                    { icon: "image", name: "Pictures" },
                    { icon: "music", name: "Music" },
                    { icon: "trash-2", name: "Trash" }
                ]
                delegate: Rectangle {
                    id: place
                    required property var modelData
                    required property int index
                    readonly property bool current: index === 1
                    width: parent.width
                    height: 32
                    radius: Theme.radiusSm
                    color: place.current ? Theme.surface3 : "transparent"
                    Row {
                        anchors { left: parent.left; leftMargin: 8; verticalCenter: parent.verticalCenter }
                        spacing: 10
                        Optional {
                            anchors.verticalCenter: parent.verticalCenter
                            type: "Icon"
                            props: ({ name: place.modelData.icon, size: 16, color: place.current ? Theme.text : Theme.textMuted })
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: place.modelData.name
                            font: place.current ? Theme.typeBodyStrong : Theme.typeBody
                            color: Theme.text
                        }
                    }
                }
            }
        }
    }

    // ---- main -------------------------------------------------------------
    Item {
        anchors { left: sidebar.right; right: parent.right; top: parent.top; bottom: parent.bottom }
        clip: true

        Text {
            id: crumbs
            x: 20; y: 14
            text: "Home  ›  <b>Documents</b>"
            textFormat: Text.StyledText
            font: Theme.typeBody
            color: Theme.textMuted
        }
        Text {
            anchors { right: parent.right; rightMargin: 20; verticalCenter: crumbs.verticalCenter }
            text: "7 items"
            font: Theme.typeCaption
            color: Theme.textMuted
        }

        Grid {
            id: grid
            anchors { left: parent.left; right: parent.right; top: crumbs.bottom; margins: 20; topMargin: 18 }
            columns: Math.max(1, Math.floor(width / 104))
            columnSpacing: 4
            rowSpacing: 10
            Repeater {
                model: [
                    { icon: "folder", name: "Projects" },
                    { icon: "folder", name: "Rwanda trip" },
                    { icon: "folder", name: "Invoices 2026" },
                    { icon: "folder", name: "Screenshots" },
                    { icon: "file-text", name: "Lugh pitch.pdf" },
                    { icon: "sheet", name: "Rwanda trip budget.ods" },
                    { icon: "image", name: "IMG_2041.jpg" }
                ]
                delegate: Item {
                    id: entry
                    required property var modelData
                    required property int index
                    width: 100
                    height: 96
                    Rectangle {
                        anchors.fill: parent
                        radius: Theme.radiusMd
                        color: entry.index === 0 ? Theme.selectedBg : "transparent"
                    }
                    Rectangle {
                        id: tile
                        anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 8 }
                        width: 48; height: 42
                        radius: Theme.radiusMd
                        color: entry.modelData.icon === "folder" ? Theme.surface3 : Theme.surface2
                        Optional {
                            anchors.centerIn: parent
                            type: "Icon"
                            props: ({ name: entry.modelData.icon, size: 22, color: Theme.textMuted })
                        }
                    }
                    Text {
                        anchors { top: tile.bottom; topMargin: 6; horizontalCenter: parent.horizontalCenter }
                        width: parent.width - 8
                        horizontalAlignment: Text.AlignHCenter
                        text: entry.modelData.name
                        font: Theme.typeCaption
                        color: Theme.text
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                    }
                }
            }
        }
    }
}
