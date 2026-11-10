// Preview-only glass simulation: draws the part of `source` (a full-scene,
// pre-blurred wallpaper) that lies under this item, with rounded corners —
// what Hyprland's layer blur would show behind a glass surface. No
// MultiEffect: one ShaderEffectSource (re-rendered only when the wallpaper
// changes), drawn directly when square, else used as a Shape fill (Qt 6.8
// ShapePath.fillItem + PathRectangle) for rounded corners. The Shape fill
// needs the GPU (RHI) scene graph: under QT_QPA_PLATFORM=offscreen (software
// renderer) rounded backdrops don't draw, square ones do.
import QtQuick
import QtQuick.Shapes

Item {
    id: root
    // Full-scene item (at scene 0,0) holding the blurred wallpaper.
    property Item source
    property real radius: 0
    // Top-left of this item in `source` coordinates. The caller binds this
    // (mapToItem isn't reactive).
    property point sourcePos: Qt.point(x, y)

    ShaderEffectSource {
        id: tex
        anchors.fill: parent
        visible: root.radius <= 0
        sourceItem: root.source
        sourceRect: Qt.rect(root.sourcePos.x, root.sourcePos.y, root.width, root.height)
        textureSize: Qt.size(Math.max(1, root.width), Math.max(1, root.height))
    }
    Shape {
        anchors.fill: parent
        visible: root.radius > 0
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeWidth: -1
            fillColor: "transparent"
            fillItem: tex
            PathRectangle {
                width: root.width
                height: root.height
                radius: root.radius
            }
        }
    }
}
