-- Per-workspace tiling for Lugh mode (Super+T, shell spec "wm.toggle-tiling").
--
-- Lugh mode floats every window (rule lugh-float-by-default). Turning tiling on
-- for a workspace:
--   1. enables a rule "lugh-tile-ws-<id>" (float = false for that workspace),
--      created after the float-by-default rule so it wins for new windows;
--      modal dialogs keep floating;
--   2. tiles the windows already on the workspace;
--   3. records the workspace in $XDG_RUNTIME_DIR/lugh/hypr-tiled-workspaces
--      so it survives `hyprctl reload` (the Lua state is rebuilt on reload);
--   4. emits a socket2 event `custom>>lugh-tiling,<id>,<0|1>` the shell can show.
--
-- Called from: the Super+T bind, and `hyprctl dispatch 'lugh.tiling.toggle'`
-- (scripts/toggle-tiling.sh) for the shell.

local M = {}

M.tiled = {}   -- [workspace id] = true
M.rules = {}   -- [workspace id] = HL.WindowRule handle

local runtime = os.getenv("XDG_RUNTIME_DIR") or "/tmp"
M.state_dir  = runtime .. "/lugh"
M.state_file = M.state_dir .. "/hypr-tiled-workspaces"

local function save()
    os.execute("mkdir -p '" .. M.state_dir .. "'")
    local f = io.open(M.state_file, "w")
    if not f then return end
    for id in pairs(M.tiled) do f:write(tostring(id), "\n") end
    f:close()
end

local function rule_for(id)
    local rule = M.rules[id]
    if not rule then
        rule = hl.window_rule({
            name  = "lugh-tile-ws-" .. id,
            match = { workspace = tostring(id), modal = false },
            float = false,
        })
        M.rules[id] = rule
    end
    return rule
end

-- Turn tiling on or off for workspace `id` (a normal workspace id).
function M.set(id, on)
    on = on and true or false
    rule_for(id):set_enabled(on)
    M.tiled[id] = on or nil

    -- Re-arrange the windows already there.
    for _, w in ipairs(hl.get_workspace_windows(id) or {}) do
        if w.floating == on then
            hl.dispatch(hl.dsp.window.float({ action = on and "unset" or "set", window = w }))
        end
    end
    if not on then
        for _, w in ipairs(hl.get_workspace_windows(id) or {}) do
            hl.dispatch(hl.dsp.window.center({ window = w }))
        end
    end

    save()
    hl.dispatch(hl.dsp.event("lugh-tiling," .. id .. "," .. (on and 1 or 0)))
end

function M.is_tiled(id)
    return M.tiled[id] == true
end

-- Toggle the focused workspace. Special workspaces are left alone.
function M.toggle()
    local ws = hl.get_active_workspace()
    if not ws or ws.special or ws.id == nil or ws.id < 1 then return end
    M.set(ws.id, not M.tiled[ws.id])
end

-- Re-create the rules after a config (re)load. Windows already have the right
-- state, so nothing is dispatched.
function M.restore()
    local f = io.open(M.state_file, "r")
    if not f then return end
    for line in f:lines() do
        local id = tonumber(line)
        if id and id >= 1 then
            M.tiled[id] = true
            rule_for(id):set_enabled(true)
        end
    end
    f:close()
end

lugh.tiling = M
return M
