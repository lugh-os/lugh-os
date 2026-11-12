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

-- Firefox on a fresh profile maps its main window at ~500x200 before it has
-- a remembered size. Give the main browser window (initial title "Mozilla
-- Firefox"; dialogs and the Library window have other titles) a sensible
-- first size; the clamp below keeps it inside the usable area.
hl.window_rule({
    name  = "lugh-firefox-size",
    match = { class = "^(firefox|firefox-esr|org.mozilla.firefox)$", initial_title = "^Mozilla Firefox$" },
    size  = "monitor_w*0.72 monitor_h*0.78",
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

-- Floating windows that open bigger than the usable area (the screen minus
-- the dock), or partly off it, are shrunk and centered so their title bar
-- and edges stay reachable. Rules can't express "at most the screen", so a
-- window.open handler does it (lugh/window.lua), and again when monitors or
-- their scale change.
require("lugh.window").install_clamp()

-- Per-workspace tiling (Super+T): restores the workspaces that had tiling on
-- before a `hyprctl reload`.
require("lugh.tiling").restore()

---------------------------------------------------------------------------
-- Layer surfaces (namespaces set by lugh-shell through LayerShellQt)
---------------------------------------------------------------------------

-- Glass surfaces: blur what is behind them. ignore_alpha 0.55 = pixels of
-- the surface with alpha below 0.55 (the transparent margins around the
-- dock, the soft shadows and glows QML draws around a panel, anti-aliased
-- edges) are not blurred, so the blur never shows past the visible glass
-- shape as a second, larger shape. Glass fills themselves are more opaque
-- than that (DESIGN-SYSTEM shell-glass).
local glass = {
    "lugh-dock",
    "lugh-launcher",
    "lugh-overview",
    "lugh-customize",
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
        ignore_alpha = 0.55,
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

-- The shell owns the motion of all its surfaces: they grow out of an island
-- with QML's liquid motion (docs/design/lugh-mode.md) and unmap when their own
-- exit has finished. A compositor fade or slide on top would only double it
-- (or slide from the wrong edge), so every lugh-* namespace, present and
-- future, gets none. Turn it back on from user.lua with
-- lugh.rules.shell_noanim:set_enabled(false).
lugh.rules = lugh.rules or {}
lugh.rules.shell_noanim = hl.layer_rule({
    name    = "lugh-shell-noanim",
    match   = { namespace = "^lugh-.+$" },
    no_anim = true,
})

---------------------------------------------------------------------------
-- Workspaces
---------------------------------------------------------------------------

-- Workspace 1 always exists on the primary monitor.
hl.workspace_rule({ workspace = "1", persistent = true, default = true })
