// Control center › power menu drawer: Sleep / Log out / Restart / Shut down.
// The last three ask first, in place (`cc.sessionConfirm`).
import QtQuick
import Lugh.UI
import Lugh.Shell

Drawer {
    id: drawer

    property var cc
    readonly property var session: Services.session
    readonly property string kind: cc.sessionConfirm      // "" | logout | restart | shutdown
    readonly property var copy: ({
        logout: [qsTr("Log out now?"), qsTr("Your apps will close."), qsTr("Log out")],
        restart: [qsTr("Restart now?"), qsTr("Your apps will close and the computer will restart."), qsTr("Restart")],
        shutdown: [qsTr("Shut down now?"), qsTr("Your apps will close and the computer will turn off."), qsTr("Shut down")]
    })

    expanded: cc.drawer === "session"

    function focusFirst(viaKeyboard) { if (loader.item) loader.item.focusFirst(viaKeyboard); }
    function run(k) {
        cc.sessionConfirm = "";
        cc.close();
        if (k === "logout") session.logout();
        else if (k === "restart") session.restart();
        else if (k === "shutdown") session.shutdown();
    }

    Loader {
        id: loader
        width: parent.width
        active: drawer.loaded
        sourceComponent: DrawerWell {
            id: well
            active: drawer.expanded

            function focusFirst(viaKeyboard) {
                const reason = viaKeyboard ? Qt.TabFocusReason : Qt.OtherFocusReason;
                (sleep.visible ? sleep : logout).forceActiveFocus(reason);
            }

            Column {
                width: parent.width

                ErrorBanner {
                    visible: drawer.session.lastError !== ""
                    width: parent.width
                    text: drawer.session.lastError
                    dismissible: false
                }

                Column {
                    visible: drawer.kind === ""
                    width: parent.width

                    DrawerRow {
                        id: sleep
                        visible: drawer.session.canSuspend
                        width: parent.width
                        entering: well.entering
                        order: 0
                        iconName: "moon"
                        text: qsTr("Sleep")
                        onClicked: { drawer.cc.close(); drawer.session.suspend(); }
                        KeyNavigation.down: logout
                    }
                    DrawerRow {
                        id: logout
                        width: parent.width
                        entering: well.entering
                        order: 1
                        iconName: "log-out"
                        text: qsTr("Log out…")
                        onClicked: drawer.cc.sessionConfirm = "logout"
                        KeyNavigation.up: sleep
                        KeyNavigation.down: restart
                    }
                    DrawerRow {
                        id: restart
                        width: parent.width
                        entering: well.entering
                        order: 2
                        iconName: "rotate-cw"
                        text: qsTr("Restart…")
                        onClicked: drawer.cc.sessionConfirm = "restart"
                        KeyNavigation.up: logout
                        KeyNavigation.down: shutdown
                    }
                    DrawerRow {
                        id: shutdown
                        width: parent.width
                        entering: well.entering
                        order: 3
                        iconName: "power"
                        text: qsTr("Shut down…")
                        onClicked: drawer.cc.sessionConfirm = "shutdown"
                        KeyNavigation.up: restart
                    }
                }

                // In-place confirmation.
                Item {
                    id: ask
                    readonly property var c: drawer.copy[drawer.kind] || drawer.copy.shutdown
                    visible: drawer.kind !== ""
                    width: parent.width
                    height: 92
                    onVisibleChanged: if (visible) cancel.forceActiveFocus(Qt.TabFocusReason)

                    Text {
                        x: 10
                        y: 8
                        width: parent.width - 20
                        text: ask.c[0]
                        font: Theme.typeBodyStrong
                        color: Theme.text
                        elide: Text.ElideRight
                    }
                    Text {
                        x: 10
                        y: 28
                        width: parent.width - 20
                        text: ask.c[1]
                        font: Theme.typeCaption
                        color: Theme.textMuted
                        elide: Text.ElideRight
                    }
                    Row {
                        anchors.right: parent.right
                        anchors.rightMargin: 4
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 4
                        spacing: Theme.space8

                        Button {
                            id: cancel
                            size: "sm"
                            text: qsTr("Cancel")
                            onClicked: drawer.cc.sessionConfirm = ""
                        }
                        Button {
                            size: "sm"
                            variant: "danger"
                            text: ask.c[2]
                            onClicked: drawer.run(drawer.kind)
                        }
                    }
                }
            }
        }
    }
}
