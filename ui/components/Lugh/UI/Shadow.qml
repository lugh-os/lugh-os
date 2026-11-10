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
// 9-patch from assets/shadows/ (make-shadows.py). No MultiEffect, no layer,
// no shader, no offscreen pass, nothing per frame; the PNG is decoded once and
// shared by every Shadow of the same level and radius. The image has two
// layers baked in (tight contact + wide ambient, offset down by
// Theme.elevation*.y) and the shape's inside cut out, so it also works under
// translucent glass. Theme.elevation*.opacity scales it for light vs dark.
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
    // Pick the baked radius and, for targets smaller than the 9-patch's
    // corners (knobs, thin pills), a scale-down factor `fit`: the whole shadow
    // is drawn smaller (a GPU scale of the same texture, so size animations
    // never reload the image). The baked radius is chosen so that, scaled,
    // it still matches the target's corners.
    readonly property var _pick: {
        if (!_level)
            return null;
        const table = Geo.geometry[elevation];
        const nearest = r => Geo.radii.reduce((a, b) => Math.abs(b - r) < Math.abs(a - r) ? b : a);
        let bucket = nearest(_radius), fit = 1;
        for (let pass = 0; pass < 2; ++pass) {
            const g = table[bucket];
            fit = Math.min(1, width / Math.max(1, g.bl - g.ml + g.br - g.mr),
                           height / Math.max(1, g.bt - g.mt + g.bb - g.mb));
            if (fit >= 1)
                break;
            bucket = nearest(_radius / fit);
        }
        const g = table[bucket];
        fit = Math.min(1, width / Math.max(1, g.bl - g.ml + g.br - g.mr),
                       height / Math.max(1, g.bt - g.mt + g.bb - g.mb));
        return { bucket: bucket, geo: g, fit: Math.max(0.05, fit) };
    }
    readonly property int _bucket: _pick ? _pick.bucket : 0
    readonly property var _geo: _pick ? _pick.geo : null
    readonly property real _fit: _pick ? _pick.fit : 1
    readonly property bool _inside: target !== null && target === parent

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

    Item {
        width: root.width / root._fit
        height: root.height / root._fit
        scale: root._fit
        transformOrigin: Item.TopLeft

        BorderImage {
            x: root._geo ? -root._geo.ml : 0
            y: root._geo ? -root._geo.mt : 0
            width: parent.width + (root._geo ? root._geo.ml + root._geo.mr : 0)
            height: parent.height + (root._geo ? root._geo.mt + root._geo.mb : 0)
            source: root._geo ? "assets/shadows/" + root.elevation + "-r" + root._bucket + ".png" : ""
            border.left: root._geo ? root._geo.bl : 0
            border.right: root._geo ? root._geo.br : 0
            border.top: root._geo ? root._geo.bt : 0
            border.bottom: root._geo ? root._geo.bb : 0
            horizontalTileMode: BorderImage.Stretch
            verticalTileMode: BorderImage.Stretch
            opacity: root._level ? root._level.opacity : 0
            smooth: true
            cache: true
        }
    }

    Accessible.ignored: true
}
