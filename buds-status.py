#!/usr/bin/env python3
"""Galaxy Buds status for the Omarchy bar.

Prints one JSON object per line whenever something changes: connection,
per-bud and case battery, where each bud is (ear, case...), and the audio
profiles PipeWire offers for the buds.

Battery comes from Samsung's own protocol over RFCOMM (the same one the
Galaxy Wearable app speaks); BlueZ alone only reports a single percentage.
Frames look like: 0xFD, 2-byte little-endian header (low 10 bits = length of
id + payload + CRC), message id, payload, CRC16, 0xDD.

Commands arrive on stdin, one per line:
  noise <0-3>   noise control: 0 off, 1 noise cancelling, 2 ambient, 3 adaptive
The helper exits when stdin closes, so it never outlives the shell.

Usage: buds-status.py [AA:BB:CC:DD:EE:FF]   (default: first paired Samsung audio device)
"""

import json
import os
import re
import select
import socket
import subprocess
import sys
import time

SOM, EOM = 0xFD, 0xDD
MSG_STATUS_UPDATED = 0x60
MSG_EXTENDED_STATUS_UPDATED = 0x61
MSG_NOISE_CONTROLS_UPDATE = 0x77
MSG_NOISE_CONTROLS = 0x78
NOISE_MODES = (0, 1, 2, 3)
SAMSUNG_MODALIAS = "bluetooth:v0075"
POLL_SECONDS = 3
CACHE_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "omarchy-galaxy-buds")


def run(cmd, timeout=4):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def device_info(address):
    out = run(["bluetoothctl", "info", address])
    name = re.search(r"^\s*Alias: (.*)$", out, re.M)
    return {
        "name": name.group(1).strip() if name else "",
        "connected": "Connected: yes" in out,
        "samsung": SAMSUNG_MODALIAS in out,
    }


def find_buds():
    for line in run(["bluetoothctl", "devices", "Paired"]).splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        address = parts[1]
        out = run(["bluetoothctl", "info", address])
        if SAMSUNG_MODALIAS in out and "Icon: audio-head" in out:
            return address
    return ""


def audio_card(address):
    """Card name, active profile and selectable profiles from PipeWire."""
    try:
        cards = json.loads(run(["pactl", "-f", "json", "list", "cards"]) or "[]")
    except ValueError:
        return None
    want = "bluez_card." + address.replace(":", "_")
    for card in cards:
        if card.get("name") != want:
            continue
        profiles = [
            {"id": pid, "label": p.get("description", pid)}
            for pid, p in sorted(card.get("profiles", {}).items(), key=lambda kv: -kv[1].get("priority", 0))
            if pid != "off" and p.get("available", True)
        ]
        return {"card": want, "profile": card.get("active_profile", ""), "profiles": profiles}
    return None


def channel_cache(address):
    return os.path.join(CACHE_DIR, address.replace(":", "") + ".channel")


def open_channel(address, channel, wait=3.0):
    """Connect to an RFCOMM channel; succeed only if it speaks the Buds protocol."""
    sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM, socket.BTPROTO_RFCOMM)
    sock.settimeout(wait)
    try:
        sock.connect((address, channel))
        first = sock.recv(1024)
    except OSError:
        sock.close()
        return None, b""
    if not first or first[0] != SOM:
        sock.close()
        return None, b""
    return sock, first


def connect_buds(address):
    """Open the Buds RFCOMM link, trying the cached channel before scanning."""
    path = channel_cache(address)
    try:
        cached = int(open(path).read().strip())
    except (OSError, ValueError):
        cached = 0
    channels = ([cached] if cached else []) + [c for c in range(1, 31) if c != cached]
    for channel in channels:
        sock, first = open_channel(address, channel)
        if sock:
            if channel != cached:
                os.makedirs(CACHE_DIR, exist_ok=True)
                with open(path, "w") as f:
                    f.write(str(channel))
            return sock, first
    return None, b""


def crc16(data):
    """CRC-16/XMODEM over message id + payload, as the buds expect it."""
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if crc & 0x8000 else crc << 1
            crc &= 0xFFFF
    return crc


def build_frame(msg_id, payload):
    body = bytes([msg_id]) + bytes(payload)
    size = len(body) + 2
    return bytes([SOM]) + size.to_bytes(2, "little") + body + crc16(body).to_bytes(2, "little") + bytes([EOM])


