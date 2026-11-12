// Notification toasts (docs/design/lugh-mode.md §3): compact floating glass
// capsules in the top-right corner of the screen, up to 3, newest on top,
// 8 px apart. Nothing here assumes a top bar.
// Content-sized: the frame anchors this item top-right (its window adds a
// small top padding, padTop, and 10 px on the right) and sizes its layer
// window from implicitWidth / implicitHeight,
// which include a small margin on the left and below for the shadows
// (`padLeft`, `padBottom`: input-transparent, see `inputRects`).
//
// Form
//   - collapsed: one 46 px row (app icon, summary, relative time), radius =
//     height / 2. Hover, keyboard focus or critical urgency expand a toast
//     liquidly to its body (≤ 3 lines), thumbnail, actions and a close button.
//   - enter: drops in from the top-right on the liquid spring; leave: fades
//     and slides right; the others reflow on the same spring.
//   - critical: danger `circle-alert` + a thin danger outline; always expanded.
//   - more than 3: a small "+N" capsule under the stack opens the center.
//
// Behaviour
//   - normal/low toasts expire after 5 s (Services.notifications.expire: the
//     notification stays in history); the timers pause while the pointer is
//     over the stack. Critical toasts stay until dismissed.
//   - the close button dismisses (gone from history too); swiping a toast to
//     the right expires it (it stays in the notification center).
//   - a "default" action (freedesktop) is invoked by clicking the toast.
//   - while the notification center is open the stack hides; normal toasts
//     expire into it, critical ones return when it closes.
//
// Contract for the frame
//   shown        true while any toast is visible or animating out
//   hiddenCount  toasts beyond the third
//   paused       expiry timers are held (pointer over the stack / center open)
//   inputRects   [rect] in this item's coordinates: the toasts and the "+N"
//                capsule at their resting size, for the window's input mask
//   implicitHeight follows the *resting* stack height at once when it grows
//   and after the motion when it shrinks: one resize per change, none per frame.
import QtQuick
import Lugh.UI
import Lugh.Shell
import "notify.js" as N

