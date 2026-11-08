"""Packaging contracts; integration tests read real built artifacts, never install them.

python3 -m unittest discover -s tests -p test_macos_packaging.py -v
DUALSCREEN_TEST_ARTIFACTS=dist/macos python3 -m unittest discover -s tests -p test_macos_packaging.py -v
"""
import os
import plistlib
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
import subprocess
import unittest
import importlib.util

ROOT = Path(__file__).resolve().parents[1]
SCRATCH = Path(os.environ.get("BUILD_SCRATCH_ROOT", Path.home() / ".hermes/cache/scratch"))
SCRATCH.mkdir(parents=True, exist_ok=True)
BUILDER = ROOT / "scripts/build-macos-app.sh"


class PackagingInputTests(unittest.TestCase):
    def test_distribution_rejects_intel_before_payload_installation(self):
        spec = importlib.util.spec_from_file_location("builder", ROOT / "scripts/build_macos_app.py")
        assert spec is not None and spec.loader is not None
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        with tempfile.TemporaryDirectory(dir=SCRATCH) as work:
            path = Path(work) / "Distribution.xml"
            builder.write_distribution(path, "0.13.0", "1.1.0", "1.1.0")
            options = ET.parse(path).getroot().find("options")
            self.assertIsNotNone(options)
            assert options is not None
            self.assertEqual(options.attrib.get("hostArchitectures"), "arm64")

    def test_rejects_non_numeric_version_before_building(self):
        self.assertTrue(BUILDER.is_file(), "macOS packaging entry point must exist")
        result = subprocess.run(["bash", str(BUILDER), "--version", "0.13.0-beta"], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("numeric MAJOR.MINOR.PATCH", result.stderr)

    def test_full_setup_is_the_default_with_explicit_app_only_escape_hatch(self):
        help_text = subprocess.check_output(["bash", str(BUILDER), "--help"], text=True)
        self.assertIn("--audio-component-pkg", help_text)
        self.assertIn("--app-only", help_text)

    def test_installer_scripts_are_bounded_and_bundle_specific(self):
        path = ROOT / "packaging/macos/installer-scripts/preinstall"
        self.assertTrue(path.is_file(), "safe upgrade preinstall script must exist")
        content = path.read_text()
        self.assertIn("/Applications/DualScreen.app/Contents/MacOS/DualScreenHost", content)
        self.assertNotIn("pkill", content)
        self.assertNotIn("SIGKILL", content)
        self.assertNotIn("kill -9", content)
        self.assertIn("kill -TERM", content)
        self.assertIn("20", content)
        subprocess.run(["/bin/bash", "-n", str(path)], check=True)

    def test_requires_actual_public_key_before_building(self):
        result = subprocess.run(["bash", str(BUILDER), "--public-key", "/nonexistent/dualscreen-key"], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Sparkle public key", result.stderr)


@unittest.skipUnless(os.environ.get("DUALSCREEN_TEST_ARTIFACTS"), "set DUALSCREEN_TEST_ARTIFACTS to verify real artifacts")
class RealArtifactTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.output = ROOT / os.environ["DUALSCREEN_TEST_ARTIFACTS"]
        cls.app = cls.output / "DualScreen.app"

    def test_bundle_metadata_resources_and_signatures(self):
        self.assertTrue(self.app.is_dir(), "a real DualScreen.app must be built")
        contents = self.app / "Contents"
        with (contents / "Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        expected = {"CFBundleIdentifier": "com.oleg.dualscreen.host", "CFBundleExecutable": "DualScreenHost", "CFBundleIconFile": "AppIcon", "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "13.0", "LSUIElement": True, "NSHighResolutionCapable": True, "SUEnableAutomaticChecks": True, "SUAutomaticallyUpdate": False, "SUAllowsAutomaticUpdates": False, "SUVerifyUpdateBeforeExtraction": True, "SURequireSignedFeed": True, "SUFeedURL": "https://github.com/oproskyrin/DualScreenPOI/releases/download/macos-updates/appcast.xml"}
        for key, value in expected.items():
            self.assertEqual(info[key], value, key)
        self.assertEqual(info["CFBundleVersion"], info["CFBundleShortVersionString"])
        import base64
        self.assertEqual(len(base64.b64decode(info["SUPublicEDKey"], validate=True)), 32)
        icon = contents / "Resources/AppIcon.icns"
        self.assertEqual(icon.read_bytes()[:4], b"icns")
        with tempfile.TemporaryDirectory(dir=SCRATCH) as scratch:
            decoded = Path(scratch) / "AppIcon.iconset"
            subprocess.run(["iconutil", "-c", "iconset", str(icon), "-o", str(decoded)], check=True)
            for size in (16, 32, 128, 256, 512):
                for scale in (1, 2):
                    name = f"icon_{size}x{size}" + ("@2x" if scale == 2 else "") + ".png"
                    self.assertTrue((decoded / name).is_file(), name)
        for license in ("adb-NOTICE.txt", "Sparkle-LICENSE.txt", "DualScreen-LICENSE.txt"):
            self.assertGreater((contents / "Resources/Licenses" / license).stat().st_size, 100)
        framework = contents / "Frameworks/Sparkle.framework"
        self.assertTrue((framework / "Versions/Current").is_symlink())
        self.assertTrue((framework / "Sparkle").is_symlink())
        for binary in (contents / "MacOS/DualScreenHost", contents / "Resources/adb", framework / "Sparkle"):
            self.assertIn("arm64", subprocess.check_output(["lipo", "-archs", str(binary)], text=True))
            deps = subprocess.check_output(["otool", "-L", str(binary)], text=True)
            self.assertNotIn("/opt/homebrew", deps)
            self.assertNotIn("/usr/local", deps)
        host_deps = subprocess.check_output(["otool", "-L", str(contents / "MacOS/DualScreenHost")], text=True)
        self.assertIn("@rpath/Sparkle.framework/", host_deps)
        self.assertIn("@executable_path/../Frameworks", subprocess.check_output(["otool", "-l", str(contents / "MacOS/DualScreenHost")], text=True))
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(self.app)], check=True)

    def test_zip_and_installer_payload(self):
        packages = list(self.output.glob("DualScreen-v*-macos-arm64.pkg"))
        archives = list(self.output.glob("DualScreen-v*-macos-arm64.zip"))
        self.assertEqual(len(packages), 1)
        self.assertEqual(len(archives), 1)
        # Both commands are read-only Installer queries: no installation occurs.
        restart = subprocess.check_output(["/usr/sbin/installer", "-query", "RestartAction", "-pkg", str(packages[0]), "-target", "/"], text=True).strip()
        self.assertEqual(restart, "RequireRestart")
        choices_xml = subprocess.check_output(["/usr/sbin/installer", "-showChoicesXML", "-pkg", str(packages[0]), "-target", "/"])
        selected = {p["choiceIdentifier"]: p["choiceIsSelected"] for root in plistlib.loads(choices_xml) for p in root["childItems"]}
        self.assertEqual(selected, {"app": 1, "audio": 1, "mic": 1})
        with tempfile.TemporaryDirectory(dir=SCRATCH) as scratch:
            scratch = Path(scratch)
            subprocess.run(["ditto", "-x", "-k", str(archives[0]), str(scratch / "zip")], check=True)
            restored = scratch / "zip/DualScreen.app"
            self.assertTrue((restored / "Contents/Frameworks/Sparkle.framework/Versions/Current").is_symlink())
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(restored)], check=True)
            subprocess.run(["pkgutil", "--expand-full", str(packages[0]), str(scratch / "pkg")], check=True)
            info_files = list((scratch / "pkg").rglob("PackageInfo"))
            infos = {ET.parse(p).getroot().attrib["identifier"]: (p, ET.parse(p).getroot()) for p in info_files}
            self.assertEqual(set(infos), {"com.oleg.dualscreen.installer", "com.dualscreen.audio.installer", "com.dualscreen.audio.installer.mic"})
            app_info_path, info = infos["com.oleg.dualscreen.installer"]
            self.assertEqual(info.attrib["install-location"], "/Applications")
            app_payload = app_info_path.parent / "Payload"
            self.assertEqual([p.name for p in app_payload.iterdir()], ["DualScreen.app"])
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app_payload / "DualScreen.app")], check=True)
            audio_path, audio_info = infos["com.dualscreen.audio.installer"]
            self.assertEqual(audio_info.attrib["install-location"], "/")
            self.assertEqual(audio_info.attrib["version"], os.environ.get("DUALSCREEN_TEST_AUDIO_VERSION", "1.1.0"))
            audio_payload = audio_path.parent / "Payload"
            driver = audio_payload / "Library/Audio/Plug-Ins/HAL/DualScreenAudio.driver"
            self.assertEqual([p.name for p in driver.parent.iterdir()], ["DualScreenAudio.driver"])
            self.assertEqual(plistlib.loads((driver / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"], "com.dualscreen.audio.driver")
            subprocess.run(["codesign", "--verify", "--strict", str(driver)], check=True)
            support = audio_payload / "Library/Application Support/DualScreenAudio"
            self.assertIn("GNU GENERAL PUBLIC LICENSE", (support / "LICENSE").read_text())
            self.assertTrue((support / "DualScreenAudio-source.tar.gz").is_file())
            self.assertFalse((audio_path.parent / "Scripts").exists())
            mic_path, mic_info = infos["com.dualscreen.audio.installer.mic"]
            self.assertEqual(mic_info.attrib["install-location"], "/")
            self.assertEqual(mic_info.attrib["version"], os.environ.get("DUALSCREEN_TEST_MIC_VERSION", "1.1.0"))
            mic_payload = mic_path.parent / "Payload"
            mic_driver = mic_payload / "Library/Audio/Plug-Ins/HAL/DualScreenMic.driver"
            self.assertEqual([p.name for p in mic_driver.parent.iterdir()], ["DualScreenMic.driver"])
            self.assertEqual(plistlib.loads((mic_driver / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"], "com.dualscreen.audio.driver.mic")
            subprocess.run(["codesign", "--verify", "--strict", str(mic_driver)], check=True)
            mic_strings = subprocess.check_output(["strings", str(mic_driver / "Contents/MacOS/DualScreenMic")], text=True)
            self.assertIn("DualScreenMic_UID", mic_strings)
            mic_support = mic_payload / "Library/Application Support/DualScreenMic"
            self.assertIn("GNU GENERAL PUBLIC LICENSE", (mic_support / "LICENSE").read_text())
            self.assertTrue((mic_support / "DualScreenMic-source.tar.gz").is_file())
            self.assertFalse((mic_path.parent / "Scripts").exists())
            distribution = ET.parse(scratch / "pkg/Distribution").getroot()
            audio_ref = next(p for p in distribution.findall("pkg-ref") if p.attrib["id"] == "com.dualscreen.audio.installer" and p.text)
            self.assertEqual(audio_ref.attrib["onConclusion"], "RequireRestart")
            mic_ref = next(p for p in distribution.findall("pkg-ref") if p.attrib["id"] == "com.dualscreen.audio.installer.mic" and p.text)
            self.assertEqual(mic_ref.attrib["onConclusion"], "RequireRestart")
            choices = distribution.findall("choice")
            self.assertEqual(len(choices), 3)
            self.assertTrue(all(p.attrib["start_selected"] == "true" for p in choices))
            component = plistlib.loads((self.output / "component.plist").read_bytes())[0]
            self.assertFalse(component["BundleIsRelocatable"])
            self.assertEqual(component["BundleOverwriteAction"], "upgrade")


if __name__ == "__main__":
    unittest.main()
