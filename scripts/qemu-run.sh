#!/usr/bin/env bash
# Boot a Lugh ISO in QEMU.
#
# Usage: scripts/qemu-run.sh <uefi|uefi-sb|bios> [options]
#
# Options:
#   --iso FILE          ISO to boot (default: $ISO or out/lugh.iso)
#   --headless          no display; serial goes to --serial-log (or out/serial-<mode>.log)
#   --serial-log FILE   serial console log file (implies --headless)
#   --dry-run           print the QEMU command and exit
#   -h, --help          show this help
#
# Environment:
#   ISO                 ISO path (overridden by --iso)
#   QEMU                QEMU binary (default: qemu-system-x86_64)
#   QEMU_MEM, QEMU_SMP  guest memory and vCPUs (default: 4G, 4)
#   QEMU_ACCEL          kvm | tcg (default: kvm when /dev/kvm is usable)
#   QEMU_EXTRA          extra arguments appended to the command (word-split)
#   OVMF_CODE, OVMF_CODE_SB, OVMF_VARS_TEMPLATE, OVMF_VARS_MS_TEMPLATE
#                       override OVMF firmware detection
#
# Modes (docs/phases/phase-0-foundation.md §6):
#   uefi     q35 + OVMF_CODE_4M.fd, VARS copied to out/OVMF_VARS.fd
#   uefi-sb  q35,smm=on + OVMF_CODE_4M.secboot.fd, Microsoft-enrolled VARS
#            copied to out/OVMF_VARS.ms.fd (boots shim -> grub -> signed kernel)
#   bios     -machine pc, SeaBIOS, no pflash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/out"

log()  { printf 'qemu-run: %s\n' "$*" >&2; }
warn() { printf 'qemu-run: warning: %s\n' "$*" >&2; }
die()  { printf 'qemu-run: error: %s\n' "$*" >&2; exit 2; }

usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; }

# OVMF lookup: Debian/Ubuntu (/usr/share/OVMF), Debian's old lowercase dir,
# Fedora (/usr/share/edk2/ovmf), Arch (/usr/share/edk2/x64), openSUSE (/usr/share/qemu).
OVMF_DIRS=(/usr/share/OVMF /usr/share/ovmf /usr/share/edk2/ovmf /usr/share/edk2/x64 /usr/share/edk2-ovmf/x64 /usr/share/qemu)

# find_fw <name>... : first existing file across OVMF_DIRS, in name order.
find_fw() {
  local name dir
  for name in "$@"; do
    for dir in "${OVMF_DIRS[@]}"; do
      if [[ -f "${dir}/${name}" ]]; then
        printf '%s\n' "${dir}/${name}"
        return 0
      fi
    done
  done
  return 1
}

fw_format() { [[ "$1" == *.qcow2 ]] && echo qcow2 || echo raw; }

mode=""
iso="${ISO:-${OUT}/lugh.iso}"
headless=0
serial_log=""
dry_run=0

while (($#)); do
  case "$1" in
    uefi|uefi-sb|bios)
      [[ -z "$mode" ]] || die "mode given twice ('$mode' and '$1')"
      mode="$1" ;;
    --iso)        [[ $# -ge 2 ]] || die "--iso needs a file"; iso="$2"; shift ;;
    --iso=*)      iso="${1#*=}" ;;
    --headless)   headless=1 ;;
    --serial-log) [[ $# -ge 2 ]] || die "--serial-log needs a file"; serial_log="$2"; headless=1; shift ;;
    --serial-log=*) serial_log="${1#*=}"; headless=1 ;;
    --dry-run)    dry_run=1 ;;
    -h|--help)    usage; exit 0 ;;
    *)            usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done

[[ -n "$mode" ]] || { usage >&2; die "missing mode (uefi, uefi-sb or bios)"; }

if [[ ! -f "$iso" ]]; then
  ((dry_run)) || die "ISO not found: $iso (run 'make iso' first, or pass ISO=/path/to.iso)"
  warn "ISO not found: $iso (dry run, continuing)"
fi

qemu="${QEMU:-qemu-system-x86_64}"
if ! command -v "$qemu" >/dev/null 2>&1; then
  ((dry_run)) || die "$qemu not found (install qemu-system-x86)"
  warn "$qemu not found (dry run, continuing)"
fi

# --- accelerator --------------------------------------------------------------
accel="${QEMU_ACCEL:-}"
if [[ -z "$accel" ]]; then
  if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    accel=kvm
  else
    accel=tcg
    if [[ -e /dev/kvm ]]; then
      warn "/dev/kvm exists but is not accessible to $(id -un); falling back to TCG (slow)."
      warn "fix: sudo usermod -aG kvm $(id -un) && log in again (see docs/dev/setup.md)"
    else
      warn "/dev/kvm not found; falling back to TCG (software emulation, slow)"
    fi
  fi
