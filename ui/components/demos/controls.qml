// LughUI controls demo: every button, toggle, slider, segmented control,
// badge and spinner in every state, for screenshots.
//
//   scripts/qml-shot.sh ui/components/demos/controls.qml out.png 1200 900 [900] [-- --dark] [--focus NAME]
//
// --dark       dark theme
// --focus NAME which control shows keyboard focus (only one can):
//              button (default) | icon | toggle | slider | segmented
// --reduce     reduce motion
import QtQuick
import QtQuick.Layouts
import Lugh.UI

Rectangle {
    id: page
    color: Theme.bg

    readonly property var args: Qt.application.arguments
    readonly property string focusName: {
        const i = args.indexOf("--focus");
        return i >= 0 && i + 1 < args.length ? args[i + 1] : "button";
    }

    Component.onCompleted: {
        Theme.dark = args.indexOf("--dark") >= 0;
        Theme.reduceMotion = args.indexOf("--reduce") >= 0;
        const target = { button: focusButton, icon: focusIcon, toggle: focusToggle,
                         slider: focusSlider, segmented: focusSeg }[focusName];
        if (target) target.forceActiveFocus(Qt.TabFocusReason);
    }

    component SectionTitle: Text {
        font: Theme.typeTitle3
        color: Theme.text
        Layout.topMargin: Theme.space8
    }
    component Caption: Text {
        font: Theme.typeCaption
        color: Theme.textMuted
        Layout.preferredWidth: 92
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.space32
        spacing: Theme.space12

        Text {
            text: "LughUI · Controls"
            font: Theme.typeTitle1
            color: Theme.text
        }
        Text {
            text: (Theme.dark ? "Dark" : "Light") + " theme · focus on " + page.focusName
            font: Theme.typeBody
            color: Theme.textMuted
        }

        // ---- Buttons -----------------------------------------------------
        SectionTitle { text: "Button" }
        RowLayout {
            spacing: Theme.space12
            Caption { text: "md" }
            Button { id: focusButton; text: "Install"; variant: "primary"; iconName: "download" }
            Button { text: "Open settings"; iconName: "settings" }
            Button { text: "Share"; variant: "ghost"; iconName: "share" }
            Button { text: "Delete bottle"; variant: "danger"; iconName: "trash-2" }
            Button { text: "Cancel" }
        }
        RowLayout {
            spacing: Theme.space12
            Caption { text: "sm" }
            Button { size: "sm"; text: "Install"; variant: "primary" }
            Button { size: "sm"; text: "Copy"; iconName: "copy" }
            Button { size: "sm"; text: "Details"; variant: "ghost" }
            Button { size: "sm"; text: "Remove"; variant: "danger" }
        }
        RowLayout {
            spacing: Theme.space12
            Caption { text: "pressed" }
            Button { text: "Install"; variant: "primary"; down: true }
            Button { text: "Open settings"; down: true }
            Button { text: "Share"; variant: "ghost"; down: true }
            Button { text: "Delete bottle"; variant: "danger"; down: true }
        }
        RowLayout {
            spacing: Theme.space12
            Caption { text: "loading" }
            Button { text: "Installing"; variant: "primary"; loading: true }
            Button { text: "Checking"; iconName: "download"; loading: true }
            Button { text: "Deleting"; variant: "danger"; iconName: "trash-2"; loading: true }
            Caption { text: "disabled"; Layout.leftMargin: Theme.space12; Layout.preferredWidth: -1 }
            Button { text: "Install"; variant: "primary"; enabled: false; disabledReason: "Not enough space" }
            Button { text: "Apply"; enabled: false; disabledReason: "Nothing changed" }
            Button { text: "Delete"; variant: "danger"; enabled: false }
        }

        // ---- Icon buttons ------------------------------------------------
        SectionTitle { text: "IconButton" }
        RowLayout {
            spacing: Theme.space12
            Caption { text: "variants" }
            IconButton { id: focusIcon; iconName: "settings"; tooltip: "Settings" }
            IconButton { iconName: "search"; tooltip: "Search"; variant: "filled" }
            IconButton { iconName: "plus"; tooltip: "New"; variant: "accent" }
            IconButton { iconName: "bell"; tooltip: "Notifications"; badge: 3 }
            IconButton { iconName: "bell"; tooltip: "Notifications"; variant: "filled"; badge: 128 }
            IconButton { iconName: "star"; tooltip: "Favorite"; checkable: true; checked: true }
            IconButton { iconName: "heart"; tooltip: "Like"; variant: "filled"; checkable: true; checked: true }
            IconButton { iconName: "x"; tooltip: "Close"; down: true }
            IconButton { iconName: "search"; tooltip: "Search"; variant: "filled"; down: true }
            IconButton { iconName: "trash-2"; tooltip: "Delete"; enabled: false }
            IconButton { iconName: "plus"; tooltip: "New"; variant: "accent"; enabled: false }
        }
        RowLayout {
            spacing: Theme.space12
            Caption { text: "glass 44" }
            Rectangle {
                color: Theme.surface3
                radius: Theme.radiusLg
                Layout.preferredWidth: glassRow.implicitWidth + 2 * Theme.space12
                Layout.preferredHeight: glassRow.implicitHeight + 2 * Theme.space12
                Row {
                    id: glassRow
                    anchors.centerIn: parent
                    spacing: Theme.space12
                    IconButton { iconName: "wifi"; tooltip: "Wi-Fi"; variant: "glass"; size: 44; iconSize: 20 }
                    IconButton { iconName: "bluetooth"; tooltip: "Bluetooth"; variant: "glass"; size: 44; iconSize: 20; checkable: true; checked: true }
                    IconButton { iconName: "moon"; tooltip: "Night light"; variant: "glass"; size: 44; iconSize: 20; down: true }
                    IconButton { iconName: "mic"; tooltip: "Microphone"; variant: "glass"; size: 44; iconSize: 20; enabled: false }
                }
            }
        }

        // ---- Toggles + segmented + badges + spinners ---------------------
        RowLayout {
            spacing: Theme.space48
            Layout.fillWidth: true

            ColumnLayout {
                spacing: Theme.space8
                Layout.alignment: Qt.AlignTop
                SectionTitle { text: "Toggle" }
                RowLayout {
                    spacing: Theme.space16
                    Toggle { id: focusToggle; checked: true }
                    Toggle { checked: false }
                    Toggle { checked: true; down: true }
                    Toggle { checked: true; enabled: false; disabledReason: "Managed by policy" }
                    Toggle { checked: false; enabled: false }
                }
                Toggle { text: "Do not disturb"; checked: true; Layout.preferredWidth: 300 }
                Toggle { text: "Show battery percentage"; checked: false; Layout.preferredWidth: 300 }

                SectionTitle { text: "SegmentedControl" }
                SegmentedControl { id: focusSeg; model: ["Lugh", "Classic", "Focus"]; currentIndex: 0 }
                SegmentedControl {
                    model: [{ text: "Grid", iconName: "layout-grid" }, { text: "List", iconName: "list" }]
                    currentIndex: 1
                }
                SegmentedControl { model: ["Day", "Week", "Month"]; currentIndex: 2; enabled: false }
            }

            ColumnLayout {
                spacing: Theme.space8
                Layout.alignment: Qt.AlignTop
                Layout.fillWidth: true
                SectionTitle { text: "Slider" }
                Slider { id: focusSlider; iconName: "volume-2"; iconTooltip: "Mute"; showValue: true; value: 0.62; Layout.fillWidth: true }
                Slider { iconName: "sun"; showValue: true; value: 0.08; Layout.fillWidth: true }
                Slider { iconName: "volume-2"; showValue: true; value: 0; Layout.fillWidth: true }
                Slider { value: 1; showValue: true; Layout.fillWidth: true }
                Slider { value: 0.35; Layout.fillWidth: true; enabled: false }

                SectionTitle { text: "Badge · Spinner" }
                RowLayout {
                    spacing: Theme.space12
                    Badge { text: "3" }
                    Badge { text: "12"; tone: "neutral" }
                    Badge { text: "99+"; tone: "danger" }
                    Badge { text: "New"; tone: "info" }
                    Badge { text: "Signed"; tone: "success" }
                    Badge { dot: true }
                    Badge { dot: true; tone: "danger" }
                    Badge { dot: true; tone: "success" }
                    Item { width: Theme.space12; height: 1 }
                    Spinner {}
                    Spinner { size: 20; color: Theme.accent }
                    Spinner { size: 24; color: Theme.text }
                    Spinner { running: false }
                }
            }
        }

        Item { Layout.fillHeight: true }
    }
}
