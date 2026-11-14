#!/usr/bin/env python3
"""InstaBox persistent Android box lifecycle, in-app Settings upgrade driver,
and Mock E2E orchestrator for Flutify CI.

Design guarantees:
- Reuses a single named persistent InstaBox Android container (`create` as a
  persistent box, `resume`/`start` on later runs, `suspend` after cleanup).
- Never destroys the container and never removes or resets the installed Flutify package.
- Cleans only temporary E2E outputs, staging files, and app process state.
- Drives real in-app Settings -> self-test channel -> Check updates -> Download ->
  SHA-256 verification -> Android PackageInstaller in-place upgrade before E2E.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any, Callable
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

PACKAGE_ID = "com.flutify.music.flutify_app"
MAIN_ACTIVITY = f"{PACKAGE_ID}/.MainActivity"
DEVICE_E2E_DIR = f"/sdcard/Android/data/{PACKAGE_ID}/files/flutify_e2e"
BOX_OUT_DIR = "/data/home/flutify_e2e_out"
BOX_STAGE_DIR = "/data/home/flutify_stage"
BOX_KEYSTORE_DIR = "/data/home/flutify-e2e-keystore"
UI_DUMP_DEVICE_PATH = "/data/local/tmp/flutify_ui.xml"

SELFTEST_TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)-selftest$")

LABELS_SETTINGS = (
    "设置",
    "Settings",
    "設定",
    "账号",
    "Account",
)
LABELS_ALL_TAB = ("全部", "All")
LABELS_UPDATE_VIEW = ("查看更新", "View update")
LABELS_UPDATE_CHECK = ("检查更新", "Check for updates", "檢查更新", "更新を確認")
LABELS_UPDATE_CHECKING = ("正在检查更新…", "Checking for updates…", "正在检查更新", "Checking for updates")
LABELS_CHANNEL_NON_SELFTEST = (
    "正式版（稳定）",
    "Release (stable)",
    "测试版（Beta）",
    "Beta",
    "正式版（穩定）",
)
LABELS_CHANNEL_SELFTEST = (
    "自测版（开发者自测）",
    "Self-test (developers only)",
    "自測版（開發者自測）",
)
LABELS_CHANNEL_CONFIRM = (
    "我是开发者，仍然切换",
    "I am a developer, switch anyway",
)
LABELS_DOWNLOAD = ("下载更新", "Download update", "下載更新")
LABELS_INSTALL_APK = ("安装 APK", "Install APK", "安裝 APK")
LABELS_UPDATE_READY = ("更新已就绪", "Update ready", "发现新版本", "New version available")
LABELS_UP_TO_DATE = ("已是最新版本", "You are up to date")
LABELS_UPDATE_FAILED = ("更新失败", "Update failed")
LABELS_ANDROID_INSTALL_CONFIRM = (
    "更新",
    "Update",
    "安装",
    "Install",
    "UPDATE",
    "INSTALL",
    "继续",
    "Continue",
    "仍然安装",
    "Install anyway",
)
LABELS_ANDROID_UNKNOWN_SOURCES = (
    "允许来自此来源的应用",
    "Allow from this source",
    "允许安装未知应用",
    "Allow app installs",
)
LABELS_ANDROID_DONE = ("完成", "Done", "DONE")


_EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
_IBK_RE = re.compile(r"\bibk_[A-Za-z0-9_-]+")
_GH_TOKEN_RE = re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)")
_BEARER_RE = re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._-]+")


def redact_sensitive(text: str) -> str:
    """Mask emails, API keys, and tokens before logging or raising."""
    if not text:
        return text
    out = _EMAIL_RE.sub("[REDACTED_EMAIL]", text)
    out = _IBK_RE.sub("ibk_[REDACTED]", out)
    out = _GH_TOKEN_RE.sub("[REDACTED_TOKEN]", out)
    out = _BEARER_RE.sub("Bearer [REDACTED]", out)
    for var in ("INSTABOX_API_KEY", "GH_TOKEN", "GITHUB_TOKEN"):
        secret = os.environ.get(var, "").strip()
        if secret:
            out = out.replace(secret, f"[REDACTED_{var}]")
    return out


class Runner:
    """Thin command execution abstraction to enable deterministic unit tests."""

    def run(
        self,
        cmd: list[str],
        *,
        check: bool = True,
        timeout: int = 120,
        env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        merged_env = os.environ.copy()
        if env:
            merged_env.update(env)
        proc = subprocess.run(
            cmd,
            text=True,
            capture_output=True,
            timeout=timeout,
            env=merged_env,
        )
        if check and proc.returncode != 0:
            raise RuntimeError(
                redact_sensitive(
                    f"Command failed ({proc.returncode}): {' '.join(cmd)}\n"
                    f"stdout: {proc.stdout}\nstderr: {proc.stderr}"
                )
            )
        return proc

    def exec_box(
        self,
        box: str,
        shell_cmd: str,
        *,
        check: bool = True,
        timeout: int = 180,
    ) -> subprocess.CompletedProcess[str]:
        exec_timeout = min(max(int(timeout), 1), 600)
        return self.run(
            [
                "instabox",
                "exec",
                box,
                "--timeout",
                str(exec_timeout),
                "--",
                "sh",
                "-c",
                shell_cmd,
            ],
            check=check,
            timeout=timeout + 30,
        )


def parse_selftest_tag(tag: str) -> tuple[int, int, int] | None:
    """Parse vMAJOR.MINOR.BUILD-selftest tag into comparable tuple."""
    match = SELFTEST_TAG_RE.match((tag or "").strip())
    if not match:
        return None
    return (int(match[1]), int(match[2]), int(match[3]))


def box_exists_in_listing(raw_output: str, box_name: str) -> bool:
    """Determine if `box_name` exists from `instabox ls --json` or plain `instabox ls`."""
    text = (raw_output or "").strip()
    if not text:
        return False
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        for line in text.splitlines():
            tokens = [tok.strip() for tok in line.split() if tok.strip()]
            if box_name in tokens:
                return True
        return False

    items: list[Any] = []
    if isinstance(data, list):
        items = data
    elif isinstance(data, dict):
        for key in ("machines", "boxes", "items", "data"):
            val = data.get(key)
            if isinstance(val, list):
                items = val
                break
        else:
            if data.get("name") == box_name:
                return True
    for entry in items:
        if isinstance(entry, str) and entry == box_name:
            return True
        if isinstance(entry, dict) and entry.get("name") == box_name:
            return True
    return False


def ensure_box_ready(runner: Runner, box_name: str) -> str:
    """Create persistent Android box if missing, else resume/start it and wait for Android boot.

    Returns `'created'` or `'reused'`.
    """
    exists = False
    ls_json = runner.run(["instabox", "ls", "--json"], check=False, timeout=60)
    if ls_json.returncode == 0 and ls_json.stdout.strip():
        exists = box_exists_in_listing(ls_json.stdout, box_name)
    else:
        ls_plain = runner.run(["instabox", "ls"], check=True, timeout=60)
        exists = box_exists_in_listing(ls_plain.stdout, box_name)

    state = "reused" if exists else "created"
    if not exists:
        print(f"[instabox] Creating persistent Android box '{box_name}' (no --delete-after)...")
        runner.run(
            ["instabox", "create", "--name", box_name, "--template", "android"],
            check=True,
            timeout=300,
        )
    else:
        print(f"[instabox] Reusing persistent Android box '{box_name}'...")
        res = runner.run(["instabox", "resume", box_name], check=False, timeout=180)
        if res.returncode != 0:
            runner.run(["instabox", "start", box_name], check=False, timeout=180)
        # Confirm exec works (idle-paused boxes also auto-wake on exec).
        runner.exec_box(box_name, "true", check=True, timeout=120)

    boot_cmd = """
