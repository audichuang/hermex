"""Run with: python3 -m unittest discover -s scripts/tests -v

Checks how scripts/fork/sim calls sim-vault, with stand-ins for sim-vault and xcrun on PATH: no real
simulator, sim-vault or NAS is touched. The sim-vault stand-in keeps leases in a JSON file.
"""

from contextlib import contextmanager
import fcntl
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
OWNER_PREFIX = "hermex:up:" + str(ROOT.resolve()) + ":"
SYNC = "aghub-cli source sync audichuang/audi-skill -g --update --yes"
PROBES = [["sim-vault", "shutdown", "--help"], ["sim-vault", "ensure", "--help"]]

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
leases_file = Path(os.environ["STUB_LEASES"])
leases = json.loads(leases_file.read_text()) if leases_file.exists() else []
if args[1:] == ["--help"]:
    default = {"shutdown": "usage: sim-vault shutdown NAME [--wait S] [--busy-lock FILE]",
               "ensure": "usage: sim-vault ensure NAME [--lease OWNER] [--deny-other-leases]"}
    print(os.environ.get("STUB_HELP_" + args[0].upper(), default.get(args[0], "")))
    raise SystemExit(int(os.environ.get("STUB_HELP_RC", "0")))
rc = int(os.environ.get("STUB_RC_" + args[0].upper(), "0"))
if args[0] == "status":
    print(json.dumps({"udid": os.environ.get("STUB_UDID") or None,
                      "leases": [{"owner": o, "stale": False} for o in leases]}))
elif args[0] == "ensure":
    if rc == 0:
        owner = args[args.index("--lease") + 1]
        if owner not in leases:
            leases_file.write_text(json.dumps(leases + [owner]))
        print("SIM-UDID")
elif args[0] == "release" and rc == 0:
    owner = args[args.index("--lease") + 1]
    leases_file.write_text(json.dumps([o for o in leases if o != owner]))
