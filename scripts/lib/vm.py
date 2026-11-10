#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Drive a Lugh test VM started by scripts/qemu-run.sh.

    vm.py --qmp SOCK key meta_l-spc          press a key combination (QEMU qcodes)
    vm.py --qmp SOCK type 'fire'             type text, one key at a time
    vm.py --qmp SOCK [--vnc SOCK] shot out/vm-shots/x.png
                                             screenshot of the guest display:
                                             QMP screendump, or the VNC display
                                             when QEMU has no surface to dump
                                             (GL scanout with virtio-vga-gl)
    vm.py --qmp SOCK quit                    power the VM off (QMP quit)
    vm.py --agent SOCK run [--timeout S] 'shell command'
                                             run a command as root in the guest
                                             (prints its output, exits with its
                                             status; 124 on timeout, 125 when the
                                             agent is unreachable)
    vm.py --agent SOCK ping [--timeout S]    wait until the guest agent answers

The agent is /usr/local/lib/lugh/test-agent in the live image; it only runs
when QEMU offers the virtio-serial port (qemu-run.sh --test-agent). Inside a
command, `as-user '<cmd>'` runs <cmd> as the desktop user with their session
bus and Wayland display. See docs/dev/testing-desktop.md.
"""
import argparse
import base64
import json
import os
import re
import socket
import sys
import time

# Characters -> QEMU qcodes (US layout). Upper case and symbols use shift.
_PLAIN = {
    " ": "spc", "\n": "ret", "\t": "tab", "-": "minus", "=": "equal",
    "[": "bracket_left", "]": "bracket_right", ";": "semicolon",
    "'": "apostrophe", "`": "grave_accent", "\\": "backslash", ",": "comma",
    ".": "dot", "/": "slash",
}
_SHIFT = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
    "*": "8", "(": "9", ")": "0", "_": "minus", "+": "equal",
    "{": "bracket_left", "}": "bracket_right", ":": "semicolon",
    '"': "apostrophe", "~": "grave_accent", "|": "backslash", "<": "comma",
    ">": "dot", "?": "slash",
}


def keys_for(ch):
    if ch.isdigit() or (ch.isalpha() and ch.islower()):
        return [ch]
    if ch.isalpha():
        return ["shift", ch.lower()]
    if ch in _PLAIN:
        return [_PLAIN[ch]]
    if ch in _SHIFT:
        return ["shift", _SHIFT[ch]]
    raise SystemExit(f"vm.py: cannot type {ch!r}")


class Qmp:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(30)
        self.sock.connect(path)
        self.file = self.sock.makefile("rw", encoding="utf-8")
        self._read()  # greeting
        self.cmd("qmp_capabilities")

    def _read(self):
        while True:
            line = self.file.readline()
            if not line:
                raise SystemExit("vm.py: QMP connection closed")
            msg = json.loads(line)
            if "event" not in msg:
                return msg

    def cmd(self, name, **args):
        req = {"execute": name}
        if args:
            req["arguments"] = args
        self.file.write(json.dumps(req) + "\n")
        self.file.flush()
        msg = self._read()
        if "error" in msg:
            raise SystemExit(f"vm.py: QMP {name}: {msg['error'].get('desc')}")
        return msg.get("return")

    def key(self, combo, hold_ms=80):
        keys = [{"type": "qcode", "data": k} for k in combo.split("-") if k]
        self.cmd("send-key", keys=keys, **{"hold-time": hold_ms})
        time.sleep(hold_ms / 1000 + 0.06)


def _recv_exact(sock, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(min(n - len(buf), 1 << 20))
        if not chunk:
            raise SystemExit("vm.py: VNC connection closed")
        buf += chunk
    return bytes(buf)


def vnc_shot(path, out):
    """One full frame from QEMU's VNC server (RFB 3.8, no auth, raw encoding)."""
    import struct
    from PIL import Image

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(20)
    sock.connect(path)
    _recv_exact(sock, 12)
    sock.sendall(b"RFB 003.008\n")
    ntypes = _recv_exact(sock, 1)[0]
    if ntypes == 0 or 1 not in _recv_exact(sock, ntypes):
        raise SystemExit("vm.py: the VNC server wants authentication")
    sock.sendall(b"\x01")
    if struct.unpack(">I", _recv_exact(sock, 4))[0] != 0:
        raise SystemExit("vm.py: VNC handshake failed")
    sock.sendall(b"\x01")  # shared
    width, height = struct.unpack(">HH", _recv_exact(sock, 4))
    _recv_exact(sock, 16)
    _recv_exact(sock, struct.unpack(">I", _recv_exact(sock, 4))[0])
    # 32 bpp, depth 24, little endian, true colour, BGRX; raw encoding only.
    sock.sendall(struct.pack(">BxxxBBBBHHHBBBxxx", 0, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0))
    sock.sendall(struct.pack(">BxHi", 2, 1, 0))
    sock.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, width, height))
    image = Image.new("RGB", (width, height))
    covered = 0
    while covered < width * height:
        kind = _recv_exact(sock, 1)[0]
        if kind == 0:  # FramebufferUpdate
            (nrects,) = struct.unpack(">xH", _recv_exact(sock, 3))
            for _ in range(nrects):
                x, y, w, h, enc = struct.unpack(">HHHHi", _recv_exact(sock, 12))
                if enc != 0:
                    raise SystemExit(f"vm.py: unexpected VNC encoding {enc}")
                data = _recv_exact(sock, w * h * 4)
                image.paste(Image.frombuffer("RGB", (w, h), data, "raw", "BGRX", 0, 1), (x, y))
                covered += w * h
        elif kind == 2:  # Bell
            pass
        elif kind == 3:  # ServerCutText
            (n,) = struct.unpack(">xxxI", _recv_exact(sock, 7))
            _recv_exact(sock, n)
        elif kind == 1:  # SetColourMapEntries
            (n,) = struct.unpack(">xHH", _recv_exact(sock, 5))[1:]
            _recv_exact(sock, n * 6)
        else:
            raise SystemExit(f"vm.py: unexpected VNC message {kind}")
    sock.close()
    image.save(out)