def battery_value(raw):
    return raw if 0 < raw <= 100 else -1


def parse_status(msg_id, payload):
    """Battery and placement from STATUS_UPDATED / EXTENDED_STATUS_UPDATED."""
    # Extended status leads with revision + ear type; plain status with revision only.
    offset = 2 if msg_id == MSG_EXTENDED_STATUS_UPDATED else 1
    if len(payload) < offset + 6:
        return None
    left, right, _coupled, _main, placement, case = payload[offset:offset + 6]
    status = {
        "left": battery_value(left),
        "right": battery_value(right),
        "case": battery_value(case),
        "leftPlacement": (placement >> 4) & 0x0F,
        "rightPlacement": placement & 0x0F,
    }
    if msg_id == MSG_EXTENDED_STATUS_UPDATED and len(payload) > 12 and payload[12] in NOISE_MODES:
        status["noise"] = payload[12]
    return status


def frames(buf):
    """Split complete frames off the buffer; returns (frames, rest)."""
    out = []
    while buf:
        if buf[0] != SOM:
            buf = buf[1:]
            continue
        if len(buf) < 3:
            break
        length = int.from_bytes(buf[1:3], "little") & 0x3FF
        if len(buf) < 3 + length + 1:
            break
        body, buf = buf[3:3 + length], buf[4 + length:]
        if len(body) >= 3:
            out.append((body[0], body[1:-2]))
    return out, buf


class Reporter:
    def __init__(self):
        self.last = None

    def emit(self, state):
        line = json.dumps(state, sort_keys=True)
        if line != self.last:
            self.last = line
            print(line, flush=True)


def read_command():
    """One stdin command as a word list; exits once stdin is closed."""
    line = sys.stdin.readline()
    if not line:
        sys.exit(0)
    return line.split()


def idle(seconds):
    """Sleep while the buds are away, still noticing the shell going away."""
    deadline = time.monotonic() + seconds
    while (left := deadline - time.monotonic()) > 0:
        if select.select([sys.stdin], [], [], left)[0]:
            read_command()


def main():
    address = sys.argv[1].upper() if len(sys.argv) > 1 and sys.argv[1] else ""
    reporter = Reporter()
    empty = {"left": -1, "right": -1, "case": -1, "leftPlacement": 0, "rightPlacement": 0, "noise": -1}

    while True:
        addr = address or find_buds()
        if not addr:
            reporter.emit({"found": False})
            idle(POLL_SECONDS * 4)
            continue

        info = device_info(addr)
        state = {"found": True, "address": addr, "name": info["name"], "connected": info["connected"]}
        state.update(empty)
        state.update(audio_card(addr) or {"card": "", "profile": "", "profiles": []})
        if not info["connected"]:
            reporter.emit(state)
            idle(POLL_SECONDS)
            continue

        sock, buf = connect_buds(addr)
        if not sock:
            reporter.emit(state)
            idle(POLL_SECONDS * 2)
            continue

        next_poll = 0
        try:
            while True:
                ready, _, _ = select.select([sock, sys.stdin], [], [], POLL_SECONDS)
                if sys.stdin in ready:
                    command = read_command()
                    if len(command) == 2 and command[0] == "noise" and command[1].isdigit() and int(command[1]) in NOISE_MODES:
                        sock.sendall(build_frame(MSG_NOISE_CONTROLS, [int(command[1])]))
                        # The buds apply it but don't always echo NOISE_CONTROLS_UPDATE back.
                        state["noise"] = int(command[1])
                if sock in ready:
                    data = sock.recv(2048)
                    if not data:
                        break
                    buf += data
                parsed, buf = frames(buf)
                for msg_id, payload in parsed:
                    if msg_id in (MSG_STATUS_UPDATED, MSG_EXTENDED_STATUS_UPDATED):
                        status = parse_status(msg_id, payload)
                        if status:
                            state.update(status)
                    elif msg_id == MSG_NOISE_CONTROLS_UPDATE and payload and payload[0] in NOISE_MODES:
                        state["noise"] = payload[0]
                if time.monotonic() >= next_poll:
                    next_poll = time.monotonic() + POLL_SECONDS
                    if not device_info(addr)["connected"]:
                        break
                    state.update(audio_card(addr) or {"card": "", "profile": "", "profiles": []})
                reporter.emit(state)
        except OSError:
            pass
        finally:
            sock.close()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
