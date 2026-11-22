import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import URLError

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))

import check_updates


class UpdateCheckTests(unittest.TestCase):
    def test_reads_stable_tag_from_public_release_endpoint(self):
        response = io.BytesIO(json.dumps({
            "tag_name": "v0.18.10",
            "draft": False,
            "prerelease": False,
        }).encode())
        with patch.object(check_updates, "urlopen", return_value=response) as urlopen:
            self.assertEqual(check_updates.fetch_latest_version(), "0.18.10")
        request = urlopen.call_args.args[0]
        self.assertEqual(request.full_url, check_updates.RELEASE_API)
        self.assertIsNone(request.get_header("Authorization"))

    def test_rejects_non_release_payload(self):
        for release in ([], {"tag_name": "v0.18.0-rc.1"}, {"tag_name": "v0.18.0", "draft": True},
                        {"tag_name": "v0.18.0", "prerelease": True}):
            with self.subTest(release=release):
                response = io.BytesIO(json.dumps(release).encode())
                with patch.object(check_updates, "urlopen", return_value=response):
                    with self.assertRaises(ValueError):
                        check_updates.fetch_latest_version()

    def test_failed_check_keeps_last_successful_result(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory) / "updates.txt"
            args = ["--cache", str(cache)]
            with patch.object(check_updates, "fetch_latest_version", return_value="0.18.10"):
                with patch.object(check_updates.time, "time", return_value=1800000000):
                    self.assertEqual(check_updates.main(args), 0)
            expected = "latest=0.18.10\nchecked_at=1800000000\n"
            self.assertEqual(cache.read_text(encoding="ascii"), expected)
            with patch.object(check_updates, "urlopen", side_effect=URLError("offline")):
                with patch("sys.stderr", new_callable=io.StringIO):
                    self.assertEqual(check_updates.main(args), 1)
            self.assertEqual(cache.read_text(encoding="ascii"), expected)