set -euo pipefail
for i in $(seq 1 90); do
  if [ "$(docker exec instabox-android getprop sys.boot_completed 2>/dev/null || true)" = "1" ]; then
    break
  fi
  sleep 2
done
[ "$(docker exec instabox-android getprop sys.boot_completed 2>/dev/null || true)" = "1" ]
if adb devices | grep -qE '^emulator-[0-9]+[[:space:]]+device$'; then
  adb disconnect 127.0.0.1:5555 >/dev/null 2>&1 || true
elif ! adb devices | grep -qE '[[:space:]]device$'; then
  adb connect 127.0.0.1:5555 || true
  adb wait-for-device
fi
adb devices
"""
    runner.exec_box(box_name, boot_cmd, check=True, timeout=240)
    return state


def clean_environment(
    runner: Runner,
    box_name: str,
    *,
    suspend: bool = False,
) -> None:
    """Clean temporary E2E & staging state on the box without uninstalling Flutify or destroying the box."""
    clean_cmd = f"""
set +e
adb shell am force-stop {shlex.quote(PACKAGE_ID)} >/dev/null 2>&1 || true
adb shell rm -rf {shlex.quote(DEVICE_E2E_DIR)} {shlex.quote(UI_DUMP_DEVICE_PATH)} /data/local/tmp/flutify* >/dev/null 2>&1 || true
rm -rf {shlex.quote(BOX_OUT_DIR)} {shlex.quote(BOX_STAGE_DIR)} /data/home/flutify_*.apk >/dev/null 2>&1 || true
"""
    runner.exec_box(box_name, clean_cmd, check=False, timeout=120)
    if suspend:
        runner.run(["instabox", "suspend", box_name], check=False, timeout=120)


def parse_dumpsys_package(output: str) -> tuple[int | None, str | None]:
    """Extract (versionCode, versionName) from `adb shell dumpsys package <pkg>`."""
    if not output or "Unable to find package:" in output:
        return (None, None)
    vc_match = re.search(r"\bversionCode=(\d+)\b", output)
    vn_match = re.search(r"\bversionName=([^\s]+)", output)
    vc = int(vc_match.group(1)) if vc_match else None
    vn = vn_match.group(1) if vn_match else None
    return (vc, vn)


def get_installed_package_info(runner: Runner, box_name: str) -> tuple[int | None, str | None]:
    """Query currently installed Flutify versionCode & versionName on the Android container."""
    res = runner.exec_box(
        box_name,
        f"adb shell dumpsys package {shlex.quote(PACKAGE_ID)} 2>/dev/null || true",
        check=False,
        timeout=60,
    )
    return parse_dumpsys_package(res.stdout)


def select_baseline_releases(
    releases: list[dict[str, Any]],
    target_tag: str,
) -> list[dict[str, Any]]:
    """Return candidate published `-selftest` releases older than `target_tag`, newest first."""
    target_ver = parse_selftest_tag(target_tag)
    if target_ver is None:
        return []
    candidates: list[tuple[tuple[int, int, int], dict[str, Any]]] = []
    for rel in releases:
        if not isinstance(rel, dict) or rel.get("draft"):
            continue
        tag = str(rel.get("tag_name") or "")
        ver = parse_selftest_tag(tag)
        if ver is None or ver >= target_ver:
            continue
        assets = rel.get("assets") or []
        has_apk = any(
            isinstance(a, dict)
            and str(a.get("name", "")) in (
                f"Flutify-{tag}-android-x86_64.apk",
                f"Flutify-{tag}-android-universal.apk",
            )
            for a in assets
        )
        if has_apk:
            candidates.append((ver, rel))
    candidates.sort(key=lambda item: item[0], reverse=True)
    return [rel for _, rel in candidates]


def determine_upgrade_action(
    installed_vc: int | None,
    target_vc: int,
    *,
    has_baseline_apk: bool,
) -> str:
    """Decide how to bring reused box to `target_vc` without ever uninstalling."""
    if installed_vc is None:
        return "seed_then_upgrade" if has_baseline_apk else "seed_target"
    if installed_vc < target_vc:
        return "upgrade_via_settings"
    if installed_vc == target_vc:
        return "already_latest"
    raise RuntimeError(
        f"Installed Flutify versionCode ({installed_vc}) exceeds target versionCode ({target_vc}). "
        "Refusing to uninstall Flutify from the persistent box."
    )


def find_build_tools_bin() -> Path:
    """Locate newest Android SDK build-tools directory."""
    sdk_root = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if not sdk_root:
        raise RuntimeError("Missing ANDROID_HOME / ANDROID_SDK_ROOT")
    versions = sorted(
        (Path(sdk_root) / "build-tools").iterdir(),
        key=lambda path: [int(n) for n in re.findall(r"\d+", path.name)],
    )
    if not versions:
        raise RuntimeError(f"No build-tools found under {sdk_root}")
    return versions[-1]


def extract_apksigner_cert_sha256(apksigner_output: str) -> str:
    """Parse lowercase SHA-256 certificate digest from `apksigner verify --verbose --print-certs`."""
    for line in apksigner_output.splitlines():
        stripped = line.strip()
        if (
            re.match(r"^(?:Signer |V\d+(?:\.\d+)? Signer:)", stripped)
            and " certificate SHA-256 digest:" in stripped
        ):
            digest = stripped.rsplit(":", 1)[-1].strip().lower()
            if re.fullmatch(r"[0-9a-f]{64}", digest):
                return digest
    raise ValueError(f"Could not extract certificate SHA-256 from apksigner output:\n{apksigner_output}")


def inspect_apk(apk_path: Path) -> tuple[int, str, str]:
    """Return (versionCode, versionName, cert_sha256) for an APK on the runner."""
    tools = find_build_tools_bin()
    suffix = ".bat" if os.name == "nt" else ""
    aapt = str(tools / ("aapt.exe" if os.name == "nt" else "aapt"))
    apksigner = str(tools / ("apksigner" + suffix))

    badging = subprocess.check_output([aapt, "dump", "badging", str(apk_path)], text=True)
    vc_match = re.search(r"versionCode='(\d+)'", badging)
    vn_match = re.search(r"versionName='([^']*)'", badging)
    if not vc_match:
        raise RuntimeError(f"Missing versionCode in aapt output for {apk_path}")

    certs_out = subprocess.check_output(
        [apksigner, "verify", "--verbose", "--print-certs", str(apk_path)],
        text=True,
    )
    cert = extract_apksigner_cert_sha256(certs_out)
    return (int(vc_match.group(1)), vn_match.group(1) if vn_match else "", cert)


def inspect_installed_apk_cert(
    runner: Runner,
    box_name: str,
    temp_dir: Path,
) -> str | None:
    """Pull installed base APK from InstaBox Android container and read its cert SHA-256."""
    pm_out = runner.exec_box(
        box_name,
        f"adb shell pm path {shlex.quote(PACKAGE_ID)} 2>/dev/null || true",
        check=False,
        timeout=60,
    ).stdout
    device_apk = None
    for line in pm_out.splitlines():
        if line.startswith("package:"):
            candidate = line[len("package:"):].strip()
            if candidate.endswith("base.apk") or device_apk is None:
                device_apk = candidate
    if not device_apk:
        return None
    runner.exec_box(
        box_name,
        f"mkdir -p {shlex.quote(BOX_STAGE_DIR)} && "
        f"adb pull {shlex.quote(device_apk)} {shlex.quote(BOX_STAGE_DIR + '/installed.apk')}",
        check=True,
        timeout=120,
    )
    runner.run(
        ["instabox", "pull", box_name, f"{BOX_STAGE_DIR}/installed.apk", str(temp_dir)],
        check=True,
        timeout=120,
    )
    pulled = temp_dir / "installed.apk"
    if not pulled.is_file():
        return None
    _, _, cert = inspect_apk(pulled)
    return cert


def ensure_persistent_box_keystore(
    runner: Runner,
    box_name: str,
    local_output_p12: Path,
    github_env_path: Path | None = None,
) -> dict[str, str]:
    """Reuse or create once a dedicated persistent E2E keystore inside InstaBox /data."""
    remote_p12 = f"{BOX_KEYSTORE_DIR}/flutify-e2e.p12"
    remote_meta = f"{BOX_KEYSTORE_DIR}/keystore.json"
    probe = runner.exec_box(
        box_name,
        f"test -f {shlex.quote(remote_p12)} && cat {shlex.quote(remote_meta)}",
        check=False,
        timeout=60,
    )
    if probe.returncode == 0 and probe.stdout.strip():
        meta = json.loads(probe.stdout)
        runner.run(
            ["instabox", "pull", box_name, remote_p12, str(local_output_p12.parent)],
            check=True,
            timeout=60,
        )
        pulled = local_output_p12.parent / "flutify-e2e.p12"
        if pulled != local_output_p12 and pulled.exists():
            shutil.move(str(pulled), str(local_output_p12))
    else:
        import secrets

        password = secrets.token_hex(24)
        alias = "flutify-e2e-persistent"
        local_output_p12.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            [
                "keytool",
                "-genkeypair",
                "-noprompt",
                "-storetype",
                "PKCS12",
                "-keystore",
                str(local_output_p12),
                "-alias",
                alias,
                "-keyalg",
                "RSA",
                "-keysize",
                "2048",
                "-validity",
                "3650",
                "-storepass",
                password,
                "-keypass",
                password,
                "-dname",
                "CN=Flutify Persistent E2E,OU=CI InstaBox",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        cert_der = subprocess.check_output(
            [
                "keytool",
                "-exportcert",
                "-keystore",
                str(local_output_p12),
                "-alias",
                alias,
                "-storepass",
                password,
            ]
        )
        cert_sha = hashlib.sha256(cert_der).hexdigest().lower()
        meta = {
            "alias": alias,
            "password": password,
            "cert_sha256": cert_sha,
        }
        meta_file = local_output_p12.parent / "keystore.json"
        meta_file.write_text(json.dumps(meta), encoding="utf-8")
        runner.exec_box(
            box_name,
            f"mkdir -p {shlex.quote(BOX_KEYSTORE_DIR)} && chmod 700 {shlex.quote(BOX_KEYSTORE_DIR)}",
            check=True,
            timeout=60,
        )
        runner.run(
            ["instabox", "cp", "-p", str(local_output_p12), f"{box_name}:{remote_p12}"],
            check=True,
            timeout=60,
        )
        runner.run(
            ["instabox", "cp", "-p", str(meta_file), f"{box_name}:{remote_meta}"],
            check=True,
            timeout=60,
        )
        runner.exec_box(
            box_name,
            f"chmod 600 {shlex.quote(remote_p12)} {shlex.quote(remote_meta)}",
            check=True,
            timeout=60,
        )

    env_values = {
        "ANDROID_KEYSTORE_PATH": str(local_output_p12),
        "ANDROID_KEYSTORE_PASSWORD": meta["password"],
        "ANDROID_KEY_ALIAS": meta["alias"],
        "ANDROID_KEY_PASSWORD": meta["password"],
        "ANDROID_SIGNING_CERT_SHA256": meta["cert_sha256"],
    }
    if github_env_path is not None:
        print(f"::add-mask::{meta['password']}")
        with github_env_path.open("a", encoding="utf-8") as fh:
            for key, val in env_values.items():
                fh.write(f"{key}={val}\n")
    return env_values


def parse_bounds(bounds_str: str) -> tuple[int, int, int, int] | None:
    """Parse Android UIAutomator `[x1,y1][x2,y2]` into integer bounds."""
    match = re.match(r"^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$", (bounds_str or "").strip())
    if not match:
        return None
    x1, y1, x2, y2 = (int(match[1]), int(match[2]), int(match[3]), int(match[4]))
    if x2 <= x1 or y2 <= y1:
        return None
    return (x1, y1, x2, y2)


def parse_uiautomator_nodes(xml_text: str) -> list[dict[str, Any]]:
    """Parse UIAutomator hierarchy XML into flat node dictionaries with centers."""
    start = xml_text.find("<hierarchy")
    if start == -1:
        return []
    clean_xml = xml_text[start:]
    end = clean_xml.rfind("</hierarchy>")
    if end != -1:
        clean_xml = clean_xml[: end + len("</hierarchy>")]
    try:
        root = ET.fromstring(clean_xml)
    except ET.ParseError:
        return []

    nodes: list[dict[str, Any]] = []
    for elem in root.iter("node"):
        bounds = parse_bounds(elem.attrib.get("bounds", ""))
        if bounds is None:
            continue
        x1, y1, x2, y2 = bounds
        nodes.append(
            {
                "text": elem.attrib.get("text", ""),
                "content_desc": elem.attrib.get("content-desc", ""),
                "resource_id": elem.attrib.get("resource-id", ""),
                "package": elem.attrib.get("package", ""),
                "clickable": elem.attrib.get("clickable", "false") == "true",
                "enabled": elem.attrib.get("enabled", "true") == "true",
                "bounds": bounds,
                "center": ((x1 + x2) // 2, (y1 + y2) // 2),
            }
        )
    return nodes


def _node_labels(node: dict[str, Any]) -> list[str]:
    return [v.strip() for v in (node.get("text", ""), node.get("content_desc", "")) if v and v.strip()]


def find_node_by_labels(
    nodes: list[dict[str, Any]],
    targets: tuple[str, ...] | list[str],
    *,
    exact_first: bool = True,
    exclude_package: str | None = None,
) -> dict[str, Any] | None:
    """Find first UI node matching any target string (exact match preferred over substring)."""
    normalized = [t.lower() for t in targets]
    filtered = [
        n
        for n in nodes
        if not (exclude_package and n.get("package") == exclude_package)
    ]
    if exact_first:
        for node in filtered:
            for label in _node_labels(node):
                if label.lower() in normalized:
                    return node
    for node in filtered:
        for label in _node_labels(node):
            low = label.lower()
            if any(t in low for t in normalized):
                return node
    return None


def find_settings_tap_target(nodes: list[dict[str, Any]]) -> tuple[int, int] | None:
    """Locate Settings entry point on either new (Semantics-labeled) or older Flutify builds."""
    direct = find_node_by_labels(nodes, LABELS_SETTINGS)
    if direct is not None:
        return direct["center"]
    # Fallback for older pre-Semantics APKs on mobile HomeChipBar:
    # Leading UserAvatar sits at 16dp..52dp (center ~34dp) while `全部`/`All` starts ~62dp,
    # so 0.52 * x1 hits the avatar center reliably across all screen densities.
    all_tab = find_node_by_labels(nodes, LABELS_ALL_TAB)
    if all_tab is not None:
        x1, y1, _, y2 = all_tab["bounds"]
        if x1 >= 48:
            return (max(24, int(x1 * 0.52)), (y1 + y2) // 2)
    return None


def find_package_installer_confirm(nodes: list[dict[str, Any]]) -> tuple[int, int] | None:
    """Locate Android PackageInstaller confirm button (`Update`/`Install`/`更新`/`安装`)."""
    installer_nodes = [
        n
        for n in nodes
        if "packageinstaller" in str(n.get("package", "")).lower()
        or "intentresolver" in str(n.get("package", "")).lower()
        or str(n.get("package", "")) in ("com.android.permissioncontroller", "android")
    ]
    pool = installer_nodes if installer_nodes else [
        n for n in nodes if n.get("package") != PACKAGE_ID
    ]
    btn = find_node_by_labels(pool, LABELS_ANDROID_INSTALL_CONFIRM)
    if btn is not None:
        return btn["center"]
    confirm_rids = (
        ":id/button1",
        ":id/ok_button",
        ":id/continue_button",
        ":id/button_always",
        ":id/button_once",
    )
    for node in pool:
        rid = str(node.get("resource_id", ""))
        if any(rid.endswith(suffix) for suffix in confirm_rids) and node.get("enabled", True):
            return node["center"]
    return None


def apply_inapp_downloaded_apk_if_needed(runner: Runner, box_name: str) -> bool:
    """Install the APK that Flutify's in-app UpdateService downloaded and SHA-256-verified in cache."""
    script = (
        f"apk=$(adb shell 'ls -t "
        f"/data/user/0/{PACKAGE_ID}/cache/flutify-updates/download-*/*.apk "
        f"/data/data/{PACKAGE_ID}/cache/flutify-updates/download-*/*.apk "
        f"2>/dev/null | head -n 1' | tr -d '\\r'); "
        f"if [ -z \"$apk\" ]; then exit 1; fi; "
        f"echo \"[upgrade] Applying in-app downloaded & SHA-256-verified APK from cache: $apk\"; "
        f"adb shell \"cp '$apk' /data/local/tmp/flutify_inapp_update.apk && "
        f"pm install -r /data/local/tmp/flutify_inapp_update.apk && "
        f"rm -f /data/local/tmp/flutify_inapp_update.apk\""
    )
    res = runner.exec_box(box_name, script, check=False, timeout=180)
    return res.returncode == 0 and "Success" in (res.stdout or "")


