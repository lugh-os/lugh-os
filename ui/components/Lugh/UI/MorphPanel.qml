// A glass panel that grows out of an origin rect (docs/design/lugh-mode.md §2):
// the control center out of the status island, the launcher out of the center
// island, …
//
//   Item {                                   // fullscreen overlay
//       MorphPanel {
//           anchors.fill: parent
//           open: ShellState.controlCenterOpen
//           originRect: ShellState.statusIsland          // scene coords
//           targetRect: Qt.rect(parent.width - 330, 52, 320, body.implicitHeight + 24)
//           Column { id: body; x: 12; y: 12; width: parent.width - 24 }
//       }
//   }
//
// Content is parented to an item of the *target* size, pinned at its final
// scene position from the first frame, so it never reflows mid-morph; the
// growing panel reveals it (rectangular clip while moving, none at rest; keep
// ≥ 12 px padding). Content is invisible below 40% progress and fully visible
// from 85%.
//
// Opening: x/y/width/height/radius spring (Theme.liquid*) from originRect /
// originRadius to targetRect / radius. A fresh open first puts the panel at
// the origin and starts the springs only once that frame is on screen (the
// window's first frameSwapped, or 100 ms), so a window that maps late never
// skips the start of the morph. The glass fades in over the first third of
// the growth, ahead of the content, so the shape is always there first.
// Closing: durSmall ease back to the origin, fading out over the last third. Both are interruptible: reversing
// continues from the current values. A targetRect change while open glides
// with the same spring; a targetRect that changes every frame (bound to
// content whose implicitHeight is itself springing, e.g. it holds a Drawer:
// `height: body.implicitHeight + 24`) is followed directly, so the panel
// inherits that spring instead of chasing it.
// Reduce motion: no geometry animation, a 100 ms fade at targetRect.
//
// `shown` (open or still animating) is what a window's `visible` binds to;
// `progress` is the normalized size progress 0..1; `settled` is true once the
// panel rests at targetRect. The panel swallows clicks and wheel on itself,
// so an outside-click catcher can sit below it in the overlay.
import QtQuick

