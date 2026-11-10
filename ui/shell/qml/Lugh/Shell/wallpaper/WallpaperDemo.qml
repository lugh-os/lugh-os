// Demo of the default wallpaper: Dawn (light) and Dusk (dark) side by side,
// each with a mock bar and dock whose "glass" is the pre-blurred wallpaper
// (the same trick the preview uses instead of a runtime blur), and below them
// the blurred variants on their own (lock screen).
//
//   QT_QPA_PLATFORM=offscreen scripts/qml-shot.sh \
//       ui/shell/qml/Lugh/Shell/wallpaper/WallpaperDemo.qml /tmp/lugh-shots/wallpaper/demo.png 1440 900
import QtQuick
import Lugh.UI
import Lugh.Shell

Rectangle {
    id: demo
    width: 1440
    height: 900
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
            dark: g.host.dark; blurred: true
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
        readonly property color glassTint: dark ? Qt.rgba(28 / 255, 27 / 255, 25 / 255, 0.70) : Qt.rgba(1, 1, 1, 0.72)
        readonly property color ink: dark ? "#EDEBE6" : "#1C1B19"
        clip: true

        Wallpaper { anchors.fill: parent; dark: desk.dark }

        Glass {
            host: desk
            x: 0; y: 0; width: desk.width; height: 30
            Text { x: 12; anchors.verticalCenter: parent.verticalCenter; text: "Files    Edit    View"; font: Theme.typeBodyStrong; color: desk.ink }
            Text { anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                   text: "Tue 10 Nov  09:41"; font: Theme.typeBodyTnum; color: desk.ink }
        }
        Glass {
            host: desk
            // the dock pill (the blurred backdrop is clipped square; at the calm
            // bottom of the art the corners are indistinguishable)
            width: 8 * 52 + 16; height: 64; radius: Theme.radiusXl
            x: (desk.width - width) / 2; y: desk.height - height - 12
            Row {
                anchors.centerIn: parent
                spacing: 8
                Repeater {
                    model: 8
                    Rectangle {
                        width: 44; height: 44; radius: 11
                        color: index === 0 ? (desk.dark ? "#F2A93B" : "#E8962E")
                                           : (desk.dark ? "#3A3732" : "#D8D4CC")
                    }
                }
            }
        }
    }

    Column {
        anchors.centerIn: parent
        spacing: 12

        Row {
            spacing: 16
            Column {
                spacing: 6
                Caption { text: "Dawn (light) · Wallpaper { dark: false }" }
                Desktop { width: 696; height: 435; dark: false }
            }
            Column {
                spacing: 6
                Caption { text: "Dusk (dark) · Wallpaper { dark: true }" }
                Desktop { width: 696; height: 435; dark: true }
            }
        }
        Row {
            spacing: 16
            Column {
                spacing: 6
                Caption { text: "Dawn · blurred: true (lock screen, glass backdrops)" }
                Wallpaper { width: 696; height: 300; dark: false; blurred: true }
            }
            Column {
                spacing: 6
                Caption { text: "Dusk · blurred: true" }
                Wallpaper { width: 696; height: 300; dark: true; blurred: true }
            }
        }
    }
}