Item {
    id: root

    readonly property int toastWidth: 320
    readonly property int maxVisible: 3
    readonly property int timeoutMs: 5000
    readonly property int collapsedHeight: 46
    readonly property int gap: Theme.space8
    // Shadow room ("menu" level reaches 15 px left, 17 px below). Right and
    // top fall into the frame's padding (padRight / padTop).
    readonly property int padLeft: 14
    readonly property int padBottom: 18
    // Demo / tests: keep the newest toast expanded.
    property bool forceExpanded: false

    readonly property ListModel _model: Services.notifications.popups
    readonly property bool shown: (_model.count > 0 || _heldHeight > 0) && (!_centerOpen || opacity > 0)
    readonly property int hiddenCount: Math.max(0, _model.count - maxVisible)
    readonly property bool paused: stackHover.hovered || _centerOpen
    property var inputRects: []

    // While the notification center is open the toasts step aside: normal
    // ones expire into it, critical ones come back when it closes.
    readonly property bool _centerOpen: ShellState.notificationCenterOpen
    on_CenterOpenChanged: {
        if (_centerOpen) {
            const ids = [];
            for (let i = 0; i < _model.count; ++i) if (_model.get(i).urgency !== 2) ids.push(_model.get(i).nid);
            for (const id of ids) Services.notifications.expire(id);
        }
        _relayout();
    }
    opacity: _centerOpen ? 0 : 1
    Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durSmall) } }

    implicitWidth: padLeft + toastWidth
    implicitHeight: _heldHeight > 0 ? _heldHeight + padBottom : 0

    // ---- relative times: one shared timer ---------------------------------
    property double _now: Date.now()
    Timer {
        interval: 30000
        repeat: true
        running: root.shown
        onTriggered: root._now = Date.now()
    }

    // ---- resting geometry: window height and input mask -------------------
    property real _restHeight: 0
    property real _heldHeight: 0
    function _relayout() { Qt.callLater(_layout); }
    function _layout() {
        const n = Math.min(_model.count, maxVisible), rects = [];
        let y = 0;
        for (let i = 0; i < n; ++i) {
            const it = list.itemAtIndex(i);
            const h = it ? it.restHeight : collapsedHeight;
            rects.push(Qt.rect(padLeft, y, toastWidth, h));
            y += h + gap;
        }
        if (hiddenCount > 0) {
            rects.push(Qt.rect(padLeft + toastWidth - more.width, y, more.width, more.height));
            y += more.height + gap;
        }
        _restHeight = n > 0 ? y - gap : 0;
        inputRects = _centerOpen ? [] : rects;
    }
    on_RestHeightChanged: {
        if (_restHeight >= _heldHeight) { _heldHeight = _restHeight; _shrink.stop(); }
        else _shrink.restart();
    }
    Timer {     // shrink once the leave / collapse motion is over
        id: _shrink
        interval: Theme.reduceMotion ? Theme.durReduced + 40 : 480
        onTriggered: root._heldHeight = root._restHeight
    }
    Connections {
        target: root._model
        function onCountChanged() { root._relayout(); }
    }

    function _announce(text) {
        if (typeof announcer.Accessible.announce === "function")
            announcer.Accessible.announce(text);
    }
    Item { id: announcer; Accessible.role: Accessible.StaticText; Accessible.name: "" }

    HoverHandler { id: stackHover }

    component Liquid: SpringAnimation {
        spring: Theme.liquidSpring; damping: Theme.liquidDamping
        mass: Theme.liquidMass; epsilon: Theme.springEpsilon
    }
    component Fade: NumberAnimation {
        duration: Theme.dur(Theme.durSmall)
        easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
    }

    ListView {
        id: list
        x: root.padLeft
        width: root.toastWidth
        // Never sized from contentHeight: a 0-high view would create no
        // delegates. The root's implicitHeight follows the stack instead.
        height: Math.max(contentHeight, 600)
        interactive: false
        boundsBehavior: Flickable.StopAtBounds
        model: root._model
        cacheBuffer: 0

        remove: Transition {
            ParallelAnimation {
                Fade { property: "opacity"; to: 0 }
                NumberAnimation {
                    property: "x"
                    to: Theme.reduceMotion ? 0 : 40
                    duration: Theme.dur(Theme.durMedium)
                    easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
                }
            }
        }
        // The stack reflows on the liquid spring.
        displaced: Theme.reduceMotion ? null : reflow
        Transition {
            id: reflow
            ParallelAnimation {
                Liquid { property: "y" }
                // Finish an interrupted remove cleanly.
                Fade { property: "opacity"; to: 1 }
                Fade { property: "x"; to: 0 }
            }
        }

        delegate: Item {
            id: toast

            required property int index
            required property int nid
            required property string appName
            required property string appIcon
            required property string summary
            required property string body
            required property int urgency
            required property double time
            required property string actions
            required property string image

            readonly property bool inStack: index >= 0 && index < root.maxVisible
            readonly property bool critical: urgency === 2
            readonly property bool hasDefault: N.hasDefaultAction(actions)
            readonly property real restHeight: card.targetHeight

            width: ListView.view ? ListView.view.width : root.toastWidth
            height: inStack ? card.height + root.gap : 0
            z: -index
            onRestHeightChanged: root._relayout()

            // Enter: drop in from the top-right. Done here, not as a ListView
            // `add` transition: ListView ignores height changes of delegates
            // in an add transition, which left toasts overlapping.
            ParallelAnimation {
                id: enter
                Liquid { target: slot; property: "x"; from: 28; to: 0 }
                Liquid { target: slot; property: "y"; from: -22; to: 0 }
                Liquid { target: slot; property: "scale"; from: 0.9; to: 1; epsilon: 0.001 }
                Fade { target: slot; property: "opacity"; from: 0; to: 1 }
            }
            Fade { id: enterFade; target: slot; property: "opacity"; from: 0; to: 1 }

            Component.onCompleted: {
                if (Theme.reduceMotion) enterFade.start(); else enter.start();
                root._relayout();
                if (index === 0) root._announce((critical ? qsTr("Urgent notification from %1: %2") : qsTr("Notification from %1: %2"))
                               .arg(appName).arg(summary !== "" ? summary : N.plain(body)));
            }

            Timer {
                interval: root.timeoutMs
                running: toast.inStack && !toast.critical && !root.paused && !swipe.active
                onTriggered: Services.notifications.expire(toast.nid)
            }

            HoverHandler { id: toastHover }

            // Moved by the enter animation; the card inside moves on swipe.
            Item {
                id: slot
                width: parent.width
                height: card.height
                opacity: 0
                transformOrigin: Item.TopRight

                NotificationCard {
                    id: card
                    width: parent.width
                    height: implicitHeight
                    glass: true
                    collapsedHeight: root.collapsedHeight
                    nid: toast.nid
                    appName: toast.appName
                    appIcon: toast.appIcon
                    summary: toast.summary
                    body: toast.body
                    urgency: toast.urgency
                    time: toast.time
                    actions: toast.actions
                    image: toast.image
                    now: root._now
                    expanded: toast.critical || toastHover.hovered || activeFocus || swipe.active
                              || (root.forceExpanded && toast.index === 0)
                    closeVisible: expanded
                    hovered: toast.hasDefault && toastHover.hovered
                    pressed: tap.pressed
                    onCloseRequested: Services.notifications.dismiss(toast.nid)

                    Accessible.role: Accessible.AlertMessage

                    // Beyond the 3rd: fade out in place (it is at the bottom).
                    opacity: (toast.inStack ? 1 : 0) * Math.max(0, 1 - Math.max(0, x) / 200)
                    visible: opacity > 0
                    Behavior on opacity {
                        enabled: !swipe.active
                        Fade {}
                    }

                    // Swipe right to send it to the notification center.
                    DragHandler {
                        id: swipe
                        target: card
                        yAxis.enabled: false
                        xAxis.minimum: 0
                        xAxis.maximum: root.toastWidth
                        onActiveChanged: {
                            if (active) return;
                            if (card.x > 96) swipeOut.start();
                            else if (Theme.reduceMotion) card.x = 0;
                            else settle.start();
                        }
                    }
                    Liquid { id: settle; target: card; property: "x"; to: 0 }
                    SequentialAnimation {
                        id: swipeOut
                        Fade { target: card; property: "x"; to: root.toastWidth * 0.75 }
                        ScriptAction { script: Services.notifications.expire(toast.nid) }
                    }
                    TapHandler {
                        id: tap
                        enabled: toast.hasDefault
                        cursorShape: Qt.PointingHandCursor
                        onTapped: Services.notifications.invokeAction(toast.nid, "default")
                    }
                }
            }
        }
    }

    // ---- "+N" ------------------------------------------------------------
    Island {
        id: more
        readonly property bool wanted: root.hiddenCount > 0
        x: root.padLeft + root.toastWidth - width
        y: list.contentHeight
        height: 28
        padding: Theme.space12
        spacing: Theme.space4
        animateWidth: false
        opacity: wanted ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { Fade {} }
        onWidthChanged: root._relayout()

        text: qsTr("%n more notification(s), open the notification center", "", root.hiddenCount)
        onClicked: if (!ShellState.notificationCenterOpen) ShellState.toggleNotificationCenter()

        Icon { name: "bell"; size: 14; color: Theme.textMuted; anchors.verticalCenter: parent.verticalCenter }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: qsTr("+%1 more").arg(root.hiddenCount)
            font: Theme.typeCaptionTnum
            color: Theme.text
        }
    }
}
