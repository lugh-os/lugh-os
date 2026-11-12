-- Look: gaps, frame, shadow and blur for Lugh mode (DESIGN-SYSTEM §4, §2 shell-glass).

hl.monitor({
    output   = "",          -- every output
    mode     = "preferred",
    position = "auto",
    scale    = "auto",       -- Hyprland picks 1, 1.25, 1.5, 2 from the panel DPI
})

hl.config({
    general = {
        -- DESIGN-SYSTEM §4: inner 6 px, outer 10 px.
        gaps_in  = 6,
        gaps_out = 10,

        -- Lugh mode: no border, windows are framed by rounding + shadow.
        -- Focus mode (Phase 2) switches to 2 px accent through the mode preset.
        border_size = 0,
        col = {
            active_border   = "rgb(E8962E)",   -- accent, used by Focus mode
            inactive_border = "rgba(DEDAD200)", -- border token, transparent
        },

        -- Without borders, let the pointer grab window edges for resizing,
        -- with a comfortable 12 px grab area outside the window.
        resize_on_border        = true,
        extend_border_grab_area = 12,
        hover_icon_on_border    = true,

        -- Floating windows snap to each other and to the screen edges,
        -- keeping the same gaps as tiling.
        snap = {
            enabled      = true,
            window_gap   = 10,
            monitor_gap  = 10,
            respect_gaps = true,
        },

        layout = "dwindle", -- used by workspaces where tiling is on (Super+T)

        -- Tearing stays off on the desktop. Games can opt in per window with an
        -- `immediate` window rule in user.lua.
        allow_tearing = false,
    },

    dwindle = {
        preserve_split = true,
    },

    decoration = {
        -- DESIGN-SYSTEM §4: windows and popovers use radius 14.
        rounding       = 14,
        rounding_power = 2.0,

        active_opacity   = 1.0,
        inactive_opacity = 1.0,

        -- Soft, neutral shadow (DESIGN-SYSTEM §4: never colored).
        -- 0x2e = 46/255 = 0.18 alpha; the inactive one is lighter (0.10).
        shadow = {
            enabled        = true,
            range          = 24,
            render_power   = 3,
            offset         = "0 4",
            color          = "rgba(0000002e)",
            color_inactive = "rgba(0000001a)",
        },

        -- Blur is used ONLY behind the shell's layer surfaces (bar, dock,
        -- launcher, ... see 50-rules.lua). Windows get no_blur by rule.
        -- Kawase blur: size 8 x 2 passes reads like the 30 px CSS blur of
        -- DESIGN-SYSTEM's shell-glass, at about half the cost of 3 passes.
        blur = {
            enabled           = true,
            size              = 8,
            passes            = 2,
            new_optimizations = true,  -- cache the blurred wallpaper; re-blur only on damage
            xray              = false, -- blur what is really behind (windows too), not just the wallpaper
            ignore_opacity    = true,  -- blur strength independent of the surface's alpha
            noise             = 0.01,  -- a touch of grain against banding
            contrast          = 1.0,
            brightness        = 1.0,
            vibrancy          = 0.12,  -- subtle color lift, like frosted glass
            vibrancy_darkness = 0.0,
            popups            = false, -- no blur behind app popup menus
            special           = false, -- no blur behind special workspaces (expensive)
            input_methods     = false,
        },

        dim_inactive = false,
    },
})

-- Title bars for windows that rely on the compositor for their frame (foot,
-- mpv, Qt, X11 apps, ...): Lugh's hyprbars build, 26 px, buttons on the right,
-- theme colours. Loaded only when installed for this Hyprland version; see
-- lugh/titlebars.lua.
require("lugh.titlebars").setup()
