// Interactive LughUI gallery: the same page as Gallery.qml in a window, with
// live theme / accent / motion switches in its header. Hover, drag and keyboard
// (Tab through everything) work here; screenshots use Gallery.qml directly.
//
//   qml6 -I ui/components ui/components/gallery/main.qml
//   qml6 -I ui/components ui/components/gallery/main.qml -- --dark --accent teal
//   qml6 -I ui/components ui/components/gallery/main.qml -- --section fields
import QtQuick
import QtQuick.Window
import Lugh.UI

Window {
    width: Math.min(1600, Screen.desktopAvailableWidth)
    height: Math.min(1100, Screen.desktopAvailableHeight)
    minimumWidth: 900
    minimumHeight: 600
    visible: true
    color: Theme.bg
    title: "LughUI Gallery"

    Gallery {
        anchors.fill: parent
    }
}
