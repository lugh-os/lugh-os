// An Image clipped to a rounded rect, on both renderers (Qt 6.8 has no
// rounded clip).
//
//   RoundedImage { source: wallpaper; radius: Theme.radiusMd; sourceSize: Qt.size(320, 0) }
//
// GPU (rhi): the Image renders into a texture that fills a rounded Shape
// (ShapePath.fillItem, as GlassPanel draws its backdrop). Software renderer
// (QT_QUICK_BACKEND=software, low-power mode) can't fill a Shape with an
// item, so there a Canvas paints the decoded image through a rounded clip
// path. fillMode is honoured on both (Stretch, PreserveAspectFit,
// PreserveAspectCrop, Pad).
import QtQuick
import QtQuick.Shapes
import QtQuick.Window

Item {
    id: root

    property alias source: img.source
    property real radius: 0
    property alias fillMode: img.fillMode
    property alias sourceSize: img.sourceSize
    property alias asynchronous: img.asynchronous
    property alias smooth: img.smooth
    property alias mipmap: img.mipmap
    readonly property alias status: img.status
    readonly property alias progress: img.progress
    readonly property alias paintedWidth: img.paintedWidth
    readonly property alias paintedHeight: img.paintedHeight

    readonly property bool _software: GraphicsInfo.api === GraphicsInfo.Software
    // Rounded area: the item rect, or the painted image when it is smaller
    // (PreserveAspectFit / Pad), so the corners sit on the picture itself.
    readonly property rect _clip: {
        const w = Math.min(width, img.paintedWidth || width);
        const h = Math.min(height, img.paintedHeight || height);
        return Qt.rect((width - w) / 2, (height - h) / 2, w, h);
    }
    readonly property real _r: Math.max(0, Math.min(radius, _clip.width / 2, _clip.height / 2))

    implicitWidth: img.implicitWidth
    implicitHeight: img.implicitHeight
    Accessible.ignored: true

    Image {
        id: img
        anchors.fill: parent
        asynchronous: true
        fillMode: Image.PreserveAspectCrop
        // Square-cornered fallback only while the radius is 0.
        visible: root._r <= 0
    }

    // ---- GPU: texture-filled rounded Shape ---------------------------------
    ShaderEffectSource {
        id: tex
        anchors.fill: parent
        sourceItem: !root._software && root._r > 0 ? img : null
        hideSource: false
        visible: false
    }
    Loader {
        anchors.fill: parent
        active: !root._software && root._r > 0
        sourceComponent: Shape {
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeWidth: -1
                fillColor: "transparent"
                fillItem: tex
                PathRectangle { x: root._clip.x; y: root._clip.y; width: root._clip.width; height: root._clip.height; radius: root._r }
            }
        }
    }

    // ---- Software: Canvas with a rounded clip -------------------------------
    // Context2D can't draw an Image item, so the (hidden) Image is grabbed at
    // its on-screen size — fillMode already applied — and the grab is painted
    // through the clip path. Regrabbed when the image or geometry changes.
    Loader {
        anchors.fill: parent
        active: root._software && root._r > 0
        sourceComponent: Canvas {
            id: canvas
            property string grabUrl: ""
            readonly property bool _ready: img.status === Image.Ready && width > 0 && height > 0
                && root.Window.window !== null && root.Window.window.visible

            function regrab() { regrabTimer.restart(); }
            function _grab() {
                if (!_ready) {
                    if (img.status !== Image.Ready && grabUrl !== "") { unloadImage(grabUrl); grabUrl = ""; requestPaint(); }
                    return;
                }
                const dpr = root.Window.window ? root.Window.window.devicePixelRatio : 1;
                img.grabToImage(r => {
                    if (grabUrl !== "") unloadImage(grabUrl);
                    grabUrl = r.url;
                    loadImage(grabUrl);
                    requestPaint();
                }, Qt.size(Math.ceil(width * dpr), Math.ceil(height * dpr)));
            }

            on_ReadyChanged: regrab()
            onWidthChanged: regrab()
            onHeightChanged: regrab()
            onImageLoaded: requestPaint()
            Component.onCompleted: regrab()
            Component.onDestruction: if (grabUrl !== "") unloadImage(grabUrl)

            Timer { id: regrabTimer; interval: 16; onTriggered: canvas._grab() }
            Connections {
                target: img
                function onPaintedGeometryChanged() { canvas.regrab(); }
                function onSourceChanged() { canvas.regrab(); }
            }
            Connections {
                target: root
                function on_RChanged() { canvas.requestPaint(); }
            }

            onPaint: {
                const ctx = getContext("2d");
                ctx.reset();
                ctx.clearRect(0, 0, width, height);
                if (grabUrl === "" || !isImageLoaded(grabUrl))
                    return;
                const c = root._clip;
                ctx.beginPath();
                ctx.roundedRect(c.x, c.y, c.width, c.height, root._r, root._r);
                ctx.clip();
                ctx.drawImage(grabUrl, 0, 0, width, height);
            }
        }
    }
}
