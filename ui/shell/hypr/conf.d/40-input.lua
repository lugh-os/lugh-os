-- Input: keyboard, pointer, touchpad, gestures.

-- Keyboard layout: Calamares (and the live image) write the system layout to
-- /etc/default/keyboard (XKBLAYOUT=..., XKBVARIANT=...). Hyprland does not read
-- it, so we do. Falls back to "us". Users override in user.lua (and Lugh
-- Settings will, from Phase 2).
local function system_keyboard()
    local kb = { layout = "us", variant = "", model = "", options = "" }
    local f = io.open("/etc/default/keyboard", "r")
    if not f then return kb end
    for line in f:lines() do
        local key, value = line:match('^%s*XKB(%u+)%s*=%s*"?([^"]*)"?%s*$')
        if key == "LAYOUT"  and value ~= "" then kb.layout  = value end
        if key == "VARIANT" then kb.variant = value end
        if key == "MODEL"   then kb.model   = value end
        if key == "OPTIONS" then kb.options = value end
    end
    f:close()
    return kb
end
local kb = system_keyboard()

hl.config({
    input = {
        kb_layout  = kb.layout,
        kb_variant = kb.variant,
        kb_model   = kb.model,
        kb_options = kb.options,

        repeat_rate  = 30,
        repeat_delay = 400,

        -- 2 = the pointer gives hover/scroll focus to the window under it, but
        -- keyboard focus moves only on click. This is the desktop (macOS/
        -- Windows) behaviour for a floating-first layout.
        follow_mouse = 2,
        sensitivity  = 0,

        touchpad = {
            natural_scroll       = true,  -- content follows the fingers
            tap_to_click         = true,
            disable_while_typing = true,
            clickfinger_behavior = true,  -- 2-finger click = right click, 3 = middle
            drag_lock            = false,
            scroll_factor        = 1.0,
        },
    },

    gestures = {
        workspace_swipe_distance     = 300,
        workspace_swipe_cancel_ratio = 0.3,
        workspace_swipe_create_new   = true,  -- swiping past the last workspace makes a new one
        workspace_swipe_forever      = false,
    },
})

-- Since 0.51 gestures are declared one by one (the old
-- gestures:workspace_swipe = true option is gone).
-- 3-finger horizontal swipe: previous/next workspace (shell spec, Lugh mode).
hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })

-- 4-finger swipe up: overview (shell spec). Calls the shell over D-Bus.
hl.gesture({
    fingers   = 4,
    direction = "up",
    action    = function() require("lugh.shell").call("ShowOverview") end,
})
