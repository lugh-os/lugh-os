// Soft, neutral drop shadow for a rounded rect (DESIGN-SYSTEM §4: menu,
// popover and window levels). Put it as a sibling *below* the target:
//
//   Shadow { target: panel; radius: Theme.radiusLg; elevation: "popover" }
//   Rectangle { id: panel; radius: Theme.radiusLg; ... }
//
// or as a child of the target (`target: parent`): it then sits at z -1,
// under the parent's own fill.
//
// Cost: one BorderImage (9 textured quads, batched) drawing a pre-rendered
// 9-patch from assets/shadows/ (make-shadows.py); targets narrower than the
// 9-patch's corners draw it as four scissor-clipped quadrants instead. No
// MultiEffect, no layer, no shader, no offscreen pass, nothing per frame; the
// PNG is decoded once and shared by every Shadow of the same level and shape.
// The image has two layers baked in (tight contact + wide ambient, offset
// down by Theme.elevation*.y) and the shape's inside cut out, so it also
// works under translucent glass.
//
// The cut-out always matches the target's corners: rounded rects use the
// baked radius just at or above theirs (short ones a larger radius scaled
// down to theirs), pills (radius = half the height, e.g. Island) a pill baked
// at about their height, scaled uniformly. A mismatched cut-out lets the dark contact core peek out past
// the corners and reads as a second shape behind the surface.
//
// Peak alpha outside the shape is Theme.elevation*.opacity, capped at
// Theme.shadowAlphaMax so the compositor never blurs behind a shadow
// (Hyprland layer rule ignore_alpha must stay above it).
//
// The shadow follows the target's geometry, opacity, visibility and (centre
// origin) scale, so fading or scaling the target carries it along.
import QtQuick
import "assets/shadows.js" as Geo

Item {
    id: root

    property Item target: null
    property real radius: Theme.radiusMd
    property string elevation: "popover"   // menu | popover | window (none hides it)

    readonly property var _level: elevation === "menu" ? Theme.elevationMenu
        : elevation === "window" ? Theme.elevationWindow
        : elevation === "popover" ? Theme.elevationPopover : null
    // Qt clamps a Rectangle's radius to half its shorter side; do the same.
    readonly property real _radius: Math.max(0, Math.min(radius, width / 2, height / 2))
    // A horizontal pill (or circle): the radius is (nearly) half the height.
    // Up to 2 px short still counts: the pill's rounder cut-out stays under
    // the target.
    readonly property bool _pill: height > 0 && height <= width + 0.5 && _radius >= height / 2 - 2
    // Image key, its geometry and the uniform scale it is drawn at.
    readonly property var _pick: {
        if (!_level || width <= 0 || height <= 0)
            return null;
        const table = Geo.geometry[elevation];
        if (_pill) {
            const h = Geo.pills.reduce((a, b) => Math.abs(b - height) < Math.abs(a - height) ? b : a);
            return { key: "p" + h, geo: table["p" + h], scale: height / h };
        }
        // Smallest baked radius whose cut-out, at the scale that fits the
        // target's height, is at least the target's radius (a rounder
        // cut-out stays under the target; half a pixel of slack absorbs
        // springs settling). Too short for any: the largest, scaled to the
        // radius, and the 9-patch splits vertically too.
        const minH = g => g.bt - g.mt + g.bb - g.mb;
        for (const b of Geo.radii) {
            const g = table["r" + b];
            const k = Math.min(1, height / minH(g));
            if (b * k >= _radius - 0.5)
                return { key: "r" + b, geo: g, scale: k };
        }
        const b = Geo.radii[Geo.radii.length - 1];
        return { key: "r" + b, geo: table["r" + b], scale: Math.min(1, Math.max(0.05, _radius / Math.max(1, b))) };
    }
    readonly property var _geo: _pick ? _pick.geo : null
    readonly property real _scale: _pick ? _pick.scale : 1
    readonly property string _source: _pick ? "assets/shadows/" + elevation + "-" + _pick.key + ".png" : ""
    readonly property bool _inside: target !== null && target === parent

    // Target size in image px, and the smallest size the 9-patch's corners fit.
    readonly property real _fw: width / _scale
    readonly property real _fh: height / _scale
    readonly property real _minW: _geo ? _geo.bl - _geo.ml + _geo.br - _geo.mr : 0
    readonly property real _minH: _geo ? _geo.bt - _geo.mt + _geo.bb - _geo.mb : 0
    readonly property bool _split: _geo !== null && (_fw < _minW - 0.01 || _fh < _minH - 0.01)

    x: target ? (_inside ? 0 : target.x) : 0
    y: target ? (_inside ? 0 : target.y) : 0
    width: target ? target.width : 0
    height: target ? target.height : 0
    z: _inside ? -1 : 0
    visible: _geo !== null && width > 0 && height > 0
        && (!target || (target.visible && target.opacity > 0))
    opacity: target && !_inside ? target.opacity : 1
    transform: Scale {
        origin.x: root.width / 2
        origin.y: root.height / 2
        xScale: root.target && !root._inside ? root.target.scale : 1
        yScale: xScale
    }

    component Patch: BorderImage {
        source: root._source
        border.left: root._geo ? root._geo.bl : 0
        border.right: root._geo ? root._geo.br : 0
        border.top: root._geo ? root._geo.bt : 0
        border.bottom: root._geo ? root._geo.bb : 0
        horizontalTileMode: BorderImage.Stretch
        verticalTileMode: BorderImage.Stretch
        smooth: true
        cache: true
    }

    Item {
        id: frame
        width: root._fw
        height: root._fh
        scale: root._scale
        transformOrigin: Item.TopLeft
        opacity: root._level ? Math.min(root._level.opacity, Theme.shadowAlphaMax) : 0

        readonly property real ml: root._geo ? root._geo.ml : 0
        readonly property real mt: root._geo ? root._geo.mt : 0
        readonly property real mr: root._geo ? root._geo.mr : 0
        readonly property real mb: root._geo ? root._geo.mb : 0

        // Large enough: one 9-patch.
        Patch {
            visible: !root._split
            x: -frame.ml
            y: -frame.mt
            width: frame.width + frame.ml + frame.mr
            height: frame.height + frame.mt + frame.mb
        }

        // Narrower than the corners: the 9-patch drawn at its smallest size
        // four times, each clipped to one quadrant and pinned to that corner.
        // The image is left/right symmetric, so the vertical seam is exact.
        // Height is matched by the scale above (only a rect far too short for
        // its level, like a 34 px window-level bar, also splits at mid
        // height, where the halves may differ slightly).
        Repeater {
            model: root._split ? 4 : 0

            Item {
                required property int index
                readonly property bool isLeft: index % 2 === 0
                readonly property bool isTop: index < 2
                readonly property real seamX: Math.round(frame.width / 2)
                readonly property real seamY: Math.round(frame.height / 2)
                readonly property real vw: Math.max(frame.width, root._minW)
                readonly property real vh: Math.max(frame.height, root._minH)

                x: isLeft ? -frame.ml : seamX
                y: isTop ? -frame.mt : seamY
                width: isLeft ? seamX + frame.ml : frame.width + frame.mr - seamX
                height: isTop ? seamY + frame.mt : frame.height + frame.mb - seamY
                clip: true

                Patch {
                    x: (parent.isLeft ? -frame.ml : frame.width - parent.vw - frame.ml) - parent.x
                    y: (parent.isTop ? -frame.mt : frame.height - parent.vh - frame.mt) - parent.y
                    width: parent.vw + frame.ml + frame.mr
                    height: parent.vh + frame.mt + frame.mb
                }
            }
        }
    }

    Accessible.ignored: true
}