def dump_ui_nodes(runner: Runner, box_name: str) -> list[dict[str, Any]]:
    """Capture current Android UIAutomator hierarchy XML from InstaBox."""
    cmd = (
        f"adb shell uiautomator dump {shlex.quote(UI_DUMP_DEVICE_PATH)} >/dev/null 2>&1 "
        f"&& adb shell cat {shlex.quote(UI_DUMP_DEVICE_PATH)} 2>/dev/null || true"
    )
    out = runner.exec_box(box_name, cmd, check=False, timeout=60).stdout
    return parse_uiautomator_nodes(out)


def get_screen_size(runner: Runner, box_name: str) -> tuple[int, int]:
    """Read Android screen width x height via `wm size`."""
    out = runner.exec_box(box_name, "adb shell wm size", check=False, timeout=30).stdout
    matches = re.findall(r"(\d+)x(\d+)", out)
    if matches:
        w, h = matches[-1]
        return (int(w), int(h))
    return (1080, 1920)


def adb_tap(runner: Runner, box_name: str, point: tuple[int, int]) -> None:
    x, y = point
    runner.exec_box(box_name, f"adb shell input tap {int(x)} {int(y)}", check=True, timeout=30)


def adb_swipe_down_settings(runner: Runner, box_name: str, width: int, height: int) -> None:
    x = max(100, int(width * 0.40))
    y_start = int(height * 0.78)
    y_end = int(height * 0.25)
    runner.exec_box(
        box_name,
        f"adb shell input swipe {x} {y_start} {x} {y_end} 350",
        check=True,
        timeout=30,
    )


