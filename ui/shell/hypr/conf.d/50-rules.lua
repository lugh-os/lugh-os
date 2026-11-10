-- Window, layer and workspace rules.
-- Rule syntax is the 0.53+ one (named rules, `match = {...}`, snake_case effects).

---------------------------------------------------------------------------
-- Windows
---------------------------------------------------------------------------

-- Lugh mode is floating-first: every new window floats, centered, at the size
-- the app asks for. Workspaces where the user turned tiling on (Super+T) get a
-- later rule that wins (see lugh/tiling.lua).
hl.window_rule({
    name   = "lugh-float-by-default",
    match  = { class = ".*" },
    float  = true,
    center = true,
})

-- No blur behind windows, ever (even translucent terminals): blur is for the
-- shell's glass only, and it is the most expensive effect.
hl.window_rule({
    name    = "lugh-no-window-blur",
    match   = { class = ".*" },
    no_blur = true,
})

-- Ignore apps that maximize themselves on start; the user maximizes (Super+Up).
hl.window_rule({
    name           = "lugh-suppress-maximize",
    match          = { class = ".*" },
    suppress_event = "maximize",
})

-- XWayland drag-and-drop helper windows (no class, no title) must never take focus.
hl.window_rule({
    name     = "lugh-fix-xwayland-drags",
    match    = { class = "^$", title = "^$", xwayland = true, float = true, fullscreen = false, pin = false },
    no_focus = true,
})

-- Picture-in-picture: small, pinned on all workspaces, bottom right.
hl.window_rule({
    name  = "lugh-pip",
    match = { title = "^(Picture-in-Picture|Picture in picture)$" },
    float = true,
    pin   = true,
    size  = "480 270",
    move  = "monitor_w-490 monitor_h-340",
})

-- Per-workspace tiling (Super+T): restores the workspaces that had tiling on
-- before a `hyprctl reload`.
require("lugh.tiling").restore()

---------------------------------------------------------------------------
-- Layer surfaces (namespaces set by lugh-shell through LayerShellQt)
---------------------------------------------------------------------------

-- Glass surfaces: blur what is behind them. ignore_alpha 0.3 = pixels of the
-- surface with alpha < 0.3 (the transparent margins around the bar pill, the
-- dock, the shadows QML draws) are not blurred, so blur stays inside the shape.
local glass = {
    "lugh-bar",
    "lugh-dock",
    "lugh-launcher",
    "lugh-controlcenter",
    "lugh-notifications",
    "lugh-notification-center",
    "lugh-menu",
    "lugh-osd",
}
for _, ns in ipairs(glass) do
    hl.layer_rule({
        name         = "lugh-glass-" .. ns,
        match        = { namespace = "^" .. ns .. "$" },
        blur         = true,
        ignore_alpha = 0.3,
    })
end

-- The wallpaper is drawn once and never animated in or out (a fade would show
-- the background color during shell restarts).
hl.layer_rule({
    name    = "lugh-wallpaper",
    match   = { namespace = "^lugh-wallpaper$" },
    no_anim = true,
})

-- lugh-lock: the lock screen itself uses ext-session-lock (not a layer). The
-- namespace is reserved for the pre-lock fade the shell may draw: no blur
-- (the shell blurs the wallpaper itself), no compositor animation.
hl.layer_rule({
    name    = "lugh-lock",
    match   = { namespace = "^lugh-lock$" },
    no_anim = true,
})

-- Off by default: if the shell prefers to own all motion of its surfaces
-- (QML fades), enable this from user.lua or the mode preset with
-- lugh.rules.shell_noanim:set_enabled(true).
lugh.rules = lugh.rules or {}
lugh.rules.shell_noanim = hl.layer_rule({
    name    = "lugh-shell-noanim",
    match   = { namespace = "^lugh-(launcher|controlcenter|notifications|notification-center|menu|osd)$" },
    no_anim = true,
})
lugh.rules.shell_noanim:set_enabled(false)

---------------------------------------------------------------------------
-- Workspaces
---------------------------------------------------------------------------

-- Workspace 1 always exists on the primary monitor.
hl.workspace_rule({ workspace = "1", persistent = true, default = true })
