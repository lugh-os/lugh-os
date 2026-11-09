# Boot smoke test

`make test-boot` (→ `scripts/test-boot.sh`) boots the ISO headless in QEMU in
three firmware modes and waits for the serial-console boot marker.

| Mode | Firmware | Machine |
|---|---|---|
| `uefi` | `OVMF_CODE_4M.fd` + `out/OVMF_VARS.fd` | `q35` |
| `uefi-sb` | `OVMF_CODE_4M.secboot.fd` + `out/OVMF_VARS.ms.fd` (Microsoft keys enrolled) | `q35,smm=on`, secure pflash |
| `bios` | SeaBIOS | `pc` |

## The marker

`lugh-boot-marker.service` (in the ISO only) runs after `multi-user.target` and
writes this to `/dev/ttyS0`:

```
LUGH-BOOT-OK VERSION_ID="0.0"
```

The live kernel command line includes `console=ttyS0,115200`, so QEMU's serial
port (`-serial file:out/serial-<mode>.log`) captures it.

## What it measures

For each mode the script records the wall-clock seconds from starting QEMU to
the marker appearing in the serial log (firmware + bootloader + kernel +
userspace). The phase 0 budget is ≤ 25 s for UEFI under KVM.

## Output

- `out/serial-<mode>.log` — the serial console of each boot
- `out/qemu-<mode>.log` — QEMU's own stdout/stderr
- `out/boot-times.json` — machine-readable results:

```json
{
  "iso": "out/lugh-0.0-amd64.iso",
  "iso_size_bytes": 912345678,
  "accel": "kvm",
  "timeout_seconds": 180,
  "date": "2026-11-09T12:00:00Z",
  "results": [
    {"mode": "uefi", "status": "pass", "seconds": 14.2, "elapsed_seconds": 14.2,
     "marker": "LUGH-BOOT-OK VERSION_ID=\"0.0\"", "serial_log": "out/serial-uefi.log"}
  ]
}
```

`status` is `pass`, `timeout` or `qemu-exited`; `seconds` is `null` unless the
mode passed. The script exits non-zero if any mode failed.

## Knobs

| Variable | Default | Meaning |
|---|---|---|
| `ISO` | `out/lugh.iso` | ISO to boot |
| `BOOT_TIMEOUT` | 180 (KVM) / 600 (TCG) | seconds to wait per mode |
| `BOOT_MARKER` | `LUGH-BOOT-OK` | marker to wait for |
| `QEMU_ACCEL` | `kvm` if `/dev/kvm` is usable, else `tcg` | accelerator |
| `QEMU_MEM`, `QEMU_SMP` | `4G`, `4` | guest size |

Later phases replace this with `tests/boot/run.py` and the `LUGH-MARK:` markers
from the build-and-release spec.
