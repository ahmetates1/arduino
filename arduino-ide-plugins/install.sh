#!/usr/bin/env bash
# Arduino IDE 2 eklentilerini ~/.arduinoIDE/plugins/ altina kurar.
# Kullanim: ./arduino-ide-plugins/install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${HOME}/.arduinoIDE/plugins"

is_arduino_ide_running() {
  pgrep -xq "Arduino IDE" 2>/dev/null && return 0
  pgrep -f "/Applications/Arduino IDE.app" >/dev/null 2>&1 && return 0
  return 1
}

wait_for_ide_to_close() {
  if ! is_arduino_ide_running; then
    return 0
  fi

  echo ""
  echo "Arduino IDE acik — eklenti kurulumu IDE kapaliyken yapilmali."
  echo "Lutfen Arduino IDE'yi tamamen kapat (File > Quit)."
  echo ""

  while is_arduino_ide_running; do
    echo -n "IDE hala acik... Kapattiktan sonra Enter'a basin (Ctrl+C = vazgec): "
    read -r
    if is_arduino_ide_running; then
      echo "Hala acik gorunuyor. Tekrar dene."
    fi
  done

  echo ""
}

shopt -s nullglob
vsix_files=("${SCRIPT_DIR}"/*.vsix)
shopt -u nullglob

if ((${#vsix_files[@]} == 0)); then
  echo "Hata: ${SCRIPT_DIR} icinde .vsix dosyasi yok." >&2
  exit 1
fi

wait_for_ide_to_close

mkdir -p "${DEST}"

for vsix in "${vsix_files[@]}"; do
  name="$(basename "${vsix}")"
  cp -f "${vsix}" "${DEST}/${name}"
  echo "Kuruldu: ${DEST}/${name}"
done

echo ""
echo "Tamam. Arduino IDE'yi ac; Sketch Vault icin sol altta VAULT veya Cmd+Shift+P."
