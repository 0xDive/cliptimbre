#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
exec "${CLIPTIMBRE_PYTHON:-python3.12}" "$HERE/install.py" "$@"
