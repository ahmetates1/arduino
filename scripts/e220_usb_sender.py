#!/usr/bin/env python3
"""
E220 (UART seffaf mod) USB-serial uzerinden veri gonderir.

On kosul: Modul M0/M1 normal modda; bilgisayar ile ayni UART hizi (varsayilan 9600).
Alici taraftaki ESP32 ile adres/kanal/air rate modul ayarlarinda eslesmeli.

Ornek:
  python3 scripts/e220_usb_sender.py -p /dev/cu.usbserial-11130 -m "77|1|0|0|0"
  echo -n "test" | python3 scripts/e220_usb_sender.py -p /dev/cu.usbserial-11130 --stdin

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


def main() -> None:
    ap = argparse.ArgumentParser(description="E220 USB-serial LoRa gonderici")
    ap.add_argument(
        "-p",
        "--port",
        default="/dev/cu.usbserial-11130",
        help="Seri port (macOS: /dev/cu....)",
    )
    ap.add_argument("-b", "--baud", type=int, default=9600, help="UART baud (E220 ile ayni)")
    ap.add_argument("-m", "--message", default="", help="Gonderilecek metin")
    ap.add_argument(
        "--stdin",
        action="store_true",
        help="Mesaji stdin'den oku (binary)",
    )
    ap.add_argument(
        "--newline",
        choices=("none", "lf", "crlf"),
        default="lf",
        help="-m ile gonderirken satir sonu (stdin'de eklenmez)",
    )
    ap.add_argument("-d", "--delay-after-open", type=float, default=0.2, help="Acilis sonrasi bekleme s")
    args = ap.parse_args()

    if args.stdin:
        payload = sys.stdin.buffer.read()
    else:
        payload = args.message.encode("utf-8")
        if args.newline == "lf":
            payload += b"\n"
        elif args.newline == "crlf":
            payload += b"\r\n"

    if not payload:
        print("Gonderilecek veri yok.", file=sys.stderr)
        raise SystemExit(2)

    with serial.Serial(args.port, args.baud, timeout=2, write_timeout=5) as ser:
        time.sleep(args.delay_after_open)
        ser.reset_input_buffer()
        n = ser.write(payload)
        ser.flush()
        print(f"Gonderildi: {n} byte -> {args.port} @ {args.baud}")


if __name__ == "__main__":
    main()
