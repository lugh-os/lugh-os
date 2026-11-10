// Control center (quick settings): a full-screen overlay surface with a 360 px
// glass panel at the top right, under the bar.
//
//   ControlCenter { anchors.fill: parent }    // frame maps it while `shown`
//
// Opens on ShellState.controlCenterOpen. Esc goes back from a sub-page, then
// closes; a click outside the panel closes (ShellState.closeAll()).
//
// Pages: the main page (tiles, sliders, media, footer) is always loaded while
// the surface exists; Wi-Fi / Bluetooth / Sound are Loaders, created when
// opened and dropped once the slide back has finished. Sub-pages slide in
// from the right (durMedium); under reduce motion they cross-fade. The panel
// height follows the current page with the same easing.
//
// Performance: no layer / MultiEffect; slider moves call the Services setters
// directly; nothing polls. The dark-mode switch cross-fades from a one-off
// snapshot of the panel (grabToImage), so the theme change reads as one fade
// instead of each color snapping on its own.
import QtQuick
import QtQuick.Window
import Lugh.UI
import Lugh.Shell

FocusScope {
    id: root

    // ---- surface contract ----------------------------------------------------
    readonly property bool open: ShellState.controlCenterOpen
    // Open, or still fading out: the frame keeps the layer mapped while true.
    readonly property bool shown: open || glass.opacity > 0
    readonly property bool wantsKeyboard: open

    // ---- geometry --------------------------------------------------------------
    property int topMargin: 30 + Theme.space4 + Theme.space2      // bar + 6
    property int rightMargin: Theme.space8
    readonly property int panelWidth: 360
    readonly property int padding: 12
    // The panel in root coordinates (scale/opacity aside), for glass backdrops.
    readonly property rect panelRect: Qt.rect(frame.x, frame.y, frame.width, frame.height)
    readonly property Item panel: glass

    // ---- state -----------------------------------------------------------------
    // "main" | "wifi" | "bluetooth" | "sound"
    readonly property string page: _page
    // Wi-Fi page: the network whose row is expanded (password / disconnect) and
    // the one we last tried to connect to (errors show inline in its row).
    property string wifiExpandedSsid: ""
    property string wifiAttemptSsid: ""

    property string _page: "main"
    property string _sub: ""          // loaded sub-page, kept while sliding out
    property bool _instant: true      // jump instead of animating (while hidden)
    property bool _themeBusy: false
    readonly property int _gutter: 6  // room for focus rings inside the clip

    // 0 = main page, 1 = sub-page; drives both slides.
    property real _p: _page === "main" ? 0 : 1
    Behavior on _p {
        enabled: !root._instant
        NumberAnimation { duration: Theme.dur(Theme.durMedium); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard }
    }
    on_PChanged: if (_p === 0 && _page === "main") _sub = ""

    focus: true
    Accessible.role: Accessible.Pane
    Accessible.name: qsTr("Control center")

    // ---- API -------------------------------------------------------------------
    function openPage(name, viaKeyboard) {
        if (name === "main") { back(viaKeyboard); return; }
        _sub = name;
        _page = name;
        // after the page's lists have their rows
        Qt.callLater(() => { if (root._page === name && sub.item) sub.item.focusFirst(viaKeyboard === true); });
    }
    function back(viaKeyboard) {
        if (_page === "main") return;
        const from = _page;
        _page = "main";
        const o = main.opener(from);
        if (o) o.forceActiveFocus(viaKeyboard ? Qt.TabFocusReason : Qt.OtherFocusReason);
    }
    function close() { ShellState.closeAll(); }
    // Keyboard focus (with ring) on the first control of the current page,
    // e.g. when the frame opened the panel from a shortcut.
    function focusFirst() {
        if (_page === "main") main.focusFirst(true);
        else if (sub.item) sub.item.focusFirst(true);
    }
    function showPowerModes() { main.showPowerModes(); }

    // Switches the theme and cross-fades the panel from a snapshot of how it
    // looked before (one offscreen grab, no live layer).
    function setDarkAnimated(on) {
        if (_themeBusy || Services.appearance.dark === on) return;
        const dpr = Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1;
        _themeBusy = true;
        const ok = glass.grabToImage(result => {
            snapshot.source = result.url;
            snapshot.opacity = 1;
            Services.appearance.setDark(on);
            snapshotFade.restart();
        }, Qt.size(Math.ceil(glass.width * dpr), Math.ceil(glass.height * dpr)));
        if (!ok) {
            _themeBusy = false;
            Services.appearance.setDark(on);
        }
    }

    // ---- open / close ------------------------------------------------------------
    function _enter() {
        exitAnim.stop();
        if (glass.opacity === 0) {
            // State was reset when it last finished closing (or is fresh), so a
            // page opened just before (openPage("wifi") then open) is kept.
            glass.scale = Theme.reduceMotion ? 1 : 0.96;
            slide.y = Theme.reduceMotion ? 0 : -Theme.space4;
        }
        enterAnim.restart();
        Qt.callLater(() => { if (root.open) root._instant = false; });
    }
    function _exit() {
        enterAnim.stop();
        exitAnim.restart();
    }
    function _reset() {
        _instant = true;
        _page = "main";
        _sub = "";
        wifiExpandedSsid = "";
        main.reset();
    }

    onOpenChanged: open ? _enter() : _exit()
    Component.onCompleted: if (open) _enter()

    Keys.onEscapePressed: event => {
        if (_page !== "main") back(true);
        else close();
        event.accepted = true;
    }

    ParallelAnimation {
        id: enterAnim
        NumberAnimation {
            target: glass; property: "opacity"; to: 1
            duration: Theme.dur(Theme.durMedium)
            easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
        }
        NumberAnimation {
            target: glass; property: "scale"; to: 1
            duration: Theme.dur(Theme.durMedium)
            easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
        }
        NumberAnimation {
            target: slide; property: "y"; to: 0
            duration: Theme.dur(Theme.durMedium)
            easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
        }
    }
    NumberAnimation {
        id: exitAnim
        target: glass; property: "opacity"; to: 0
        duration: Theme.dur(Theme.durSmall)
        easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
        onFinished: root._reset()
    }

    // ---- wifi bookkeeping ----------------------------------------------------------
    Connections {
        target: Services.network
        function onConnectingSsidChanged() {
            const n = Services.network;
            if (n.connectingSsid !== "" || n.lastError !== "" || root.wifiAttemptSsid === "") return;
            if (n.connected && n.ssid === root.wifiAttemptSsid) {
                if (root.wifiExpandedSsid === root.wifiAttemptSsid) root.wifiExpandedSsid = "";
                root.wifiAttemptSsid = "";
            }
        }
    }

    // ---- outside click closes ----------------------------------------------------------
    MouseArea {
        anchors.fill: parent
        enabled: root.open
        acceptedButtons: Qt.AllButtons
        onPressed: root.close()
    }

    // ---- panel ---------------------------------------------------------------------------
    Item {
        id: frame
        x: root.width - root.rightMargin - width
        y: root.topMargin
        width: root.panelWidth

        readonly property real maxH: Math.max(200, root.height - root.topMargin - Theme.space16)
        readonly property real contentH: root._page === "main" ? main.implicitHeight
                                       : sub.item ? sub.item.implicitHeight : main.implicitHeight
        height: Math.min(contentH + 2 * root.padding, maxH)
        Behavior on height {
            enabled: !root._instant
            NumberAnimation { duration: Theme.dur(Theme.durMedium); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard }
        }

        GlassPanel {
            id: glass
            anchors.fill: parent
            radius: Theme.radiusXl
            elevation: "popover"
            opacity: 0
            visible: opacity > 0
            transformOrigin: Item.TopRight
            transform: Translate { id: slide }

            // Swallows clicks so they don't reach the outside-click catcher.
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                onWheel: wheel => wheel.accepted = true
            }

            Item {
                id: viewport
                anchors.fill: parent
                anchors.margins: root.padding - root._gutter
                clip: true

                MainPage {
                    id: main
                    cc: root
                    x: root._gutter - (Theme.reduceMotion ? 0 : root._p * viewport.width * 0.3)
                    y: root._gutter
                    width: viewport.width - 2 * root._gutter
                    opacity: 1 - root._p
                    visible: root._p < 1
                    enabled: root._page === "main"
                    focus: root._page === "main"
                }

                Loader {
                    id: sub
                    x: root._gutter + (Theme.reduceMotion ? 0 : (1 - root._p) * viewport.width)
                    y: root._gutter
                    width: viewport.width - 2 * root._gutter
                    opacity: Theme.reduceMotion ? root._p : Math.min(1, root._p * 2)
                    visible: root._p > 0
                    enabled: root._page !== "main"
                    focus: root._page !== "main"
                    active: root._sub !== ""
                    sourceComponent: root._sub === "wifi" ? wifiPage
                                   : root._sub === "bluetooth" ? bluetoothPage
                                   : root._sub === "sound" ? soundPage : null
                }
            }
        }

        // Old-theme snapshot, faded out over the new theme (see setDarkAnimated).
        Image {
            id: snapshot
            anchors.fill: parent
            opacity: 0
            visible: opacity > 0 && source.toString() !== ""
            cache: false
            smooth: true
            Accessible.ignored: true
        }
        NumberAnimation {
            id: snapshotFade
            target: snapshot; property: "opacity"; from: 1; to: 0
            duration: Theme.dur(Theme.durLarge)
            easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
            onFinished: { snapshot.source = ""; root._themeBusy = false; }
        }
    }

    Component { id: wifiPage; WifiPage { cc: root; maxHeight: frame.maxH - 2 * root.padding } }
    Component { id: bluetoothPage; BluetoothPage { cc: root; maxHeight: frame.maxH - 2 * root.padding } }
    Component { id: soundPage; SoundPage { cc: root; maxHeight: frame.maxH - 2 * root.padding } }
}
