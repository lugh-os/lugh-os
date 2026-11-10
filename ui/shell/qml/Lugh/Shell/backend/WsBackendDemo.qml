// Manual smoke test for WsBackend against a running lugh-shell-devd
// (read-only: it calls no setter):
//
//     cargo run -p lugh-shell-devd &
//     QT_QPA_PLATFORM=offscreen scripts/qml-shot.sh \
//         ui/shell/qml/Lugh/Shell/backend/WsBackendDemo.qml /tmp/x.png 200 200 2500
//
// Prints one "WsBackendDemo:" line with live values after 2 s.
import QtQuick
import Lugh.Shell

Item {
    id: demo
    width: 200
    height: 200

    property int events: 0

    WsBackend {
        id: ws
        url: Qt.application.arguments.indexOf("--backend") >= 0
            ? Qt.application.arguments[Qt.application.arguments.indexOf("--backend") + 1]
            : "ws://127.0.0.1:7777"
        onEvent: demo.events += 1
    }

    Component.onCompleted: Services.attach(ws)

    Timer {
        interval: 2000
        running: true
        onTriggered: console.info("WsBackendDemo:",
            "connected=" + ws.connected,
            "live=" + Services.live,
            "events=" + demo.events,
            "session.userName=" + JSON.stringify(Services.session.userName),
            "session.hostName=" + JSON.stringify(Services.session.hostName),
            "network.ssid=" + JSON.stringify(Services.network.ssid),
            "audio.volume=" + Services.audio.volume)
    }

    Text {
        anchors.centerIn: parent
        horizontalAlignment: Text.AlignHCenter
        text: (ws.connected ? "live" : "offline") + "\n" + Services.session.userName
            + "\n" + Services.network.ssid + "\n" + Math.round(Services.audio.volume * 100) + " %"
    }
}
