// Demo of the bundled wallpaper set (Dawn, Tide, Ember) on one sheet: for each,
// the light and the dark variant with mock Lugh-mode islands and dock whose
// "glass" is the pre-blurred wallpaper (the same trick the preview uses
// instead of a runtime blur), and the two blurred variants (lock screen).
//
//   QT_QPA_PLATFORM=offscreen scripts/qml-shot.sh \
//       ui/shell/qml/Lugh/Shell/wallpaper/WallpaperDemo.qml /tmp/lugh-shots/wallpaper/set.png 1600 1000
import QtQuick
import Lugh.UI
import Lugh.Shell

Rectangle {
    id: demo
    width: 1600
    height: 1000
    color: "#EEECE7"

    component Caption: Text {
        font: Theme.typeCaption
        color: "#5F5B54"
    }

    component Glass: Item {
        id: g
        required property Item host   // the Desktop tile it sits on
        default property alias content: inner.data
        property real radius: 0
        clip: true
        Wallpaper {
            // the blurred art, positioned as if it filled the whole tile
            x: -g.x; y: -g.y
            width: g.host.width; height: g.host.height
            dark: g.host.dark; blurred: true; name: g.host.name; _useRepo: true
        }
        Rectangle {
            anchors.fill: parent
            radius: g.radius
            color: g.host.glassTint
            border.color: g.host.dark ? Qt.rgba(1, 1, 1, 0.08) : Qt.rgba(0, 0, 0, 0.08)
        }
        Item { id: inner; anchors.fill: parent }
    }

    // A desktop tile: wallpaper + glass bar + glass dock, the glass filled with
    // the blurred wallpaper clipped to the surface, then the glass tint.
    component Desktop: Item {
        id: desk
        property bool dark: false
        property string name: "dawn"
        readonly property color glassTint: dark ? Qt.rgba(28 / 255, 27 / 255, 25 / 255, 0.82) : Qt.rgba(1, 1, 1, 0.72)
        readonly property color ink: dark ? "#EDEBE6" : "#1C1B19"
        clip: true

        Wallpaper { anchors.fill: parent; dark: desk.dark; name: desk.name; _useRepo: true }

        // the three islands (36 px tall in the shell; scaled to the tile)
        Repeater {
            model: [{ x: 5, w: 96 }, { x: (desk.width - 74) / 2, w: 74 }, { x: desk.width - 5 - 70, w: 70 }]
            Glass {
                required property var modelData
                host: desk
                x: modelData.x; y: 4; width: modelData.w; height: 18; radius: 9
                Rectangle {
                    anchors.centerIn: parent
                    width: parent.width - 24; height: 3; radius: 1.5
                    color: desk.ink; opacity: 0.85
                }
            }
        }
        Glass {
            host: desk
            width: 8 * 26 + 12; height: 32; radius: 16
            x: (desk.width - width) / 2; y: desk.height - height - 5
            Row {
                anchors.centerIn: parent
                spacing: 4
                Repeater {
                    model: 8
                    Rectangle {
                        width: 22; height: 22; radius: 6
                        color: index === 0 ? (desk.dark ? "#F2A93B" : "#E8962E")
                                           : (desk.dark ? "#3A3732" : "#D8D4CC")
                    }
                }
            }
        }
    }

    Column {
        anchors.centerIn: parent
        spacing: 14

        Repeater {
            model: [{ name: "dawn", title: "Dawn" }, { name: "tide", title: "Tide" }, { name: "ember", title: "Ember" }]
            Column {
                id: rowItem
                required property var modelData
                spacing: 6
                Caption { text: rowItem.modelData.title + " · Wallpaper { name: \"" + rowItem.modelData.name + "\" } · light, dark, blurred light, blurred dark" }
                Row {
                    spacing: 12
                    Desktop { width: 496; height: 279; name: rowItem.modelData.name; dark: false }
                    Desktop { width: 496; height: 279; name: rowItem.modelData.name; dark: true }
                    Column {
                        spacing: 9
                        Wallpaper { width: 240; height: 135; name: rowItem.modelData.name; dark: false; blurred: true; _useRepo: true }
                        Wallpaper { width: 240; height: 135; name: rowItem.modelData.name; dark: true; blurred: true; _useRepo: true }
                    }
                }
            }
        }
    }
}
