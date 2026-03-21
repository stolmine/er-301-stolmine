#!/usr/bin/env python3
"""Virtual TXo monitor — displays CV and gate state from the ER-301 emulator."""

import struct
import sys
import time
import os

MONITOR_PATH = "/tmp/er301-txo-monitor"

# TXo opcodes
TO_TR = 0x00
TO_TR_TOG = 0x01
TO_CV = 0x10
TO_CV_SET = 0x11

cv_values = [0.0] * 4
tr_states = [False] * 4
msg_count = 0


def decode_value(data):
    if len(data) >= 4:
        raw = struct.unpack(">h", bytes(data[2:4]))[0]
        # TXo: 16384 = ~5V, 32767 = ~10V
        return raw * (10.0 / 32767.0)
    return 0.0


def process_message(addr, data):
    global msg_count
    if len(data) < 2:
        return

    cmd = data[0]
    port = data[1]
    if port > 3:
        return

    msg_count += 1

    if cmd == TO_CV or cmd == TO_CV_SET:
        cv_values[port] = decode_value(data)
    elif cmd == TO_TR:
        tr_states[port] = (data[3] if len(data) > 3 else 0) > 0
    elif cmd == TO_TR_TOG:
        tr_states[port] = not tr_states[port]


def draw():
    sys.stdout.write("\033[H\033[J")  # clear
    sys.stdout.write("\033[1m  Virtual TXo Monitor\033[0m\n")
    sys.stdout.write(f"  msgs: {msg_count}\n\n")

    # CV outputs
    for i in range(4):
        v = cv_values[i]
        bar_width = 30
        # map -10V..+10V to 0..bar_width
        pos = int((v + 10.0) / 20.0 * bar_width)
        pos = max(0, min(bar_width, pos))
        bar = "█" * pos + "░" * (bar_width - pos)
        sys.stdout.write(f"  CV {i+1}:  {v:+7.3f}V  [{bar}]\n")

    sys.stdout.write("\n")

    # TR outputs
    for i in range(4):
        state = tr_states[i]
        indicator = "\033[92m██ HIGH\033[0m" if state else "\033[90m░░ LOW \033[0m"
        sys.stdout.write(f"  TR {i+1}:  {indicator}\n")

    sys.stdout.write("\n  (ctrl-c to quit)\n")
    sys.stdout.flush()


def main():
    print(f"Waiting for emulator output at {MONITOR_PATH}...")
    print("Enable I2C master in the TXo package menu, then insert a TXo unit.")

    while not os.path.exists(MONITOR_PATH):
        time.sleep(0.5)

    with open(MONITOR_PATH, "rb") as f:
        draw()
        last_draw = time.time()

        while True:
            header = f.read(2)
            if len(header) < 2:
                now = time.time()
                if now - last_draw > 0.05:
                    draw()
                    last_draw = now
                time.sleep(0.01)
                continue

            addr = header[0]
            length = header[1]
            data = f.read(length)
            if len(data) < length:
                time.sleep(0.01)
                continue

            process_message(addr, list(data))

            now = time.time()
            if now - last_draw > 0.05:  # 20fps
                draw()
                last_draw = now


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n  Bye.")
