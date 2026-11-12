#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# End-to-end desktop test: boot the live ISO in QEMU (UEFI), follow it from
# autologin to the desktop, drive it with the keyboard, log out to the sign-in
# screen and log back in. Screenshots -> out/vm-shots/, logs -> out/vm-logs/.
#
# Usage: scripts/test-desktop.sh [options]
#
#   --iso FILE     ISO to boot (default: $ISO or out/lugh.iso)
#   --gl MODE      auto | on | off (see scripts/qemu-run.sh; off = software
#                  rendering in the guest, which Lugh answers with low power)
#   --keep         leave the VM running when the test ends (sockets in out/vm/)
#   --boot-only    boot, wait for the desktop, then stop here with the VM
#                  running (for fast iteration, docs/dev/testing-desktop.md)
#   --attach       do not boot: test the VM already running from --keep/--boot-only
#   -h, --help     show this help
#
# Environment: BOOT_TIMEOUT (seconds to the desktop, default 300 with KVM,
# 1200 with TCG), LIVE_PASSWORD (default "live"), QEMU_MEM, QEMU_SMP, QEMU_ACCEL.
#
# How it talks to the guest (docs/dev/testing-desktop.md):
#   - serial console (out/vm-logs/serial.log): boot log and the LUGH-MARK lines
#     ("session-ready" from lugh-shell's first frame, "greeter-ready" from
#     lugh-greeter), copied there by lugh-test-markers.service;
#   - QMP: screendump and send-key;
#   - a root command agent on a virtio-serial port, which the image only
#     starts when QEMU offers that port.
# Exits non-zero when any step fails.
#
# Guest commands are single-quoted on purpose: they expand in the guest.
# shellcheck disable=SC2016
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/out"
SHOTS="$OUT/vm-shots"
LOGS="$OUT/vm-logs"
VMDIR="$OUT/vm"
QMP="$VMDIR/qmp.sock"
AGENT="$VMDIR/agent.sock"
VNC="$VMDIR/vnc.sock"
SERIAL="$LOGS/serial.log"
PASSWORD="${LIVE_PASSWORD:-live}"

log()  { printf 'test-desktop: %s\n' "$*" >&2; }
die()  { printf 'test-desktop: error: %s\n' "$*" >&2; exit 2; }

iso="${ISO:-$OUT/lugh.iso}"
gl="${QEMU_GL:-auto}"
keep=0 boot_only=0 attach=0
while (($#)); do
  case "$1" in
    --iso) iso="$2"; shift ;;
    --gl) gl="$2"; shift ;;
    --keep) keep=1 ;;
    --boot-only) boot_only=1; keep=1 ;;
    --attach) attach=1; keep=1 ;;
    -h|--help) sed -n '3,/^set -uo/{/^set -uo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

if [[ -z "${QEMU_ACCEL:-}" ]]; then
  if [[ -r /dev/kvm && -w /dev/kvm ]]; then QEMU_ACCEL=kvm; else QEMU_ACCEL=tcg; fi
fi
export QEMU_ACCEL
if [[ "$QEMU_ACCEL" == kvm ]]; then slow=1; else slow=4; fi
BOOT_TIMEOUT="${BOOT_TIMEOUT:-$((300 * slow))}"

vm()  { python3 "$ROOT/scripts/lib/vm.py" --qmp "$QMP" --agent "$AGENT" --vnc "$VNC" "$@"; }
# g <command>: run as root in the guest.  gu <command>: as the desktop user.
g()   { vm run --timeout "${GT:-40}" "$1"; }
gu()  { g "as-user $(printf '%q' "$1")"; }
key() { vm key "$@"; }
shot() { vm shot "$SHOTS/$1" && log "  screenshot out/vm-shots/$1"; }
now_ms() { date +%s%3N; }

