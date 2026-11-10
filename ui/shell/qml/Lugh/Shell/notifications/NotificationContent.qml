// The body of one notification, shared by toasts and notification-center
// cards: summary (with a `circle-alert` glyph when critical), body in a safe
// markup subset, optional image thumbnail, and action buttons.
// Internal to notifications/ (not exported in the qmldir).
import QtQuick
import QtQuick.Layouts
import Lugh.UI
import Lugh.Shell
import "notify.js" as N

ColumnLayout {
    id: root

    property int nid: -1
    property string summary: ""
    property string body: ""
    property int urgency: 1
    property string actions: "[]"
    property string image: ""
    property int bodyLines: 2
    // Room kept free at the end of the summary line (e.g. for a close button).
    property real summaryTrailing: 0
    // Pushes the thumbnail down (e.g. below a time label in the corner).
    property real imageTopMargin: 0

    readonly property bool critical: urgency === 2
    readonly property var _actions: N.parseActions(actions)

    spacing: Theme.space8

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.space12

        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignTop
            spacing: Theme.space2

            RowLayout {
                Layout.fillWidth: true
                Layout.rightMargin: root.summaryTrailing
                spacing: Theme.space4
                visible: root.summary !== ""

                Icon {
                    visible: root.critical
                    name: "circle-alert"
                    size: 16
                    color: Theme.danger
                    Layout.alignment: Qt.AlignTop
                    Layout.topMargin: 1
                }
                Text {
                    Layout.fillWidth: true
                    text: root.summary
                    font: Theme.typeBodyStrong
                    color: Theme.text
                    elide: Text.ElideRight
                    maximumLineCount: 2
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    lineHeight: Theme.lineHeading
                }
            }

            Text {
                id: bodyText
                Layout.fillWidth: true
                visible: root.body !== ""
                text: N.bodyMarkup(root.body)
                textFormat: Text.StyledText
                font: Theme.typeBody
                color: Theme.textMuted
                linkColor: Theme.accentText
                wrapMode: Text.Wrap
                maximumLineCount: root.bodyLines
                elide: Text.ElideRight
                lineHeight: 1.3
                onLinkActivated: link => Qt.openUrlExternally(link)

                HoverHandler {
                    cursorShape: bodyText.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
                }
            }
        }

        // Thumbnail (image-path / image-data). Square-cropped, decoded at size.
        Rectangle {
            visible: root.image !== "" && thumb.status !== Image.Error
            Layout.preferredWidth: 48
            Layout.preferredHeight: 48
            Layout.alignment: Qt.AlignTop
            Layout.topMargin: root.imageTopMargin
            radius: Theme.radiusSm
            color: Theme.surface2
            border.width: 1
            border.color: Theme.glassBorder

            Image {
                id: thumb
                anchors.fill: parent
                anchors.margins: 1
                source: root.image
                sourceSize: Qt.size(96, 96)
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                smooth: true
            }
        }
    }

    Flow {
        Layout.fillWidth: true
        Layout.topMargin: Theme.space4
        visible: root._actions.length > 0
        spacing: Theme.space8

        Repeater {
            model: root._actions
            Button {
                required property var modelData
                text: modelData.label
                size: "sm"
                variant: "secondary"
                onClicked: Services.notifications.invokeAction(root.nid, modelData.key)
            }
        }
    }
}
