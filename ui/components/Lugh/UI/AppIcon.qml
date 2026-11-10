// Application icon (DESIGN-SYSTEM §6): dock, launcher, notifications.
//
//   AppIcon { iconName: entry.icon; fallbackText: entry.name; size: 48 }
//
// iconName is a freedesktop icon name (resolved in the current icon theme),
// an absolute path, or a URL. Non-square artwork sits on a subtle surface
// plate; when nothing can be found, the first letter of fallbackText is drawn
// on a squircle plate. Textures are always requested at size × DPR.
import QtQuick
import QtQuick.Window
import QtQuick.Controls.impl as Impl

Item {
    id: root

    property string iconName: ""
    property int size: 48
    property string fallbackText: ""

    readonly property bool _isFile: iconName.startsWith("/") || iconName.indexOf("://") > 0
    readonly property int _px: Math.round(size * Screen.devicePixelRatio)
    readonly property Item _art: _isFile ? fileImage : themeImage
    readonly property bool found: iconName !== "" && _art.status === Image.Ready
    readonly property bool _loading: _art.status === Image.Loading
    // Wide/tall artwork (aspect off by >10%) gets the plate and an inset.
    readonly property bool _nonSquare: found && _art.implicitWidth > 0 && _art.implicitHeight > 0
        && Math.abs(_art.implicitWidth - _art.implicitHeight) > 0.1 * Math.max(_art.implicitWidth, _art.implicitHeight)

    implicitWidth: size
    implicitHeight: size
    Accessible.ignored: true

    // Plate: behind non-square art, and the letter fallback.
    Rectangle {
        anchors.fill: parent
        visible: root._nonSquare || (!root.found && !root._loading)
        radius: Math.round(root.size * 0.26)
        color: root._nonSquare ? Theme.surface : Theme.surface2
        border.width: 1
        border.color: Theme.border

        Text {
            anchors.centerIn: parent
            visible: !root._nonSquare && root.fallbackText !== ""
            text: root.fallbackText.trim().charAt(0).toUpperCase()
            color: Theme.textMuted
            font.family: Theme.fontUi
            font.weight: Font.DemiBold
            font.pixelSize: Math.max(8, Math.round(root.size * 0.46))
            Accessible.ignored: true
        }

        Icon {
            anchors.centerIn: parent
            visible: !root._nonSquare && root.fallbackText.trim() === ""
            name: "app-window"
            size: Math.round(root.size * 0.5)
            color: Theme.textMuted
        }
    }

    Impl.IconImage {
        id: themeImage
        readonly property real _inset: root._nonSquare ? root.size * 0.14 : 0
        anchors.fill: parent
        anchors.margins: _inset
        visible: !root._isFile && root.found
        name: root._isFile ? "" : root.iconName
        sourceSize: Qt.size(root._px, root._px)
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: false
    }

    Image {
        id: fileImage
        readonly property real _inset: root._nonSquare ? root.size * 0.14 : 0
        anchors.fill: parent
        anchors.margins: _inset
        visible: root._isFile && root.found
        source: !root._isFile ? "" : root.iconName.startsWith("/") ? "file://" + root.iconName : root.iconName
        sourceSize: Qt.size(root._px, root._px)
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
        mipmap: false
        cache: true
    }
}