qemu_pid=""
# shellcheck disable=SC2329  # called from the traps below
stop_vm() {
  ((keep)) && return 0
  [[ -n "$qemu_pid" ]] || return 0
  vm quit >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do kill -0 "$qemu_pid" 2>/dev/null || break; sleep 0.1; done
  kill -KILL "$qemu_pid" 2>/dev/null || true
  wait "$qemu_pid" 2>/dev/null || true
  qemu_pid=""
}
trap stop_vm EXIT
trap 'stop_vm; exit 130' INT TERM

# --- results --------------------------------------------------------------------
names=() results=() details=()
failed=0
record() { # record <name> <pass|FAIL|skip> <detail>
  names+=("$1"); results+=("$2"); details+=("${3:-}")
  [[ "$2" == FAIL ]] && failed=1
  log "$(printf '%-34s %-4s %s' "$1" "$2" "${3:-}")"
}
# check <name> <detail-on-pass> <command...>: pass when the command succeeds.
check() {
  local name="$1" detail="$2" out; shift 2
  if out="$("$@" 2>&1)"; then record "$name" pass "$detail"
  else record "$name" FAIL "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"; fi
}

# marker_count <text>: how often a marker is in the serial log so far.
marker_count() { grep -ac "$1" "$SERIAL" 2>/dev/null || true; }
# wait_marker <text> <count> <timeout s>
wait_marker() {
  local deadline=$(( $(date +%s) + $3 ))
  while (( $(marker_count "$1") < $2 )); do
    (( $(date +%s) < deadline )) || return 1
    if [[ -n "$qemu_pid" ]] && ! kill -0 "$qemu_pid" 2>/dev/null; then return 1; fi
    sleep 0.5
  done
}
# wait_guest <timeout s> <command>: until the guest command succeeds.
wait_guest() {
  local deadline=$(( $(date +%s) + $1 ))
  until g "$2" >/dev/null 2>&1; do
    (( $(date +%s) < deadline )) || return 1
    sleep 0.5
  done
}
layer_mapped() { gu 'hyprctl layers' | grep -q "namespace: $1\b"; }
layer_gone()   { ! layer_mapped "$1"; }
# wait_layer <namespace> <mapped|gone> [timeout s]
wait_layer() {
  local deadline=$(( $(date +%s) + ${3:-8} ))
  while :; do
    if [[ "$2" == mapped ]]; then layer_mapped "$1" && return 0; else layer_gone "$1" && return 0; fi
    (( $(date +%s) < deadline )) || return 1
    sleep 0.4
  done
}

# active_ws: id of the focused workspace.
active_ws() { gu 'hyprctl -j activeworkspace' | tr -d '\r' | python3 -c 'import json,sys; t=sys.stdin.read(); print(json.loads(t[t.index("{"):t.rindex("}")+1])["id"])'; }
# win_fits <class regex> [title regex]: the newest matching window lies inside
# its monitor's usable area (monitor minus the reserved panel strip, with room
# for a server-side title bar above it when it has one). Prints the geometry.
# shellcheck disable=SC2329  # run through check()
win_fits() {
  local json
  json="$(gu 'hyprctl -j monitors; echo @@SPLIT@@; hyprctl -j clients; echo @@SPLIT@@; hyprctl -j layers; echo @@SPLIT@@; hyprctl plugin list 2>/dev/null')" || { echo "hyprctl failed"; return 1; }
  python3 - "$1" "${2:-.}" "$json" <<'PY'
import json, re, sys
cls, title, raw = sys.argv[1], sys.argv[2], sys.argv[3].replace("\r", "")
mons, clients, layers, plugins = raw.split("@@SPLIT@@")[:4]
mons, clients, layers = json.loads(mons), json.loads(clients), json.loads(layers)
win = [c for c in clients if re.search(cls, c.get("class", ""), re.I) and re.search(title, c.get("title", ""), re.I) and c.get("mapped", True)]
if not win:
    print(f"no window of class {cls}"); sys.exit(1)
c = min(win, key=lambda c: c.get("focusHistoryID", 99))
m = next(m for m in mons if m["id"] == c["monitor"])
s = m.get("scale", 1) or 1
lw, lh = m["width"] / s, m["height"] / s
if m.get("transform", 0) % 2: lw, lh = lh, lw
l, t, r, b = m.get("reserved", [0, 0, 0, 0])
x0, y0, x1, y1 = m["x"] + l, m["y"] + t, m["x"] + lw - r, m["y"] + lh - b
# the panel's own layer: its top edge (the reserved strip is what Hyprland uses)
dock = [v for mon in layers.values() for lvl in mon["levels"].values() for v in lvl if v.get("namespace") == "lugh-dock"]
bar = 26 if "hyprbars" in plugins else 0
(x, y), (w, h) = c["at"], c["size"]
print(f"{c['class']} at {x},{y} size {w}x{h}; usable {x0:.0f},{y0:.0f}-{x1:.0f},{y1:.0f} (reserved {l},{t},{r},{b}); "
      f"panel layer {[(d['x'], d['y'], d['w'], d['h']) for d in dock]}; floating {c.get('floating')}")
ok = x >= x0 - 1 and y - bar >= y0 - 1 and x + w <= x1 + 1 and y + h <= y1 + 1 and b > 0
sys.exit(0 if ok else 1)
PY
}

