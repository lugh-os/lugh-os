// Segmented control: pick one of a few options.
//
//   SegmentedControl { model: [qsTr("Lugh"), qsTr("Classic"), qsTr("Focus")]
//                      currentIndex: mode; onActivated: i => mode = i }
//   SegmentedControl { model: [{ text: qsTr("Grid"), iconName: "layout-grid" },
//                              { text: qsTr("List"), iconName: "list" }] }
//
// Equal-width segments on a recessed surface2 track. The selection pill
// (surface + accent tint + accent hairline, label in accentText) springs to
// the current segment; under reduce motion it jumps and fades in. Left/Right
// (and Home/End) move and activate; Space/Enter re-activate the current one.
import QtQuick
import QtQuick.Templates as T

T.Control {
    id: root

    property var model: []
    property int currentIndex: 0

    signal activated(int index)

    readonly property int _count: model ? model.length : 0
    readonly property int _pad: 2
    readonly property real _segW: _count > 0 ? (width - 2 * _pad) / _count : 0

    function _text(i) { const m = model[i]; return typeof m === "string" ? m : (m && m.text) || "" }
    function _icon(i) { const m = model[i]; return typeof m === "string" ? "" : (m && m.iconName) || "" }
    function _activate(i) {
        if (i < 0 || i >= _count) return;
        currentIndex = i;
        activated(i);
    }

    implicitWidth: {
        let w = 0;
        for (let i = 0; i < rep.count; ++i) {
            const it = rep.itemAt(i);
            if (it) w = Math.max(w, it.implicitWidth);
        }
        return Math.max(w, 48) * _count + 2 * _pad;
    }
    implicitHeight: Theme.hitTarget

    focusPolicy: Qt.StrongFocus
    hoverEnabled: true
    opacity: enabled ? 1 : Theme.disabledOpacity

    Keys.onPressed: event => {
        let i = -1;
        if (event.key === Qt.Key_Left) i = Math.max(0, currentIndex - 1);
        else if (event.key === Qt.Key_Right) i = Math.min(_count - 1, currentIndex + 1);
        else if (event.key === Qt.Key_Home) i = 0;
        else if (event.key === Qt.Key_End) i = _count - 1;
        else if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) i = currentIndex;
        if (i < 0) return;
        event.accepted = true;
        if (i !== currentIndex || event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
            _activate(i);
    }

    Accessible.role: Accessible.PageTabList
    Accessible.name: _count > 0 && currentIndex >= 0 ? _text(currentIndex) : ""

    background: Rectangle {
        radius: Theme.radiusSm + root._pad + 2
        color: Theme.surface2
        border.width: 1
        border.color: Theme.dark ? Theme.border : Qt.tint(Theme.surface2, Theme.hoverOverlay)
        antialiasing: true

        FocusRing { show: root.visualFocus }
    }

    contentItem: Item {
        // selection pill
        Item {
            id: pill
            visible: root.currentIndex >= 0 && root.currentIndex < root._count
            y: root._pad
            width: root._segW
            height: root.height - 2 * root._pad
            x: root._pad + root.currentIndex * root._segW
            Behavior on x {
                enabled: !Theme.reduceMotion
                SpringAnimation {
                    spring: Theme.springSpring
                    damping: Theme.springDamping
                    epsilon: Theme.springEpsilon
                }
            }

            // soft contact shadow
            Rectangle {
                anchors.fill: parent
                anchors.topMargin: 1
                anchors.bottomMargin: -1
                radius: Theme.radiusSm + 2
                color: Theme.shadowColor
                opacity: Theme.dark ? 0.5 : 0.35
                antialiasing: true
            }
            Rectangle {
                anchors.fill: parent
                radius: Theme.radiusSm + 2
                color: Qt.tint(Theme.surface, Theme.selectedBg)
                border.width: 1
                border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.5)
                antialiasing: true
            }

            NumberAnimation on opacity {
                id: pillFade
                running: false
                from: 0.2; to: 1
                duration: Theme.durReduced
            }
        }

        Connections {
            target: root
            function onCurrentIndexChanged() { if (Theme.reduceMotion) pillFade.restart(); }
        }

        Repeater {
            id: rep
            model: root._count

            Item {
                id: seg
                required property int index
                readonly property bool sel: index === root.currentIndex
                readonly property string label: root._text(index)
                readonly property string icon: root._icon(index)

                x: root._pad + index * root._segW
                y: root._pad
                width: root._segW
                height: root.height - 2 * root._pad
                implicitWidth: segRow.implicitWidth + 2 * Theme.space12

                Accessible.role: Accessible.PageTab
                Accessible.name: label
                Accessible.checkable: true
                Accessible.checked: sel
                Accessible.onPressAction: root._activate(index)

                Rectangle {
                    anchors.fill: parent
                    radius: Theme.radiusSm + 2
                    color: ma.pressed ? Theme.pressedOverlay : Theme.hoverOverlay
                    opacity: !seg.sel && root.enabled && (ma.containsMouse || ma.pressed) ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: Theme.durMicro } }
                }

                Row {
                    id: segRow
                    anchors.centerIn: parent
                    spacing: 6
                    Icon {
                        visible: seg.icon !== ""
                        anchors.verticalCenter: parent.verticalCenter
                        name: seg.icon
                        size: 16
                        color: seg.sel ? Theme.accentText : Theme.textMuted
                        Behavior on color { ColorAnimation { duration: Theme.durMicro } }
                    }
                    Text {
                        visible: seg.label !== ""
                        anchors.verticalCenter: parent.verticalCenter
                        text: seg.label
                        font: seg.sel ? Theme.typeBodyStrong : Theme.typeBody
                        color: seg.sel ? Theme.accentText : Theme.textMuted
                        Behavior on color { ColorAnimation { duration: Theme.durMicro } }
                    }
                }

                MouseArea {
                    id: ma
                    anchors.fill: parent
                    hoverEnabled: true
                    onPressed: root.forceActiveFocus(Qt.MouseFocusReason)
                    onClicked: root._activate(seg.index)
                }
            }
        }
    }
}
