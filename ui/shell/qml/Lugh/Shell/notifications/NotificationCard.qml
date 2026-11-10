// One notification as a liquid capsule, shared by the toasts and the
// notification center. Collapsed it is a single row: leading icon (the app's,
// or a danger `circle-alert` when critical), summary on one line, relative
// time. `expanded` grows it (height on the liquid spring, radius easing from
// a capsule to Theme.radiusLg) to show NotificationContent: body, thumbnail,
// actions. A notification with nothing more to show stays a capsule.
//
// Critical = the danger icon + a thin danger outline (never color alone).
// The detail is only instantiated while expanded or still animating.
// Internal to notifications/ (not exported in the qmldir).
import QtQuick
import Lugh.UI
import Lugh.Shell
import "notify.js" as N

FocusScope {
    id: card

    property int nid: -1
    property string appName: ""
    property string appIcon: ""
    property string summary: ""
    property string body: ""
    property int urgency: 1
    property double time: 0
    property string actions: "[]"
    property string image: ""

    property double now: Date.now()
    property bool expanded: false
    // true: floating glass with a shadow (toast); false: a flat translucent card.
    property bool glass: false
    property color fill: "transparent"
    property bool showIcon: true
    property int collapsedHeight: 46
    property int padding: 14
    property int bodyLines: 3
    property bool includeDefault: false
    property bool closeVisible: false
    property bool hovered: false       // brightens (set by the owner's HoverHandler)
    property bool pressed: false
    property bool selected: false      // keyboard-current: focus ring
    property string closeTooltip: qsTr("Dismiss")

    signal closeRequested()

    readonly property bool critical: urgency === 2
    readonly property string title: summary !== "" ? summary : (N.plain(body) !== "" ? N.plain(body) : appName)
    // With an empty summary the body is the title; don't repeat it below.
    readonly property string _detailBody: summary !== "" ? body : ""
    readonly property bool hasDetail: _detailBody !== "" || image !== "" || _actionCount > 0
    readonly property int _actionCount: (includeDefault ? N.parseActionsWithDefault(actions, "x") : N.parseActions(actions)).length
    readonly property real _detailH: detail.item ? detail.item.implicitHeight : 0
    readonly property bool _open: expanded && hasDetail
    // Where the capsule is going; `height` gets there on the spring.
    readonly property real targetHeight: collapsedHeight + (_open ? _detailH : 0)
    readonly property real radius: Math.min(_r, height / 2)
    readonly property real _lead: critical || showIcon ? 20 + Theme.space8 : 0

    property real _h: targetHeight
    property real _r: _open ? Theme.radiusLg : collapsedHeight / 2
    property bool _ready: false
    Component.onCompleted: _ready = true

    Behavior on _h {
        enabled: card._ready && !Theme.reduceMotion
        SpringAnimation {
            spring: Theme.liquidSpring; damping: Theme.liquidDamping
            mass: Theme.liquidMass; epsilon: Theme.springEpsilon
        }
    }
    Behavior on _r {
        enabled: card._ready && !Theme.reduceMotion
        NumberAnimation {
            duration: Theme.durMedium
            easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
        }
    }

    implicitHeight: Math.max(collapsedHeight, _h)

    Accessible.role: Accessible.ListItem
    Accessible.name: (critical ? qsTr("Urgent: ") : "") + appName + ": " + title
    Accessible.description: N.plain(body)

    // ---- surface ----------------------------------------------------------
    Loader {
        anchors.fill: parent
        sourceComponent: card.glass ? glassSurface : flatSurface
    }
    Component {
        id: glassSurface
        GlassPanel { radius: card.radius; elevation: "menu" }
    }
    Component {
        id: flatSurface
        Rectangle {
            radius: card.radius
            color: card.fill
            border.width: 1
            border.color: Theme.glassBorder
            antialiasing: true
        }
    }
    Rectangle {
        anchors.fill: parent
        radius: card.radius
        antialiasing: true
        color: card.pressed ? Theme.pressedOverlay : card.hovered ? Theme.hoverOverlay : "transparent"
        border.width: card.critical ? 1 : 0
        border.color: Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.7)
        Behavior on color { ColorAnimation { duration: Theme.durMicro } }
    }
    FocusRing { target: card; show: card.selected }

    // ---- the one-line row -------------------------------------------------
    Item {
        id: row
        x: card.padding
        width: card.width - card.padding - Theme.space12
        height: card.collapsedHeight

        Icon {
            visible: card.critical
            anchors.verticalCenter: parent.verticalCenter
            name: "circle-alert"
            size: 20
            color: Theme.danger
        }
        Loader {
            active: card.showIcon && !card.critical
            anchors.verticalCenter: parent.verticalCenter
            sourceComponent: AppIcon {
                iconName: card.appIcon
                fallbackText: card.appName
                size: 20
            }
        }
        Text {
            x: card._lead
            width: Math.max(0, timeText.x - Theme.space8 - x)
            anchors.verticalCenter: parent.verticalCenter
            text: card.title
            textFormat: Text.PlainText
            font: Theme.typeLabel
            color: Theme.text
            elide: Text.ElideRight
            maximumLineCount: 1
        }
        Text {
            id: timeText
            x: closeSlot.x - (closeSlot.width > 0 ? Theme.space4 : 0) - width
            anchors.verticalCenter: parent.verticalCenter
            text: N.relativeTime(card.time, card.now)
            font: Theme.typeCaptionTnum
            color: Theme.textMuted
        }
        Item {
            id: closeSlot
            anchors.right: parent.right
            anchors.rightMargin: -Theme.space4
            anchors.verticalCenter: parent.verticalCenter
            width: card.closeVisible || closeBtn.activeFocus ? 24 : 0
            height: 24
            Behavior on width {
                enabled: card._ready && !Theme.reduceMotion
                NumberAnimation {
                    duration: Theme.durSmall
                    easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
                }
            }
            IconButton {
                id: closeBtn
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconName: "x"
                size: 24
                iconSize: 14
                tooltip: card.closeTooltip
                opacity: closeSlot.width / 24
                visible: opacity > 0 || activeFocus
                onClicked: card.closeRequested()
            }
        }
    }

    // ---- detail -----------------------------------------------------------
    Item {
        y: card.collapsedHeight - Theme.space4
        width: card.width
        height: Math.max(0, card.height - y)
        clip: card._h !== card.targetHeight || !card._open

        Loader {
            id: detail
            x: card.padding + card._lead
            y: Theme.space2
            width: card.width - x - card.padding
            active: card.hasDetail && (card.expanded || card._h > card.collapsedHeight + 0.5)
            opacity: card._open ? 1 : 0
            Behavior on opacity {
                enabled: card._ready
                NumberAnimation {
                    duration: Theme.dur(Theme.durSmall)
                    easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
                }
            }
            sourceComponent: NotificationContent {
                nid: card.nid
                body: card._detailBody
                actions: card.actions
                image: card.image
                bodyLines: card.bodyLines
                includeDefault: card.includeDefault
            }
        }
    }
}