mkdir -p "$SHOTS" "$LOGS" "$VMDIR"

# --- boot -----------------------------------------------------------------------
if ((attach)); then
  [[ -S "$QMP" && -S "$AGENT" ]] || die "--attach: no running VM (no sockets in out/vm/)"
  log "attaching to the running VM"
  boot_s="n/a"
else
  [[ -f "$iso" ]] || die "ISO not found: $iso (run 'make iso' first)"
  rm -f "$SHOTS"/*.png "$LOGS"/* "$QMP" "$AGENT" "$VNC"
  : >"$SERIAL"
  log "booting $(basename "$(readlink -f "$iso")") (UEFI, accel=$QEMU_ACCEL, gl=$gl, timeout ${BOOT_TIMEOUT}s)"
  start=$(now_ms)
  QEMU_MEM="${QEMU_MEM:-4G}" "$ROOT/scripts/qemu-run.sh" uefi --iso "$iso" --headless \
    --serial-log "$SERIAL" --gl "$gl" --qmp "$QMP" --vnc "$VNC" --test-agent "$AGENT" --share "$OUT" \
    >"$LOGS/qemu.log" 2>&1 &
  qemu_pid=$!
  if wait_marker "LUGH-MARK: session-ready" 1 "$BOOT_TIMEOUT"; then
    boot_s=$(awk -v ms=$(( $(now_ms) - start )) 'BEGIN { printf "%.1f", ms / 1000 }')
    record "boot to desktop (autologin)" pass "${boot_s}s from QEMU start to the shell's first frame"
  else
    boot_s="n/a"
    record "boot to desktop (autologin)" FAIL "no 'LUGH-MARK: session-ready' on the serial console after ${BOOT_TIMEOUT}s"
    shot 00-boot-failed.png || true
  fi
fi

if ! vm ping --timeout $((60 * slow)); then
  record "guest agent" FAIL "the test agent does not answer (see out/vm-logs/serial.log)"
  tail -n 25 "$SERIAL" | tr -d '\r' | sed 's/^/    | /' >&2
else
  record "guest agent" pass ""
fi

collect_logs() {
  GT=60 g 'journalctl -b --no-pager -o short-monotonic' >"$LOGS/journal.log" 2>&1 || true
  GT=60 gu 'journalctl --user -b -u lugh-shell --no-pager -o short-monotonic' >"$LOGS/lugh-shell.log" 2>&1 || true
  GT=60 g 'journalctl -b -u greetd --no-pager -o short-monotonic' >"$LOGS/greeter.log" 2>&1 || true
  GT=60 g 'journalctl -b -t lugh-hyprland -t lugh-session --no-pager -o short-monotonic' >"$LOGS/hyprland-journal.log" 2>&1 || true
  gu 'cat "$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/hyprland.log"' >"$LOGS/hyprland.log" 2>&1 || true
  g 'systemctl --failed --no-pager; echo; loginctl list-sessions --no-pager; echo; free -m; echo; dpkg-query -W hyprland lugh-shell lugh-greeter lugh-session greetd cage' >"$LOGS/system.txt" 2>&1 || true
}

if ((boot_only)); then
  shot 01-desktop.png || true
  collect_logs
  log "VM left running. QMP: out/vm/qmp.sock  agent: out/vm/agent.sock"
  log "  run a command:  scripts/lib/vm.py --agent out/vm/agent.sock run 'systemctl status greetd'"
  log "  re-test:        scripts/test-desktop.sh --attach"
  exit "$failed"
fi

# --- 01 desktop -----------------------------------------------------------------
sleep 3
shot 01-desktop.png
check "session: user lugh, wayland" "" g 'loginctl list-sessions --no-legend | grep -w lugh >/dev/null && [ "$(loginctl show-user lugh -p State --value)" = active ]'
check "lugh-shell.service active" "" gu 'systemctl --user is-active --quiet lugh-shell.service'
check "D-Bus space.lugh.Shell1" "" gu 'busctl --user introspect space.lugh.Shell1 /space/lugh/Shell1 space.lugh.Shell1 | grep -q ToggleControlCenter'
check "panel, wallpaper mapped" "" gu 'l=$(hyprctl layers); for n in lugh-dock lugh-wallpaper; do echo "$l" | grep -q "namespace: $n" || { echo "missing $n"; exit 1; }; done'
check "no old top bar (lugh-bar) layer" "" gu '! hyprctl layers | grep -q "namespace: lugh-bar\b"'
check "panel reserves the bottom edge" "" gu 'hyprctl -j monitors | tr -d " \n" | grep -Eq "\"reserved\":\[[0-9]+,[0-9]+,[0-9]+,[1-9][0-9]*\]"'
if g 'test -e /usr/lib/lugh/hyprland/hyprbars.so'; then
  check "hyprbars plugin loaded" "" gu 'hyprctl plugin list | grep -qi hyprbars'
else
  record "hyprbars plugin loaded" skip "lugh-hyprbars not installed"
fi
renderer="$(gu 'grep -m1 "\]: Renderer: " "$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/hyprland.log" | sed "s/.*Renderer: //"' 2>/dev/null | tr -d '\r' | head -n1)"
low_power="$(gu 'if systemctl --user show-environment | grep -q "^LUGH_LOW_POWER=1"; then echo on; else echo off; fi' 2>/dev/null | tr -d '\r' | tail -n1)"
record "renderer" pass "${renderer:-unknown}; low power: ${low_power:-?}"
mem_login="$(g 'free -m | awk "/^Mem:/ {print \$3}"' | tr -d '\r' | tail -n1)"
record "memory used after login" pass "${mem_login:-?} MB (whole VM, no apps open)"

# --- 02/03 launcher -------------------------------------------------------------
key meta_l-spc
if wait_layer lugh-launcher mapped; then record "Super+Space opens the launcher" pass ""; else record "Super+Space opens the launcher" FAIL "no lugh-launcher layer"; fi
sleep 1.2; shot 02-launcher.png
vm type fire
sleep 1.5; shot 03-launcher-results.png
key esc; sleep 0.4; key esc
if wait_layer lugh-launcher gone; then record "Esc closes the launcher" pass ""; else record "Esc closes the launcher" FAIL "lugh-launcher still mapped"; fi

# --- 04 control center ----------------------------------------------------------
key meta_l-c
if wait_layer lugh-controlcenter mapped; then record "Super+C opens the control center" pass ""; else record "Super+C opens the control center" FAIL "no lugh-controlcenter layer"; fi
sleep 1.2; shot 04-controlcenter.png
key esc
if wait_layer lugh-controlcenter gone; then record "Esc closes the control center" pass ""; else record "Esc closes the control center" FAIL "still mapped"; fi

# --- 05 notification center -----------------------------------------------------
key meta_l-n
if wait_layer lugh-notification-center mapped; then record "Super+N opens notifications" pass ""; else record "Super+N opens notifications" FAIL "no lugh-notification-center layer"; fi
sleep 1.2; shot 05-notifications.png
key esc
wait_layer lugh-notification-center gone || true

# --- 06 toast -------------------------------------------------------------------
check "notify-send accepted" "" gu 'notify-send -a "Lugh test" "Hello from the test" "The notification service is running."'
if wait_layer lugh-notifications mapped 10; then record "notification toast shown" pass ""; else record "notification toast shown" FAIL "no lugh-notifications layer"; fi
sleep 1; shot 06-toast.png
sleep 6

# --- 15/16/17 overview, workspaces, panel keyboard focus --------------------------
key meta_l-tab
if wait_layer lugh-overview mapped; then record "Super+Tab opens the overview" pass ""; else record "Super+Tab opens the overview" FAIL "no lugh-overview layer"; fi
sleep 1.2; shot 15-overview.png
key esc
if wait_layer lugh-overview gone; then record "Esc closes the overview" pass ""; else record "Esc closes the overview" FAIL "lugh-overview still mapped"; fi

ws_before="$(active_ws 2>/dev/null)"
key ctrl-meta_l-right; sleep 1
ws_after="$(active_ws 2>/dev/null)"
if [[ "$ws_after" == 2 ]]; then record "Super+Ctrl+Right: workspace 2" pass "$ws_before -> $ws_after"
else record "Super+Ctrl+Right: workspace 2" FAIL "active workspace $ws_before -> ${ws_after:-?}"; fi
shot 16-workspace-2.png
key ctrl-meta_l-left; sleep 1
ws_back="$(active_ws 2>/dev/null)"
if [[ "$ws_back" == 1 ]]; then record "Super+Ctrl+Left: back to 1" pass ""; else record "Super+Ctrl+Left: back to 1" FAIL "active workspace ${ws_back:-?}"; fi

# Super+B gives the panel the keyboard with the start button focused; Enter
# then opens the Lugh menu, which proves where the keyboard went.
key meta_l-b; sleep 0.8
shot 17-panel-focus.png
key ret
if wait_layer lugh-menu mapped 5; then record "Super+B, Enter: panel has the keyboard" pass "Enter on the start button opened lugh-menu"
else record "Super+B, Enter: panel has the keyboard" FAIL "Enter after Super+B opened no lugh-menu (see 17-panel-focus.png)"; fi
sleep 1; shot 17b-panel-enter.png
key esc; wait_layer lugh-menu gone 4 || { key esc; wait_layer lugh-menu gone 4 || true; }
key esc; sleep 0.5

# --- 07/08 lock -----------------------------------------------------------------
locked() { gu 'hyprctl layers | grep -q "namespace: lugh-lock"'; }
# kill_shell: SIGKILL lugh-shell, print the ms until the new shell's first frame.
kill_shell() {
  GT=40 g 't0=$(cut -d" " -f1 /proc/uptime)
as-user "systemctl --user kill -s KILL lugh-shell.service"
for i in $(seq 150); do
  t1=$(journalctl -b -t lugh-shell -o short-monotonic --no-pager -g "LUGH-MARK: session-ready" | tail -n1 | sed "s/^\[ *\([0-9.]*\)\].*/\1/")
  if awk -v a="$t0" -v b="${t1:-0}" "BEGIN { exit !(b > a) }"; then
    awk -v a="$t0" -v b="$t1" "BEGIN { printf \"%d\\n\", (b - a) * 1000 }"; exit 0
  fi
  sleep 0.1