raise SystemExit(rc)
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
        self.leases_file = self.root / "leases.json"
        self.locks = self.home / "Library/Caches/HermexSimulatorLocks"
        self.owners = self.home / "Library/Developer/CoreSimulator/sim-vault/owners"
        self.device_lock = str(self.locks / "{udid}.lock")

    def invoke(self, *args, vault=True, **stub_env):
        if not vault:
            (self.bin / "sim-vault").unlink()
        self.calls_file.unlink(missing_ok=True)
        env = {"HOME": str(self.home), "STUB_CALLS": str(self.calls_file),
               "STUB_LEASES": str(self.leases_file),
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

    def leases(self):
        return json.loads(self.leases_file.read_text()) if self.leases_file.exists() else []

    def owner_files(self):
        return sorted(self.owners.glob("hermex-*")) if self.owners.exists() else []

    @contextmanager
    def held_by_test_sim(self, udid):
        """Hold the per-device lock the way scripts/test-sim does."""
        self.locks.mkdir(parents=True, exist_ok=True)
        with (self.locks / (udid + ".lock")).open("a+") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            handle.write("PID 1: other checkout (SIM-UDID)\n")
            handle.flush()
            yield

    def test_ensure_takes_a_session_lease_and_prints_only_the_udid(self):
        result, calls = self.invoke("ensure", STUB_UDID="SIM-UDID")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[:3], [*PROBES, ["sim-vault", "status", NAME, "--json"]])
        self.assertEqual(calls[3][:-1], ["sim-vault", "ensure", NAME, "--boot", "--lease"])
        owner = calls[3][-1]
        self.assertTrue(owner.startswith(OWNER_PREFIX) and len(owner) == len(OWNER_PREFIX) + 8, owner)
        self.assertEqual(result.stdout, "SIM-UDID\n")
        self.assertEqual(result.stderr.splitlines()[-1], "ensure rc=0")
        [record] = self.owner_files()
        self.assertTrue(record.name.endswith("-HERMEX-iPhone-18-Pro-Max"))
        self.assertEqual(record.read_text().strip(), owner)

    def test_second_ensure_in_the_same_checkout_is_refused_until_down(self):
        first, calls = self.invoke("ensure")
        self.assertEqual(first.returncode, 0, first.stderr)
        owner = calls[-1][-1]
        second, calls = self.invoke("ensure")
        self.assertEqual(second.returncode, 8)
        self.assertNotIn("ensure", [c[1] for c in calls if c[2:] != ["--help"]])
        self.assertIn("HERMEX_SIM_OWNER", second.stderr)
        self.assertEqual(self.leases(), [owner])

        down, calls = self.invoke("down")
        self.assertEqual(down.returncode, 0, down.stderr)
        self.assertIn(["sim-vault", "release", NAME, "--lease", owner], calls)
        self.assertEqual(self.owner_files(), [])
        third, calls = self.invoke("ensure")
        self.assertEqual(third.returncode, 0, third.stderr)
        self.assertNotEqual(calls[-1][-1], owner)

    def test_stale_record_does_not_block_ensure(self):
        self.invoke("ensure")
        self.leases_file.write_text("[]")
        again, _ = self.invoke("ensure")
        self.assertEqual(again.returncode, 0, again.stderr)

    def test_ensure_with_a_session_owner_keeps_no_record(self):
        result, calls = self.invoke("ensure", HERMEX_SIM_OWNER="hermex:up:session-b")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[-1][-1], "hermex:up:session-b")
        self.assertEqual(self.owner_files(), [])

    def test_ensure_is_refused_while_test_sim_holds_the_device(self):
        with self.held_by_test_sim("SIM-UDID"):
            result, calls = self.invoke("ensure", STUB_UDID="SIM-UDID")
        self.assertEqual(result.returncode, 8)
        self.assertNotIn("ensure", [c[1] for c in calls if c[2:] != ["--help"]])
        self.assertIn("under test", result.stderr)
        self.assertEqual(self.leases(), [])
        self.assertEqual(result.stderr.splitlines()[-1], "ensure rc=8")

    def test_ensure_holds_the_test_sim_lock_while_leasing(self):
        # The stand-in ensure tries the device lock itself: it must find it held by the wrapper.
        probe = self.bin / "sim-vault"
        probe.write_text(STUB.replace(
            'elif args[0] == "ensure":',
            'elif args[0] == "ensure":\n'
            '    import fcntl\n'
            '    h = open(os.environ["HOME"] + "/Library/Caches/HermexSimulatorLocks/SIM-UDID.lock", "a+")\n'
            '    try:\n'
            '        fcntl.flock(h, fcntl.LOCK_EX | fcntl.LOCK_NB); raise SystemExit(70)\n'
            '    except BlockingIOError:\n'
            '        pass'))
        result, _ = self.invoke("ensure", STUB_UDID="SIM-UDID")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_ensure_passes_the_exit_code_through(self):
        result, _ = self.invoke("ensure", STUB_RC_ENSURE="5", STUB_UDID="SIM-UDID")
        self.assertEqual(result.returncode, 5)
        self.assertEqual(result.stderr.splitlines()[-1], "ensure rc=5")
        result, _ = self.invoke("ensure", STUB_RC_ENSURE="3")
        self.assertEqual(result.returncode, 3)

    def test_down_releases_then_shuts_down_unless_a_build_or_test_sim_holds_the_device(self):
        self.invoke("ensure")
        result, calls = self.invoke("down")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[2:], [
            ["sim-vault", "release", NAME, "--lease", calls[2][-1]],
            ["sim-vault", "shutdown", NAME, "--busy-lock", "/tmp/hermex-build.lock",
             "--busy-lock", self.device_lock],
        ])
        self.assertTrue(self.locks.is_dir(), "sim-vault cannot create a lock in a missing directory")
        self.assertEqual(result.stderr.splitlines()[-1], "down rc=0")

    def test_down_without_a_lease_only_shuts_down(self):
        result, calls = self.invoke("down")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c[1] for c in calls[2:]], ["shutdown"])

    def test_down_reports_a_device_still_in_use_with_its_code(self):
        result, _ = self.invoke("down", HERMEX_SIM_OWNER="x", STUB_RC_SHUTDOWN="8")
        self.assertEqual(result.returncode, 8)
        self.assertEqual(result.stderr.splitlines()[-1], "down rc=8")

    def test_down_does_not_shut_down_when_release_fails_and_keeps_the_record(self):
        self.invoke("ensure")
        result, calls = self.invoke("down", STUB_RC_RELEASE="1")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("shutdown", [call[1] for call in calls[2:]])
        self.assertEqual(len(self.owner_files()), 1)
        self.assertEqual(result.stderr.splitlines()[-1], "down rc=1")

    def test_old_sim_vault_is_refused_before_any_lease_or_archive_work(self):
        olds = ({"STUB_HELP_RC": "2", "STUB_HELP_SHUTDOWN": "invalid choice: 'shutdown'",
                 "STUB_HELP_ENSURE": "invalid choice"},
                {"STUB_HELP_SHUTDOWN": "usage: sim-vault shutdown NAME [--wait S]"},
                {"STUB_HELP_ENSURE": "usage: sim-vault ensure NAME [--lease OWNER]"})
        for command in ("ensure", "down", "park"):
            for env in olds:
                with self.subTest(command=command, env=env):
                    result, calls = self.invoke(command, **env)
                    self.assertEqual(result.returncode, 2)
                    self.assertEqual(calls, PROBES)
                    self.assertIn(SYNC, result.stderr)
                    self.assertEqual(result.stderr.splitlines()[-1], command + " rc=2")
                    self.assertEqual(self.owner_files(), [])

    def test_park_holds_off_for_builds_and_test_sim_runs(self):
        for rc in ("0", "8", "9"):
            with self.subTest(rc=rc):
                result, calls = self.invoke("park", STUB_RC_PARK=rc)
                self.assertEqual(result.returncode, int(rc))
                self.assertEqual(calls[2:], [["sim-vault", "park", NAME, "--shutdown",
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
