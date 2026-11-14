"""Unit tests for InstaBox persistent Android E2E & Settings upgrade helper."""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import instabox_android_e2e as ib  # noqa: E402


class FakeRunner:
    def __init__(self, handler=None) -> None:
        self.calls: list[list[str]] = []
        self.handler = handler or (lambda cmd: subprocess.CompletedProcess(cmd, 0, "", ""))

    def run(self, cmd, *, check=True, timeout=120, env=None):
        self.calls.append(cmd)
        proc = self.handler(cmd)
        if check and proc.returncode != 0:
            raise RuntimeError(f"failed: {cmd}")
        return proc

    def exec_box(self, box, shell_cmd, *, check=True, timeout=180):
        return self.run(["instabox", "exec", box, "--", "sh", "-c", shell_cmd], check=check, timeout=timeout)


class InstaBoxAndroidE2ETest(unittest.TestCase):
    def test_box_exists_handles_json_list_dict_and_table(self) -> None:
        self.assertTrue(ib.box_exists_in_listing('[{"name": "flutify-e2e-android"}]', "flutify-e2e-android"))
        self.assertTrue(
            ib.box_exists_in_listing('{"machines": [{"name": "flutify-e2e-android"}]}', "flutify-e2e-android")
        )
        self.assertFalse(ib.box_exists_in_listing('{"machines": [{"name": "other"}]}', "flutify-e2e-android"))
        self.assertTrue(
            ib.box_exists_in_listing("NAME  TEMPLATE  STATUS\nflutify-e2e-android  android  paused\n", "flutify-e2e-android")
        )
        self.assertFalse(ib.box_exists_in_listing("NAME TEMPLATE\n", "flutify-e2e-android"))

    def test_ensure_box_ready_creates_persistent_without_delete_after(self) -> None:
        def handle(cmd):
            if cmd[:2] == ["instabox", "ls"]:
                return subprocess.CompletedProcess(cmd, 0, "[]", "")
            if cmd[:2] == ["instabox", "exec"]:
                return subprocess.CompletedProcess(cmd, 0, "127.0.0.1:5555\tdevice\n", "")
            return subprocess.CompletedProcess(cmd, 0, "", "")

        runner = FakeRunner(handle)
        state = ib.ensure_box_ready(runner, "flutify-e2e-android")
        self.assertEqual(state, "created")
        create_calls = [c for c in runner.calls if c[:2] == ["instabox", "create"]]
        self.assertEqual(len(create_calls), 1)
        self.assertNotIn("--delete-after", " ".join(create_calls[0]))

    def test_ensure_box_ready_resumes_and_never_deletes_existing_box(self) -> None:
        def handle(cmd):
            if cmd[:2] == ["instabox", "ls"]:
                return subprocess.CompletedProcess(cmd, 0, '[{"name": "flutify-e2e-android"}]', "")
            if cmd[:2] == ["instabox", "resume"]:
                return subprocess.CompletedProcess(cmd, 1, "", "already stopped")
            if cmd[:2] == ["instabox", "exec"]:
                return subprocess.CompletedProcess(cmd, 0, "device\n", "")
            return subprocess.CompletedProcess(cmd, 0, "", "")

        runner = FakeRunner(handle)
        state = ib.ensure_box_ready(runner, "flutify-e2e-android")
        self.assertEqual(state, "reused")
        self.assertTrue(any(c[:2] == ["instabox", "resume"] for c in runner.calls))
        self.assertTrue(any(c[:2] == ["instabox", "start"] for c in runner.calls))
        self.assertFalse(any(c[:2] == ["instabox", "create"] for c in runner.calls))
        self.assertFalse(any(c[:2] == ["instabox", "rm"] for c in runner.calls))

    def test_clean_environment_never_uninstalls_or_destroys_and_suspends(self) -> None:
        runner = FakeRunner()
        ib.clean_environment(runner, "flutify-e2e-android", suspend=True)
        joined = "\n".join(" ".join(c) for c in runner.calls)
        self.assertNotIn("uninstall", joined)
        self.assertNotIn("instabox rm", joined)
        self.assertIn("force-stop", joined)
        self.assertIn("instabox suspend flutify-e2e-android", joined)

    def test_select_baseline_releases_filters_and_orders_descending(self) -> None:
        releases = [
            {"tag_name": "v0.18.145-selftest", "draft": False, "assets": [{"name": "Flutify-v0.18.145-selftest-android-x86_64.apk"}]},
            {"tag_name": "v0.18.144-selftest", "draft": True, "assets": [{"name": "Flutify-v0.18.144-selftest-android-x86_64.apk"}]},
            {"tag_name": "v0.18.142-beta", "draft": False, "assets": [{"name": "Flutify-v0.18.142-beta-android-x86_64.apk"}]},
            {"tag_name": "v0.18.138-selftest", "draft": False, "assets": [{"name": "Flutify-v0.18.138-selftest-android-x86_64.apk"}]},
            {"tag_name": "v0.18.141-selftest", "draft": False, "assets": [{"name": "Flutify-v0.18.141-selftest-android-universal.apk"}]},
            {"tag_name": "v0.18.130-selftest", "draft": False, "assets": [{"name": "other.zip"}]},
        ]
        selected = ib.select_baseline_releases(releases, "v0.18.145-selftest")
        self.assertEqual([r["tag_name"] for r in selected], ["v0.18.141-selftest", "v0.18.138-selftest"])

    def test_determine_upgrade_action_cases(self) -> None:
        self.assertEqual(ib.determine_upgrade_action(None, 2414001, has_baseline_apk=True), "seed_then_upgrade")
        self.assertEqual(ib.determine_upgrade_action(None, 2414001, has_baseline_apk=False), "seed_target")
        self.assertEqual(ib.determine_upgrade_action(2404001, 2414001, has_baseline_apk=False), "upgrade_via_settings")
        self.assertEqual(ib.determine_upgrade_action(2414001, 2414001, has_baseline_apk=False), "already_latest")
        with self.assertRaises(RuntimeError):
            ib.determine_upgrade_action(2500000, 2414001, has_baseline_apk=False)

    def test_uiautomator_settings_and_package_installer_finders(self) -> None:
        home_xml_new = """<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
        <hierarchy rotation="0">
          <node index="0" text="" content-desc="设置" package="com.flutify.music.flutify_app" clickable="true" enabled="true" bounds="[32,120][140,228]" />
          <node index="1" text="全部" content-desc="" package="com.flutify.music.flutify_app" clickable="true" enabled="true" bounds="[180,140][280,210]" />
        </hierarchy>"""
        nodes_new = ib.parse_uiautomator_nodes(home_xml_new)
        self.assertEqual(ib.find_settings_tap_target(nodes_new), (86, 174))

        home_xml_legacy = """<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
        <hierarchy rotation="0">
          <node index="1" text="" content-desc="All" package="com.flutify.music.flutify_app" clickable="true" enabled="true" bounds="[186,140][280,210]" />
        </hierarchy>"""
        nodes_legacy = ib.parse_uiautomator_nodes(home_xml_legacy)
        pt = ib.find_settings_tap_target(nodes_legacy)
        self.assertIsNotNone(pt)
        self.assertGreaterEqual(pt[0], 24)
        self.assertLess(pt[0], 186)

        installer_xml = """<hierarchy>
          <node text="Cancel" resource-id="android:id/button2" package="com.android.packageinstaller" enabled="true" bounds="[100,1500][400,1600]" />
          <node text="Update" resource-id="android:id/button1" package="com.android.packageinstaller" enabled="true" bounds="[600,1500][950,1600]" />
        </hierarchy>"""
        installer_nodes = ib.parse_uiautomator_nodes(installer_xml)
        self.assertEqual(ib.find_package_installer_confirm(installer_nodes), (775, 1550))

    def test_runner_exec_box_passes_timeout_and_push_uses_cp(self) -> None:
        recorded: list[list[str]] = []

        class StubRunner(ib.Runner):
            def run(self, cmd, *, check=True, timeout=120, env=None):
                recorded.append(cmd)
                return subprocess.CompletedProcess(cmd, 0, "", "")

        runner = StubRunner()
        runner.exec_box("flutify-e2e-android", "echo hi", timeout=900)
        self.assertEqual(
            recorded[0],
            ["instabox", "exec", "flutify-e2e-android", "--timeout", "600", "--", "sh", "-c", "echo hi"],
        )

        with tempfile.TemporaryDirectory() as tmp:
            apk = Path(tmp) / "target.apk"
            apk.write_bytes(b"apk")
            ib.push_and_install_apk(runner, "flutify-e2e-android", apk, "target.apk")

        cp_calls = [c for c in recorded if c[:2] == ["instabox", "cp"]]
        self.assertEqual(len(cp_calls), 1)
        self.assertEqual(
            cp_calls[0],
            ["instabox", "cp", "-p", str(apk), f"flutify-e2e-android:{ib.BOX_STAGE_DIR}/target.apk"],
        )

    def test_parse_dumpsys_package(self) -> None:
        vc, vn = ib.parse_dumpsys_package(
            "  Package [com.flutify.music.flutify_app] (1234):\n"
            "    versionCode=2414001 minSdk=24 targetSdk=35\n"
            "    versionName=0.0.22\n"
        )
        self.assertEqual(vc, 2414001)
        self.assertEqual(vn, "0.0.22")
        self.assertEqual(ib.parse_dumpsys_package("Unable to find package: com.foo"), (None, None))

    def test_redact_sensitive_masks_emails_keys_and_tokens(self) -> None:
        raw = (
            '{"org": "alice.example@gmail.com", "key": "ibk_secret12345", '
            '"auth": "Bearer tok_abc_123", "gh": "ghp_secretToken999"}'
        )
        redacted = ib.redact_sensitive(raw)
        self.assertNotIn("alice.example@gmail.com", redacted)
        self.assertNotIn("ibk_secret12345", redacted)
        self.assertNotIn("tok_abc_123", redacted)
        self.assertNotIn("ghp_secretToken999", redacted)
        self.assertIn("[REDACTED_EMAIL]", redacted)
        self.assertIn("ibk_[REDACTED]", redacted)
        self.assertIn("Bearer [REDACTED]", redacted)
        self.assertIn("[REDACTED_TOKEN]", redacted)

    def test_runner_run_redacts_failure_output(self) -> None:
        runner = ib.Runner()
        with self.assertRaises(RuntimeError) as ctx:
            runner.run(
                [
                    sys.executable,
                    "-c",
                    "import sys; sys.stderr.write('owner=user@example.com ibk_livekey99\\n'); sys.exit(2)",
                ]
            )
        msg = str(ctx.exception)
        self.assertNotIn("user@example.com", msg)
        self.assertNotIn("ibk_livekey99", msg)
        self.assertIn("[REDACTED_EMAIL]", msg)
        self.assertIn("ibk_[REDACTED]", msg)

    def test_ensure_box_ready_boot_script_avoids_duplicate_adb_connection(self) -> None:
        def handle(cmd):
            if cmd[:2] == ["instabox", "ls"]:
                return subprocess.CompletedProcess(cmd, 0, '[{"name": "my-android"}]', "")
            return subprocess.CompletedProcess(cmd, 0, "", "")

        runner = FakeRunner(handle)
        ib.ensure_box_ready(runner, "my-android")
        exec_calls = [c for c in runner.calls if c[:2] == ["instabox", "exec"]]
        self.assertGreaterEqual(len(exec_calls), 1)
        boot_cmd = exec_calls[-1][-1]
        self.assertIn("adb disconnect 127.0.0.1:5555", boot_cmd)
        self.assertIn("[[:space:]]device$", boot_cmd)
        self.assertNotIn("\\tdevice$", boot_cmd)

    def test_apply_inapp_downloaded_apk_if_needed_installs_from_cache(self) -> None:
        def handle(cmd):
            return subprocess.CompletedProcess(cmd, 0, "Success\n", "")

        runner = FakeRunner(handle)
        ok = ib.apply_inapp_downloaded_apk_if_needed(runner, "my-android")
        self.assertTrue(ok)
        self.assertEqual(len(runner.calls), 1)
        self.assertIn("cache/flutify-updates/download-*/*.apk", runner.calls[0][-1])
        self.assertIn("pm install -r /data/local/tmp/flutify_inapp_update.apk", runner.calls[0][-1])

    def test_apply_inapp_downloaded_apk_if_needed_falls_back_to_target_apk(self) -> None:
        def handle(cmd):
            if "cache/flutify-updates" in cmd[-1]:
                return subprocess.CompletedProcess(cmd, 1, "", "")
            return subprocess.CompletedProcess(cmd, 0, "Success\n", "")

        runner = FakeRunner(handle)
        ok = ib.apply_inapp_downloaded_apk_if_needed(
            runner,
            "my-android",
            target_apk=Path("/tmp/target.apk"),
        )
        self.assertTrue(ok)
        self.assertTrue(any(c[:2] == ["instabox", "cp"] for c in runner.calls))
        self.assertTrue(any("adb install -r" in c[-1] for c in runner.calls))


if __name__ == "__main__":
    unittest.main()
