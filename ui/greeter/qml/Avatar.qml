// Round user picture: the account image when it loads, otherwise initials on
// an accent-tinted disc. Same as Lugh.Shell's lockscreen/Avatar.qml; the
// greeter keeps its own copy so it depends only on Lugh.UI. The image is
// clipped to a circle with a Shape whose fill is the image texture
// (ShapePath.fillItem, Qt 6.8), so no layer or shader is involved.
//
//   Avatar { source: Services.session.avatar; name: Services.session.realName; size: 88 }
import QtQuick
import QtQuick.Shapes
import Lugh.UI

Item {
    id: root

    property url source: ""
    property string name: ""
    property int size: 88
    // Thin ring around the picture so it reads on any wallpaper.
    property bool ring: true

    readonly property bool hasImage: source.toString() !== "" && img.status === Image.Ready
    readonly property string initials: {
        const parts = name.trim().split(/\s+/).filter(p => p.length > 0);
        if (parts.length === 0) return "";
        const first = parts[0].charAt(0);
        const last = parts.length > 1 ? parts[parts.length - 1].charAt(0) : "";
        return (first + last).toUpperCase();
    }

    implicitWidth: size
    implicitHeight: size
    Accessible.ignored: true

    // Initials fallback (also shown while the image loads).
    Rectangle {
        anchors.fill: parent
        radius: width / 2
        visible: !root.hasImage
        color: Qt.tint(Theme.surface, Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.22))
        border.width: 1
        border.color: Theme.border

        Text {
            anchors.centerIn: parent
            text: root.initials
            visible: text !== ""
            font.family: Theme.fontUi
            font.pixelSize: Math.round(root.size * 0.36)
            font.weight: 600
            color: Theme.accentText
        }
        Icon {
            anchors.centerIn: parent
            visible: root.initials === ""
            name: "user"
            size: Math.round(root.size * 0.44)
            color: Theme.accentText
        }
    }

    Image {
        id: img
        visible: false
        source: root.source
        asynchronous: true
        fillMode: Image.PreserveAspectCrop
        width: root.size
        height: root.size
        sourceSize: Qt.size(Math.ceil(root.size * Screen.devicePixelRatio), Math.ceil(root.size * Screen.devicePixelRatio))
        smooth: true
    }

    Shape {
        anchors.fill: parent
        visible: root.hasImage
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeWidth: -1
            fillItem: img
            startX: root.size / 2; startY: 0
            PathArc { x: root.size / 2; y: root.size; radiusX: root.size / 2; radiusY: root.size / 2 }
            PathArc { x: root.size / 2; y: 0; radiusX: root.size / 2; radiusY: root.size / 2 }
        }
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: -2
        radius: width / 2
        visible: root.ring
        color: "transparent"
        border.width: 2
        border.color: Theme.glassHighlight
    }
}
