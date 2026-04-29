#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

echo "==> Build numarasini artiriyorum..."
"${ROOT}/scripts/bump_build_number.sh"

echo "==> Release APK derleniyor..."
flutter build apk --release

APK="${ROOT}/build/app/outputs/flutter-apk/app-release.apk"
if [[ -f "${APK}" ]]; then
  echo "OK: APK hazir:"
  echo "    ${APK}"
  ls -lh "${APK}"
else
  echo "HATA: APK bulunamadi: ${APK}" >&2
  exit 1
fi