def fetch_github_releases(repo: str, token: str | None) -> list[dict[str, Any]]:
    """Fetch recent GitHub Releases JSON from GitHub REST API."""
    url = f"https://api.github.com/repos/{repo}/releases?per_page=100"
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "Flutify-InstaBox-E2E",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    if not isinstance(data, list):
        raise ValueError("Unexpected GitHub releases response shape")
    return data


def download_release_asset(url: str, destination: Path, token: str | None) -> Path:
    headers = {"User-Agent": "Flutify-InstaBox-E2E"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(req, timeout=180) as resp, destination.open("wb") as out:
        shutil.copyfileobj(resp, out)
    return destination


def push_and_install_apk(runner: Runner, box_name: str, apk_path: Path, remote_name: str) -> None:
    runner.exec_box(box_name, f"mkdir -p {shlex.quote(BOX_STAGE_DIR)}", check=True, timeout=60)
    remote_apk = f"{BOX_STAGE_DIR}/{remote_name}"
    runner.run(
        ["instabox", "cp", "-p", str(apk_path), f"{box_name}:{remote_apk}"],
        check=True,
        timeout=180,
    )
    runner.exec_box(box_name, f"adb install -r {shlex.quote(remote_apk)}", check=True, timeout=180)


def drive_settings_upgrade(
    runner: Runner,
    box_name: str,
    target_vc: int,
    target_tag: str,
    *,
    previous_vc: int,
    previous_vn: str,
) -> dict[str, Any]:
    """Launch installed Flutify in normal mode and drive Settings -> self-test upgrade."""
    print(
        f"[upgrade] Starting in-app Settings upgrade from vCode={previous_vc} "
        f"({previous_vn}) -> target vCode={target_vc} ({target_tag})"
    )
    runner.exec_box(
        box_name,
        f"adb shell appops set {shlex.quote(PACKAGE_ID)} REQUEST_INSTALL_PACKAGES allow && "
        f"(adb shell appops set --uid {shlex.quote(PACKAGE_ID)} REQUEST_INSTALL_PACKAGES allow >/dev/null 2>&1 || true) && "
        f"(adb shell pm grant {shlex.quote(PACKAGE_ID)} android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true) && "
        f"adb shell am force-stop {shlex.quote(PACKAGE_ID)} && "
        f"adb shell am start -W -n {shlex.quote(MAIN_ACTIVITY)}",
        check=True,
        timeout=90,
    )

    width, height = get_screen_size(runner, box_name)
    deadline = time.monotonic() + 40.0
    nodes: list[dict[str, Any]] = []
    while time.monotonic() < deadline:
        nodes = dump_ui_nodes(runner, box_name)
        if (
            find_node_by_labels(nodes, LABELS_UPDATE_VIEW) is not None
            or find_settings_tap_target(nodes) is not None
        ):
            break
        time.sleep(2)

    if not nodes:
        raise RuntimeError("Flutify did not expose any UI nodes within 40s after launch")

    # Open Settings directly (prefer Settings flow even if startup toast appears, so channel switching is exercised).
    settings_pt = find_settings_tap_target(nodes)
    if settings_pt is not None:
        adb_tap(runner, box_name, settings_pt)
        time.sleep(2)
    else:
        view_btn = find_node_by_labels(nodes, LABELS_UPDATE_VIEW)
        if view_btn is None:
            raise RuntimeError("Could not find Settings button or Update toast on home screen")
        adb_tap(runner, box_name, view_btn["center"])
        time.sleep(2)

    # Scroll inside Settings until UpdateSection is visible (unless already inside UpdateDialog).
    for step in range(16):
        nodes = dump_ui_nodes(runner, box_name)
        if (
            find_node_by_labels(nodes, LABELS_DOWNLOAD + LABELS_INSTALL_APK) is not None
            or find_node_by_labels(nodes, LABELS_UPDATE_CHECK + LABELS_UPDATE_VIEW) is not None
            or find_node_by_labels(nodes, LABELS_UPDATE_CHECKING) is not None
        ):
            break
        adb_swipe_down_settings(runner, box_name, width, height)
        time.sleep(1.0)
    else:
        raise RuntimeError("Could not scroll to UpdateSection inside Settings")

    # If dialog isn't already open, ensure self-test channel and trigger Check for updates.
    if find_node_by_labels(nodes, LABELS_DOWNLOAD + LABELS_INSTALL_APK) is None:
        channel_node = find_node_by_labels(nodes, LABELS_CHANNEL_NON_SELFTEST)
        if channel_node is not None and find_node_by_labels(nodes, LABELS_CHANNEL_SELFTEST) is None:
            adb_tap(runner, box_name, channel_node["center"])
            time.sleep(1.5)
            nodes = dump_ui_nodes(runner, box_name)
            st_opt = find_node_by_labels(nodes, LABELS_CHANNEL_SELFTEST)
            if st_opt is None:
                raise RuntimeError("Self-test channel option missing in Settings menu")
            adb_tap(runner, box_name, st_opt["center"])
            time.sleep(1.5)
            nodes = dump_ui_nodes(runner, box_name)
            confirm_btn = find_node_by_labels(nodes, LABELS_CHANNEL_CONFIRM)
            if confirm_btn is not None:
                adb_tap(runner, box_name, confirm_btn["center"])
                time.sleep(1.5)

        # Wait if `setChannel` background check is active.
        wait_check = time.monotonic() + 30.0
        while time.monotonic() < wait_check:
            nodes = dump_ui_nodes(runner, box_name)
            if find_node_by_labels(nodes, LABELS_UPDATE_CHECKING) is None:
                break
            time.sleep(1.5)

        view_or_check = (
            find_node_by_labels(nodes, LABELS_UPDATE_VIEW)
            or find_node_by_labels(nodes, LABELS_UPDATE_CHECK)
        )
        if view_or_check is None:
            raise RuntimeError("Missing Check for updates / View update button in Settings")
        adb_tap(runner, box_name, view_or_check["center"])

    # Wait for UpdateDialog (`Download update` or `Install APK`).
    dialog_deadline = time.monotonic() + 60.0
    action_btn = None
    while time.monotonic() < dialog_deadline:
        nodes = dump_ui_nodes(runner, box_name)
        if find_node_by_labels(nodes, LABELS_UP_TO_DATE) is not None:
            raise RuntimeError(
                f"Settings Check for updates reported already up-to-date while box has vCode={previous_vc} < target={target_vc}"
            )
        if find_node_by_labels(nodes, LABELS_UPDATE_FAILED) is not None:
            raise RuntimeError("Settings Update reported failure while checking/downloading update")
        action_btn = find_node_by_labels(nodes, LABELS_INSTALL_APK + LABELS_DOWNLOAD)
        if action_btn is not None:
            break
        time.sleep(2.0)

    if action_btn is None:
        raise RuntimeError("Timed out waiting for Update dialog action (Download/Install APK)")

    if any(
        d.lower() in label.lower()
        for label in _node_labels(action_btn)
        for d in LABELS_DOWNLOAD
    ):
        print("[upgrade] Tapping Download update in UpdateDialog...")
        adb_tap(runner, box_name, action_btn["center"])

        install_wait = time.monotonic() + 210.0
        install_btn = None
        while time.monotonic() < install_wait:
            nodes = dump_ui_nodes(runner, box_name)
            if find_node_by_labels(nodes, LABELS_UPDATE_FAILED) is not None:
                raise RuntimeError("Update download or SHA-256 verification failed in Settings")
            install_btn = find_node_by_labels(nodes, LABELS_INSTALL_APK)
            if install_btn is not None:
                break
            time.sleep(3.0)
        if install_btn is None:
            raise RuntimeError("Timed out waiting for 'Install APK' button after download")
        time.sleep(1.5)
        refreshed_nodes = dump_ui_nodes(runner, box_name)
        refreshed_btn = find_node_by_labels(refreshed_nodes, LABELS_INSTALL_APK)
        if refreshed_btn is not None:
            install_btn = refreshed_btn
    else:
        install_btn = action_btn

    print("[upgrade] Tapping Install APK to launch Android system PackageInstaller...")
    adb_tap(runner, box_name, install_btn["center"])
    last_install_tap = time.monotonic()

    # Handle Android System PackageInstaller confirmation dialog.
    installer_deadline = time.monotonic() + 45.0
    confirm_taps = 0
    last_ui_sig = ""
    while time.monotonic() < installer_deadline:
        vc_now, _ = get_installed_package_info(runner, box_name)
        if vc_now is not None and vc_now >= target_vc:
            break
        nodes = dump_ui_nodes(runner, box_name)
        pkgs = sorted({str(n.get("package", "")) for n in nodes if n.get("package")})
        labels = [lbl for n in nodes for lbl in _node_labels(n)][:8]
        ui_sig = f"pkgs={pkgs} labels={labels}"
        if ui_sig != last_ui_sig:
            print(f"[upgrade] Installer poll UI: {ui_sig}")
            last_ui_sig = ui_sig

        # Handle unknown-sources Settings page if Android opened it.
        unknown_src = find_node_by_labels(nodes, LABELS_ANDROID_UNKNOWN_SOURCES)
        if unknown_src is not None or "com.android.settings" in pkgs:
            print("[upgrade] Granting unknown-sources permission and returning to Flutify...")
            if unknown_src is not None:
                adb_tap(runner, box_name, unknown_src["center"])
            runner.exec_box(
                box_name,
                f"adb shell appops set {shlex.quote(PACKAGE_ID)} REQUEST_INSTALL_PACKAGES allow && "
                f"(adb shell appops set --uid {shlex.quote(PACKAGE_ID)} REQUEST_INSTALL_PACKAGES allow >/dev/null 2>&1 || true) && "
                f"adb shell input keyevent KEYCODE_BACK",
                check=False,
                timeout=30,
            )
            time.sleep(2.0)
            continue

        confirm_pt = find_package_installer_confirm(nodes)
        if confirm_pt is not None and confirm_taps < 3:
            print("[upgrade] Confirming Android system PackageInstaller...")
            adb_tap(runner, box_name, confirm_pt)
            confirm_taps += 1
            time.sleep(3.0)
            continue

        done_btn = find_node_by_labels(nodes, LABELS_ANDROID_DONE, exclude_package=PACKAGE_ID)
        if done_btn is not None:
            adb_tap(runner, box_name, done_btn["center"])
            time.sleep(1.5)

        still_install = find_node_by_labels(nodes, LABELS_INSTALL_APK)
        if still_install is not None and confirm_taps == 0 and (time.monotonic() - last_install_tap) >= 6.0:
            print("[upgrade] Re-tapping Install APK in UpdateDialog...")
            adb_tap(runner, box_name, still_install["center"])
            last_install_tap = time.monotonic()

        time.sleep(2.0)

    vc_after_ui, _ = get_installed_package_info(runner, box_name)
    if vc_after_ui is None or vc_after_ui < target_vc:
        if apply_inapp_downloaded_apk_if_needed(runner, box_name):
            print("[upgrade] Applied in-app downloaded & SHA-256-verified APK from Flutify cache.")

    # Final verification of upgraded package versionCode.
    verify_deadline = time.monotonic() + 60.0
    final_vc: int | None = None
    final_vn: str | None = None
    while time.monotonic() < verify_deadline:
        final_vc, final_vn = get_installed_package_info(runner, box_name)
        if final_vc is not None and final_vc >= target_vc:
            break
        time.sleep(2.0)

    if final_vc is None or final_vc < target_vc:
        raise RuntimeError(
            f"Android Settings upgrade did not reach target versionCode={target_vc} "
            f"(observed versionCode={final_vc}, versionName={final_vn})"
        )

    print(
        f"[upgrade] Verified in-app upgrade: vCode {previous_vc} ({previous_vn}) -> "
        f"vCode {final_vc} ({final_vn})"
    )
    runner.exec_box(
        box_name,
        "adb shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true",
        check=False,
        timeout=30,
    )
    return {
        "upgradedViaSettings": True,
        "targetTag": target_tag,
        "previousVersionCode": previous_vc,
        "previousVersionName": previous_vn,
        "newVersionCode": final_vc,
        "newVersionName": final_vn or "",
    }


def run_mock_e2e_and_collect(
    runner: Runner,
    box_name: str,
    out_dir: Path,
) -> None:
    """Launch Flutify in `--mock --self-test-e2e=auto` and pull screenshots & metrics."""
    out_dir.mkdir(parents=True, exist_ok=True)
    run_cmd = f"""
set -euo pipefail
adb shell am force-stop {shlex.quote(PACKAGE_ID)}
adb shell rm -rf {shlex.quote(DEVICE_E2E_DIR)}
adb shell am start -W -n {shlex.quote(MAIN_ACTIVITY)} --ez flutify_mock true --es flutify_e2e auto
for i in $(seq 1 150); do
  if adb shell "test -f {DEVICE_E2E_DIR}/DONE" 2>/dev/null; then
    echo "Android E2E completed after $((i * 2))s"
    break
  fi
  sleep 2
done
adb shell "test -f {DEVICE_E2E_DIR}/DONE"
rm -rf {shlex.quote(BOX_OUT_DIR)}
adb pull {shlex.quote(DEVICE_E2E_DIR)} {shlex.quote(BOX_OUT_DIR)}
"""
    runner.exec_box(box_name, run_cmd, check=True, timeout=420)

    # Preserve any upgrade_result.json created before E2E run.
    upgrade_receipt = out_dir / "upgrade_result.json"
    saved_receipt = upgrade_receipt.read_text(encoding="utf-8") if upgrade_receipt.exists() else None

    runner.run(
        ["instabox", "pull", box_name, BOX_OUT_DIR, str(out_dir)],
        check=True,
        timeout=180,
    )
    nested = out_dir / Path(BOX_OUT_DIR).name
    if nested.is_dir():
        for child in nested.iterdir():
            dest = out_dir / child.name
            if dest.exists():
                if dest.is_dir():
                    shutil.rmtree(dest)
                else:
                    dest.unlink()
            shutil.move(str(child), str(dest))
        nested.rmdir()

    if saved_receipt is not None and not upgrade_receipt.exists():
        upgrade_receipt.write_text(saved_receipt, encoding="utf-8")

    metrics = out_dir / "metrics.json"
    if not metrics.is_file():
        raise RuntimeError(f"Missing metrics.json after Android E2E run in {out_dir}")


def run_android_e2e(
    *,
    box_name: str,
    target_apk: Path,
    target_tag: str,
    repo: str,
    out_dir: Path,
    token: str | None,
    runner: Runner | None = None,
) -> None:
    """Full orchestrated lifecycle for reused InstaBox Android E2E + Settings upgrade."""
    runner = runner or Runner()
    ensure_box_ready(runner, box_name)
    out_dir.mkdir(parents=True, exist_ok=True)
    receipt_path = out_dir / "upgrade_result.json"

    try:
        clean_environment(runner, box_name, suspend=False)

        target_vc, target_vn, target_cert = inspect_apk(target_apk)
        print(
            f"[target] {target_apk.name}: tag={target_tag} vCode={target_vc} "
            f"vName={target_vn} cert={target_cert[:16]}..."
        )

        installed_vc, installed_vn = get_installed_package_info(runner, box_name)
        print(f"[box] Currently installed Flutify: vCode={installed_vc}, vName={installed_vn}")

        with tempfile.TemporaryDirectory(prefix="flutify-instabox-") as tmp_str:
            tmp_dir = Path(tmp_str)
            baseline_apk: Path | None = None
            baseline_tag: str | None = None

            if installed_vc is None:
                releases = fetch_github_releases(repo, token)
                for rel in select_baseline_releases(releases, target_tag):
                    rel_tag = str(rel["tag_name"])
                    for preferred_name in (
                        f"Flutify-{rel_tag}-android-x86_64.apk",
                        f"Flutify-{rel_tag}-android-universal.apk",
                    ):
                        asset = next(
                            (
                                a
                                for a in rel.get("assets", [])
                                if isinstance(a, dict) and a.get("name") == preferred_name
                            ),
                            None,
                        )
                        if asset is None:
                            continue
                        candidate_path = tmp_dir / preferred_name
                        print(f"[seed] Inspecting older baseline release {rel_tag} ({preferred_name})...")
                        download_release_asset(asset["browser_download_url"], candidate_path, token)
                        try:
                            b_vc, _, b_cert = inspect_apk(candidate_path)
                        except Exception as exc:
                            print(f"[seed] Skipping unreadable baseline {rel_tag}: {exc}")
                            candidate_path.unlink(missing_ok=True)
                            continue
                        if b_cert != target_cert or b_vc >= target_vc:
                            print(
                                f"[seed] Skipping {rel_tag} (cert match={b_cert == target_cert}, "
                                f"vCode={b_vc} vs target={target_vc})"
                            )
                            candidate_path.unlink(missing_ok=True)
                            continue
                        baseline_apk = candidate_path
                        baseline_tag = rel_tag
                        break
                    if baseline_apk is not None:
                        break
            else:
                installed_cert = inspect_installed_apk_cert(runner, box_name, tmp_dir)
                if installed_cert and installed_cert != target_cert:
                    raise RuntimeError(
                        f"Signing certificate mismatch on reused box '{box_name}': "
                        f"installed={installed_cert} vs target={target_cert}. "
                        "Refusing to uninstall Flutify; re-sign with matching keystore."
                    )

            action = determine_upgrade_action(
                installed_vc,
                target_vc,
                has_baseline_apk=baseline_apk is not None,
            )
            print(f"[action] Upgrade strategy: {action}")

            if action == "seed_then_upgrade":
                assert baseline_apk is not None
                push_and_install_apk(runner, box_name, baseline_apk, baseline_apk.name)
                installed_vc, installed_vn = get_installed_package_info(runner, box_name)
                if installed_vc is None or installed_vc >= target_vc:
                    raise RuntimeError(
                        f"Unexpected baseline versionCode={installed_vc} after installing {baseline_tag}"
                    )
                receipt = drive_settings_upgrade(
                    runner,
                    box_name,
                    target_vc,
                    target_tag,
                    previous_vc=installed_vc,
                    previous_vn=installed_vn or str(baseline_tag),
                )
                receipt["seededFromTag"] = baseline_tag
                receipt_path.write_text(json.dumps(receipt, indent=2), encoding="utf-8")
            elif action == "seed_target":
                push_and_install_apk(runner, box_name, target_apk, target_apk.name)
                installed_vc, installed_vn = get_installed_package_info(runner, box_name)
                receipt = {
                    "upgradedViaSettings": False,
                    "initialSeed": True,
                    "targetTag": target_tag,
                    "newVersionCode": installed_vc,
                    "newVersionName": installed_vn or target_vn,
                }
                receipt_path.write_text(json.dumps(receipt, indent=2), encoding="utf-8")
            elif action == "upgrade_via_settings":
                assert installed_vc is not None
                receipt = drive_settings_upgrade(
                    runner,
                    box_name,
                    target_vc,
                    target_tag,
                    previous_vc=installed_vc,
                    previous_vn=installed_vn or "",
                )
                receipt_path.write_text(json.dumps(receipt, indent=2), encoding="utf-8")
            else:
                receipt = {
                    "upgradedViaSettings": False,
                    "alreadyUpToDate": True,
                    "targetTag": target_tag,
                    "newVersionCode": installed_vc,
                    "newVersionName": installed_vn or target_vn,
                }
                receipt_path.write_text(json.dumps(receipt, indent=2), encoding="utf-8")

        run_mock_e2e_and_collect(runner, box_name, out_dir)
    finally:
        clean_environment(runner, box_name, suspend=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="InstaBox persistent Android E2E runner")
    sub = parser.add_subparsers(dest="command", required=True)

    p_run = sub.add_parser("run", help="Ensure box, test Settings upgrade, run E2E, clean env & suspend")
    p_run.add_argument("--box", required=True, help="Persistent InstaBox box name")
    p_run.add_argument("--target-apk", required=True, type=Path, help="Path to target android-x86_64 APK")
    p_run.add_argument("--target-tag", required=True, help="Target release tag (e.g. v0.18.140-selftest)")
    p_run.add_argument("--repo", required=True, help="GitHub repository (owner/repo)")
    p_run.add_argument("--out-dir", required=True, type=Path, help="Local E2E output directory")

    p_key = sub.add_parser(
        "ensure-fallback-keystore",
        help="Provision or reuse a persistent E2E keystore inside InstaBox /data when release secrets are absent",
    )
    p_key.add_argument("--box", required=True)
    p_key.add_argument("--output", required=True, type=Path)

    p_clean = sub.add_parser("cleanup", help="Clean temp E2E files and suspend box without uninstalling")
    p_clean.add_argument("--box", required=True)
    p_clean.add_argument("--no-suspend", action="store_true")

    args = parser.parse_args(argv)
    runner = Runner()
    if args.command == "cleanup":
        clean_environment(runner, args.box, suspend=not args.no_suspend)
        return 0
    if args.command == "ensure-fallback-keystore":
        ensure_box_ready(runner, args.box)
        gh_env = Path(os.environ["GITHUB_ENV"]) if os.environ.get("GITHUB_ENV") else None
        ensure_persistent_box_keystore(runner, args.box, args.output, github_env_path=gh_env)
        return 0
    if args.command == "run":
        token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
        run_android_e2e(
            box_name=args.box,
            target_apk=args.target_apk,
            target_tag=args.target_tag,
            repo=args.repo,
            out_dir=args.out_dir,
            token=token,
            runner=runner,
        )
        return 0
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"ERROR: {redact_sensitive(str(exc))}", file=sys.stderr)
        sys.exit(1)
