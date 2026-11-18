"""Run with: python3 -m unittest discover -s scripts/tests -v

Checks how scripts/fork/sim calls sim-vault, with stand-ins for sim-vault and xcrun on PATH: no real
simulator, sim-vault or NAS is touched.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/fork/sim"
NAME = "HERMEX iPhone 18 Pro Max"
OWNER = "hermex:up:" + str(ROOT.resolve())

STUB = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

tool = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["STUB_CALLS"], "a") as calls:
    calls.write(json.dumps([tool, *args]) + "\n")
if tool == "xcrun":
    raise SystemExit(99)
if args[1:] == ["--help"]:
    print(os.environ.get("STUB_HELP", "usage: sim-vault shutdown NAME [--wait S] [--busy-lock FILE]"))
    raise SystemExit(int(os.environ.get("STUB_HELP_RC", "0")))
if args[0] == "ensure":
    print("SIM-UDID")
raise SystemExit(int(os.environ.get("STUB_RC_" + args[0].upper(), "0")))
'''


class ForkSimTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "python3").symlink_to(sys.executable)
        for tool in ("sim-vault", "xcrun"):
            path = self.bin / tool
            path.write_text(STUB)
            path.chmod(0o755)
        self.home = self.root / "home"
        self.home.mkdir()
        self.calls_file = self.root / "calls.jsonl"
        self.locks = self.home / "Library/Caches/HermexSimulatorLocks"
        self.device_lock = str(self.locks / "{udid}.lock")

    def invoke(self, *args, vault=True, **stub_env):
        if not vault:
            (self.bin / "sim-vault").unlink()
        env = {"HOME": str(self.home), "STUB_CALLS": str(self.calls_file),
               "PATH": "{}:/usr/bin:/bin".format(self.bin), **stub_env}
        prefix = ["/usr/bin/env", "-i", *("{}={}".format(k, v) for k, v in env.items()),
                  "/bin/bash", "--noprofile", "--norc"]
        tools = ["xcrun"] + (["sim-vault"] if vault else [])
        probe = subprocess.run([*prefix, "-c", "command -v " + " ".join(tools)],
                               capture_output=True, text=True, check=True, timeout=30)
        self.assertEqual(probe.stdout.split(), [str(self.bin / t) for t in tools],
                         "PATH must resolve to the stand-ins")
        result = subprocess.run([*prefix, str(SCRIPT), *args], capture_output=True, text=True, timeout=30)
        calls = ([json.loads(line) for line in self.calls_file.read_text().splitlines()]
                 if self.calls_file.exists() else [])
        self.assertFalse(any(call[0] == "xcrun" for call in calls), "only sim-vault touches devices")
        return result, calls

    def test_ensure_boots_with_the_checkout_lease_and_prints_only_the_udid(self):
        result, calls = self.invoke("ensure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [["sim-vault", "ensure", NAME, "--boot", "--lease", OWNER]])
        self.assertEqual(result.stdout, "SIM-UDID\n")
        self.assertEqual(result.stderr.splitlines()[-1], "ensure rc=0")

    def test_ensure_owner_can_be_set_per_session(self):
        result, calls = self.invoke("ensure", HERMEX_SIM_OWNER="hermex:up:session-b")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[0][-1], "hermex:up:session-b")

    def test_ensure_passes_the_exit_code_through(self):
        result, _ = self.invoke("ensure", STUB_RC_ENSURE="5")
        self.assertEqual(result.returncode, 5)
        self.assertEqual(result.stderr.splitlines()[-1], "ensure rc=5")

    def test_down_releases_then_shuts_down_unless_test_sim_holds_the_device(self):
        result, calls = self.invoke("down")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [
            ["sim-vault", "shutdown", "--help"],
            ["sim-vault", "release", NAME, "--lease", OWNER],
            ["sim-vault", "shutdown", NAME, "--busy-lock", self.device_lock],
        ])
        self.assertTrue(self.locks.is_dir(), "sim-vault cannot create a lock in a missing directory")
        self.assertEqual(result.stderr.splitlines()[-1], "down rc=0")

    def test_down_reports_a_device_still_in_use_with_its_code(self):
        result, calls = self.invoke("down", STUB_RC_SHUTDOWN="8")
        self.assertEqual(result.returncode, 8)
        self.assertEqual(result.stderr.splitlines()[-1], "down rc=8")

    def test_down_does_not_shut_down_when_release_fails(self):
        result, calls = self.invoke("down", STUB_RC_RELEASE="1")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("shutdown", [call[1] for call in calls[1:]])
        self.assertEqual(result.stderr.splitlines()[-1], "down rc=1")

    def test_down_with_an_old_sim_vault_keeps_the_lease(self):
        for env in ({"STUB_HELP_RC": "2", "STUB_HELP": "invalid choice: 'shutdown'"},
                    {"STUB_HELP": "usage: sim-vault shutdown NAME [--wait S]"}):
            with self.subTest(env=env):
                self.calls_file.unlink(missing_ok=True)
                result, calls = self.invoke("down", **env)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(calls, [["sim-vault", "shutdown", "--help"]])
                self.assertIn("aghub-cli source sync audichuang/audi-skill -g --update --yes", result.stderr)
                self.assertEqual(result.stderr.splitlines()[-1], "down rc=2")

    def test_park_holds_off_for_builds_and_test_sim_runs(self):
        for rc in ("0", "8", "9"):
            with self.subTest(rc=rc):
                self.calls_file.unlink(missing_ok=True)
                result, calls = self.invoke("park", STUB_RC_PARK=rc)
                self.assertEqual(result.returncode, int(rc))
                self.assertEqual(calls, [["sim-vault", "park", NAME, "--shutdown",
                                          "--busy-lock", "/tmp/hermex-build.lock",
                                          "--busy-lock", self.device_lock]])
                self.assertTrue(self.locks.is_dir())
                self.assertEqual(result.stderr.splitlines()[-1], "park rc=" + rc)

    def test_usage_and_missing_sim_vault(self):
        result, calls = self.invoke("restore")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(calls, [])
        result, calls = self.invoke("park", vault=False)
        self.assertEqual(result.returncode, 127)
        self.assertEqual(calls, [])
        self.assertEqual(result.stderr.splitlines()[-1], "park rc=127")


if __name__ == "__main__":
    unittest.main()
