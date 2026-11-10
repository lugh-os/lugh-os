-- Helpers to reach lugh-shell over D-Bus (space.lugh.Shell1 on the session bus).
--
-- busctl ships with systemd (always installed). Calls are fire-and-forget
-- (--expect-reply=no): a key press never waits on the shell. If the shell is
-- restarting, D-Bus activation (space.lugh.Shell1.service ->
-- lugh-shell.service) queues the call until it is back.

local M = {}

M.bus_name  = "space.lugh.Shell1"
M.path      = "/space/lugh/Shell1"
M.interface = "space.lugh.Shell1"

-- Quote one argument for /bin/sh.
local function q(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end
M.quote = q

-- Build the shell command for a method call.
-- M.command("ShowLauncher", "s", "")  ->  busctl --user ... ShowLauncher s ''
function M.command(method, signature, ...)
    local parts = {
        "busctl --user --expect-reply=no call",
        M.bus_name, M.path, M.interface, method,
    }
    if signature and signature ~= "" then
        parts[#parts + 1] = signature
        for _, arg in ipairs({ ... }) do
            parts[#parts + 1] = q(arg)
        end
    end
    return table.concat(parts, " ")
end

-- A dispatcher for hl.bind(): hl.bind("SUPER + SPACE", shell.dsp("ShowLauncher", "s", ""))
function M.dsp(method, signature, ...)
    return hl.dsp.exec_cmd(M.command(method, signature, ...))
end

-- Run the call now (from Lua callbacks such as gestures).
function M.call(method, signature, ...)
    hl.exec_cmd(M.command(method, signature, ...))
end

return M
