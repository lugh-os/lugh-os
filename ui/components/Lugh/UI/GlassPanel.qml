// Shell glass surface (DESIGN-SYSTEM §2 shell-glass, §4): bar, dock,
// launcher, control center, notifications.
//
//   GlassPanel { radius: Theme.radiusXl; elevation: "window"; Row { ... } }
//
// Draws the Theme.glass tint, a 1 px Theme.glassBorder hairline, a 1 px inner
// top highlight (Theme.glassHighlight) and a Shadow. It never blurs: the
// compositor blurs what is behind the surface (Hyprland `layerrule = blur`).
// With Theme.transparency off it falls back to an opaque surface.
import QtQuick
import QtQuick.Shapes

Item {
    id: root

    property real radius: Theme.radiusXl
    property string elevation: "popover"   // none | menu | popover | window
    default property alias content: contentArea.data

    // Opaque surface + regular border instead of glass (Popover without
    // `glass`, and the transparency-off fallback).
    property bool _opaque: !Theme.transparency
    readonly property alias _contentArea: contentArea

    implicitWidth: _childMax("implicitWidth")
    implicitHeight: _childMax("implicitHeight")
    function _childMax(prop) {
        let m = 0;
        for (let i = 0; i < contentArea.children.length; ++i)
            m = Math.max(m, contentArea.children[i][prop] || 0);
        return m;
    }

    Shadow {
        target: fill
        radius: root.radius
        elevation: root.elevation
    }

    // Preview only (Theme.backdrop is null in production): draw the blurred
    // wallpaper under the tint, clipped to the rounded rect, to simulate the
    // compositor's layer blur. Inactive => no cost.
    Loader {
        anchors.fill: parent
        active: Theme.backdrop !== null && !root._opaque && root.visible
        sourceComponent: Shape {
            id: shape
            preferredRendererType: Shape.CurveRenderer
            property rect area: Qt.rect(0, 0, 0, 0)
            function sync() {
                if (!Theme.backdrop) return;
                const p = root.mapToItem(Theme.backdrop, 0, 0);
                area = Qt.rect(p.x, p.y, root.width, root.height);
            }
            Component.onCompleted: sync()
            Connections {
                target: root
                function onXChanged() { shape.sync(); }
                function onYChanged() { shape.sync(); }
                function onWidthChanged() { shape.sync(); }
                function onHeightChanged() { shape.sync(); }
            }
            Timer { // ancestors move too (open animations); cheap resync while visible
                interval: 32; repeat: true; running: shape.visible; onTriggered: shape.sync()
            }
            ShaderEffectSource {
                id: backdropSource
                sourceItem: Theme.backdrop
                sourceRect: shape.area
                hideSource: false
                live: true
                visible: false
            }
            ShapePath {
                strokeWidth: -1
                // Software scene graph can't draw fillItem; degrade to "no
                // backdrop" instead of the default white fill.
                fillColor: "transparent"
                fillItem: backdropSource
                PathRectangle { x: 0; y: 0; width: root.width; height: root.height; radius: root.radius }
            }
        }
    }

    Rectangle {
        id: fill
        anchors.fill: parent
        radius: root.radius
        color: root._opaque ? Theme.surface : Theme.glass
        border.width: 1
        border.color: root._opaque ? Theme.border : Theme.glassBorder
        antialiasing: true

        // Inner top highlight: a 1 px ring inset by the hairline, clipped to
        // the top so it runs along the top edge and into the corners.
        Item {
            x: 1; y: 1
            width: parent.width - 2
            height: Math.max(2, Math.min(root.radius, parent.height / 2))
            clip: true
            visible: !root._opaque

            Rectangle {
                width: parent.width
                height: fill.height - 2
                radius: Math.max(0, fill.radius - 1)
                color: "transparent"
                border.width: 1
                border.color: Theme.glassHighlight
                antialiasing: true
            }
        }
    }

    Item {
        id: contentArea
        anchors.fill: parent
    }
}
