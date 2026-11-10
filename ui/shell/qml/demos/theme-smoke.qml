import QtQuick
import Lugh.UI
import Lugh.Shell
Rectangle {
    color: Theme.bg
    Column {
        anchors.centerIn: parent; spacing: Theme.space8
        Text { text: "Lugh " + Services.clock.time; font: Theme.typeDisplay; color: Theme.text }
        Text { text: Services.session.realName + " · " + Services.network.ssid; font: Theme.typeBody; color: Theme.textMuted }
        Rectangle { width: 120; height: 36; radius: Theme.radiusSm; color: Theme.accent
            Text { anchors.centerIn: parent; text: "Accent"; font: Theme.typeBodyStrong; color: Theme.onAccent } }
    }
}
