#!/usr/bin/env bash
# QEMU boot smoke test for the Lugh ISO.
#
# Usage: scripts/test-boot.sh [uefi] [uefi-sb] [bios]     (default: all three)
#
# Boots each firmware mode headless (scripts/qemu-run.sh), logs the serial
# console to out/serial-<mode>.log and waits for the boot marker printed by
# lugh-boot-marker.service:  LUGH-BOOT-OK VERSION_ID="0.0"
# Writes out/boot-times.json, prints a summary table and exits non-zero if any
# mode fails.
#
# Environment:
#   ISO           ISO to boot (default: out/lugh.iso)
#   BOOT_TIMEOUT  seconds to wait per mode (default: 180 with KVM, 600 with TCG)
#   BOOT_MARKER   marker to wait for (default: LUGH-BOOT-OK)
#   QEMU_ACCEL, QEMU_MEM, QEMU_SMP, ...   passed through to qemu-run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/out"
QEMU_RUN="${ROOT}/scripts/qemu-run.sh"
MARKER="${BOOT_MARKER:-LUGH-BOOT-OK}"
ISO="${ISO:-${OUT}/lugh.iso}"
export ISO

log() { printf 'test-boot: %s\n' "$*" >&2; }
die() { printf 'test-boot: error: %s\n' "$*" >&2; exit 2; }

modes=()
for arg in "$@"; do
  case "$arg" in
    uefi|uefi-sb|bios) modes+=("$arg") ;;
    -h|--help) sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown mode '$arg' (expected uefi, uefi-sb or bios)" ;;
  esac
done
((${#modes[@]})) || modes=(uefi uefi-sb bios)

[[ -f "$ISO" ]] || die "ISO not found: $ISO (run 'make iso' first)"
mkdir -p "$OUT"

# Same accelerator decision as qemu-run.sh, made once so the timeout matches.
if [[ -z "${QEMU_ACCEL:-}" ]]; then
  if [[ -r /dev/kvm && -w /dev/kvm ]]; then QEMU_ACCEL=kvm; else QEMU_ACCEL=tcg; fi
fi
export QEMU_ACCEL
if [[ "$QEMU_ACCEL" == kvm ]]; then default_timeout=180; else default_timeout=600; fi
TIMEOUT="${BOOT_TIMEOUT:-$default_timeout}"
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "BOOT_TIMEOUT must be a whole number of seconds"
[[ "$QEMU_ACCEL" == kvm ]] || log "no KVM: using TCG with a ${TIMEOUT}s timeout per mode"

qemu_pid=""
stop_qemu() {
  [[ -n "$qemu_pid" ]] || return 0
  if kill -0 "$qemu_pid" 2>/dev/null; then
    kill -TERM "$qemu_pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "$qemu_pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "$qemu_pid" 2>/dev/null || true
  fi
  wait "$qemu_pid" 2>/dev/null || true
  qemu_pid=""
}
trap stop_qemu EXIT
trap 'stop_qemu; exit 130' INT
trap 'stop_qemu; exit 143' TERM

now_ms() { date +%s%3N; }

# show_tail <file>: last lines of a log, without CRs and terminal escapes.
show_tail() {
  tail -n 20 "$1" 2>/dev/null | tr -d '\r' | sed -e 's/\x1b\[[0-9;=?]*[A-Za-z]//g' -e '/^[[:space:]]*$/d' \
    | sed 's/^/    | /' >&2 || true
}

declare -A status seconds marker_line
failed=0

for mode in "${modes[@]}"; do
  serial="${OUT}/serial-${mode}.log"
  qemu_log="${OUT}/qemu-${mode}.log"
  : >"$serial"
  log "booting ${mode} (timeout ${TIMEOUT}s, serial ${serial#"${ROOT}/"})"

  start=$(now_ms)
  "$QEMU_RUN" "$mode" --headless --serial-log "$serial" >"$qemu_log" 2>&1 &
  qemu_pid=$!

  result=timeout
  deadline=$((start + TIMEOUT * 1000))
  while :; do
    if grep -qa "$MARKER" "$serial" 2>/dev/null; then
      result=pass
      break
    fi
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
      # One last look: the marker may have landed just before QEMU exited.
      grep -qa "$MARKER" "$serial" 2>/dev/null && result=pass || result=qemu-exited
      break
    fi
    (($(now_ms) < deadline)) || break
    sleep 0.5
  done
  end=$(now_ms)
  stop_qemu

  elapsed=$(awk -v ms=$((end - start)) 'BEGIN { printf "%.1f", ms / 1000 }')
  status[$mode]=$result
  seconds[$mode]=$elapsed
  marker_line[$mode]="$(grep -a -m1 -o "${MARKER}.*" "$serial" 2>/dev/null | tr -d '\r' || true)"

  if [[ "$result" == pass ]]; then
    log "${mode}: PASS in ${elapsed}s (${marker_line[$mode]})"
  else
    failed=1
    log "${mode}: FAIL (${result}) after ${elapsed}s; last serial lines:"
    show_tail "$serial"
    if [[ "$result" == qemu-exited ]]; then
      log "QEMU output (${qemu_log#"${ROOT}/"}):"
      show_tail "$qemu_log"
    fi
  fi
done

# --- report -------------------------------------------------------------------
json_escape() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }

iso_real="$(readlink -f "$ISO")"
iso_size=$(stat -c %s "$iso_real")
{
  printf '{\n'
  printf '  "iso": "%s",\n' "$(json_escape "${iso_real#"${ROOT}/"}")"
  printf '  "iso_size_bytes": %s,\n' "$iso_size"
  printf '  "accel": "%s",\n' "$QEMU_ACCEL"
  printf '  "timeout_seconds": %s,\n' "$TIMEOUT"
  printf '  "date": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "results": [\n'
  n=${#modes[@]}; i=0
  for mode in "${modes[@]}"; do
    i=$((i + 1))
    if [[ "${status[$mode]}" == pass ]]; then secs=${seconds[$mode]}; else secs=null; fi
    printf '    {"mode": "%s", "status": "%s", "seconds": %s, "elapsed_seconds": %s, "marker": "%s", "serial_log": "out/serial-%s.log"}%s\n' \
      "$mode" "${status[$mode]}" "$secs" "${seconds[$mode]}" "$(json_escape "${marker_line[$mode]}")" "$mode" \
      "$([[ $i -lt $n ]] && echo , || true)"
  done
  printf '  ]\n}\n'
} >"${OUT}/boot-times.json"

printf '\n%-9s %-12s %10s\n' MODE RESULT SECONDS
printf '%-9s %-12s %10s\n' --------- ------------ ----------
for mode in "${modes[@]}"; do
  printf '%-9s %-12s %10s\n' "$mode" "${status[$mode]}" "${seconds[$mode]}"
done
printf '\naccel=%s  iso=%s (%s MB)  report=out/boot-times.json\n' \
  "$QEMU_ACCEL" "${iso_real#"${ROOT}/"}" "$((iso_size / 1000000))"

exit "$failed"
