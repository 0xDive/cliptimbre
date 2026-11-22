#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
exec "$HERE/install_macos.sh" --uninstall "$@"