done
exit 1' | tr -d '\r' | tail -n1
}
key meta_l-l
if wait_layer lugh-lock mapped 12; then record "Super+L locks the session" pass ""; else record "Super+L locks the session" FAIL "no lugh-lock layer"; fi
sleep 2; shot 07-lock.png
# A shell crash while locked must come back locked (ADR-029).
if ms="$(kill_shell)" && [[ "$ms" =~ ^[0-9]+$ ]]; then
  sleep 1.5
  if locked; then record "shell killed while locked: still locked" pass "lock screen back ${ms} ms after SIGKILL"
  else record "shell killed while locked: still locked" FAIL "the shell restarted unlocked"; fi
else
  record "shell killed while locked: still locked" FAIL "the shell did not come back"
fi
vm type "wrong-password"; key ret
sleep 3.5
check "a wrong password stays locked" "" locked
shot 07b-lock-wrong-password.png
vm type "$PASSWORD"; key ret
sleep 4; shot 08-unlocked.png
if locked; then record "password unlocks" FAIL "still locked after typing the password"; else record "password unlocks" pass ""; fi

# --- apps, crash recovery, numbers (before logging out) -------------------------
# Terminal through its keybind (Ctrl+Alt+T -> launch.sh -> systemd scope).
key ctrl-alt-t
if wait_guest 20 'as-user "hyprctl clients" | grep -qi "class: foot"'; then
  check "Ctrl+Alt+T: foot in an app-lugh scope" "" gu 'systemctl --user list-units --no-legend "app-lugh-*.scope" | grep -q .'
