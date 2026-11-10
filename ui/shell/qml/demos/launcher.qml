// Launcher demo: the wallpaper, the center island, and the launcher dropping
// out of it.
//
//   QT_QPA_PLATFORM=offscreen scripts/qml-shot.sh ui/shell/qml/demos/launcher.qml \
//       /tmp/lugh-shots/launcher/fi-light.png 1440 900 900 -- --query fi
//
// Args:
//   --dark, --accent <name>, --reduce-motion
//   --query <text>     opened as ShowLauncher(query) would (Services.shell.showLauncher)
//   --recent-key       keyboard highlight on the second recent tile
//   --down <n>         press ↓ n times after opening
//   --slow [--lag <ms>=150]
//                      attach a demo backend that answers every search late
//                      (and answers every query, so stale answers must be
//                      dropped by Services). It also serves the stress data:
//                      "many" → 200 rows, "long" → long titles and icons
//                      that do not resolve. `--no-recent` empties `recent`.
//   --motion <open|type|close> --out <dir>
//                      grab the scene every ~33 ms into <dir>/<motion>-NN.png
//                      and log the panel geometry per frame, then quit (pass
//                      a long qml-shot delay, e.g. 20000).
// Glass: the compositor blurs behind the panel; here GlassPanel draws the
// pre-blurred wallpaper under itself (Theme.backdrop, GPU renderers only).
import QtQuick
import Lugh.UI
import Lugh.Shell

