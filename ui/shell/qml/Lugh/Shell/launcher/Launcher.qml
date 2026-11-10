// Launcher (Lugh mode, Super+Space): Spotlight-style centered search
// (DESIGN-SYSTEM §8, shell spec §Launcher, §States, NFR-2/NFR-3).
//
//   Launcher { anchors.fill: parent }   // the frame anchors it to the screen
//
// Fullscreen overlay root. Opens when ShellState.launcherOpen; closes on Esc
// (after clearing a non-empty query), an outside click, or after activating
// a result. The frame maps the layer surface while `shown` and gives it the
// keyboard while `wantsKeyboard`.
//
// Open-to-typing (NFR-2, ≤ 100 ms): the panel and its SearchField always
// exist (hidden while closed), so the field takes focus on the first frame;
// the result/recent views live in an asynchronous Loader created at startup.
// Searching calls Services.launcher.search(text) on every change (Rust
// answers in < 30 ms; slow providers stream in and keep row 0 highlighted).
//
// Keys: ↑/↓ move (wrap) · PageUp/PageDown · Tab/Shift+Tab jump groups ·
// Enter activates · Ctrl+Enter secondary action · Esc clears, then closes.
// With an empty query, the arrows/Tab move across the recent apps.
import QtQuick
import Lugh.UI
import Lugh.Shell