else
  record "Ctrl+Alt+T: foot in an app-lugh scope" FAIL "no foot window after 20s"
fi
sleep 1; shot 11-foot.png
if gu 'hyprctl plugin list' 2>/dev/null | grep -qi hyprbars; then
  check "foot has a Lugh title bar" "" gu 'hyprctl decorations class:foot | grep -qi bar'
fi
key meta_l-up; sleep 1.2
check "Super+Up: maximized foot above the panel" "" win_fits '^foot$'
shot 18-foot-maximized.png
key meta_l-up; sleep 0.8
key meta_l-left; sleep 1.2
check "Super+Left: snapped foot above the panel" "" win_fits '^foot$'
shot 19-foot-snapped.png
# An app asking for far more than the screen gets clamped into the usable area.
gu 'setsid -f foot --title lugh-huge -W 400x150 >/dev/null 2>&1' >/dev/null 2>&1 || true
if wait_guest 15 'as-user "hyprctl clients" | grep -q "title: lugh-huge"'; then
  sleep 1.2
  check "huge floating window clamped" "" win_fits '^foot$' '^lugh-huge$'
else
  record "huge floating window clamped" FAIL "the 400x150-cell foot did not open"
fi
shot 20-huge-clamped.png
gu 'hyprctl dispatch "hl.dsp.window.close({ window = \"title:^lugh-huge$\" })"' >/dev/null 2>&1 || true
sleep 0.5

