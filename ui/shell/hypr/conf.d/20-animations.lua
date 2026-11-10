-- Animations (DESIGN-SYSTEM §5).
--
-- Hyprland speeds are in deciseconds: speed 3 = 300 ms, 2.4 = 240 ms, 1.8 = 180 ms.
-- Design durations: micro 120, small 180, medium 240, large 300 ms.
--
-- One curve for everything: cubic-bezier(0.2, 0, 0, 1), the design's easing.
-- Springs (stiffness 400, damping 32) are not used yet: the Lua spring field was
-- renamed between 0.55 (`dampening`) and 0.57 (`damping`), and the bezier gives
-- the same settle without overshoot. Revisit when the Lugh repo pins a version.

hl.config({
    animations = {
        enabled = true,
        workspace_wraparound = false,
    },
})

hl.curve("lugh",   { type = "bezier", points = { { 0.2, 0 }, { 0, 1 } } })
hl.curve("linear", { type = "bezier", points = { { 0, 0 }, { 1, 1 } } })

local function anim(leaf, speed, curve, style)
    hl.animation({ leaf = leaf, enabled = true, speed = speed, bezier = curve, style = style })
end

-- Windows: open scales 0.94 -> 1 with a fade, close scales to 0.96 with a fade.
anim("windowsIn",   3,   "lugh", "popin 94%")
anim("windowsOut",  3,   "lugh", "popin 96%")
anim("windowsMove", 3,   "lugh")              -- snap, maximize, tiling reflow
anim("fadeIn",      3,   "lugh")
anim("fadeOut",     3,   "lugh")
anim("fadeSwitch",  1.8, "lugh")
anim("fadeShadow",  1.8, "lugh")
anim("fadeDim",     1.8, "lugh")
anim("fadePopups",  1.2, "lugh")              -- app menus: micro

-- Layer surfaces (bar, dock, launcher, OSD, ...): fade in 240 ms, out 180 ms.
-- The shell runs its own QML motion inside the surfaces; this only covers the
-- moment a surface maps or unmaps.
anim("layersIn",      2.4, "lugh", "fade")
anim("layersOut",     1.8, "lugh", "fade")
anim("fadeLayersIn",  2.4, "lugh")
anim("fadeLayersOut", 1.8, "lugh")

-- Workspaces slide horizontally (matches the 3-finger swipe), 300 ms.
anim("workspaces",       3, "lugh", "slide")
anim("specialWorkspace", 3, "lugh", "slidevert")

-- Border color change (Focus mode): micro. No rotating gradient.
anim("border", 1.2, "lugh")
hl.animation({ leaf = "borderangle", enabled = false })

anim("zoomFactor", 3, "lugh")
