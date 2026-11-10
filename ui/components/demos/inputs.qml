// Visual check for LughUI inputs: TextField, SearchField, ListRow, Tabs, Menu,
// MenuItem, MenuSeparator, Tooltip in their states.
//   QT_QPA_PLATFORM=offscreen scripts/qml-shot.sh ui/components/demos/inputs.qml /tmp/lugh-shots/inputs/light.png 1200 900
//   ... 1200 900 900 -- --dark
import QtQuick
import QtQuick.Layouts
import QtQuick.Templates as T
import Lugh.UI

Item {
    id: root
    anchors.fill: parent
    Component.onCompleted: Theme.dark = Qt.application.arguments.indexOf("--dark") >= 0

    component Section: Text {
        font.family: Theme.fontUi
        font.pixelSize: Theme.typeCaption.pixelSize
        font.weight: Font.DemiBold
        color: Theme.textMuted
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 0.6
        Layout.topMargin: Theme.space8
    }
    component Label: Text {
        font: Theme.typeCaption
        color: Theme.textMuted
    }

    Rectangle { anchors.fill: parent; color: Theme.bg }

    RowLayout {
        anchors.fill: parent
        anchors.margins: Theme.space32
        spacing: Theme.space32

        // ---- column 1: text fields -----------------------------------------
        ColumnLayout {
            Layout.preferredWidth: 340
            Layout.alignment: Qt.AlignTop
            spacing: Theme.space8

            Text { text: "Inputs"; font: Theme.typeTitle2; color: Theme.text }
            Section { text: "TextField" }
            Label { text: "Empty" }
            TextField { Layout.fillWidth: true; placeholderText: "Device name" }
            Label { text: "Filled, leading icon, clearable" }
            TextField { Layout.fillWidth: true; iconName: "user"; text: "Aoife Ní Bhriain"; clearable: true; placeholderText: "Full name" }
            Label { text: "Focused (keyboard)" }
            TextField { id: focused; Layout.fillWidth: true; iconName: "server"; text: "lugh-desktop"; placeholderText: "Hostname" }
            Label { text: "Error" }
            TextField {
                Layout.fillWidth: true; text: "my_laptop!"; placeholderText: "Hostname"
                errorText: "Use letters, digits and hyphens only."
            }
            Label { text: "Password (masked, reveal)" }
            TextField { Layout.fillWidth: true; password: true; text: "correct horse"; placeholderText: "Password"; iconName: "lock" }
            Label { text: "Disabled" }
            TextField { Layout.fillWidth: true; enabled: false; text: "/home/aoife"; placeholderText: "Home folder" }

            Section { text: "SearchField" }
            SearchField { Layout.fillWidth: true; placeholderText: "Search settings" }
            SearchField { Layout.fillWidth: true; text: "bluetooth" }
        }

        // ---- column 2: launcher field + list rows ---------------------------
        ColumnLayout {
            Layout.preferredWidth: 380
            Layout.alignment: Qt.AlignTop
            spacing: Theme.space8

            Text { text: "Lists"; font: Theme.typeTitle2; color: Theme.text }
            Section { text: "SearchField large (launcher), busy" }
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: launcherCol.implicitHeight + 2 * Theme.space8
                radius: Theme.radiusXl
                color: Theme.surface
                border.width: 1
                border.color: Theme.border
                ColumnLayout {
                    id: launcherCol
                    anchors.fill: parent
                    anchors.margins: Theme.space8
                    spacing: 0
                    SearchField { Layout.fillWidth: true; large: true; placeholderText: "Search apps, files and settings" }
                    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }
                    SearchField { Layout.fillWidth: true; large: true; busy: true; text: "fire" }
                    ListRow { Layout.fillWidth: true; title: "Firefox"; subtitle: "Web browser"; appIcon: "firefox"; highlighted: true; trailingText: "Open" }
                    ListRow { Layout.fillWidth: true; title: "Files"; subtitle: "Browse folders"; appIcon: "org.gnome.Nautilus" }
                }
            }

            Section { text: "ListRow" }
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: rows.implicitHeight + 2 * Theme.space4
                radius: Theme.radiusMd
                color: Theme.surface
                border.width: 1
                border.color: Theme.border
                ColumnLayout {
                    id: rows
                    anchors.fill: parent
                    anchors.topMargin: Theme.space4
                    anchors.bottomMargin: Theme.space4
                    spacing: 0
                    ListRow { Layout.fillWidth: true; title: "Wi-Fi"; subtitle: "Connected to Glasnevin-5G"; iconName: "wifi"; showChevron: true }
                    ListRow { Layout.fillWidth: true; title: "Bluetooth"; iconName: "bluetooth"; trailing: Component { Toggle { checked: true } } }
                    ListRow { Layout.fillWidth: true; title: "English (Ireland)"; iconName: "languages"; selected: true }
                    ListRow { Layout.fillWidth: true; title: "Keyboard-current row with a much longer title that has to elide"; iconName: "keyboard"; highlighted: true; trailingText: "Super+K" }
                    ListRow { Layout.fillWidth: true; title: "Storage"; iconName: "hard-drive"; trailingText: "212 GB free"; showChevron: true }
                    ListRow { Layout.fillWidth: true; title: "Remote desktop"; subtitle: "Needs an administrator"; iconName: "monitor"; enabled: false }
                    ListRow { Layout.fillWidth: true; title: "Erase all content"; iconName: "trash-2"; danger: true }
                }
            }
        }

        // ---- column 3: tabs, menu, tooltip ----------------------------------
        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignTop
            spacing: Theme.space8

            Text { text: "Navigation"; font: Theme.typeTitle2; color: Theme.text }
            Section { text: "Tabs" }
            Tabs { Layout.fillWidth: true; model: ["General", "Network", "Privacy", "About"]; currentIndex: 1 }

            Section { text: "Menu (open)" }
            Item {
                id: menuAnchor
                Layout.fillWidth: true
                implicitHeight: 300
                Menu {
                    id: menu
                    x: 0; y: 0
                    focus: false
                    closePolicy: T.Popup.NoAutoClose
                    MenuItem { text: "Open"; iconName: "folder-open"; shortcutText: "Ctrl+O" }
                    Menu {
                        title: "Open With"
                        MenuItem { text: "Text Editor" }
                        MenuItem { text: "Image Viewer" }
                    }
                    MenuItem { text: "Copy"; iconName: "copy"; shortcutText: "Ctrl+C" }
                    MenuItem { text: "Rename…"; iconName: "pencil"; shortcutText: "F2"; enabled: false }
                    MenuSeparator {}
                    MenuItem { text: "Show Hidden Files"; checkable: true; checked: true; shortcutText: "Ctrl+H" }
                    MenuSeparator {}
                    MenuItem { text: "Move to Trash"; iconName: "trash-2"; danger: true; shortcutText: "Del" }
                }
            }

            Section { text: "Tooltip" }
            Item {
                Layout.fillWidth: true
                implicitHeight: 80
                Rectangle {
                    id: tipTarget
                    x: Theme.space64; y: 44
                    width: 32; height: 32
                    radius: Theme.radiusSm
                    color: Theme.surface2
                    Icon { anchors.centerIn: parent; name: "bell"; size: 18 }
                    Tooltip { visible: true; text: "Do not disturb is off"; delay: 0 }
                }
            }
        }
    }

    Timer {
        // Popups and focus after the first layout pass.
        interval: 50; running: true
        onTriggered: {
            menu.open();
            menu.currentIndex = 2;
            focused.forceActiveFocus(Qt.TabFocusReason);
        }
    }
}