# Firefox through the launcher: Super+Space, "fire", Enter.
key meta_l-spc; wait_layer lugh-launcher mapped || true
sleep 0.8; vm type fire; sleep 1.5; key ret
if wait_guest $((90 * slow)) 'as-user "hyprctl clients" | grep -qi "class: firefox"'; then
  check "launcher starts Firefox in a scope" "" gu 'systemctl --user list-units --no-legend "app-lugh-*.scope" | grep -qi firefox'
else
  record "launcher starts Firefox in a scope" FAIL "no Firefox window after $((90 * slow))s"
fi
sleep 6; shot 12-firefox.png
if gu 'hyprctl plugin list' 2>/dev/null | grep -qi hyprbars; then
  check "Firefox draws its own frame (no Lugh bar)" "" gu '! hyprctl decorations class:firefox | grep -qi bar'
fi
# Files (pcmanfm-qt, Qt 6) through Super+E: decorated by the compositor.
key meta_l-e
if wait_guest $((30 * slow)) 'as-user "hyprctl clients" | grep -qi "class: pcmanfm-qt"'; then
  sleep 2; record "Super+E opens Files" pass ""
  if gu 'hyprctl plugin list' 2>/dev/null | grep -qi hyprbars; then
    check "Files (Qt 6) has a Lugh title bar" "" gu 'hyprctl decorations class:pcmanfm-qt | grep -qi bar'
  fi
