import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import call, patch

import install


class InstallerTests(unittest.TestCase):
    def setUp(self):
        work = tempfile.TemporaryDirectory(prefix="cliptimbre test ")
        self.addCleanup(work.cleanup)
        self.data = Path(work.name) / "User data"
        self.scripts = Path(work.name) / "Fusion" / "Scripts"
        self.utility = self.scripts / "Utility"

    def run_wrapper(self, verb, *args):
        if sys.platform == "win32":
            command = [os.environ["COMSPEC"], "/d", "/c", f"{verb}_windows.cmd"]
        else:
            platform = "macos" if sys.platform == "darwin" else "linux"
            command = ["bash", f"./{verb}_{platform}.sh"]

        result = subprocess.run(
            [*command, *args],
            cwd=install.ROOT,
            env={
                **os.environ,
                "CLIPTIMBRE_PYTHON": sys.executable,
                "STREAMER_VOICE_DATA_DIR": str(self.data),
            },
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def test_platform_wrappers_run_the_installer(self):
        for verb in ("install", "uninstall"):
            with self.subTest(verb=verb):
                self.assertIn("--scripts-dir", self.run_wrapper(verb, "--help"))

    def test_install_and_uninstall_preserve_local_data(self):
        self.data.mkdir(parents=True)
        profile = self.data / "active_profile.txt"
        profile.write_text("Existing profile\n", encoding="utf-8")
        config = self.data / "config.json"
        original_config = b'{"threshold": 0.62}\n'
        config.write_bytes(original_config)
        rules = self.data / "ad_safety_terms.json"
        original_rules = b'{"rules": []}\n'
        rules.write_bytes(original_rules)

        with patch.object(install, "DATA", self.data), patch.object(install, "runtime"):
            install.install(self.utility, None)

        launcher = self.utility / install.SOURCE_LAUNCHER.name
        self.assertEqual(launcher.read_bytes(), install.SOURCE_LAUNCHER.read_bytes())
        self.assertEqual((self.data / "VERSION").read_text().strip(), install.VERSION)
        self.assertTrue((self.data / "backend/profile.py").is_file())
        self.assertTrue((self.data / "backend/process_utils.py").is_file())
        self.assertTrue((self.data / "resolve/windows_process.lua").is_file())
        for name in ("chevron-right.png", "chevron-down.png", "LICENSE"):
            self.assertEqual(
                (self.data / "resolve/icons" / name).read_bytes(),
                (install.ROOT / "resolve_lua/icons" / name).read_bytes(),
            )
        self.run_wrapper("uninstall", "--scripts-dir", str(self.scripts))

        self.assertFalse(launcher.exists())
        self.assertEqual(profile.read_text(encoding="utf-8").strip(), "Existing profile")
        self.assertEqual(config.read_bytes(), original_config)
        self.assertEqual(rules.read_bytes(), original_rules)

    def test_uninstaller_leaves_an_unrelated_launcher_alone(self):
        self.utility.mkdir(parents=True)
        unrelated = self.utility / install.SOURCE_LAUNCHER.name
        unrelated.write_bytes(b"-- An unrelated script\n")
        self.run_wrapper("uninstall", "--scripts-dir", str(self.scripts))
        self.assertEqual(unrelated.read_bytes(), b"-- An unrelated script\n")

    def test_upgrade_refreshes_stock_rules_and_backs_them_up(self):
        self.data.mkdir(parents=True)
        rules = self.data / "ad_safety_terms.json"
        previous = b'{"version": 1, "rules": ["previous stock rules"]}\n'
        rules.write_bytes(previous)
        with patch.object(install, "DATA", self.data), patch.object(install, "runtime"), patch.object(
            install, "OLD_STARTER_RULES_SHA256", hashlib.sha256(previous).hexdigest(),
        ):
            install.install(self.utility, None)

        self.assertEqual(rules.read_bytes(), (install.ROOT / "ad_safety_terms.default.json").read_bytes())
        [backup] = (self.data / "backups").glob("*/ad_safety_terms.json")
        self.assertEqual(backup.read_bytes(), previous)

    def test_windows_installs_torch_wheels_before_resolving_the_dependencies(self):
        scripts = self.data / ".venv/Scripts"

        def create_environment(_):
            scripts.mkdir(parents=True)
            for name in ("python.exe", "pythonw.exe"):
                (scripts / name).touch()

        with (
            patch.object(install, "DATA", self.data),
            patch.object(install.sys, "platform", "win32"),
            patch.object(install.platform, "machine", return_value="AMD64"),
            patch.object(install.venv, "EnvBuilder") as builder,
            patch.object(install, "check_runtime", return_value=True) as check_runtime,
            patch.object(install.subprocess, "run") as run,
        ):
            builder.return_value.create.side_effect = create_environment
            install.runtime(None)
            install.runtime(None)

        builder.assert_called_once_with(with_pip=True)
        self.assertEqual(check_runtime.call_args_list, [call(scripts / "pythonw.exe")] * 2)
        pip = [str(scripts / "python.exe"), "-m", "pip", "--disable-pip-version-check", "install",
               "--no-compile", "--prefer-binary"]
        pins = ["torch==2.11.0", "torchaudio==2.11.0"]
        self.assertEqual(run.call_args_list, [
            call([*pip, "--index-url", "https://download.pytorch.org/whl/cpu", "--no-deps", *pins], check=True),
            call([*pip, "-r", str(install.ROOT / "requirements.txt"), *pins], check=True),
        ])
