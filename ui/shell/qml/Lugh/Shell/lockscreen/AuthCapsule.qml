// The floating glass capsule that asks for a password (or any one-line
// answer) on the lock screen and in the greeter (docs/design/lugh-mode.md
// §3 "Lock / greeter"). ui/greeter/qml/AuthCapsule.qml is a copy of this file:
// the greeter depends only on Lugh.UI. Keep the two identical.
//
//   AuthCapsule {
//       avatarName: user.realName; avatarSource: user.avatar
//       busy: session.authenticating; errorText: session.authError
//       capsLock: keyboard.capsLock
//       onSubmitted: session.unlock(text)
//   }
//
// Layout: [avatar 32 | field | reveal | round accent submit] in a 48 px glass
// capsule. `leadingIcon` puts an icon disc in place of the avatar.
//
// Motion (all x / width / scale / opacity; none under reduce motion except
// short fades):
//   - squish(): a quick press of the whole capsule (called on submit).
//   - shake():  a short kick to the side that settles like liquid.
//   - done:     the capsule contracts into a dot around the avatar.
//   - messages: error / info / Caps Lock show in a small capsule that glides
//     out from under this one. It hangs below the item's own bounds, so the
//     layout around the capsule never moves.
//   - busy:     the submit button shows a spinner; the field is read-only.
import QtQuick
import QtQuick.Templates as T
import Lugh.UI

