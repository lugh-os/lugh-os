// Mock terminal content (foot-like), JetBrains Mono. The terminal keeps its
// own dark palette in both themes, as foot does by default.
pragma ComponentBehavior: Bound
import QtQuick
import Lugh.UI

Item {
    id: root
    clip: true
    // foot's palette (matches the dark tokens of DESIGN-SYSTEM §2.2).
    readonly property color fg: "#EDEBE6"
    readonly property color dim: "#A29D94"
    readonly property color green: "#4CC38A"
    readonly property color blue: "#5BB4DA"
    readonly property color amber: "#F2A93B"

    function prompt() {
        return "<font color='" + green + "'>amara@lugh-laptop</font>:<font color='" + blue + "'>~</font>$ ";
    }
    function esc(s) { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;"); }

    readonly property var lines: [
        prompt() + "lugh status",
        "<font color='" + amber + "'>Lugh 0.1</font> (Phase 1 preview) · Debian 13 trixie",
        "<font color='" + dim + "'>shell    </font> lugh-shell 0.1.0    running    94 MB",
        "<font color='" + dim + "'>session  </font> Hyprland            Lugh mode",
        "<font color='" + dim + "'>updates  </font> 12 ready            snapshot first",
        "",
        prompt() + "git log --oneline -3",
        "<font color='" + amber + "'>f6f27e1</font> fix(branding): rebuild live image os-release",
        "<font color='" + amber + "'>fee450b</font> fix(grub): skip unsigned fonts under Secure Boot",
        "<font color='" + amber + "'>b13fb56</font> fix(iso): show Plymouth splash with serial console",
        "",
        prompt() + "free -h | head -2",
        esc("               total   used   free  shared  buff/cache"),
        esc("Mem:            7.6Gi  1.9Gi  3.8Gi   212Mi       2.1Gi"),
        prompt()
    ]

    Column {
        id: column
        anchors { fill: parent; margins: 12 }
        spacing: 2
        Repeater {
            model: root.lines
            delegate: Text {
                id: line
                required property string modelData
                required property int index
                width: column.width
                text: modelData === "" ? " " : modelData
                textFormat: Text.StyledText
                font: Theme.typeMono
                color: root.fg
                elide: Text.ElideRight
                // Block cursor after the last prompt.
                Rectangle {
                    visible: line.index === root.lines.length - 1
                    x: line.contentWidth + 1
                    y: 2
                    width: 8
                    height: line.height - 3
                    color: root.fg
                    opacity: 0.85
                }
            }
        }
    }
}