else
  record "Super+E opens Files" FAIL "no pcmanfm-qt window"
fi
shot 21-files.png

# Volume key -> the island OSD.
vol_before="$(gu 'pactl get-sink-volume @DEFAULT_SINK@ | grep -o "[0-9]*%" | head -n1' | tr -d '\r')"
key volumedown; sleep 0.25; key volumedown
sleep 0.6; shot 13-osd-volume.png
vol_after="$(gu 'pactl get-sink-volume @DEFAULT_SINK@ | grep -o "[0-9]*%" | head -n1' | tr -d '\r')"
if [[ -n "$vol_after" && "$vol_before" != "$vol_after" ]]; then record "volume key changes the volume" pass "$vol_before -> $vol_after"
else record "volume key changes the volume" FAIL "volume $vol_before -> $vol_after"; fi
sleep 2

if ms="$(kill_shell)" && [[ "$ms" =~ ^[0-9]+$ ]]; then
  sleep 1
  if gu 'c=$(hyprctl clients); echo "$c" | grep -qi "class: foot" && echo "$c" | grep -qi "class: firefox"' && layer_mapped lugh-dock; then
    record "shell restarts after SIGKILL" pass "first frame ${ms} ms after the kill; foot and Firefox kept running"
  else
    record "shell restarts after SIGKILL" FAIL "back after ${ms} ms, but an app or the panel is missing"
  fi
else
  record "shell restarts after SIGKILL" FAIL "no new first frame 15s after the kill"
fi
sleep 1; shot 14-after-shell-restart.png
gu 'for a in $(hyprctl clients -j | grep -o "\"address\": \"[^\"]*\"" | cut -d\" -f4); do hyprctl dispatch "hl.dsp.window.close({ window = \"address:$a\" })"; done' >/dev/null 2>&1 || true
sleep 1
g 'pkill -u lugh -x firefox; pkill -u lugh -x foot; pkill -u lugh -x pcmanfm-qt; true' >/dev/null 2>&1 || true
sleep 4

# Numbers: RSS, idle CPU over 10 s, session memory.
GT=40 g 'pid=$(as-user "systemctl --user show -p MainPID --value lugh-shell.service"); t() { awk "{print \$14+\$15}" /proc/$pid/stat; }
a=$(t); sleep 10; b=$(t); hz=$(getconf CLK_TCK)
echo "lugh-shell pid $pid"
echo "lugh-shell RSS: $(awk "/VmRSS/ {printf \"%.0f MB\", \$2/1024}" /proc/$pid/status) (anon $(awk "/RssAnon/ {printf \"%.0f\", \$2/1024}" /proc/$pid/status) MB, file $(awk "/RssFile/ {printf \"%.0f\", \$2/1024}" /proc/$pid/status) MB)"
echo "lugh-shell idle CPU over 10 s: $(awk -v d=$((b-a)) -v hz=$hz "BEGIN {printf \"%.1f%%\", d*100/hz/10}")"
hp=$(pgrep -x Hyprland | head -n1); echo "Hyprland RSS: $(awk "/VmRSS/ {printf \"%.0f MB\", \$2/1024}" /proc/$hp/status)"
free -m | awk "/^Mem:/ {print \"memory used now (after the app tests): \" \$3 \" MB of \" \$2 \" MB (available \" \$7 \" MB)\"}"
systemd-analyze 2>/dev/null | head -n1' >"$LOGS/numbers.txt" 2>&1 || true
idle="$(grep -a 'idle CPU' "$LOGS/numbers.txt" | sed 's/.*: //' | tr -d '\r')"
rss="$(grep -a 'lugh-shell RSS' "$LOGS/numbers.txt" | sed 's/.*RSS: //' | tr -d '\r')"
record "lugh-shell at idle" pass "CPU ${idle:-?} over 10 s, RSS ${rss:-?}"

