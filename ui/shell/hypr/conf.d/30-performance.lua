-- Performance and rendering. Each choice says why.
--
-- Rough GPU cost on top of plain compositing (1080p60, Intel Xe iGPU class):
--   * rounding + shadows on windows: ~0.1-0.3 ms/frame, only when windows redraw.
--   * blur behind shell layers: one cached wallpaper blur (new_optimizations)
--     plus a re-blur of the area under a surface when what is behind it changes:
--     ~0.3-0.8 ms for the bar + dock at 2 passes, ~1-2 ms while a large
--     launcher/control center is open over a playing video.
--   * animations: only while they run.
--   * idle desktop: 0 frames rendered (vfr), so ~0 GPU.
-- conf.d/low-power.lua removes blur, shadows and animations for weak GPUs.

hl.config({
    debug = {
        -- Variable frame rate: render only when something is damaged, never
        -- on an idle screen. (Was misc:vfr before 0.55; now lives under debug.)
        vfr = true,

        -- 2 = full damage tracking (the default): redraw only damaged regions.
        damage_tracking = 2,

        -- Logs go to $XDG_RUNTIME_DIR/hypr/<instance>/hyprland.log; no stdout
        -- spam into the journal.
        disable_logs        = false,
        enable_stdout_logs  = false,
    },

    render = {
        -- A fullscreen window's buffer goes straight to the display plane,
        -- skipping composition (less latency, less GPU). 2 = auto: only for
        -- windows that declare content type "game" (wp-content-type), where it
        -- is known to be safe; 1 can flicker on some drivers with other apps.
        direct_scanout = 2,
    },

    misc = {
        -- No Hyprland branding, no random wallpaper, no splash text: Lugh draws
        -- its own wallpaper layer (lugh-wallpaper).
        disable_hyprland_logo     = true,
        disable_splash_rendering  = true,
        force_default_wallpaper   = 0,
        -- What shows before lugh-wallpaper maps, or if the shell is restarting:
        -- the Theme `bg` token (#F7F6F3), so there is never a black flash.
        background_color          = "rgb(F7F6F3)",

        -- Interactive resizes and drags follow the pointer 1:1. Animating them
        -- only adds latency and extra frames.
        animate_manual_resizes        = false,
        animate_mouse_windowdragging  = false,

        -- VRR only for fullscreen windows (games, video): smoother there, and no
        -- refresh-rate flicker on the desktop.
        vrr = 2,

        -- If the shell (which owns the lock screen) crashes while locked, the
        -- restarted shell may take over the lock instead of the red "lockdead"
        -- screen. The session stays locked in between.
        allow_session_lock_restore = true,

        -- Wake the screen on input.
        key_press_enables_dpms   = true,
        mouse_move_enables_dpms  = true,

        -- lugh-session sets XDG_CURRENT_DESKTOP=Lugh:Hyprland on purpose;
        -- don't warn about it.
        disable_xdg_env_checks = true,

        -- "Application not responding" dialog (needs hyprland-guiutils).
        enable_anr_dialog = true,

        -- Raise and focus windows that ask for activation (xdg-activation),
        -- e.g. clicking a link focuses Firefox. Matches macOS/Windows.
        focus_on_activate = true,
    },

    cursor = {
        -- Hardware cursor planes: the cursor moves without redrawing the scene.
        -- 2 = auto: on everywhere except drivers known to break it (NVIDIA).
        no_hardware_cursors = 2,
        -- Keep the cursor theme in sync with GTK settings.
        sync_gsettings_theme = true,
    },

    xwayland = {
        enabled = true,
        -- XWayland apps are not upscaled on HiDPI/fractional outputs: crisp
        -- instead of blurry. They render at native pixels (apps that support
        -- GDK_SCALE/QT_SCALE_FACTOR can be scaled per app).
        force_zero_scaling = true,
    },

    opengl = {
        -- Reduces flicker on the NVIDIA proprietary driver; no effect elsewhere.
        nvidia_anti_flicker = true,
    },

    ecosystem = {
        -- A distro-packaged Hyprland: no "what's new" or donation pop-ups.
        no_update_news  = true,
        no_donation_nag = true,
    },
})
