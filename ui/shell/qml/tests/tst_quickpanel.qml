// Quick panel (controlcenter/ControlCenter.qml) behaviour test: tile drag
// reorder, Shift+arrow reorder, add / remove in edit mode, Keep awake, the
// Esc chain and the auto-fit on a 1366×768 screen. Asserts on
// ShellSettings.quickToggles / quickCalendarFolded, so run it with a
// throw-away XDG_CONFIG_HOME (ShellSettings persists).
//
// qmltestrunner is not installed here, so this runs under plain qml6: the
// TestCase starts itself, prints one PASS/FAIL line per test function and a
// "Totals:" line, and exits 1 if any test failed (the `exitGuard` TestCase
// keeps QtTest from quitting with 0 first):
//
//   XDG_CONFIG_HOME=$(mktemp -d) QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 \
//     timeout 60 qml6 -I ui/components -I ui/shell/qml ui/shell/qml/tests/tst_quickpanel.qml
import QtQuick
import QtQuick.Window
import QtTest
import Lugh.UI
import Lugh.Shell

Window {
    id: win
    width: 1366
    height: 768
    visible: true
    color: Theme.bg

    readonly property var defaultTiles: ["wifi", "bluetooth", "dnd", "nightlight", "darkmode", "powerprofile"]

    Binding { target: ShellState; property: "statusIsland"; value: Qt.rect(win.width - 206, win.height - 46, 200, 40) }
    Binding { target: ShellState; property: "panelReserved"; value: 60 }

    ControlCenter {
        id: cc
        anchors.fill: parent
        visible: shown
        focus: true
    }

    // Mandatory but never run: QtTest quits (exit code 0) once every
    // registered test case is done, so this one keeps it from quitting and
    // `quickPanel` exits with the real result.
    TestCase { id: exitGuard; name: "ExitGuard"; when: false }

    TestCase {
        id: tc
        name: "QuickPanel"
        when: win.visible

        // ---- helpers --------------------------------------------------------
        function tiles() { return ShellSettings.quickToggles.map(String).join(","); }
        function find(item, pred) {
            if (!item) return null;
            if (pred(item)) return item;
            const kids = item.children || [];
            for (let i = 0; i < kids.length; ++i) {
                const r = find(kids[i], pred);
                if (r) return r;
            }
            return null;
        }
        function tile(id) {
            const t = cc._tileItem(id);
            verify(t !== null, "tile " + id);
            return t;
        }
        function settle() {
            tryVerify(() => cc.panelItem.opacity === 1, 3000, "panel open");
            wait(Theme.durSmall + 50);      // tile x/y Behaviors
        }
        function center(item) { return item.mapToItem(cc, item.width / 2, item.height / 2); }
        // Press on `item`, move to `to` (cc coordinates) in small steps, release.
        function drag(item, to) {
            const from = center(item);
            mousePress(cc, from.x, from.y);
            const steps = 12;
            for (let i = 1; i <= steps; ++i)
                mouseMove(cc, from.x + (to.x - from.x) * i / steps, from.y + (to.y - from.y) * i / steps, 10, Qt.LeftButton);
            mouseRelease(cc, to.x, to.y, Qt.LeftButton);
        }

        function initTestCase() {
            Theme.reduceMotion = true;
            ShellSettings.quickCalendarFolded = false;
            wait(200);      // first frame
        }
        function init() {
            ShellSettings.quickToggles = win.defaultTiles.slice();
            Services.session.setIdleInhibit(false);
            if (!ShellState.controlCenterOpen) ShellState.toggleControlCenter();
            cc.forceActiveFocus();
            cc.setEditing(false);
            settle();
        }
        function cleanup() {
            console.log((qtest_results.failed ? "FAIL!  : " : "PASS   : ") + name + "::" + qtest_results.functionName + "()");
        }
        function cleanupTestCase() {
            ShellState.closeAll();
            Theme.reduceMotion = false;
            const fails = qtest_results.failCount;
            console.log("Totals: " + (qtest_results.passCount - fails) + " checked, " + fails + " failed");
            Qt.callLater(() => Qt.exit(fails > 0 ? 1 : 0));
        }

        // ---- tiles ------------------------------------------------------------
        function test_drag_forward() {
            cc.setEditing(true);
            settle();
            // Wi-Fi (slot 0) onto Night light's spot (slot 3, second row, right).
            drag(tile("wifi"), center(tile("nightlight")));
            tryCompare(tc, "_order", "bluetooth,dnd,nightlight,wifi,darkmode,powerprofile");
            compare(cc._dragFrom, -1, "drag state cleared");
            verify(cc.editing, "still editing");
        }
        function test_drag_backward() {
            cc.setEditing(true);
            settle();
            // Power mode (slot 5) to the first slot.
            drag(tile("powerprofile"), center(tile("wifi")));
            tryCompare(tc, "_order", "powerprofile,wifi,bluetooth,dnd,nightlight,darkmode");
        }
        function test_drag_cancelled_outside_edit() {
            // Not editing: a drag does nothing (and the press toggles nothing either).
            const before = tiles();
            drag(tile("dnd"), center(tile("powerprofile")));
            wait(50);
            compare(tiles(), before);
        }
        function test_keyboard_reorder() {
            cc.setEditing(true);
            settle();
            tile("dnd").forceActiveFocus(Qt.TabFocusReason);
            keyClick(Qt.Key_Right, Qt.ShiftModifier);
            tryCompare(tc, "_order", "wifi,bluetooth,nightlight,dnd,darkmode,powerprofile");
            tryVerify(() => cc._tileItem("dnd") && cc._tileItem("dnd").activeFocus, 1000, "focus follows the moved tile");
            keyClick(Qt.Key_Up, Qt.ShiftModifier);
            tryCompare(tc, "_order", "wifi,dnd,bluetooth,nightlight,darkmode,powerprofile");
            keyClick(Qt.Key_Left, Qt.ShiftModifier);
            tryCompare(tc, "_order", "dnd,wifi,bluetooth,nightlight,darkmode,powerprofile");
            keyClick(Qt.Key_Left, Qt.ShiftModifier);      // already first: no change
            wait(50);
            compare(tiles(), "dnd,wifi,bluetooth,nightlight,darkmode,powerprofile");
            // Plain arrows only move focus.
            keyClick(Qt.Key_Right);
            wait(50);
            compare(tiles(), "dnd,wifi,bluetooth,nightlight,darkmode,powerprofile");
            verify(cc._tileItem("wifi").activeFocus, "arrow moved focus");
        }
        function test_remove() {
            cc.setEditing(true);
            settle();
            const rm = find(tile("dnd"), it => it.objectName === "remove");
            verify(rm !== null && rm.visible, "remove button");
            mouseClick(rm);
            tryCompare(tc, "_order", "wifi,bluetooth,nightlight,darkmode,powerprofile");
            // Keyboard: Delete removes and focus lands on the next tile.
            tile("bluetooth").forceActiveFocus(Qt.TabFocusReason);
            keyClick(Qt.Key_Delete);
            tryCompare(tc, "_order", "wifi,nightlight,darkmode,powerprofile");
            tryVerify(() => cc._tileItem("nightlight") && cc._tileItem("nightlight").activeFocus, 1000, "focus on the next tile");
        }
        function test_add() {
            cc.setEditing(true);
            settle();
            const chip = find(cc, it => it.objectName === "add:caffeine");
            verify(chip !== null && chip.visible, "add chip");
            mouseClick(chip);
            tryCompare(tc, "_order", win.defaultTiles.concat(["caffeine"]).join(","));
            verify(cc.spareIds.indexOf("caffeine") < 0, "no longer offered");
            tryVerify(() => find(cc, it => it.objectName === "add:caffeine") === null, 1000, "chip gone");
        }
        function test_toggle_not_while_editing() {
            const was = Services.notifications.dnd;
            cc.setEditing(true);
            settle();
            mouseClick(tile("dnd"));
            compare(Services.notifications.dnd, was, "edit mode does not toggle");
            cc.setEditing(false);
            mouseClick(tile("dnd"), 30, tile("dnd").height / 2);
            compare(Services.notifications.dnd, !was, "tap toggles");
            Services.notifications.setDnd(was);
        }

        // ---- Keep awake ----------------------------------------------------------
        function test_keep_awake() {
            ShellSettings.quickToggles = ["caffeine", "wifi"];
            settle();
            const t = tile("caffeine");
            verify(!t.on);
            mouseClick(t);
            compare(Services.session.idleInhibited, true, "inhibits idle");
            tryVerify(() => tile("caffeine").on, 1000, "tile lit");
            Services.session.setIdleInhibit(false);       // e.g. changed by the backend
            tryVerify(() => !tile("caffeine").on, 1000, "follows the service");
        }

        // ---- Esc chain -------------------------------------------------------------
        function test_escape_chain() {
            cc.openPage("wifi", true);
            tryCompare(cc, "drawer", "wifi");
            cc.forceActiveFocus();
            cc.setEditing(true);                    // closes the Wi-Fi drawer
            compare(cc.drawer, "");
            cc.openPage("sound", false);
            keyClick(Qt.Key_Escape);
            verify(!cc.editing, "Esc leaves edit mode first");
            compare(cc.drawer, "sound");
            keyClick(Qt.Key_Escape);
            compare(cc.drawer, "", "then closes the drawer");
            verify(ShellState.controlCenterOpen);
            keyClick(Qt.Key_Escape);
            verify(!ShellState.controlCenterOpen, "then the panel");
        }

        // ---- fit -------------------------------------------------------------------
        function test_fits_768() {
            compare(win.height, 768);
            verify(cc.fitLevel > 0, "a 768 px screen needs the compact layout");
            tryCompare(cc.panelRect, "height", cc._fitHeight(cc.fitLevel));     // the estimate matches the layout
            verify(cc.panelRect.y >= cc.topMargin, "no scrolling: " + cc.panelRect.y);
            verify(cc.panelRect.y + cc.panelRect.height <= win.height - ShellState.panelReserved, "above the panel");
            compare(ShellSettings.quickCalendarFolded, false, "saved fold untouched");
        }
        function test_calendar_fold() {
            ShellSettings.quickCalendarFolded = false;
            const auto = cc.autoFold;
            compare(cc.calendarCollapsed, auto);
            cc.toggleCalendarFold();
            if (auto) {
                // Unfolded for this opening only.
                verify(!cc.calendarCollapsed);
                compare(ShellSettings.quickCalendarFolded, false);
                cc.toggleCalendarFold();
                verify(cc.calendarCollapsed);
                compare(ShellSettings.quickCalendarFolded, false, "re-folding an auto fold is not saved");
            } else {
                verify(cc.calendarCollapsed);
                compare(ShellSettings.quickCalendarFolded, true, "saved");
                cc.toggleCalendarFold();
                compare(ShellSettings.quickCalendarFolded, false);
            }
            ShellState.closeAll();
            tryVerify(() => !cc.shown, 2000);
            compare(cc.calendarPeek, false, "peek resets on close");
        }

        property string _order: ShellSettings.quickToggles.map(String).join(",")
    }
}
