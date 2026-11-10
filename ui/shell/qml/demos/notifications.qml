// Notifications demo (Lugh mode): wallpaper, stand-in islands, the toast
// capsules under the status island and, optionally, the notification center
// growing out of the center island.
//
//   scripts/qml-shot.sh ui/shell/qml/demos/notifications.qml /tmp/out.png 1440 900 900 -- [flags]
//   --dark              dark theme
//   --accent <name>     amber | teal | green | blue | red | graphite
//   --reduce-motion     reduce motion (also --reduce)
//   --center            open the notification center
//   --empty             no notifications at all
//   --many              30 notifications in the history
//   --more              5 toasts (shows the "+N more" capsule)
//   --expanded          keep the newest toast expanded
//   --stress            awkward content: long text, markup, no icon, long
//                       action labels, a broken image, time = 0
//   --motion <kind>     toast-in | toast-expand | toast-out | center-open | center-close:
//                       grabs the scene every ~33 ms into --frames <dir>
//                       (<kind>-NN.png), then quits
// Glass: Theme.backdrop is a blurred wallpaper, so GlassPanel shows what the
// compositor's blur would (GPU renderers only).
import QtQuick
import Lugh.UI
import Lugh.Shell

Item {
    id: demo
    implicitWidth: 1440
    implicitHeight: 900

    readonly property var args: Qt.application.arguments
    function flag(n) { return args.indexOf(n) >= 0 }
    function arg(n, d) { const i = args.indexOf(n); return i >= 0 && i + 1 < args.length ? args[i + 1] : d }

    readonly property string repo: Qt.resolvedUrl("../../../../")
    readonly property string motion: arg("--motion", "")
    readonly property string outDir: arg("--frames", "/tmp/lugh-shots/notify/motion")
    function wall(kind) { return repo + "branding/wallpapers/dawn-" + (Theme.dark ? "dark" : "light") + "-" + kind + ".jpg" }
    property bool ready: false

    function post(appName, appIcon, summary, body, urgency, actions, image, ageMin, historyOnly) {
        const n = Services.notifications;
        const row = { nid: n._next++, appName: appName, appIcon: appIcon, summary: summary, body: body,
                      urgency: urgency, time: ageMin < 0 ? 0 : Date.now() - (ageMin || 0) * 60000,
                      actions: JSON.stringify(actions || []), image: image || "" };
        n.history.insert(0, row);
        if (!historyOnly) n.popups.insert(0, row);
    }
    function screenshotToast() {
        post("Screenshot", "applets-screenshooter", "Screenshot saved",
             "Saved to Pictures/Screenshots and copied to the clipboard.", 1,
             [{ key: "default", label: "Open" }, { key: "edit", label: "Edit" }, { key: "folder", label: "Show in Files" }],
             wall("blur"), 0);
    }

    Component.onCompleted: {
        Theme.dark = flag("--dark");
        Theme.accentName = arg("--accent", "amber");
        Theme.reduceMotion = flag("--reduce-motion") || flag("--reduce");
        Services.notifications.clearAll();
        if (flag("--many")) {
            const apps = [["Mail", "mail-client"], ["Chat", "internet-chat"], ["Files", "system-file-manager"],
                          ["Terminal", "utilities-terminal"], ["Calendar", "x-office-calendar"]];
            const what = ["Build finished", "Keza Uwase sent a file", "Stand-up in 10 minutes", "Copy finished",
                          "Jean-Paul mentioned you", "Backup complete", "New sign-in from Kigali"];
            for (let i = 29; i >= 0; --i) {
                const a = apps[(i * 7) % 5 === 0 ? 0 : i % apps.length];
                post(a[0], a[1], what[i % what.length], "Item " + (i + 1) + " of 30: details for this notification.",
                     i === 4 ? 2 : 1, i % 6 === 0 ? [{ key: "default", label: "Open" }] : [], "", i * 9, true);
            }
        } else if (flag("--stress")) {
            post("", "", "", "A notification with no app name, no icon and no summary, only a body that goes on for a while.", 1, [], "", -1, true);
            post("Org.Example.AVeryLongApplicationNameThatKeepsGoing", "no-such-icon", "Time is zero here", "", 1, [], "", -1, true);
            post("Updater", "no-such-icon",
                 "A very long summary that cannot possibly fit on one line of a 320 pixel capsule, so it must elide",
                 "<script>alert(1)</script> <b>Bold</b>, <i>italic</i>, <u>underline</u>, a <a href=\"https://lugh.space\">link</a> and a "
                 + "<a href=\"javascript:alert(1)\">bad link</a>.\nSecond line.\nThird line.\nFourth line that should be cut off by the line limit.\nFifth.",
                 1, [{ key: "a", label: "Restart and install all pending updates now" }, { key: "b", label: "Remind me again tomorrow morning" },
                     { key: "c", label: "Details" }, { key: "d", label: "Fourth, never shown" }],
                 "file:///nonexistent/broken.png", 1);
            post("Supercalifragilistic", "", "Nobreakwordthatisextremelylongandhasnospacesatallanywhereinitwhatsoever_really_none",
                 "Bodywithoutanyspacesatallwhichmustwraporelidebutneveroverflowthecapsuleboundsnomatterwhathappenshere.", 2,
                 [{ key: "default", label: "" }, { key: "ok", label: "OK" }], "", 0);
            post("Mail", "mail-client", "Short", "", 1, [], "", 0);
        } else if (!flag("--empty")) {
            // Older, history only: the Mail group gets 4 and collapses.
            post("System", "preferences-system", "Updates ready", "12 updates are ready to install. A snapshot is taken first.", 0,
                 [{ key: "install", label: "Install now" }], "", 190, true);
            post("Calendar", "x-office-calendar", "Design review in 15 minutes", "Shell visuals with Keza and Jean-Paul", 1, [], "", 75, true);
            post("Mail", "mail-client", "Jean-Paul Habimana — Icon review", "Attached are the new dock icons.", 1, [], "", 52, true);
            post("Mail", "mail-client", "Lugh weekly", "Phase 1 shell: bar, dock and launcher landed.", 0, [], "", 20, true);
            post("Mail", "mail-client", "Aline Mukamana — Re: Greeter copy", "Looks good to me. Ship it.", 1, [], "", 12, true);
            if (flag("--more")) {
                post("Files", "system-file-manager", "Copy finished", "4 files copied to Documents.", 1, [], "", 3);
                post("Terminal", "utilities-terminal", "Build finished", "cargo build --release finished in 41 s.", 0, [], "", 2);
            }
            post("Mail", "mail-client", "Keza Uwase — Notes from the shell review",
                 "Thanks for walking us through the dock and the launcher today. A few things we agreed on: the "
                 + "<b>notification stack</b> keeps three toasts, critical ones stay, and the calendar opens from the "
                 + "clock. Full notes are in <a href=\"https://lugh.space/notes\">the shared doc</a>.", 1, [], "", 1);
            if (motion !== "toast-in" && motion !== "toast-expand")
                post("Battery", "battery", "Battery critically low",
                     "8% left. Plug in the charger or the laptop will suspend in about 5 minutes.", 2,
                     [{ key: "settings", label: "Power settings" }], "", 0);
            if (motion !== "toast-in") screenshotToast();
        }
        popups.forceExpanded = flag("--expanded");
        if (flag("--center") || motion === "center-close") ShellState.notificationCenterOpen = true;
        ready = true;
    }

    // Pre-blurred wallpaper: the source of the simulated compositor blur.
    Loader {
        anchors.fill: parent
        active: demo.ready
        sourceComponent: Wallpaper { blurred: true; source: demo.wall("blur") }
        onLoaded: Theme.backdrop = item
    }
    Loader {
        anchors.fill: parent
        active: demo.ready
        sourceComponent: Wallpaper { source: demo.wall("2560x1600") }
    }

    // Stand-ins for the bar's islands.
    Island {
        id: centerIsland
        anchors.horizontalCenter: parent.horizontalCenter
        y: Theme.islandMargin
        text: "Notifications and calendar"
        active: ShellState.notificationCenterOpen
        onClicked: ShellState.toggleNotificationCenter()
        onSceneRectChanged: ShellState.centerIsland = sceneRect
        Component.onCompleted: ShellState.centerIsland = sceneRect
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: Services.clock.date + " · " + Services.clock.time
            font: Theme.typeLabelTnum
            color: Theme.text
        }
    }
    Island {
        anchors { right: parent.right; rightMargin: Theme.islandSideMargin }
        y: Theme.islandMargin
        text: "Control center"
        Icon { name: "wifi"; size: 16; anchors.verticalCenter: parent.verticalCenter }
        Icon { name: "volume-2"; size: 16; anchors.verticalCenter: parent.verticalCenter }
        Icon { name: "battery-medium"; size: 16; anchors.verticalCenter: parent.verticalCenter }
    }

    NotificationPopups {
        id: popups
        anchors { top: parent.top; topMargin: Theme.barHeight; right: parent.right; rightMargin: Theme.islandSideMargin }
        visible: shown
    }

    NotificationCenter {
        id: center
        anchors.fill: parent
        visible: shown
    }

    // ---- motion capture ---------------------------------------------------
    property int _frame: 0
    property double _t0: 0
    function _trigger() {
        _t0 = Date.now();
        switch (motion) {
        case "toast-in": screenshotToast(); break;
        case "toast-expand": popups.forceExpanded = true; break;
        case "toast-out": Services.notifications.expire(Services.notifications.popups.get(0).nid); break;
        case "center-open": ShellState.notificationCenterOpen = true; break;
        case "center-close": ShellState.notificationCenterOpen = false; break;
        }
    }
    Timer {     // settle first, then go
        interval: 900
        running: demo.motion !== ""
        onTriggered: { demo._trigger(); grabber.start(); }
    }
    // Grabs are kept in memory and saved after the last one: encoding a PNG
    // per frame would stall the motion being captured.
    property var _grabs: []
    Timer {
        id: grabber
        interval: 33
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            const n = demo._frame++;
            console.log("frame " + n + " t=" + (Date.now() - demo._t0) + "ms popupsH=" + popups.implicitHeight
                        + " rects=" + JSON.stringify(popups.inputRects.map(r => [r.x, r.y, r.width, r.height])));
            demo.grabToImage(r => {
                demo._grabs.push([n, r]);
                if (demo._grabs.length < 20) return;
                for (const g of demo._grabs)
                    g[1].saveToFile(demo.outDir + "/" + demo.motion + "-" + String(g[0]).padStart(2, "0") + ".png");
                Qt.exit(0);
            });
            if (demo._frame >= 20) stop();
        }
    }
}
