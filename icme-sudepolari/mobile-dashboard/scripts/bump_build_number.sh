#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBSPEC="${ROOT}/pubspec.yaml"

if [[ ! -f "${PUBSPEC}" ]]; then
  echo "pubspec.yaml bulunamadi: ${PUBSPEC}" >&2
  exit 1
fi

line="$(grep -E '^version:[[:space:]]+' "${PUBSPEC}" | head -n 1 || true)"
if [[ -z "${line}" ]]; then
  echo "pubspec.yaml icinde 'version:' satiri bulunamadi." >&2
  exit 1
fi

raw="$(echo "${line}" | awk '{print $2}')"
name="${raw%%+*}"
build="${raw#*+}"

if [[ "${build}" == "${raw}" ]]; then
  # '+' yoksa +1 ekle
  new="${name}+1"
else
  if ! [[ "${build}" =~ ^[0-9]+$ ]]; then
    echo "Gecersiz build numarasi: '${raw}' (beklenen: x.y.z+N)" >&2
    exit 1
  fi
  new="${name}+$((build + 1))"
fi

tmp="$(mktemp)"
awk -v new="${new}" '
  BEGIN { done=0 }
  /^version:[[:space:]]+/ {
    if (done==0) {
      print "version: " new
      done=1
      next
    }
  }
  { print }
' "${PUBSPEC}" > "${tmp}"
mv "${tmp}" "${PUBSPEC}"

echo "OK: version -> ${new}"
