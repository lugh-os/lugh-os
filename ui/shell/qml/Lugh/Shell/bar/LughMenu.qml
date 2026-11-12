// The Lugh menu (docs/design/lugh-mode.md: grows out of the start button of
// the bottom Panel). A fullscreen overlay root: the frame anchors it to every
// screen edge and maps it while `shown`; it takes the keyboard while
// `wantsKeyboard`.
//
//   LughMenu { anchors.fill: parent }    // opens with ShellState.lughMenuOpen
//
// A MorphPanel springs from ShellState.logoIsland (the start button) to a
// compact panel standing 8 px above the Panel (ShellState.panelRect /
// panelReserved), left-aligned with the button. Outside click or Esc closes it (ShellState.closeAll()).
// Keyboard: Up/Down/Home/End/Tab move, Enter/Space activate; the first enabled
// row is current on open.
//
// Log out / Restart / Shut down ask first in a modal Dialog that this overlay
// keeps up after the panel closes (`shown` stays true until it is answered).
import QtQuick
import QtQuick.Window
import Lugh.UI
import Lugh.Shell

Item {
    id: root

    readonly property bool open: ShellState.lughMenuOpen
    // True while the panel is open or animating out, or a confirmation is up.
    readonly property bool shown: morph.shown || pendingConfirm !== ""
    readonly property bool wantsKeyboard: open || pendingConfirm !== ""

    // "" | "logout" | "restart" | "shutdown"
    property string pendingConfirm: ""

    readonly property int panelWidth: 232
    readonly property int pad: Theme.space4 + Theme.space2
    readonly property int rowHeight: 36
    readonly property int headerHeight: 44
    readonly property int separatorHeight: 9
    readonly property bool canSuspend: Services.session.canSuspend
    // Known without loading the content, so the morph has its target at once.
    readonly property int panelHeight: 2 * pad + headerHeight + 2 * separatorHeight
                                       + (canSuspend ? 8 : 7) * rowHeight
    // Bottom edge of the menu: above the panel, whichever of its rects is
    // higher (with auto-hide the reserved zone is 0 but the panel shows).
    readonly property real _bottom: Math.min(ShellState.logoIsland.y, ShellState.panelRect.y,
                                             height - ShellState.panelReserved) - Theme.space8

    function _ask(kind) {
        ShellState.closeAll();
        pendingConfirm = kind;
    }

    Accessible.role: Accessible.PopupMenu
    Accessible.name: qsTr("Lugh menu")

    // Outside click closes (and swallows the click, like any menu).
    MouseArea {
        anchors.fill: parent
        enabled: root.open
        acceptedButtons: Qt.AllButtons
        onPressed: ShellState.closeAll()
    }

    MorphPanel {
        id: morph
        anchors.fill: parent
        open: root.open
        originRect: ShellState.logoIsland
        targetRect: Qt.rect(Math.max(Theme.space8, Math.min(root.width - root.panelWidth - Theme.space8, ShellState.logoIsland.x)),
                            Math.max(Theme.space8, root._bottom - root.panelHeight),
                            root.panelWidth, root.panelHeight)
        radius: Theme.radiusXl
        elevation: "popover"

        Loader {
            anchors.fill: parent
            active: morph.shown
            sourceComponent: FocusScope {
                id: panel

                // Index into `rows` of the keyboard/hover-current row.
                property int current: -1
                readonly property var rows: root.canSuspend
                    ? [settingsRow, customizeRow, storeRow, lockRow, sleepRow, logoutRow, restartRow, shutdownRow]
                    : [settingsRow, customizeRow, storeRow, lockRow, logoutRow, restartRow, shutdownRow]

                function move(step) {
                    const n = rows.length;
                    let i = current;
                    for (let k = 0; k < n; ++k) {
                        i = i < 0 ? (step > 0 ? 0 : n - 1) : (i + step + n) % n;
                        if (rows[i].actionable) { current = i; return; }
                    }
                }
                function edge(last) {
                    current = -1;
                    move(last ? -1 : 1);
                }
                function activate() {
                    if (root.open && current >= 0 && rows[current].actionable)
                        rows[current].triggered();
                }
                function reset() {
                    edge(false);
                    forceActiveFocus();
                }

                focus: true
                Keys.onUpPressed: move(-1)
                Keys.onDownPressed: move(1)
                Keys.onTabPressed: move(1)
                Keys.onBacktabPressed: move(-1)
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Home) { edge(false); event.accepted = true; }
                    else if (event.key === Qt.Key_End) { edge(true); event.accepted = true; }
                    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                        activate(); event.accepted = true;
                    }
                }
                Keys.onEscapePressed: ShellState.closeAll()

                Component.onCompleted: if (root.open) reset()
                Connections {
                    target: root
                    function onOpenChanged() { if (root.open) panel.reset(); }
                }

                component Row_: LughMenuRow {
                    id: menuRow
                    width: parent.width
                    height: root.rowHeight
                    current: panel.current >= 0 && panel.rows[panel.current] === menuRow
                    onHoveredIn: panel.current = panel.rows.indexOf(menuRow)
                }
                component Hairline: Item {
                    width: parent.width
                    height: root.separatorHeight
                    Rectangle {
                        x: Theme.space12 - Theme.space2
                        y: Theme.space4
                        width: parent.width - 2 * x
                        height: 1
                        color: Theme.border
                        opacity: 0.7
                    }
                }

                Column {
                    x: root.pad
                    y: root.pad
                    width: parent.width - 2 * root.pad

                    // What this machine runs. Informational.
                    Item {
                        width: parent.width
                        height: root.headerHeight
                        Accessible.role: Accessible.StaticText
                        Accessible.name: qsTr("About Lugh: %1").arg(Services.session.osVersion)

                        Image {
                            // 26 px box, ~16 px visible mark, centered on the
                            // rows' icon column so the labels line up below.
                            x: Theme.space12 - Theme.space2 + 8 - width / 2
                            y: Math.round((parent.height - height) / 2)
                            width: 26
                            height: 26
                            source: Theme.dark ? "assets/lugh-logo-dark.svg" : "assets/lugh-logo.svg"
                            sourceSize: Qt.size(width * Screen.devicePixelRatio, height * Screen.devicePixelRatio)
                            smooth: true
                        }
                        Column {
                            x: Theme.space12 - Theme.space2 + 16 + Theme.space12 - Theme.space2
                            width: parent.width - x - Theme.space8
                            anchors.verticalCenter: parent.verticalCenter
                            Text {
                                width: parent.width
                                text: qsTr("Lugh")
                                font: Theme.typeLabel
                                color: Theme.text
                                elide: Text.ElideRight
                                Accessible.ignored: true
                            }
                            Text {
                                width: parent.width
                                text: Services.session.osVersion
                                font: Theme.typeCaption
                                color: Theme.textMuted
                                elide: Text.ElideRight
                                Accessible.ignored: true
                            }
                        }
                    }

                    Hairline {}

                    Row_ {
                        id: settingsRow
                        text: qsTr("Settings…")
                        iconName: "settings"
                        disabledReason: qsTr("Settings arrives in Phase 2")
                    }
                    Row_ {
                        id: customizeRow
                        text: qsTr("Customize…")
                        iconName: "palette"
                        onTriggered: ShellState.openCustomize("")
                    }
                    Row_ {
                        id: storeRow
                        text: qsTr("Store…")
                        iconName: "shopping-bag"
                        disabledReason: qsTr("The Store arrives in Phase 2")
                    }

                    Hairline {}

                    Row_ {
                        id: lockRow
                        text: qsTr("Lock")
                        iconName: "lock"
                        shortcutText: qsTr("Super+L")
                        onTriggered: { ShellState.closeAll(); Services.session.lock(); }
                    }
                    Row_ {
                        id: sleepRow
                        visible: root.canSuspend
                        text: qsTr("Sleep")
                        iconName: "moon"
                        onTriggered: { ShellState.closeAll(); Services.session.suspend(); }
                    }
                    Row_ {
                        id: logoutRow
                        text: qsTr("Log out…")
                        iconName: "log-out"
                        onTriggered: root._ask("logout")
                    }
                    Row_ {
                        id: restartRow
                        text: qsTr("Restart…")
                        iconName: "rotate-ccw"
                        onTriggered: root._ask("restart")
                    }
                    Row_ {
                        id: shutdownRow
                        text: qsTr("Shut down…")
                        iconName: "power"
                        onTriggered: root._ask("shutdown")
                    }
                }
            }
        }
    }

    // Confirmation for the session-ending actions. Calm on purpose: no red,
    // the default button is the action the user just chose.
    Loader {
        anchors.fill: parent
        active: root.pendingConfirm !== ""
        sourceComponent: Item {
            Dialog {
                id: confirm
                readonly property var _copy: ({
                    logout: [qsTr("Log out?"), qsTr("Your apps will close. Save any open work first."), qsTr("Log out")],
                    restart: [qsTr("Restart now?"), qsTr("Your apps will close and the computer will restart."), qsTr("Restart")],
                    shutdown: [qsTr("Shut down now?"), qsTr("Your apps will close and the computer will turn off."), qsTr("Shut down")]
                })
                // Captured once: the copy must not change while the dialog fades out.
                property string kind: ""
                readonly property var _c: _copy[kind] || _copy.shutdown
                title: _c[0]
                text: _c[1]
                primaryText: _c[2]
                onAccepted: {
                    const s = Services.session;
                    if (kind === "logout") s.logout();
                    else if (kind === "restart") s.restart();
                    else if (kind === "shutdown") s.shutdown();
                }
                onClosed: root.pendingConfirm = ""
                Component.onCompleted: { kind = root.pendingConfirm; open(); }
            }
        }
    }
}
