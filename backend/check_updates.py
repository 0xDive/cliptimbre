# GNU AGPL version 3 only. See LICENSE and LICENSE-RESOLVE-EXCEPTION.md.

import argparse
import http.client
import json
from pathlib import Path
import re
import sys
import tempfile
import time
from urllib.request import Request, urlopen


RELEASE_API = "https://api.github.com/repos/0xDive/cliptimbre/releases/latest"
RELEASE_TAG = re.compile(r"v((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))")
MAX_RESPONSE_BYTES = 1024 * 1024


def fetch_latest_version():
    request = Request(RELEASE_API, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "ClipTimbre",
    })
    with urlopen(request, timeout=8) as response:
        body = response.read(MAX_RESPONSE_BYTES + 1)
    if len(body) > MAX_RESPONSE_BYTES:
        raise ValueError("GitHub release response is too large")
    release = json.loads(body)
    if not isinstance(release, dict) or release.get("draft") or release.get("prerelease"):
        raise ValueError("GitHub did not return a stable release")
    tag = release.get("tag_name")
    match = RELEASE_TAG.fullmatch(tag) if isinstance(tag, str) else None
    if not match:
        raise ValueError("GitHub release tag must use vX.Y.Z")
    return match.group(1)


def write_cache(path, version, checked_at):
    temp = tempfile.NamedTemporaryFile(
        mode="w", encoding="ascii", dir=path.parent, prefix=".updates-", delete=False
    )
    temp_path = Path(temp.name)
    try:
        with temp:
            temp.write(f"latest={version}\nchecked_at={checked_at}\n")
        temp_path.replace(path)
    finally:
        temp_path.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Check for the latest stable ClipTimbre release.")
    parser.add_argument("--cache", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        version = fetch_latest_version()
        write_cache(args.cache, version, int(time.time()))
    except (OSError, ValueError, http.client.HTTPException) as exc:
        print(f"ClipTimbre update check failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
