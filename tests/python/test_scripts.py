"""python3 -m unittest discover -s tests/python"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "jvm"))
sys.path.insert(0, str(ROOT / "config"))

import patch_vmargs as pv  # noqa: E402
import tune_options as to  # noqa: E402

# vmArgs no formato do ProjectZomboid64.json do B41
B41_VMARGS = [
    "-Djava.awt.headless=true",
    "-Xmx3072m",
    "-Dzomboid.steam=1",
    "-Dzomboid.znetlog=1",
    "-Djava.library.path=linux64/:natives/",
    "-Djava.security.egd=file:/dev/urandom",
    "-XX:+UseZGC",
    "-XX:-OmitStackTraceInFastThrow",
]


class PatchVmArgs(unittest.TestCase):
    def test_preserves_unmanaged_and_replaces_gc(self):
        new = pv.profile_args("g1", 10, 17)
        out = pv.patch_vmargs(B41_VMARGS, new)
        self.assertNotIn("-XX:+UseZGC", out)
        self.assertNotIn("-Xmx3072m", out)
        for keep in ("-Djava.library.path=linux64/:natives/", "-XX:-OmitStackTraceInFastThrow", "-Dzomboid.steam=1"):
            self.assertIn(keep, out)
        self.assertEqual(out.count("-Xmx10g"), 1)

    def test_idempotent(self):
        new = pv.profile_args("zgc", 8, 17) + pv.diagnostics_args(True, True, "zperf-agent.jar")
        once = pv.patch_vmargs(B41_VMARGS, new)
        twice = pv.patch_vmargs(once, new)
        self.assertEqual(once, twice)

    def test_unlock_before_experimental(self):
        args = pv.profile_args("g1", 8, 17)
        self.assertLess(args.index("-XX:+UnlockExperimentalVMOptions"), args.index("-XX:G1NewSizePercent=30"))

    def test_auto_profile_by_java(self):
        self.assertEqual(pv.resolve_profile("auto", 17), "zgc")
        self.assertEqual(pv.resolve_profile("auto", 21), "zgc-gen")
        self.assertIn("-XX:+ZGenerational", pv.profile_args("zgc-gen", 8, 21))
        self.assertNotIn("-XX:+ZGenerational", pv.profile_args("zgc-gen", 8, 24))
        with self.assertRaises(SystemExit):
            pv.profile_args("zgc-gen", 8, 17)

    def test_heap_policy(self):
        self.assertEqual(pv.auto_heap_gb(8), 3)
        self.assertEqual(pv.auto_heap_gb(15.6), 8)   # "16 GB" reportados pelo SO
        self.assertEqual(pv.auto_heap_gb(31.8), 12)
        self.assertEqual(pv.auto_heap_gb(64), 16)

    def test_main_writes_backup_and_json(self):
        with tempfile.TemporaryDirectory() as d:
            gd = Path(d)
            (gd / "ProjectZomboid64.json").write_text(json.dumps(
                {"mainClass": "zombie/gameStates/MainScreenState", "classpath": ["."], "vmArgs": B41_VMARGS}))
            (gd / "jre64").mkdir()
            (gd / "jre64" / "release").write_text('JAVA_VERSION="17.0.1"\n')
            self.assertEqual(pv.main(["--game-dir", d, "--heap", "10g", "--gc-log"]), 0)
            data = json.loads((gd / "ProjectZomboid64.json").read_text())
            self.assertIn("-XX:ZAllocationSpikeTolerance=5", data["vmArgs"])
            self.assertEqual(data["mainClass"], "zombie/gameStates/MainScreenState")
            self.assertTrue((gd / "ProjectZomboid64.json.zperf-backup").exists())
            pv.main(["--game-dir", d, "--restore"])
            self.assertEqual(json.loads((gd / "ProjectZomboid64.json").read_text())["vmArgs"], B41_VMARGS)


class TuneOptions(unittest.TestCase):
    INI = "version=1\nvsync=true\nlightingFPS=30\nzoomLevels1x=50;75;125;150;175;200\nfoo=bar\n"

    def test_only_existing_keys(self):
        lines = to.parse_ini(self.INI)
        out, changes, missing = to.apply(lines, {"vsync": "false", "corpseShadows": "false"}, None)
        self.assertIn(("vsync", "true", "false"), changes)
        self.assertEqual(missing, ["corpseShadows"])
        self.assertNotIn("corpseShadows=false", out)
        self.assertIn("foo=bar", out)

    def test_cap_zoom(self):
        self.assertEqual(to.cap_zoom("50;75;125;150;175;200", 150), "50;75;125;150")
        lines = to.parse_ini(self.INI)
        out, changes, _ = to.apply(lines, {}, 150)
        self.assertIn("zoomLevels1x=50;75;125;150", out)

    def test_profile_file_parses(self):
        prof = to.read_profile(ROOT / "config" / "options-perf.ini")
        self.assertEqual(prof.get("vsync"), "false")
        self.assertNotIn("lightingQuality", prof)  # comentada de propósito


if __name__ == "__main__":
    unittest.main()
