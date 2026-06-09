#!/usr/bin/env python3
"""
USB-serial uzerinden bagli E220 (UART seffaf mod) dinler ve konsola yazar.

esp32_e220_sender ile kullanim:
  python3 scripts/e220_usb_listener.py -p /dev/cu.usbserial-11130

Bagimlilik: pip install pyserial
"""

from __future__ import annotations

import argparse
import sys
import time

try:
    import serial
except ImportError as e:
    print("pyserial yuklu degil: pip install pyserial", file=sys.stderr)
    raise SystemExit(1) from e


def read_idle_packet(ser: serial.Serial, idle_ms: float) -> bytes:
    """UART burst: son bayttan idle_ms sessizlik gelince paket bitti sayilir."""
    buf = bytearray()

    while True:
        chunk = ser.read(256)
        if chunk:
            buf.extend(chunk)
            break
        time.sleep(0.005)

    last_rx = time.monotonic()
    while True:
        chunk = ser.read(256)
        now = time.monotonic()
        if chunk:
            buf.extend(chunk)
            last_rx = now
        elif (now - last_rx) * 1000.0 >= idle_ms:
            return bytes(buf)


def main() -> None:
    ap = argparse.ArgumentParser(description="E220 USB-serial dinleyici")
    ap.add_argument("-p", "--port", default="/dev/cu.usbserial-11130")
    ap.add_argument("-b", "--baud", type=int, default=9600)
    ap.add_argument(
        "-i",
        "--idle-ms",
        type=float,
        default=80.0,
        help="Paket sonu icin sessizlik suresi (ESP32 listener ile uyumlu)",
    )
    ap.add_argument(
        "--hex",
        action="store_true",
        help="Gelen baytlari hex olarak yazdir",
    )
    args = ap.parse_args()

    print(f"Dinleniyor: {args.port} @ {args.baud} (Ctrl+C cikis)", flush=True)

    with serial.Serial(args.port, args.baud, timeout=0.05) as ser:
        time.sleep(0.2)
        ser.reset_input_buffer()

        try:
            while True:
                pkt = read_idle_packet(ser, args.idle_ms)
                if args.hex:
                    print("[LoRa]", pkt.hex(" "), flush=True)
                else:
                    text = pkt.decode("utf-8", errors="replace").rstrip("\r\n")
                    print("[LoRa]", text, flush=True)
        except KeyboardInterrupt:
            print("", file=sys.stderr)


if __name__ == "__main__":
    main()
