// Underline tabs (API.md).
//
//   Tabs { model: ["General", "Network", "Privacy"]; currentIndex: 0 }
//
// Tabs keep their natural width, left-aligned, over a 1 px hairline. The
// current tab has accent-text label and a 2 px accent underline that slides
// between tabs (fade only under reduce motion). Left/Right/Home/End move
// between tabs when one has keyboard focus. When the tabs don't fit, the strip
// flicks, keeps the current tab in view and fades at the overflowing edge.
import QtQuick
import QtQuick.Templates as T

T.TabBar {
    id: control

    property var model: []
    // Color the overflow edge fades blend into: set it to the surface the
    // tabs sit on when that is not Theme.bg.
    property color _fadeColor: Theme.bg

    function _focusTab(i) {
        if (i < 0 || i >= count) return;
        currentIndex = i;
        const tab = itemAt(i);
        if (tab) tab.forceActiveFocus(Qt.TabFocusReason);
    }

    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset,
                            contentWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset,
                             contentHeight + topPadding + bottomPadding)
    spacing: Theme.space4
    padding: 0

    Accessible.role: Accessible.PageTabList

    Repeater {
        model: control.model

        T.TabButton {
            id: tab
            required property var modelData
            required property int index

            text: modelData
            width: implicitWidth
            implicitWidth: implicitContentWidth + leftPadding + rightPadding
            implicitHeight: 40
            leftPadding: Theme.space12
            rightPadding: Theme.space12
            topPadding: 0
            bottomPadding: 0
            hoverEnabled: true
            focusPolicy: Qt.StrongFocus
            font: Theme.typeBodyStrong
            opacity: enabled ? 1 : Theme.disabledOpacity

            Accessible.role: Accessible.PageTab
            Accessible.name: text
            Accessible.selected: checked

            Keys.onLeftPressed: control._focusTab(index - 1)
            Keys.onRightPressed: control._focusTab(index + 1)
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Home) { control._focusTab(0); event.accepted = true; }
                else if (event.key === Qt.Key_End) { control._focusTab(control.count - 1); event.accepted = true; }
            }

            contentItem: Text {
                text: tab.text
                font: tab.font
                color: tab.checked ? Theme.accentText : tab.hovered && tab.enabled ? Theme.text : Theme.textMuted
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                Behavior on color { ColorAnimation { duration: Theme.durMicro } }
            }

            background: Item {
                Rectangle {
                    anchors.fill: parent
                    anchors.topMargin: Theme.space4
                    anchors.bottomMargin: Theme.space4 + 2
                    radius: Theme.radiusSm
                    color: tab.down ? Theme.pressedOverlay
                        : tab.hovered && tab.enabled && !tab.checked ? Theme.hoverOverlay : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.durMicro } }

                    FocusRing { show: tab.visualFocus }
                }
            }
        }
    }

    contentItem: ListView {
        id: strip
        onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
        EdgeFade { opacity: strip.interactive && !strip.atXBeginning ? 1 : 0 }
        EdgeFade { atStart: false; x: strip.width - width; opacity: strip.interactive && !strip.atXEnd ? 1 : 0 }
        model: control.contentModel
        currentIndex: control.currentIndex
        spacing: control.spacing
        orientation: ListView.Horizontal
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.AutoFlickIfNeeded
        interactive: contentWidth > width
        clip: interactive
        snapMode: ListView.NoSnap
        highlightFollowsCurrentItem: false
        highlight: Item {
            id: indicator
            readonly property Item _cur: ListView.view ? ListView.view.currentItem : null
            x: _cur ? _cur.x + Theme.space8 : 0
            width: _cur ? _cur.width - 2 * Theme.space8 : 0
            height: ListView.view ? ListView.view.height : 0
            z: 2
            visible: _cur !== null

            Behavior on x {
                enabled: !Theme.reduceMotion
                NumberAnimation { duration: Theme.durMedium; easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard }
            }
            Behavior on width {
                enabled: !Theme.reduceMotion
                NumberAnimation { duration: Theme.durMedium; easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard }
            }

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 2
                radius: 1
                color: Theme.accent
            }
        }
    }

    // Overflow: the strip flicks; a fade on each edge that has more tabs
    // replaces the hard cut.
    component EdgeFade: Rectangle {
        property bool atStart: true
        width: Theme.space32
        height: strip.height - 1
        z: 3
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durMicro) } }
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: atStart ? 0 : 1; color: control._fadeColor }
            GradientStop {
                position: atStart ? 1 : 0
                color: Qt.rgba(control._fadeColor.r, control._fadeColor.g, control._fadeColor.b, 0)
            }
        }
    }

    background: Item {
        implicitHeight: 40
        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            color: Theme.border
        }
    }
}
