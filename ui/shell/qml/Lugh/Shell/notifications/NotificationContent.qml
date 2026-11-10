// The detail of one notification, shown when its capsule expands (toasts and
// notification-center cards): body in a safe markup subset (≤ bodyLines),
// optional image thumbnail, and up to three action buttons on one row (long
// labels share the width and elide).
// Laid out by hand, not with positioners: implicitHeight is right as soon as
// the item exists, also in a window that is not mapped yet.
// Internal to notifications/ (not exported in the qmldir).
import QtQuick
import Lugh.UI
import Lugh.Shell
import "notify.js" as N

Item {
    id: root

    property int nid: -1
    property string body: ""
    property string actions: "[]"
    property string image: ""
    property int bodyLines: 3
    // The notification center lists the "default" action as a button; on a
    // toast it is the click on the toast.
    property bool includeDefault: false
    property real bottomPadding: Theme.space12

    readonly property var _actions: includeDefault ? N.parseActionsWithDefault(actions, qsTr("Open"))
                                                   : N.parseActions(actions)
    readonly property bool _hasThumb: image !== "" && thumb.status !== Image.Error
    readonly property bool _hasBody: body !== ""
    readonly property real _topH: Math.max(_hasBody ? bodyText.implicitHeight : 0, _hasThumb ? thumbFrame.height : 0)
    readonly property real _actionsH: _actions.length > 0 ? 28 : 0
    readonly property bool empty: !_hasBody && !_hasThumb && _actions.length === 0

    implicitHeight: empty ? 0
        : _topH + (_topH > 0 && _actionsH > 0 ? Theme.space8 : 0) + _actionsH + bottomPadding

    Text {
        id: bodyText
        width: root.width - (root._hasThumb ? thumbFrame.width + Theme.space12 : 0)
        visible: root._hasBody
        text: N.bodyMarkup(root.body)
        textFormat: Text.StyledText
        font: Theme.typeCaption
        color: Theme.textMuted
        linkColor: Theme.accentText
        wrapMode: Text.Wrap
        maximumLineCount: root.bodyLines
        elide: Text.ElideRight
        lineHeight: 1.35
        onLinkActivated: link => Qt.openUrlExternally(link)

        HoverHandler {
            cursorShape: bodyText.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
        }
    }

    // Thumbnail (image-path / image-data). Square-cropped, decoded at size;
    // gone when the image fails to load.
    Rectangle {
        id: thumbFrame
        visible: root._hasThumb
        anchors.right: parent.right
        width: 40
        height: 40
        radius: Theme.radiusSm
        color: Theme.surface2
        border.width: 1
        border.color: Theme.glassBorder

        Image {
            id: thumb
            anchors.fill: parent
            anchors.margins: 1
            source: root.image
            sourceSize: Qt.size(80, 80)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
        }
    }

    Item {
        id: actionRow
        y: root._topH + (root._topH > 0 ? Theme.space8 : 0)
        width: parent.width
        height: root._actionsH
        visible: root._actions.length > 0

        readonly property var widths: {
            const nat = [];
            for (let i = 0; i < buttons.count; ++i) {
                const b = buttons.itemAt(i);
                nat.push(b ? b.implicitWidth : 0);
            }
            return N.fitWidths(nat, width, Theme.space8);
        }
        function xOf(i) {
            let x = 0;
            for (let k = 0; k < i && k < widths.length; ++k) x += widths[k] + Theme.space8;
            return x;
        }

        Repeater {
            id: buttons
            model: root._actions
            Button {
                required property var modelData
                required property int index
                x: actionRow.xOf(index)
                anchors.verticalCenter: parent.verticalCenter
                width: index < actionRow.widths.length ? actionRow.widths[index] : implicitWidth
                text: modelData.label
                size: "sm"
                variant: index === 0 && root.includeDefault && modelData.key === "default" ? "primary" : "secondary"
                onClicked: Services.notifications.invokeAction(root.nid, modelData.key)
            }
        }
    }
}
