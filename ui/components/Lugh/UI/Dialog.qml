// Modal dialog (API.md): 400 px wide, radiusLg, title (typeTitle3), body,
// optional extra content, inline error, and a secondary + primary button.
//
//   Dialog {
//       title: qsTr("Delete “Photos”?")
//       text: qsTr("The bottle and its apps are removed. This can’t be undone.")
//       primaryText: qsTr("Delete"); danger: true
//       onAccepted: busy = true        // stays open while busy; close() when done
//   }
//
// accepted() is emitted by the primary button or Enter. The dialog then
// closes, unless a handler set `busy` (async work: the caller closes it, or
// sets errorText and clears busy). rejected() is emitted by the secondary
// button or Esc, and closes it. While busy both actions are disabled and the
// primary button shows a spinner. Outside clicks do nothing (modal).
import QtQuick
import QtQuick.Layouts
import QtQuick.Templates as T

T.Dialog {
    id: control

    property string text: ""
    property string primaryText: qsTr("OK")
    property string secondaryText: qsTr("Cancel")
    property bool danger: false
    property bool busy: false
    property string errorText: ""
    // Extra content between the body and the buttons (sized by its
    // implicitHeight; give it `width: parent.width`).
    default property alias extraContent: extraArea.data

    function _accept() {
        if (busy)
            return;
        result = T.Dialog.Accepted;
        accepted();
        if (!busy)
            close();
    }
    function _reject() {
        if (busy)
            return;
        result = T.Dialog.Rejected;
        rejected();
        close();
    }

    parent: T.Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(400, (parent ? parent.width : 400) - 2 * Theme.space24)
    implicitHeight: implicitContentHeight + topPadding + bottomPadding

    modal: true
    focus: true
    closePolicy: T.Popup.NoAutoClose
    padding: Theme.space24

    T.Overlay.modal: Rectangle {
        color: Theme.scrim
        Behavior on opacity {
            NumberAnimation { duration: Theme.dur(Theme.durMedium) }
        }
    }

    background: GlassPanel {
        radius: Theme.radiusLg
        elevation: "window"
        _opaque: true
    }

    contentItem: FocusScope {
        focus: true
        implicitWidth: layout.implicitWidth
        implicitHeight: layout.implicitHeight

        Keys.onEscapePressed: event => { event.accepted = true; control._reject() }
        Keys.onReturnPressed: event => { event.accepted = true; control._accept() }
        Keys.onEnterPressed: event => { event.accepted = true; control._accept() }

        ColumnLayout {
            id: layout
            anchors.fill: parent
            spacing: 0

            Text {
                Layout.fillWidth: true
                visible: text !== ""
                text: control.title
                font: Theme.typeTitle3
                lineHeight: lineCount > 1 ? Theme.lineHeading : 1
                color: Theme.text
                wrapMode: Text.Wrap
                Accessible.role: Accessible.Heading
                Accessible.name: text
            }

            Text {
                Layout.fillWidth: true
                Layout.topMargin: control.title !== "" ? Theme.space8 : 0
                visible: text !== ""
                text: control.text
                font: Theme.typeBody
                lineHeight: lineCount > 1 ? Theme.lineBody : 1
                color: Theme.textMuted
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }

            Item {
                id: extraArea
                Layout.fillWidth: true
                // Hidden children take no room: no height and no margin (the
                // area itself stays visible so children can report `visible`).
                Layout.topMargin: implicitHeight > 0 ? Theme.space16 : 0
                implicitHeight: {
                    let h = 0;
                    for (let i = 0; i < children.length; ++i)
                        if (children[i].visible)
                            h = Math.max(h, children[i].implicitHeight);
                    return h;
                }
            }

            RowLayout {
                id: errorRow
                Layout.fillWidth: true
                Layout.topMargin: Theme.space16
                visible: control.errorText !== ""
                spacing: Theme.space8

                Icon {
                    Layout.alignment: Qt.AlignTop
                    Layout.topMargin: 1
                    name: "circle-alert"
                    size: 18
                    color: Theme.danger
                }
                Text {
                    Layout.fillWidth: true
                    text: control.errorText
                    font: Theme.typeBody
                    lineHeight: lineCount > 1 ? Theme.lineBody : 1
                    color: Theme.danger
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    Accessible.role: Accessible.AlertMessage
                    Accessible.name: text
                }
            }

            RowLayout {
                Layout.alignment: Qt.AlignRight
                Layout.topMargin: Theme.space24
                spacing: Theme.space8

                Button {
                    visible: control.secondaryText !== ""
                    text: control.secondaryText
                    variant: "secondary"
                    enabled: !control.busy
                    onClicked: control._reject()
                }
                Button {
                    text: control.primaryText
                    variant: control.danger ? "danger" : "primary"
                    loading: control.busy
                    onClicked: control._accept()
                }
            }
        }
    }

    enter: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "opacity"; from: 0; to: 1
                duration: Theme.dur(Theme.durMedium)
                easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
            }
            NumberAnimation {
                property: "scale"; from: Theme.reduceMotion ? 1 : 0.96; to: 1
                duration: Theme.dur(Theme.durMedium)
                easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
            }
        }
    }

    exit: Transition {
        NumberAnimation {
            property: "opacity"; to: 0
            duration: Theme.dur(Theme.durSmall)
            easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
        }
    }
}