Item {
    id: demo
    implicitWidth: 1440
    implicitHeight: 900

    readonly property var args: Qt.application.arguments
    function arg(name, fallback) {
        const i = args.indexOf(name);
        return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
    }
    function flag(name) { return args.indexOf(name) >= 0; }

    readonly property string motion: arg("--motion", "")
    readonly property string outDir: arg("--out", "/tmp/lugh-shots/launcher/motion")
    readonly property string startQuery: arg("--query", "")

    property bool configured: false
    Component.onCompleted: {
        Theme.dark = flag("--dark");
        Theme.accentName = arg("--accent", "amber");
        Theme.reduceMotion = flag("--reduce-motion");
        if (flag("--slow")) slow.attach();
        else if (flag("--no-recent")) Services.launcher.recent.clear();
        configured = true;
        if (motion === "") start.start();
        else settle.start();
    }

    function openNow() {
        Services.shell.showLauncher(startQuery);
    }

    // Stills: open on the first turn (the body Loader is asynchronous).
    Timer {
        id: start
        interval: 1
        onTriggered: {
            demo.openNow();
            after.start();
        }
    }
    Timer {
        id: after
        interval: 250
        onTriggered: {
            if (demo.flag("--recent-key")) { keys.press(Qt.Key_Right); keys.press(Qt.Key_Right); }
            for (let i = 0; i < Number(demo.arg("--down", 0)); ++i) keys.press(Qt.Key_Down);
        }
    }
    // Sends a navigation key to the launcher body (as the field would).
    QtObject {
        id: keys
        function find(it) {
            for (let i = 0; i < it.children.length; ++i) {
                const c = it.children[i];
                if (c.handleKey !== undefined) return c;
                const r = find(c);
                if (r) return r;
            }
            return null;
        }
        function press(key) {
            const b = find(launcher);
            if (b) b.handleKey({ key: key, modifiers: 0 });
        }
    }

    Rectangle { anchors.fill: parent; color: Theme.bg }

    // The repo's art (the demo runs without lugh-branding installed).
    Loader {
        id: blurredWall
        anchors.fill: parent
        active: demo.configured
        sourceComponent: Wallpaper { blurred: true; _useRepo: true }
        onLoaded: Theme.backdrop = item
    }
    Loader {
        anchors.fill: parent
        active: demo.configured
        sourceComponent: Wallpaper { _useRepo: true }
    }

    // The center island the launcher drops out of.
    Island {
        id: island
        anchors.horizontalCenter: parent.horizontalCenter
        y: Theme.islandMargin
        height: Theme.islandHeight
        interactive: false
        text: qsTr("Clock")
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Tue 10 · 02:20"
            font: Theme.typeLabelTnum
            color: Theme.text
        }
    }
    Binding { target: ShellState; property: "centerIsland"; value: island.sceneRect }

    Launcher {
        id: launcher
        anchors.fill: parent
        visible: shown
        focus: true
    }

    // ---- --slow: a backend that answers late --------------------------------
    QtObject {
        id: slow
        signal event(string json)
        readonly property int delay: Number(demo.arg("--lag", 150))
        property var apps: []
        property var recent: []
        property var queue: []          // { due, json }
        property var served: []         // rows of the last search received
        property string servedQuery: ""

        function attach() {
            const src = Services.apps.installed;
            for (let i = 0; i < src.count; ++i) {
                const a = src.get(i);
                apps.push({ appId: a.appId, name: a.name, genericName: a.genericName, keywords: a.keywords, icon: a.icon });
            }
            if (!demo.flag("--no-recent")) {
                const r = Services.launcher.recent;
                for (let i = 0; i < r.count; ++i)
                    recent.push({ appId: r.get(i).appId, name: r.get(i).name, icon: r.get(i).icon });
            }
            Services.attach(slow);
        }
        function rows(text) {
            const q = text.trim().toLowerCase(), out = [];
            if (!q.length) return out;
            if (/^[\d\s.+\-*/()]+$/.test(q) && /\d[+\-*/]/.test(q)) {
                let v = NaN;
                try { v = Function('"use strict";return (' + q + ")")(); } catch (e) {}
                if (isFinite(v)) out.push({ kind: "calc", group: "Calculator", title: String(v), subtitle: "", icon: "calculator", target: String(v) });
            }
            if (q === "many") {
                for (let i = 0; i < 200; ++i)
                    out.push({ kind: i < 120 ? "app" : "file", group: i < 120 ? "Apps" : "Files",
                               title: "Many result " + (i + 1), subtitle: i % 3 ? "Row " + (i + 1) + " of 200" : "",
                               icon: i < 120 ? apps[i % apps.length].icon : "file", target: "many-" + i });
                return out;
            }
            if (q === "long") {
                const t = "Long title that keeps going well past the edge of a six hundred pixel panel to prove that it elides";
                out.push({ kind: "app", group: "Apps", title: t, subtitle: "And a subtitle that is every bit as long as the title, which nobody will ever read to the end",
                           icon: "no-such-icon-anywhere", target: "x" });
                out.push({ kind: "app", group: "Apps", title: "", subtitle: "No title, no icon", icon: "", target: "y" });
                out.push({ kind: "file", group: "Files", title: "Quarterly-report-final-FINAL-v7-reviewed-by-everyone-really-final.ods",
                           subtitle: "~/Documents/Work/2026/Finance/Reports/Quarterly/Drafts/Old/Archive/Do not open", icon: "text-x-generic", target: "z" });
                out.push({ kind: "setting", group: "Settings", title: "Long", subtitle: "Settings", icon: "", target: "s" });
                return out;
            }
            for (const a of apps)
                if ((a.name + " " + a.genericName + " " + a.keywords).toLowerCase().indexOf(q) >= 0)
                    out.push({ kind: "app", group: "Apps", title: a.name, subtitle: a.genericName, icon: a.icon, target: a.appId });
            return out;
        }
        function call(method, argsJson) {
            const a = JSON.parse(argsJson); if (demo.flag("--trace")) console.log("[demo] call", Date.now() % 100000, method, argsJson);
            let d = null;
            if (method === "core.snapshot") {
                event(JSON.stringify({ t: "snapshot", d: { launcher: { query: "", searching: false, results: [], recent: recent } } }));
            } else if (method === "launcher.search") {
                served = rows(a[0]); servedQuery = a[0];
                d = { t: "patch", s: "launcher", d: { query: a[0], results: served, searching: false } };
            } else if (method === "launcher.activate" || method === "launcher.activateSecondary") {
                const r = served[a[0]];
                console.log("[demo] " + method + "(" + a[0] + ") → “"
                            + (r ? r.title : "?") + "” of the answer to “" + servedQuery + "”; field “"
                            + launcher.query + "”");
            }
            if (d) { queue.push({ due: Date.now() + delay, json: JSON.stringify(d) }); pump.start(); }
        }
    }
    Timer {
        id: pump
        interval: 5
        repeat: true
        onTriggered: {
            const now = Date.now();
            while (slow.queue.length && slow.queue[0].due <= now) { if (demo.flag("--trace")) console.log("[demo] answer", now % 100000); slow.event(slow.queue.shift().json); }
            if (!slow.queue.length) stop();
        }
    }

    // ---- --motion -------------------------------------------------------------
    property int _frame: 0
    property int _pending: 0
    property double _t0: 0
    readonly property int _frames: motion === "type" ? 30 : motion === "close" ? 12 : 20
    Timer {     // let the wallpaper and the body load, then go
        id: settle
        interval: 1800
        onTriggered: {
            if (demo.motion === "open") { demo._t0 = Date.now(); demo.openNow(); grabber.start(); }
            else { demo.openNow(); later.start(); }
        }
    }
    Timer {
        id: later
        interval: 900
        onTriggered: {
            demo._t0 = Date.now();
            if (demo.motion === "close") ShellState.closeAll();
            grabber.start();
        }
    }
    Timer {
        id: grabber
        interval: 33
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            const n = demo._frame++;
            if (demo.motion === "type") {
                if (n === 1) launcher.query = "f";
                if (n === 4) launcher.query = "fi";
                if (n === 12) launcher.query = "12*7+3";
                if (n === 20) launcher.query = "zzzz";
            }
            const p = launcher.panelItem;
            const f = demo.Window.window.activeFocusItem;
            console.log("frame " + String(n).padStart(2, "0") + " t=" + (Date.now() - demo._t0) + "ms panel x=" + p.x.toFixed(1)
                        + " y=" + p.y.toFixed(1) + " w=" + p.width.toFixed(1) + " h=" + p.height.toFixed(1)
                        + " r=" + p.radius.toFixed(1) + " op=" + p.opacity.toFixed(2)
                        + " shown=" + launcher.shown + " fieldFocus=" + (f !== null && f.placeholderText !== undefined));
            demo._pending++;
            demo.grabToImage(r => {
                r.saveToFile(demo.outDir + "/" + demo.motion + "-" + String(n).padStart(2, "0") + ".png");
                if (--demo._pending === 0 && !grabber.running) Qt.exit(0);
            });
            if (demo._frame >= demo._frames) stop();
        }
    }
}