fi
case "$accel" in
  kvm) accel_args=(-enable-kvm -cpu host) ;;
  tcg) accel_args=(-accel tcg -cpu max) ;;
  *)   die "QEMU_ACCEL must be kvm or tcg, got '$accel'" ;;
esac

# --- firmware -----------------------------------------------------------------
machine_args=()
fw_args=()

# prepare_vars <template> <dest>: copy the VARS template on first run.
prepare_vars() {
  local template="$1" dest="$2"
  if [[ ! -f "$dest" ]]; then
    if ((dry_run)); then
      log "would copy $template -> $dest"
    else
      mkdir -p "$(dirname "$dest")"
      cp "$template" "$dest"
      chmod u+w "$dest"
      log "created $dest from $template"
    fi
  fi
}

case "$mode" in
  uefi)
    code="${OVMF_CODE:-$(find_fw OVMF_CODE_4M.fd OVMF_CODE.4m.fd OVMF_CODE.fd || true)}"
    tmpl="${OVMF_VARS_TEMPLATE:-$(find_fw OVMF_VARS_4M.fd OVMF_VARS.4m.fd OVMF_VARS.fd || true)}"
    [[ -n "$code" && -n "$tmpl" ]] || die "OVMF firmware not found in ${OVMF_DIRS[*]} (install 'ovmf', or set OVMF_CODE and OVMF_VARS_TEMPLATE)"
    vars="${OUT}/OVMF_VARS.fd"
    prepare_vars "$tmpl" "$vars"
    machine_args=(-machine q35)
    fw_args=(-drive "if=pflash,format=$(fw_format "$code"),readonly=on,file=${code}"
             -drive "if=pflash,format=$(fw_format "$tmpl"),file=${vars}")
    ;;
  uefi-sb)
    code="${OVMF_CODE_SB:-$(find_fw OVMF_CODE_4M.secboot.fd OVMF_CODE.secboot.4m.fd OVMF_CODE.secboot.fd || true)}"
    tmpl="${OVMF_VARS_MS_TEMPLATE:-$(find_fw OVMF_VARS_4M.ms.fd OVMF_VARS.ms.fd OVMF_VARS.secboot.fd || true)}"
    [[ -n "$code" ]] || die "Secure Boot OVMF (OVMF_CODE_4M.secboot.fd) not found in ${OVMF_DIRS[*]} (set OVMF_CODE_SB)"
    [[ -n "$tmpl" ]] || die "OVMF VARS with Microsoft keys enrolled (OVMF_VARS_4M.ms.fd) not found (set OVMF_VARS_MS_TEMPLATE)"
    vars="${OUT}/OVMF_VARS.ms.fd"
    prepare_vars "$tmpl" "$vars"
    # SMM is required by the secure-boot OVMF build; the flash must be secure-only.
    # shellcheck disable=SC2054  # commas are QEMU option syntax, not separators
    machine_args=(-machine q35,smm=on
                  -global driver=cfi.pflash01,property=secure,value=on
                  -global ICH9-LPC.disable_s3=1)
    fw_args=(-drive "if=pflash,format=$(fw_format "$code"),readonly=on,file=${code}"
             -drive "if=pflash,format=$(fw_format "$tmpl"),file=${vars}")
    ;;
  bios)
    machine_args=(-machine pc)
    ;;
esac

# --- console ------------------------------------------------------------------
if ((headless)); then
  serial_log="${serial_log:-${OUT}/serial-${mode}.log}"
  ((dry_run)) || mkdir -p "$(dirname "$serial_log")"
  console_args=(-display none -monitor none -serial "file:${serial_log}")
else
  console_args=(-serial mon:stdio)
fi

extra_args=()
if [[ -n "${QEMU_EXTRA:-}" ]]; then
  read -r -a extra_args <<<"${QEMU_EXTRA}"
fi

cmd=("$qemu" "${accel_args[@]}" -m "${QEMU_MEM:-4G}" -smp "${QEMU_SMP:-4}"
     "${machine_args[@]}" "${fw_args[@]}" -cdrom "$iso" "${console_args[@]}"
     "${extra_args[@]}")

if ((dry_run)); then
  printf '%q ' "${cmd[@]}"
  printf '\n'
  exit 0
fi

log "mode=${mode} accel=${accel} iso=${iso}${serial_log:+ serial=${serial_log}}"
exec "${cmd[@]}"
