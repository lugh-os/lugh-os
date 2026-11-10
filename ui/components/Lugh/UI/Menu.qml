// Popup menu (API.md): surface, radiusMd, Shadow (menu level), 6 px padding.
//
//   Menu {
//       id: menu
//       MenuItem { text: qsTr("Open"); iconName: "folder-open"; shortcutText: "Ctrl+O" }
//       MenuSeparator {}
//       MenuItem { text: qsTr("Move to Trash"); iconName: "trash-2"; danger: true }
//   }
//   onClicked: menu.popup()        // at the cursor
//
// Enter: fade + scale 0.96 → 1 from transformOrigin (default top-left; set
// Popup.TopRight etc. for menus anchored on the right) in durSmall; under
// reduce motion only a durReduced fade. Exit: short fade. Up/Down/Enter/Esc
// come from T.Menu. Items line up their labels when any item has an icon or
// is checkable.
import QtQuick
import QtQuick.Templates as T

T.Menu {
    id: control

    // True when any item needs the leading icon/check column (labels align).
    readonly property bool _reserveIcon: {
        const n = count;
        for (let i = 0; i < n; ++i) {
            const it = itemAt(i);
            if (it && ((it.iconName !== undefined && it.iconName !== "") || it.checkable))
                return true;
        }
        return false;
    }

    // Widest item, so long labels and shortcuts are never clipped.
    readonly property real _itemsWidth: {
        let w = 0;
        const n = count;
        for (let i = 0; i < n; ++i) {
            const it = itemAt(i);
            if (it) w = Math.max(w, it.implicitWidth);
        }
        return w;
    }

    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset,
                            _itemsWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset,
                             contentHeight + topPadding + bottomPadding)

    padding: Theme.space4 + Theme.space2
    margins: Theme.space8
    overlap: Theme.space4 + Theme.space2
    transformOrigin: T.Popup.TopLeft

    delegate: MenuItem {}

    contentItem: ListView {
        implicitWidth: control._itemsWidth
        implicitHeight: contentHeight
        model: control.contentModel
        interactive: Window.window ? contentHeight + control.topPadding + control.bottomPadding > control.height : false
        clip: interactive
        currentIndex: control.currentIndex
        boundsBehavior: Flickable.StopAtBounds
    }

    background: Item {
        implicitWidth: 200
        implicitHeight: 40

        Shadow {
            target: panel
            radius: Theme.radiusMd
            elevation: "menu"
        }
        Rectangle {
            id: panel
            anchors.fill: parent
            radius: Theme.radiusMd
            color: Theme.surface
            border.width: 1
            border.color: Theme.border
        }
    }

    enter: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "opacity"; from: 0; to: 1
                duration: Theme.dur(Theme.durSmall)
                easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
            }
            NumberAnimation {
                property: "scale"; from: Theme.reduceMotion ? 1 : 0.96; to: 1
                duration: Theme.dur(Theme.durSmall)
                easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
            }
        }
    }
    exit: Transition {
        NumberAnimation {
            property: "opacity"; from: 1; to: 0
            duration: Theme.dur(Theme.durMicro)
            easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
        }
    }
}
