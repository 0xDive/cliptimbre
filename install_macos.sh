#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PYTHON="${CLIPTIMBRE_PYTHON:-${STREAMER_VOICE_PYTHON:-}}"
if [[ -z "$PYTHON" ]]; then
  candidates=(python3.12 python3.11 python3.10 python3.13 python3.14 python3)
  if [[ "$(uname -m)" == x86_64 ]]; then
    candidates=(python3.11 python3.10 python3)
  fi
  for candidate in "${candidates[@]}"; do
    if command -v "$candidate" >/dev/null 2>&1; then
      PYTHON="$candidate"
      break
    fi
  done
fi
if [[ -z "$PYTHON" ]]; then
  echo "Install Python 3.12 (3.11 on Intel Macs) or set CLIPTIMBRE_PYTHON." >&2
  exit 1
fi
exec "$PYTHON" "$HERE/install.py" "$@"
