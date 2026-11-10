// The Lugh menu (shell spec §Top bar: logo menu). A fullscreen overlay root:
// the frame anchors it to every screen edge and maps it while `shown`.
//
//   LughMenu { anchors.fill: parent }    // opens with ShellState.lughMenuOpen
//
// The glass panel sits at the top-left, just under the bar. Outside click or
// Esc closes it (ShellState.closeAll()). Keyboard: Up/Down/Home/End/Tab move,
// Enter/Space activate; the first enabled row is current on open. Enter =
// fade + scale 0.96 → 1 from the top-left in durSmall; exit = a short fade
// (fade only under reduce motion).
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
    readonly property bool shown: open || _t > 0 || pendingConfirm !== ""
    readonly property bool wantsKeyboard: open || pendingConfirm !== ""

    // "" | "logout" | "restart" | "shutdown"
    property string pendingConfirm: ""
    // Panel presence 0 → 1; drives opacity and scale.
    property real _t: open ? 1 : 0
    Behavior on _t {
        NumberAnimation {
            duration: root.open ? Theme.dur(Theme.durSmall) : Theme.dur(Theme.durMicro)
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Theme.easeStandard
        }
    }

    readonly property int barHeight: 30

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

    Loader {
        id: content
        anchors.fill: parent
        active: root.shown
        sourceComponent: Item {
            FocusScope {
                id: panel

                // Index into `rows` of the keyboard/hover-current row.
                property int current: -1
                readonly property var rows: [settingsRow, storeRow, lockRow, logoutRow, restartRow, shutdownRow]
                readonly property int pad: Theme.space4 + Theme.space2

                function _first() {
                    for (let i = 0; i < rows.length; ++i)
                        if (rows[i].actionable) return i;
                    return -1;
                }
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
                    current = _first();
                    forceActiveFocus();
                }

                x: Theme.space8
                y: root.barHeight + Theme.space4 + Theme.space2
                width: 240
                height: column.implicitHeight + 2 * pad
                focus: true
                opacity: root._t
                visible: opacity > 0
                scale: Theme.reduceMotion || !root.open ? 1 : 0.96 + 0.04 * root._t
                transformOrigin: Item.TopLeft

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

                GlassPanel {
                    anchors.fill: parent
                    radius: Theme.radiusMd
                    elevation: "menu"
                }
                // Clicks on the panel's padding and header must not reach the
                // outside-click handler.
                MouseArea { anchors.fill: parent }

                Column {
                    id: column
                    x: panel.pad
                    y: panel.pad
                    width: parent.width - 2 * panel.pad

                    // About header: what this machine runs. Informational.
                    Item {
                        width: parent.width
                        height: 52
                        Accessible.role: Accessible.StaticText
                        Accessible.name: qsTr("About Lugh: %1").arg(Services.session.osVersion)

                        Image {
                            id: headerLogo
                            // 30 px box, ~19 px visible mark, centered on the
                            // rows' icon column so the labels line up below.
                            x: Theme.space8 + 8 - width / 2
                            y: Math.round((parent.height - height) / 2)
                            width: 30
                            height: 30
                            source: Theme.dark ? "assets/lugh-logo-dark.svg" : "assets/lugh-logo.svg"
                            sourceSize: Qt.size(width * Screen.devicePixelRatio, height * Screen.devicePixelRatio)
                            smooth: true
                        }
                        Column {
                            // Same x as the row labels (8 + 16 icon + 8).
                            x: Theme.space8 + 16 + Theme.space8
                            width: parent.width - x - Theme.space8
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1
                            Text {
                                width: parent.width
                                text: qsTr("About Lugh")
                                font: Theme.typeBodyStrong
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

                    MenuSeparator { width: parent.width }

                    LughMenuRow {
                        id: settingsRow
                        width: parent.width
                        text: qsTr("Settings…")
                        iconName: "settings"
                        disabledReason: qsTr("Settings arrives in Phase 2")
                        current: panel.current === 0
                        onHoveredIn: panel.current = 0
                    }
                    LughMenuRow {
                        id: storeRow
                        width: parent.width
                        text: qsTr("Store…")
                        iconName: "shopping-bag"
                        disabledReason: qsTr("The Store arrives in Phase 2")
                        current: panel.current === 1
                        onHoveredIn: panel.current = 1
                    }

                    MenuSeparator { width: parent.width }

                    LughMenuRow {
                        id: lockRow
                        width: parent.width
                        text: qsTr("Lock")
                        iconName: "lock"
                        shortcutText: qsTr("Super+L")
                        current: panel.current === 2
                        onHoveredIn: panel.current = 2
                        onTriggered: { ShellState.closeAll(); Services.session.lock(); }
                    }
                    LughMenuRow {
                        id: logoutRow
                        width: parent.width
                        text: qsTr("Log out…")
                        iconName: "log-out"
                        current: panel.current === 3
                        onHoveredIn: panel.current = 3
                        onTriggered: root._ask("logout")
                    }
                    LughMenuRow {
                        id: restartRow
                        width: parent.width
                        text: qsTr("Restart…")
                        iconName: "rotate-ccw"
                        current: panel.current === 4
                        onHoveredIn: panel.current = 4
                        onTriggered: root._ask("restart")
                    }
                    LughMenuRow {
                        id: shutdownRow
                        width: parent.width
                        text: qsTr("Shut down…")
                        iconName: "power"
                        current: panel.current === 5
                        onHoveredIn: panel.current = 5
                        onTriggered: root._ask("shutdown")
                    }
                }
            }

            // Confirmation for the session-ending actions. Calm on purpose:
            // no red, the default button is the action the user just chose.
            Dialog {
                id: confirm
                readonly property var _copy: ({
                    logout: [qsTr("Log out?"), qsTr("Your apps will close. Save any open work first."), qsTr("Log out")],
                    restart: [qsTr("Restart now?"), qsTr("Your apps will close and the computer will restart."), qsTr("Restart")],
                    shutdown: [qsTr("Shut down now?"), qsTr("Your apps will close and the computer will turn off."), qsTr("Shut down")]
                })
                readonly property var _c: _copy[root.pendingConfirm] || _copy.shutdown
                title: _c[0]
                text: _c[1]
                primaryText: _c[2]
                onAccepted: {
                    const s = Services.session;
                    if (root.pendingConfirm === "logout") s.logout();
                    else if (root.pendingConfirm === "restart") s.restart();
                    else if (root.pendingConfirm === "shutdown") s.shutdown();
                }
                onClosed: root.pendingConfirm = ""
                Component.onCompleted: if (root.pendingConfirm !== "") open()
                Connections {
                    target: root
                    function onPendingConfirmChanged() { if (root.pendingConfirm !== "") confirm.open(); }
                }
            }
        }
    }
}
