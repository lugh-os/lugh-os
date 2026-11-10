-- Session start and stop.
--
-- In a real Lugh session (LUGH_SESSION=1, set by lugh-session), once Hyprland
-- is up: push the session environment (WAYLAND_DISPLAY, HYPRLAND_INSTANCE_SIGNATURE,
-- the toolkit variables from 00-env.lua, ...) into systemd and D-Bus activation,
-- then start lugh-session.target, which starts lugh-shell.service and binds
-- graphical-session.target (portals, xdg autostart).
--
-- Nested development sessions (Hyprland started by hand) skip this, so the
-- host session's systemd environment is never touched. Start the shell by hand
-- there (see docs/dev/hyprland.md).

if lugh.session then
    hl.on("hyprland.start", function()
        hl.exec_cmd("lugh-session --ready")
    end)
    -- lugh-session itself stops the target after the compositor exits; this
    -- only makes the shell go away first, before outputs disappear.
    hl.on("hyprland.shutdown", function()
        hl.exec_cmd("systemctl --user stop lugh-shell.service")
    end)
end