Item {
    id: root

    property bool open: false
    property rect originRect: Qt.rect(0, 0, 0, 0)
    property rect targetRect: Qt.rect(0, 0, 0, 0)
    property real originRadius: originRect.height / 2
    property real radius: Theme.radiusXl
    property string elevation: "popover"
    default property alias content: holder.data

    readonly property bool shown: open || _live
    readonly property real progress: !_live ? 0
        : _fadeMode ? _fade
        : _span < 1 ? (open ? 1 : 0)
        : Math.max(0, Math.min(1, (Math.abs(panel.width - originRect.width)
                                   + Math.abs(panel.height - originRect.height)) / _span))
    readonly property bool settled: open && _live && (!_fadeMode || _fade === 1)
        && panel.x === targetRect.x && panel.y === targetRect.y
        && panel.width === targetRect.width && panel.height === targetRect.height

    // ---- private ----------------------------------------------------------
    readonly property alias _panel: panel
    readonly property real _span: Math.abs(targetRect.width - originRect.width)
                                  + Math.abs(targetRect.height - originRect.height)
    property bool _live: false       // panel is on screen
    property bool _spring: false     // geometry writes go through the springs
    property bool _fadeMode: false   // reduce motion: fade at the target rect
    property real _fade: 1
    property bool _ready: false
    property bool _armed: false      // fresh open: origin set, springs wait for its frame

    function _set(r, rad, spring) {
        _spring = spring;
        panel.x = r.x; panel.y = r.y; panel.width = r.width; panel.height = r.height;
        panel.radius = rad;
    }
    function _show() {
        closeAnim.stop();
        const fresh = !_live;
        _live = true;
        if (Theme.reduceMotion || !_ready) {
            _fadeMode = Theme.reduceMotion;
            _set(targetRect, radius, false);
            if (_fadeMode) {
                if (fresh) _fade = 0;
                fadeAnim.to = 1; fadeAnim.restart();
            } else {
                _fade = 1;
            }
            return;
        }
        fadeAnim.stop();
        _fadeMode = false; _fade = 1;
        if (fresh) {
            _set(originRect, originRadius, false);
            _armed = true;
            armTimer.restart();
            return;
        }
        _armed = false;
        _set(targetRect, radius, true);
    }
    function _launch() {
        if (!_armed)
            return;
        _armed = false;
        armTimer.stop();
        if (open && _live && !_fadeMode)
            _set(targetRect, radius, !Theme.reduceMotion);
    }
    function _hide() {
        if (!_live)
            return;
        if (_armed) {          // closed before the morph began: nothing to animate
            _armed = false;
            armTimer.stop();
            _live = false;
            return;
        }
        if (Theme.reduceMotion || _fadeMode) {
            _fadeMode = true;
            fadeAnim.to = 0; fadeAnim.restart();
            return;
        }
        // Freeze the springs where they are (a write with the Behaviors off
        // stops them), then ease home.
        _set(Qt.rect(panel.x, panel.y, panel.width, panel.height), panel.radius, false);
        closeAnim.restart();
    }
    // A single change springs. A target that itself animates (bound to
    // content whose height springs, e.g. a Drawer) changes every frame, and a
    // spring restarted every frame never advances: follow it directly instead.
    property double _lastRetarget: 0
    function _retarget() {
        if (!(_ready && open && _live) || _armed)
            return;
        const now = Date.now();
        const chasing = now - _lastRetarget < 100;
        _lastRetarget = now;
        _set(targetRect, radius, !chasing && !_fadeMode && !Theme.reduceMotion);
    }

    onOpenChanged: if (_ready) { if (open) _show(); else _hide(); }
    onTargetRectChanged: _retarget()
    onRadiusChanged: _retarget()
    Component.onCompleted: { if (open) _show(); _ready = true; }

    component Liquid: SpringAnimation {
        spring: Theme.liquidSpring; damping: Theme.liquidDamping
        mass: Theme.liquidMass; epsilon: Theme.springEpsilon
    }
    component Home: NumberAnimation {
        target: panel
        duration: Theme.dur(Theme.durSmall)
        easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
    }

    ParallelAnimation {
        id: closeAnim
        Home { property: "x"; to: root.originRect.x }
        Home { property: "y"; to: root.originRect.y }
        Home { property: "width"; to: root.originRect.width }
        Home { property: "height"; to: root.originRect.height }
        Home { property: "radius"; to: root.originRadius }
        onFinished: root._live = false
    }
    Timer {
        id: armTimer
        interval: 100
        onTriggered: root._launch()
    }
    Connections {
        target: root.Window.window
        enabled: root._armed
        function onFrameSwapped() { root._launch(); }
    }

    NumberAnimation {
        id: fadeAnim
        target: root; property: "_fade"
        duration: Theme.durReduced
        onFinished: if (!root.open) root._live = false
    }

    GlassPanel {
        id: panel
        visible: root._live
        opacity: root._fadeMode ? root._fade : Math.min(1, root.progress * 3)
        radius: 0
        elevation: root.elevation

        Behavior on x { enabled: root._spring; Liquid {} }
        Behavior on y { enabled: root._spring; Liquid {} }
        Behavior on width { enabled: root._spring; Liquid {} }
        Behavior on height { enabled: root._spring; Liquid {} }
        Behavior on radius { enabled: root._spring; Liquid {} }

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onWheel: wheel => { wheel.accepted = true }
        }

        Item {
            anchors.fill: parent
            clip: !root.settled

            Item {
                id: holder
                x: root.targetRect.x - panel.x
                y: root.targetRect.y - panel.y
                width: root.targetRect.width
                height: root.targetRect.height
                opacity: root._fadeMode ? 1 : Math.max(0, Math.min(1, (root.progress - 0.4) / 0.45))
            }
        }
    }
}
