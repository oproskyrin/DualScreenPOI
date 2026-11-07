#!/usr/bin/env python3
"""Exercise the built host's device-free branch in disposable app fixtures.

No installation, launchctl, TCC requests, signing keys or existing-host restarts.
The fixture uses a synthetic PUBLIC key only; this is not an update-signature test.
Run after: (cd host && swift build -c release)
"""
import base64
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / "host/.build/release/DualScreenHost"
SOURCES = list((ROOT / "host/Sources").rglob("*.swift"))
assert BINARY.exists(), "Build the release host first"
assert BINARY.stat().st_mtime >= max(p.stat().st_mtime for p in SOURCES), "Release binary is stale; rebuild before smoke testing (old binaries ignore the smoke flag)"
FRAMEWORK = ROOT / "host/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
assert FRAMEWORK.is_dir(), "Sparkle artifact missing; build the host first"
SCRATCH = Path(os.environ.get("TMPDIR", str(Path.home() / ".hermes/cache/scratch")))
SCRATCH.mkdir(parents=True, exist_ok=True)

with tempfile.TemporaryDirectory(prefix="dualscreen-app-smoke-", dir=SCRATCH) as directory:
    work = Path(directory)
    app = work / "DualScreen.app"
    executable = app / "Contents/MacOS/DualScreenHost"
    executable.parent.mkdir(parents=True)
    shutil.copy2(BINARY, executable)
    framework_parent = app / "Contents/Frameworks"
    framework_parent.mkdir()
    shutil.copytree(FRAMEWORK, framework_parent / "Sparkle.framework", symlinks=True)
    info = {
        "CFBundleIdentifier": "com.oleg.dualscreen.host",
        "CFBundlePackageType": "APPL",
        "CFBundleExecutable": "DualScreenHost",
        "CFBundleName": "DualScreen Smoke Fixture",
        "CFBundleVersion": "0.13.0",
        "CFBundleShortVersionString": "0.13.0",
        "LSUIElement": True,
        "SUFeedURL": "https://example.invalid/appcast.xml",
        "SUPublicEDKey": base64.b64encode(bytes([1]) * 32).decode(),
        "SUEnableAutomaticChecks": False,
        "SUAutomaticallyUpdate": False,
        "SUAllowsAutomaticUpdates": False,
        "SURequireSignedFeed": True,
        "SUVerifyUpdateBeforeExtraction": True,
    }
    home = work / "home"
    home.mkdir()
    env = dict(os.environ, CFFIXED_USER_HOME=str(home), HOME=str(home))

    def run(binary, expected_status):
        result = subprocess.run([str(binary), "--app-smoke-test"], env=env, text=True, capture_output=True, timeout=15)
        assert result.returncode == expected_status, (result.returncode, result.stdout, result.stderr)
        assert "[ds]" not in result.stdout and "[usb]" not in result.stdout, result.stdout
        values = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
        assert len(values) == 1, (result.stdout, result.stderr)
        return values[0]

    plist_path = app / "Contents/Info.plist"
    plist_path.write_bytes(plistlib.dumps(info))
    valid = run(executable, 0)
    assert valid["validBundle"] and valid["updaterInitialized"] and valid["publicKeyLoaded"] and valid["canCheck"] and not valid["error"], valid
    print("PASS actual app smoke initializes Sparkle and terminates without host startup:", json.dumps(valid, sort_keys=True))
    info["SUFeedURL"] = "http://example.invalid/appcast.xml"
    plist_path.write_bytes(plistlib.dumps(info))
    invalid = run(executable, 2)
    assert not invalid["validBundle"] and not invalid["updaterInitialized"] and not invalid["canCheck"], invalid
    print("PASS invalid bundled config cannot instantiate updater")
    cli = run(BINARY, 2)
    assert not cli["validBundle"] and not cli["updaterInitialized"] and not cli["canCheck"], cli
    print("PASS actual raw CLI smoke never instantiates Sparkle or starts host services")