# QML errors in the shell's log so far.
gu 'journalctl --user -b -u lugh-shell --no-pager -o cat' >"$LOGS/lugh-shell.log" 2>&1 || true
qml_errors=$(grep -acE '\.(qml|js):[0-9]+|module ".*" is not installed|QML [A-Za-z]+: ' "$LOGS/lugh-shell.log" || true)
if (( qml_errors == 0 )); then record "no QML warnings in the shell log" pass ""; else
  record "no QML warnings in the shell log" FAIL "$qml_errors line(s), see out/vm-logs/lugh-shell.log"; fi

# --- 09 log out -> greeter ------------------------------------------------------
n_greeter=$(marker_count "LUGH-MARK: greeter-ready")
n_ready=$(marker_count "LUGH-MARK: session-ready")
t0=$(now_ms)
gu 'hyprctl dispatch "hl.dsp.exit()"' >/dev/null 2>&1 || true
if wait_marker "LUGH-MARK: greeter-ready" $((n_greeter + 1)) $((60 * slow)); then
  record "log out shows the sign-in screen" pass "$(awk -v ms=$(( $(now_ms) - t0 )) 'BEGIN { printf "%.1f", ms / 1000 }')s"
else
  record "log out shows the sign-in screen" FAIL "no 'LUGH-MARK: greeter-ready' on the serial console"
fi
sleep 2.5; shot 09-greeter.png
check "greeter runs as _greetd under cage" "" g 'pgrep -u _greetd -x cage >/dev/null && pgrep -u _greetd -x lugh-greeter >/dev/null'

# --- 10 log in again ------------------------------------------------------------
n_ready=$(marker_count "LUGH-MARK: session-ready")
t0=$(now_ms)
vm type "$PASSWORD"; key ret
if wait_marker "LUGH-MARK: session-ready" $((n_ready + 1)) $((60 * slow)); then
  login_s=$(awk -v ms=$(( $(now_ms) - t0 )) 'BEGIN { printf "%.1f", ms / 1000 }')
  record "password logs in from the greeter" pass "${login_s}s from Enter to the shell's first frame"
else
  login_s="n/a"
  record "password logs in from the greeter" FAIL "no second 'LUGH-MARK: session-ready'"
fi
sleep 3; shot 10-desktop-again.png
check "lugh-shell active after re-login" "" gu 'systemctl --user is-active --quiet lugh-shell.service'

collect_logs
{
  echo "boot to desktop: ${boot_s}s"
  echo "greeter login to desktop: ${login_s}s"
  echo "renderer: ${renderer:-unknown}; low power: ${low_power:-?}"
  echo "memory used right after login, no apps: ${mem_login:-?} MB"
  echo "ISO: $(basename "$(readlink -f "$iso")") $(stat -Lc %s "$iso" 2>/dev/null) bytes"
} >>"$LOGS/numbers.txt"

# --- summary --------------------------------------------------------------------
printf '\n%-36s %-6s %s\n' STEP RESULT DETAIL
printf '%-36s %-6s %s\n' ------------------------------------ ------ ------
for i in "${!names[@]}"; do
  printf '%-36s %-6s %s\n' "${names[$i]}" "${results[$i]}" "${details[$i]}"
done
printf '\nscreenshots: out/vm-shots/   logs: out/vm-logs/   numbers: out/vm-logs/numbers.txt\n'
tr -d '\r' <"$LOGS/numbers.txt" | sed 's/^/  /'
exit "$failed"