FocusScope {
    id: root

    readonly property bool open: ShellState.launcherOpen
    // Open, or still fading out.
    readonly property bool shown: open || stage.opacity > 0
    readonly property bool wantsKeyboard: open
    // The query text (D-Bus ShowLauncher(query) / preview --query set it).
    property alias query: field.text
    // The glass panel, for frames that draw a backdrop under it.
    readonly property Item panelItem: panel

    property int panelWidth: 680
    property real topFraction: 0.22
    property int maxResultsHeight: 440

    focus: true
    Accessible.role: Accessible.Dialog
    Accessible.name: qsTr("Search")

    readonly property int _headerHeight: 64
    readonly property var _springish: [0.16, 1, 0.3, 1, 1, 1]

    // ---- open / close ------------------------------------------------------
    onOpenChanged: {
        if (open) {
            closeAnim.stop();
            _prepare();
            openAnim.restart();
        } else {
            openAnim.stop();
            closeAnim.restart();
        }
    }
    Component.onCompleted: if (open) { _prepare(); openAnim.restart(); }

    function _prepare() {
        if (field.text !== "") field.text = "";   // searches "" via onTextChanged
        else Services.launcher.search("");
        if (body.item) body.item.reset();
        field.forceActiveFocus(Qt.OtherFocusReason);
        // The frame may make the surface visible after this handler runs;
        // invisible items can't take focus, so retry before the next frame.
        Qt.callLater(() => { if (root.open && !field.activeFocus) field.forceActiveFocus(Qt.OtherFocusReason); });
    }
    function close() { ShellState.launcherOpen = false; }

    function _activateResult(index, secondary) {
        if (index < 0 || index >= Services.launcher.results.count) return;
        if (secondary) {
            // TODO(Services): activateSecondary(index): open the file's
            // location / app details (spec §Launcher). Logged until it exists.
            if (typeof Services.launcher.activateSecondary === "function")
                Services.launcher.activateSecondary(index);
            else {
                const r = Services.launcher.results.get(index);
                console.info("[launcher] secondary action", r.kind, r.target);
            }
        } else {
            Services.launcher.activate(index);
        }
        close();
    }
    function _activateRecent(appId) {
        Services.apps.activate(appId);
        close();
    }

    ParallelAnimation {
        id: openAnim
        NumberAnimation {
            target: stage; property: "opacity"; to: 1
            duration: Theme.reduceMotion ? Theme.durReduced : Theme.durMedium
            easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
        }
        NumberAnimation {
            target: holder; property: "scale"; from: Theme.reduceMotion ? 1 : 0.96; to: 1
            duration: Theme.durMedium
            easing.type: Easing.BezierSpline; easing.bezierCurve: root._springish
        }
        NumberAnimation {
            target: holder; property: "slide"; from: Theme.reduceMotion ? 0 : -8; to: 0
            duration: Theme.durMedium
            easing.type: Easing.BezierSpline; easing.bezierCurve: root._springish
        }
    }
    NumberAnimation {
        id: closeAnim
        target: stage; property: "opacity"; to: 0
        duration: Theme.reduceMotion ? Theme.durReduced : Theme.durSmall
        easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
    }

    // ---- scene ---------------------------------------------------------------
    Item {
        id: stage
        anchors.fill: parent
        opacity: 0
        visible: root.shown

        // Very light scrim: separates the panel from the desktop without
        // hiding it (the panel's own shadow does most of the lifting).
        Rectangle {
            anchors.fill: parent
            color: Theme.scrim
            opacity: Theme.dark ? 0.16 : 0.22
        }

        // Outside click closes.
        MouseArea {
            anchors.fill: parent
            enabled: root.open
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
            onClicked: ShellState.closeAll()
        }

        Item {
            id: holder
            property real slide: 0

            width: Math.min(root.panelWidth, root.width - 2 * Theme.space24)
            height: root._headerHeight + (divider.visible ? 1 : 0) + bodyClip.height
            x: Math.round((root.width - width) / 2)
            y: Math.round(root.height * root.topFraction) + slide
            transformOrigin: Item.Top

            GlassPanel {
                id: panel
                anchors.fill: parent
                radius: Theme.radiusXl
                elevation: "window"

                // Clicks inside the panel never reach the outside-click area.
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.AllButtons
                    onWheel: wheel => wheel.accepted = true
                }

                SearchField {
                    id: field
                    x: Theme.space4
                    y: (root._headerHeight - height) / 2
                    width: parent.width - 2 * Theme.space4
                    large: true
                    focus: true
                    placeholderText: qsTr("Search apps, files and settings")
                    busy: busyDelay.elapsed && Services.launcher.searching

                    onTextChanged: Services.launcher.search(text)

                    // Esc with text: the field clears it (SearchField), and a
                    // frame-level Esc shortcut must not steal the key.
                    Keys.onShortcutOverride: event => {
                        event.accepted = event.key === Qt.Key_Escape && field.length > 0;
                    }
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Escape) {   // only reached when empty
                            root.close();
                            event.accepted = true;
                        } else if (body.item && body.item.handleKey(event)) {
                            event.accepted = true;
                        }
                    }
                }

                // Spinner only after 300 ms of searching (spec §States).
                Timer {
                    id: busyDelay
                    property bool elapsed: false
                    interval: 300
                    running: Services.launcher.searching
                    onRunningChanged: if (running) elapsed = false
                    onTriggered: elapsed = true
                }

                Rectangle {
                    id: divider
                    y: root._headerHeight
                    width: parent.width
                    height: 1
                    color: Theme.glassBorder
                    visible: bodyClip.height > 0.5
                }

                Item {
                    id: bodyClip
                    y: root._headerHeight + 1
                    width: parent.width
                    clip: true
                    height: body.item ? body.item.targetHeight : 0
                    // Grows with the content; never under reduce motion, and
                    // not while the panel is still opening.
                    Behavior on height {
                        enabled: !Theme.reduceMotion && !openAnim.running && root.open
                        NumberAnimation {
                            duration: Theme.durSmall
                            easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
                        }
                    }

                    Loader {
                        id: body
                        width: parent.width
                        asynchronous: true
                        sourceComponent: LauncherBody {
                            query: field.text
                            results: Services.launcher.results
                            recent: Services.launcher.recent
                            searching: Services.launcher.searching
                            // Never past the bottom of a short screen.
                            maxResultsHeight: Math.max(160, Math.min(root.maxResultsHeight,
                                root.height - holder.y + holder.slide - root._headerHeight - Theme.space48))
                            onActivateResult: (index, secondary) => root._activateResult(index, secondary)
                            onActivateRecent: appId => root._activateRecent(appId)
                        }
                    }
                }
            }
        }
    }
}