def run_agent(path, command, timeout):
    deadline = time.monotonic() + timeout
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(path)
    except OSError as err:
        print(f"vm.py: agent socket {path}: {err}", file=sys.stderr)
        return 125
    sock.sendall(base64.b64encode(command.encode()) + b"\n")
    buf = b""
    end = re.compile(rb"\n@@LUGH-RC:(\d+)@@\n")
    while True:
        left = deadline - time.monotonic()
        if left <= 0:
            sys.stdout.buffer.write(buf)
            print("\nvm.py: timed out waiting for the guest", file=sys.stderr)
            return 124
        sock.settimeout(left)
        try:
            chunk = sock.recv(65536)
        except socket.timeout:
            continue
        if not chunk:
            sys.stdout.buffer.write(buf)
            return 125
        buf += chunk
        m = end.search(buf)
        if m:
            sys.stdout.buffer.write(buf[: m.start()].lstrip(b"\n"))
            if m.start() and not buf[: m.start()].endswith(b"\n"):
                sys.stdout.buffer.write(b"\n")
            sys.stdout.flush()
            return int(m.group(1))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--qmp")
    ap.add_argument("--agent")
    ap.add_argument("--vnc")
    sub = ap.add_subparsers(dest="action", required=True)
    p = sub.add_parser("key"); p.add_argument("combo", nargs="+")
    p = sub.add_parser("type"); p.add_argument("text")
    p = sub.add_parser("shot"); p.add_argument("file")
    sub.add_parser("quit")
    p = sub.add_parser("run"); p.add_argument("--timeout", type=float, default=60); p.add_argument("command")
    p = sub.add_parser("ping"); p.add_argument("--timeout", type=float, default=120)
    args = ap.parse_args()

    if args.action in ("run", "ping"):
        if not args.agent:
            ap.error("--agent is required")
        if args.action == "run":
            return run_agent(args.agent, args.command, args.timeout)
        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline:
            devnull = os.open(os.devnull, os.O_WRONLY)
            saved = os.dup(1), os.dup(2)
            os.dup2(devnull, 1); os.dup2(devnull, 2)
            try:
                rc = run_agent(args.agent, "true", 5)
            finally:
                os.dup2(saved[0], 1); os.dup2(saved[1], 2)
                os.close(devnull); os.close(saved[0]); os.close(saved[1])
            if rc == 0:
                return 0
            time.sleep(1)
        return 124

    if not args.qmp:
        ap.error("--qmp is required")
    qmp = Qmp(args.qmp)
    if args.action == "key":
        for combo in args.combo:
            qmp.key(combo)
    elif args.action == "type":
        for ch in args.text:
            qmp.key("-".join(keys_for(ch)), hold_ms=40)
    elif args.action == "shot":
        path = os.path.abspath(args.file)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if os.path.exists(path):
            os.remove(path)
        try:
            qmp.cmd("screendump", filename=path, format="png")
        except SystemExit as err:
            # GL scanout: QEMU has no surface to dump; read the VNC display.
            if "no surface" not in str(err) or not args.vnc or not os.path.exists(args.vnc):
                raise
            vnc_shot(args.vnc, path)
            return 0
        for _ in range(100):  # QEMU writes the file after replying
            if os.path.exists(path) and os.path.getsize(path) > 0:
                break
            time.sleep(0.05)
        else:
            raise SystemExit(f"vm.py: screendump did not produce {path}")
    elif args.action == "quit":
        qmp.cmd("quit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
