// Loading placeholder (DESIGN-SYSTEM §7: skeleton shimmer, ≤ 1.2 s loop).
//
//   Skeleton { width: 180; height: 12 }
//
// A surface2 block with a soft surface3 band sweeping across it. The band
// moves with an XAnimator (render thread, no per-frame JS) and stops while
// the skeleton is not visible. It sweeps inside the straight part of the
// shape (inset by the radius), so the plain rect clip never shows square
// corners. Reduce motion: static block.
import QtQuick

Rectangle {
    id: root

    radius: Theme.radiusSm
    color: Theme.surface2
    implicitWidth: 120
    implicitHeight: 12
    antialiasing: true

    Accessible.role: Accessible.Animation
    Accessible.name: qsTr("Loading")

    readonly property bool _running: visible && !Theme.reduceMotion && sweep.width > 0

    Item {
        id: sweep
        x: Math.min(root.radius, root.width / 2)
        width: root.width - 2 * x
        height: root.height
        clip: true
        visible: root._running

        Rectangle {
            id: band
            width: Math.max(48, Math.min(160, sweep.width * 0.6))
            height: parent.height
            x: -width
            opacity: 0
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: Qt.rgba(Theme.surface3.r, Theme.surface3.g, Theme.surface3.b, 0) }
                GradientStop { position: 0.5; color: Theme.surface3 }
                GradientStop { position: 1.0; color: Qt.rgba(Theme.surface3.r, Theme.surface3.g, Theme.surface3.b, 0) }
            }
        }

        // Sweep and an opacity envelope, both Animators (render thread). The
        // envelope hides the band while it crosses the clip edges, so no
        // hard edge shows where it enters or leaves.
        ParallelAnimation {
            id: anim
            loops: Animation.Infinite
            running: root._running
            XAnimator {
                target: band
                from: -band.width; to: sweep.width
                duration: 1200
                easing.type: Easing.InOutQuad
            }
            SequentialAnimation {
                OpacityAnimator { target: band; from: 0; to: 1; duration: 450; easing.type: Easing.InQuad }
                PauseAnimation { duration: 300 }
                OpacityAnimator { target: band; from: 1; to: 0; duration: 450; easing.type: Easing.OutQuad }
            }
        }

        onWidthChanged: if (anim.running) anim.restart()
    }
}
