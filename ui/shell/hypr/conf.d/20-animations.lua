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

-- Every duration stays within 150-300 ms. Exits are shorter than entrances,
-- so a closing window never holds up the one behind it.

-- Windows: open grows 0.95 -> 1 with a fade, close shrinks to 0.97 with a
-- fade. Small scale steps read as smooth; larger ones look like a jump.
anim("windowsIn",   2.6, "lugh", "popin 95%")
anim("windowsOut",  2.0, "lugh", "popin 97%")
-- Snap, maximize, tiling reflow. Kept short: while it runs the app's buffer
-- lags behind the animated size (Hyprland extends its edges, see
-- render.expand_undersized_textures), and a long move makes that visible.
-- Interactive drags and resizes are not animated (30-performance.lua).
anim("windowsMove", 2.2, "lugh")
anim("fadeIn",      2.6, "lugh")
anim("fadeOut",     2.0, "lugh")
anim("fadeSwitch",  1.8, "lugh")
anim("fadeShadow",  1.8, "lugh")
anim("fadeDim",     1.8, "lugh")
anim("fadePopups",  1.5, "lugh")              -- app menus: the shortest

-- Layer surfaces of other programs (input methods, portals' pickers, ...):
-- a plain fade. The shell's own lugh-* surfaces get no compositor animation
-- at all (rule lugh-shell-noanim in 50-rules.lua): they run their own QML
-- motion, and a compositor fade or slide on top doubles it.
anim("layersIn",      2.2, "lugh", "fade")
anim("layersOut",     1.6, "lugh", "fade")
anim("fadeLayersIn",  2.2, "lugh")
anim("fadeLayersOut", 1.6, "lugh")

-- Workspaces: the 2 x 2 grid (lugh/workspaces.lua) moves both across and up
-- and down, but Hyprland has one style for all switches. "slidefade 20%"
-- slides a fifth of the screen while cross-fading, so a vertical move does
-- not read as a full sideways slide, and the 3-finger horizontal swipe still
-- tracks the fingers. lugh.anim.workspaces_axis("vertical"|"horizontal")
-- switches to a full slide on one axis for code that knows the direction.
local WS_SPEED = 2.8
anim("workspaces",       WS_SPEED, "lugh", "slidefade 20%")
anim("specialWorkspace", 2.6, "lugh", "slidefadevert 20%")

-- Border color change (Focus mode). No rotating gradient.
anim("border", 1.5, "lugh")
hl.animation({ leaf = "borderangle", enabled = false })

anim("zoomFactor", 2.4, "lugh")

lugh.anim = lugh.anim or {}
function lugh.anim.workspaces_axis(axis)
    anim("workspaces", WS_SPEED, "lugh", axis == "vertical" and "slidevert" or "slide")
end
