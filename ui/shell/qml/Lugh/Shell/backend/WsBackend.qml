// WsBackend: a Services backend that talks to `lugh-shell-devd` over a
// WebSocket (docs/specs/shell-bridge.md), so the preview on a dev machine
// drives that machine's real services:
//
//     cargo run -p lugh-shell-devd            # ws://127.0.0.1:7777
//     WsBackend { id: ws; url: "ws://127.0.0.1:7777" }
//     Component.onCompleted: Services.attach(ws)
//
// Loaded by URL by the preview and deliberately not listed in the qmldir:
// production (the in-process LughBackend) never needs QtWebSockets.
import QtQuick
import QtWebSockets

QtObject {
    id: backend

    property url url: "ws://127.0.0.1:7777"
    readonly property bool connected: socket.status === WebSocket.Open
    // Calls made while disconnected wait here (oldest dropped past the cap).
    readonly property int maxQueued: 100
    // Reconnect delay: 0.5 s, doubling up to 5 s; reset once connected.
    readonly property int minBackoff: 500
    readonly property int maxBackoff: 5000

    // Every incoming frame that has a `t` field: snapshot, patch, signal.
    signal event(string json)

    // Sends {"m": method, "a": <args>}. `argsJson` is a JSON array.
    function call(method: string, argsJson: string) {
        let args = [];
        try {
            args = JSON.parse(argsJson || "[]");
        } catch (err) {
            console.warn("WsBackend: bad arguments for", method, err);
            return;
        }
        const frame = JSON.stringify({ "m": method, "a": args });
        if (connected) {
            socket.sendTextMessage(frame);
            return;
        }
        // A snapshot is requested anyway on (re)connect; never queue one.
        if (method === "core.snapshot") return;
        _queue.push(frame);
        if (_queue.length > maxQueued) _queue.splice(0, _queue.length - maxQueued);
    }

    property var _queue: []
    property int _backoff: minBackoff
    property bool _everConnected: false

    function _opened() {
        _backoff = minBackoff;
        if (_everConnected) console.info("WsBackend: reconnected to", url);
        _everConnected = true;
        // Fresh state first, then whatever was asked for while offline.
        socket.sendTextMessage('{"m":"core.snapshot","a":[]}');
        const pending = _queue;
        _queue = [];
        for (const frame of pending) socket.sendTextMessage(frame);
    }
    function _lost() {
        if (retry.running) return;
        retry.interval = _backoff;
        _backoff = Math.min(maxBackoff, _backoff * 2);
        retry.start();
    }

    property WebSocket _socket: WebSocket {
        id: socket
        url: backend.url
        active: true
        onStatusChanged: s => {
            if (s === WebSocket.Open) {
                backend._opened();
            } else if (s === WebSocket.Error) {
                console.warn("WsBackend:", errorString, "(" + backend.url + ")");
                backend._lost();
            } else if (s === WebSocket.Closed) {
                backend._lost();
            }
        }
        onTextMessageReceived: message => {
            // Replies ({"id":…,"r"/"e":…}) carry no `t`; only events go on.
            let t;
            try { t = JSON.parse(message).t; } catch (err) { console.warn("WsBackend: bad frame", err); return; }
            if (t !== undefined) backend.event(message);
        }
    }

    property Timer _retry: Timer {
        id: retry
        onTriggered: {
            // Toggling `active` is how a QML WebSocket reopens.
            socket.active = false;
            socket.active = true;
        }
    }
}