FocusScope {
    id: root

    // ---- who / what --------------------------------------------------------
    property url avatarSource: ""
    property string avatarName: ""
    // Icon disc instead of the avatar (username field, extra prompts).
    property string leadingIcon: ""
    property string placeholder: qsTr("Password")
    // Masked input with a reveal button.
    property bool secret: true
    property bool showSubmit: true
    property string submitTooltip: qsTr("Unlock")
    // Submit with an empty field (password-less accounts in the greeter).
    property bool allowEmpty: false
    // Accessible label of the field ("Password for Amara Nkusi").
    property string a11yLabel: placeholder
    // Left / Right in an empty field emit horizontalArrow() instead of moving
    // the caret (the greeter switches user).
    property bool arrowsWhenEmpty: false

    // ---- state -------------------------------------------------------------
    property bool busy: false
    // Success: contract into a dot.
    property bool done: false
    property string errorText: ""
    property string infoText: ""
    property bool capsLock: false
    // Widest the message capsule may get before its text wraps.
    property int maxMessageWidth: 400

    readonly property alias field: field
    readonly property alias text: field.text
    readonly property bool canSubmit: showSubmit && !busy && !done && (allowEmpty || field.length > 0)
    // True while something of the capsule moves (tests, first-frame checks).
    readonly property bool animating: shakeAnim.running || widthSpring.running || squishSpring.running
                                      || messageSlide.running

    signal submitted()
    signal edited()
    // Any key pressed in the field (hosts use it as "the user is here").
    signal activity()
    // Esc: the field has been cleared; wasEmpty tells if it already was.
    signal escapePressed(bool wasEmpty)
    signal horizontalArrow(int direction)

    function clear() { field.clear(); field._revealed = false; }
    function focusField() { field.forceActiveFocus(Qt.OtherFocusReason); }
    // Text typed while the focus was elsewhere.
    function typeText(t) {
        focusField();
        if (!field.readOnly) field.insert(field.cursorPosition, t);
    }
    function submit() {
        if (!canSubmit) return;
        squish();
        submitted();
    }
    function shake() {
        if (Theme.reduceMotion) return;
        shakeAnim.restart();
    }
    function squish() {
        if (Theme.reduceMotion) return;
        _squished = true;
        squishRelease.restart();
    }
    // Put the capsule in its settled state at once (no running animation).
    function settle() {
        shakeAnim.complete();
        squishRelease.stop();
        _squished = false;
    }

    property bool _squished: false
    property bool _ready: false
    Component.onCompleted: _ready = true

    // ---- messages (latched so the text stays while the capsule glides away) --
    readonly property var _messages: {
        const m = [];
        if (errorText !== "") m.push({ kind: "error", icon: "circle-alert", text: errorText });
        else if (infoText !== "") m.push({ kind: "info", icon: "info", text: infoText });
        if (capsLock && secret) m.push({ kind: "caps", icon: "arrow-big-up", text: qsTr("Caps Lock is on") });
        return m;
    }
    property var _latched: _messages
    on_MessagesChanged: if (_messages.length > 0) _latched = _messages
    readonly property bool _messageShown: _messages.length > 0 && !done

    implicitWidth: 320
    implicitHeight: 48

    // ---- message capsule (under the main one, clipped at its bottom edge) ---
    Item {
        id: messageClip
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.height - 1
        width: root.maxMessageWidth
        height: message.height + Theme.space8 + 2
        clip: true
        visible: message.opacity > 0

        Rectangle {
            id: message
            anchors.horizontalCenter: parent.horizontalCenter
            width: messageColumn.implicitWidth + Theme.space12 * 2
            height: messageColumn.implicitHeight + Theme.space8 * 2
            radius: Math.min(height / 2, Theme.space16)
            // Near-opaque so danger / warning text stays AA on any wallpaper.
            color: Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, 0.92)
            border.width: 1
            border.color: Theme.glassBorder
            antialiasing: true

            y: root._messageShown || Theme.reduceMotion ? Theme.space8 : -height
            opacity: root._messageShown ? 1 : 0

            Behavior on y {
                enabled: root._ready && !Theme.reduceMotion
                SpringAnimation {
                    id: messageSlide
                    spring: Theme.liquidSpring; damping: Theme.liquidDamping
                    mass: Theme.liquidMass; epsilon: Theme.springEpsilon
                }
            }
            Behavior on opacity {
                enabled: root._ready
                NumberAnimation {
                    duration: Theme.dur(Theme.durSmall)
                    easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
                }
            }

            Column {
                id: messageColumn
                anchors.centerIn: parent
                spacing: Theme.space4

                Repeater {
                    model: root._latched
                    delegate: Row {
                        id: line
                        required property var modelData
                        spacing: Theme.space8
                        Accessible.role: modelData.kind === "error" ? Accessible.AlertMessage : Accessible.StaticText
                        Accessible.name: modelData.text

                        Icon {
                            name: line.modelData.icon
                            size: 14
                            color: line.modelData.kind === "error" ? Theme.danger
                                 : line.modelData.kind === "info" ? Theme.info : Theme.warning
                            // Centered on the first line of a wrapped message.
                            y: Math.round((lineText.implicitHeight / Math.max(1, lineText.lineCount) - height) / 2)
                        }
                        Text {
                            id: lineText
                            width: Math.min(implicitWidth, root.maxMessageWidth - Theme.space12 * 2 - 14 - Theme.space8)
                            text: line.modelData.text
                            font: Theme.typeLabel
                            color: line.modelData.kind === "error" ? Theme.danger : Theme.text
                            wrapMode: Text.Wrap
                            maximumLineCount: 3
                            elide: Text.ElideRight
                            Accessible.ignored: true
                        }
                    }
                }
            }
        }
    }

    // ---- the capsule -------------------------------------------------------------
    Item {
        id: body
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.done && !Theme.reduceMotion ? root.height : root.width
        height: root.height
        scale: root._squished ? 0.965 : 1
        transform: Translate { id: shakeShift }

        Behavior on width {
            enabled: root._ready && !Theme.reduceMotion
            SpringAnimation {
                id: widthSpring
                spring: Theme.liquidSpring; damping: Theme.liquidDamping
                mass: Theme.liquidMass; epsilon: Theme.springEpsilon
            }
        }
        Behavior on scale {
            enabled: root._ready && !Theme.reduceMotion
            SpringAnimation {
                id: squishSpring
                spring: Theme.snappySpring; damping: Theme.snappyDamping
                mass: Theme.snappyMass; epsilon: 0.0005
            }
        }

        GlassPanel {
            anchors.fill: parent
            radius: height / 2
            elevation: "popover"
        }
        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: "transparent"
            FocusRing { show: field._keyboardFocus && !root.done }
        }

        // Leading: the avatar, or an icon disc. Stays when the capsule is a dot.
        Avatar {
            x: Theme.space8
            anchors.verticalCenter: parent.verticalCenter
            size: 32
            ring: false
            visible: root.leadingIcon === ""
            source: root.avatarSource
            name: root.avatarName
        }
        Rectangle {
            x: Theme.space8
            anchors.verticalCenter: parent.verticalCenter
            width: 32
            height: 32
            radius: 16
            visible: root.leadingIcon !== ""
            color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.08)
            Icon {
                anchors.centerIn: parent
                name: root.leadingIcon
                size: 16
                color: Theme.textMuted
            }
        }

        Item {
            id: inner
            anchors.fill: parent
            opacity: root.done ? 0 : 1
            visible: opacity > 0
            Behavior on opacity {
                enabled: root._ready
                NumberAnimation { duration: Theme.dur(Theme.durMicro) }
            }

            TextField {
                id: field
                x: Theme.space8 + 32 + Theme.space8
                y: Math.round((parent.height - height) / 2)
                width: Math.max(0, parent.width - x - (root.showSubmit ? 32 + Theme.space8 + Theme.space4 : Theme.space12))
                leftPadding: Theme.space4
                password: root.secret
                placeholderText: root.placeholder
                readOnly: root.busy || root.done
                focus: true
                font: Theme.typeBody
                // The capsule is the field's box.
                background: Item { implicitWidth: 120; implicitHeight: 36 }

                // Qt blanks Accessible.name while passwordEdit is set, so the
                // label also goes in the description (read by Orca).
                Accessible.name: root.a11yLabel
                Accessible.description: [root.a11yLabel, root.errorText !== "" ? root.errorText : root.infoText,
                                         root.capsLock && root.secret ? qsTr("Caps Lock is on") : ""]
                                        .filter(s => s !== "").join(". ")

                // Without a submit button (a username field) Enter still reports.
                onAccepted: root.showSubmit ? root.submit() : root.submitted()
                onTextEdited: root.edited()
                Keys.onPressed: event => {
                    root.activity();
                    if (event.key === Qt.Key_Escape) {
                        const wasEmpty = field.text === "";
                        root.clear();
                        root.escapePressed(wasEmpty);
                        event.accepted = true;
                    } else if (root.arrowsWhenEmpty && field.text === ""
                               && (event.key === Qt.Key_Left || event.key === Qt.Key_Right)) {
                        root.horizontalArrow(event.key === Qt.Key_Left ? -1 : 1);
                        event.accepted = true;
                    }
                }
            }

            T.Button {
                id: submitButton
                x: parent.width - width - Theme.space8
                anchors.verticalCenter: parent.verticalCenter
                width: 32
                height: 32
                visible: root.showSubmit
                enabled: root.canSubmit
                focusPolicy: Qt.TabFocus
                hoverEnabled: true
                padding: 0
                scale: down && !Theme.reduceMotion ? 0.92 : 1
                Behavior on scale {
                    enabled: !Theme.reduceMotion
                    SpringAnimation {
                        spring: Theme.snappySpring; damping: Theme.snappyDamping
                        mass: Theme.snappyMass; epsilon: 0.0005
                    }
                }
                Accessible.role: Accessible.Button
                Accessible.name: root.submitTooltip
                Accessible.description: root.busy ? qsTr("Checking your password")
                                      : !enabled ? qsTr("Type your password first") : ""
                onClicked: { root.focusField(); root.submit(); }

                background: Rectangle {
                    radius: width / 2
                    antialiasing: true
                    color: submitButton.down ? Qt.tint(Theme.accent, Theme.pressedOverlay)
                         : submitButton.hovered ? Qt.tint(Theme.accent, Theme.hoverOverlay) : Theme.accent
                    // Waiting for input: dimmed. Authenticating: full, with a spinner.
                    opacity: submitButton.enabled || root.busy ? 1 : Theme.disabledOpacity
                    Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durMicro) } }
                    FocusRing { show: submitButton.visualFocus }
                }
                contentItem: Item {
                    Icon {
                        anchors.centerIn: parent
                        name: "arrow-right"
                        size: 16
                        color: Theme.onAccent
                        visible: !root.busy
                        opacity: submitButton.enabled ? 1 : 0.6
                    }
                    Spinner {
                        anchors.centerIn: parent
                        size: 16
                        color: Theme.onAccent
                        running: root.busy && submitButton.visible
                        visible: root.busy
                    }
                }
                Tooltip {
                    text: root.busy ? qsTr("Checking your password") : root.submitTooltip
                    visible: submitButton.hovered || submitButton.visualFocus
                }
            }
        }
    }

    // ---- animations ------------------------------------------------------------
    // A kick to the left, then it swings back and settles (about 0.4 s).
    SequentialAnimation {
        id: shakeAnim
        NumberAnimation { target: shakeShift; property: "x"; to: -12; duration: 70; easing.type: Easing.OutQuad }
        NumberAnimation {
            target: shakeShift; property: "x"; to: 0; duration: 360
            easing.type: Easing.OutElastic; easing.amplitude: 1.0; easing.period: 0.42
        }
    }
    Timer {
        id: squishRelease
        interval: 110
        onTriggered: root._squished = false
    }
}
