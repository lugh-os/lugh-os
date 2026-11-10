-- Low-power profile: for weak GPUs, battery saver and the power-saver profile.
--
-- Applied on top of the normal config by lugh.lua when
-- $XDG_RUNTIME_DIR/lugh/hypr-low-power exists (or LUGH_LOW_POWER=1).
-- The shell switches it with scripts/low-power.sh on|off (flag + `hyprctl reload`),
-- e.g. when power-profiles-daemon goes to "power-saver" or the battery is low.
--
-- What it saves: the blur passes behind the shell (the biggest cost), shadow
-- rendering for every window, and all animation frames. The desktop then only
-- renders when content changes, with plain compositing. Shell glass surfaces
-- should switch to an opaque fill when blur is off (the shell can read
-- `hyprctl getoption decoration:blur:enabled`).

hl.config({
    decoration = {
        blur   = { enabled = false },
        shadow = { enabled = false },
        rounding = 14, -- rounding stays: it is nearly free and part of the look
    },
    animations = {
        enabled = false,
    },
})
