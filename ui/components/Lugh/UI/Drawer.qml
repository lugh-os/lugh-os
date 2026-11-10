// Expand/collapse container (docs/design/lugh-mode.md §2 "Reflow").
//
//   Drawer {
//       width: parent.width
//       expanded: showOutputs
//       Column { width: parent.width; Chip { … } Slider { … } }
//   }
//
// API choice: children are ordinary items (default property → content). They
// are parented to an inner container as wide as the drawer and as tall as the
// tallest child's implicitHeight; give them `width: parent.width`. The
// container is `visible: false` while the drawer is fully collapsed, so
// collapsed content costs no rendering or input. Children are created with
// the drawer (not by a Component); for heavy content use
// `Loader { active: drawer.loaded }` — `loaded` turns true on the first
// expand and stays (always true with `lazy: false`).
//
// implicitHeight springs (liquid) between 0 and the content height, and
// glides too when the content height changes while expanded; content is
// clipped and fades. `animating` is true until both have settled. Reduce
// motion: instant height, fade only. Put it in a Column/ColumnLayout (or bind
// `height: implicitHeight`) so neighbours follow.
import QtQuick

Item {
    id: root

    property bool expanded: false
    property bool lazy: true
    default property alias content: holder.data
    readonly property bool animating: _h !== _target || holder.opacity !== (expanded ? 1 : 0)
    readonly property bool loaded: _loaded

    property bool _loaded: false
    property bool _ready: false
    readonly property real _contentH: _childMax("implicitHeight")
    readonly property real _target: expanded ? _contentH : 0
    property real _h: _target

    function _childMax(prop) {
        let m = 0;
        for (let i = 0; i < holder.children.length; ++i)
            m = Math.max(m, holder.children[i][prop] || 0);
        return m;
    }

    Behavior on _h {
        enabled: root._ready && !Theme.reduceMotion
        SpringAnimation {
            spring: Theme.liquidSpring; damping: Theme.liquidDamping
            mass: Theme.liquidMass; epsilon: Theme.springEpsilon
        }
    }

    implicitWidth: _childMax("implicitWidth")
    implicitHeight: Math.max(0, _h)
    clip: _h !== _contentH

    onExpandedChanged: if (expanded) _loaded = true
    Component.onCompleted: { _loaded = !lazy || expanded; _ready = true; }

    Item {
        id: holder
        width: root.width
        height: root._contentH
        visible: root.expanded || root._h > 0.5
        opacity: root.expanded ? 1 : 0
        Behavior on opacity {
            enabled: root._ready
            NumberAnimation {
                duration: Theme.dur(Theme.durSmall)
                easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
            }
        }
    }
}
