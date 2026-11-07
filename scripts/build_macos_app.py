#!/usr/bin/env python3
"""Build local macOS app, first-install PKG and Sparkle ZIP; never install/publish."""
import argparse
import base64
import binascii
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import tarfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
FEED = "https://github.com/oproskyrin/DualScreenPOI/releases/download/macos-updates/appcast.xml"


def run(*args, capture=False) -> str:
    result = subprocess.run([str(a) for a in args], check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else ""


def validate_binary(binary, arch, apple_only=False):
    arches = run("/usr/bin/lipo", "-archs", binary, capture=True).split()
    if arch not in arches:
        raise ValueError(f"{binary} has {arches}, not requested architecture {arch}")
    deps = run("/usr/bin/otool", "-L", binary, capture=True)
    for line in deps.splitlines():
        if not line.startswith("\t"):
            continue
        dependency = line.strip().split(" (", 1)[0]
        if dependency.startswith(("/opt/", "/usr/local/")):
            raise ValueError(f"nonportable dependency: {binary}: {dependency}")
        if apple_only and not dependency.startswith(("/usr/lib/", "/System/Library/")):
            raise ValueError(f"adb dependency is not an Apple system library: {dependency}")
    return deps


def make_icon(source, destination, scratch):
    iconset = scratch / "AppIcon.iconset"
    iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            name = f"icon_{size}x{size}" + ("@2x" if scale == 2 else "") + ".png"
            run("/usr/bin/sips", "-z", size * scale, size * scale, source,
                "--out", iconset / name, capture=True)
    run("/usr/bin/iconutil", "-c", "icns", iconset, "-o", destination)


def sign_own(path, identity):
    args = ["/usr/bin/codesign", "--force", "--sign", identity]
    # Ad-hoc and the local self-signed identity ("DualScreen Local …") have no
    # Apple-issued timestamp service; hardened runtime would also block the
    # vendor-signed Sparkle framework under library validation.
    if identity != "-" and not identity.startswith("DualScreen Local"):
        args += ["--timestamp", "--options", "runtime"]
    run(*args, path)


def validate_audio_component(package, scratch, arch):
    """Inspect only; never execute installer scripts or register a HAL driver."""
    expanded = scratch / "audio-expanded"
    run("/usr/sbin/pkgutil", "--expand-full", package, expanded)
    infos = list(expanded.rglob("PackageInfo"))
    if len(infos) != 1:
        raise ValueError("audio input must be one flat component PKG, not a distribution")
    info_path = infos[0]
    info = ET.parse(info_path).getroot()
    if info.attrib.get("identifier") != "com.dualscreen.audio.installer" or info.attrib.get("install-location") != "/":
        raise ValueError("audio component must use com.dualscreen.audio.installer at /")
    if (info_path.parent / "Scripts").exists() or info.find("scripts") is not None:
        raise ValueError("audio component must not run installer scripts or restart CoreAudio")
    payload = info_path.parent / "Payload"
    driver_rel = Path("Library/Audio/Plug-Ins/HAL/DualScreenAudio.driver")
    support_rel = Path("Library/Application Support/DualScreenAudio")
    for path in payload.rglob("*"):
        relative = path.relative_to(payload)
        if path.is_dir() and not path.is_symlink():
            continue
        if not (relative.is_relative_to(driver_rel) or relative.is_relative_to(support_rel)):
            raise ValueError(f"unexpected audio payload: {relative}")
    driver = payload / driver_rel
    support = payload / support_rel
    plist = plistlib.loads((driver / "Contents/Info.plist").read_bytes())
    if plist.get("CFBundleIdentifier") != "com.dualscreen.audio.driver":
        raise ValueError("wrong branded audio driver bundle identifier")
    binary = driver / "Contents/MacOS/DualScreenAudio"
    validate_binary(binary, arch)
    strings = run("/usr/bin/strings", binary, capture=True)
    if "DualScreenAudio_UID" not in strings:
        raise ValueError("audio driver does not retain DualScreenAudio_UID")
    run("/usr/bin/codesign", "--verify", "--strict", driver)
    if "GNU GENERAL PUBLIC LICENSE" not in (support / "LICENSE").read_text():
        raise ValueError("audio payload lacks GPL license")
    for required in (support / "NOTICE.txt", support / "UPSTREAM_SHA", driver / "Contents/Resources/LICENSE", driver / "Contents/Resources/NOTICE.txt"):
        if not required.is_file():
            raise ValueError(f"required audio attribution missing: {required}")
    with tarfile.open(support / "DualScreenAudio-source.tar.gz", "r:gz") as archive:
        names = {name.removeprefix("./") for name in archive.getnames()}
        required = {"LICENSE", "NOTICE.txt", "UPSTREAM_SHA", "build-dualscreen-audio.sh", "verify-dualscreen-audio.c", "modified/BlackHole.c", "modified/DualScreenAudioConfig.h", "modified/Info.plist", "upstream/BlackHole/BlackHole.c", "upstream/LICENSE"}
        if not required.issubset(names):
            raise ValueError(f"incomplete corresponding audio source: missing {sorted(required - names)}")
    return info.attrib["version"]


def write_distribution(path, app_version, audio_version):
    distribution = ET.Element("installer-gui-script", {"minSpecVersion": "2"})
    ET.SubElement(distribution, "title").text = "DualScreen"
    ET.SubElement(distribution, "options", {"customize": "never", "require-scripts": "false", "rootVolumeOnly": "true", "hostArchitectures": "arm64"})
    ET.SubElement(distribution, "domains", {"enable_anywhere": "false", "enable_currentUserHome": "false", "enable_localSystem": "true"})
    os_versions = ET.SubElement(distribution, "allowed-os-versions")
    ET.SubElement(os_versions, "os-version", {"min": "13.0"})
    outline = ET.SubElement(distribution, "choices-outline")
    for choice, identifier, title, filename, version in (("app", "com.oleg.dualscreen.installer", "DualScreen application", "DualScreenApp.pkg", app_version), ("audio", "com.dualscreen.audio.installer", "DualScreen tablet audio output", "DualScreenAudio.pkg", audio_version)):
        ET.SubElement(outline, "line", {"choice": choice})
        element = ET.SubElement(distribution, "choice", {"id": choice, "title": title, "visible": "false", "start_selected": "true"})
        ET.SubElement(element, "pkg-ref", {"id": identifier})
        attributes = {"id": identifier, "version": version, "auth": "Root"}
        if choice == "audio":
            attributes["onConclusion"] = "RequireRestart"
        ET.SubElement(distribution, "pkg-ref", attributes).text = filename
    ET.ElementTree(distribution).write(path, encoding="utf-8", xml_declaration=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default=os.environ.get("VERSION", "1.1.0"))
    parser.add_argument("--public-key", type=Path, default=Path(os.environ.get("SPARKLE_PUBLIC_KEY_FILE", ROOT / "packaging/macos/sparkle-public-key.txt")))
    parser.add_argument("--output", type=Path, default=ROOT / "dist/macos")
    parser.add_argument("--arch", choices=("arm64", "x86_64"), default="arm64")
    parser.add_argument("--host-binary", type=Path, help="package a prebuilt release executable instead of running swift build")
    parser.add_argument("--sparkle-framework", type=Path, default=Path(os.environ.get("SPARKLE_FRAMEWORK", ROOT / "host/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework")))
    parser.add_argument("--sparkle-license", type=Path, default=os.environ.get("SPARKLE_LICENSE"))
    parser.add_argument("--adb", type=Path, default=Path(os.environ.get("ADB_BINARY", shutil.which("adb") or "/opt/homebrew/bin/adb")))
    parser.add_argument("--adb-notice", type=Path, default=os.environ.get("ADB_NOTICE"))
    parser.add_argument("--codesign-identity", default=os.environ.get("CODESIGN_IDENTITY", "-"))
    parser.add_argument("--installer-identity", default=os.environ.get("INSTALLER_IDENTITY"))
    parser.add_argument("--audio-component-pkg", type=Path, default=Path(os.environ.get("AUDIO_COMPONENT_PKG", ROOT / "dist/DualScreenAudio/DualScreenAudio-1.1.0.pkg")), help="verified native HAL component for full first-install setup (required by default)")
    parser.add_argument("--app-only", action="store_true", help="explicitly build an app-only installer (no HAL); ZIP updates are always app-only")
    args = parser.parse_args()
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", args.version):
        parser.error("version must be numeric MAJOR.MINOR.PATCH (no prefix or prerelease)")
    try:
        public_key = args.public_key.read_text().strip()
        if len(base64.b64decode(public_key, validate=True)) != 32:
            raise ValueError("Ed25519 public key must be 32 bytes")
    except (OSError, ValueError, binascii.Error) as error:
        parser.error(f"Sparkle public key unavailable/invalid at {args.public_key}: {error}")
    if sys.platform != "darwin":
        parser.error("macOS packaging requires macOS and Command Line Tools")
    if not args.app_only and not args.audio_component_pkg.is_file():
        parser.error("full installer requires AUDIO_COMPONENT_PKG / --audio-component-pkg; use --app-only only intentionally")
    framework = args.sparkle_framework.resolve()
    if not (framework / "Sparkle").is_file():
        parser.error(f"Sparkle.framework missing: {framework}; resolve SwiftPM dependencies or set SPARKLE_FRAMEWORK")
    adb = args.adb.resolve()
    notice = Path(args.adb_notice) if args.adb_notice else adb.parent / "NOTICE.txt"
    licenses = [Path(args.sparkle_license)] if args.sparkle_license else [framework / "Resources/LICENSE", framework / "Resources/LICENSE.txt", framework.parents[2] / "LICENSE", ROOT / "host/.build/artifacts/sparkle/Sparkle/LICENSE"]
    sparkle_license = next((p for p in licenses if p.is_file()), None)
    if not notice.is_file() or sparkle_license is None:
        parser.error("Required adb NOTICE.txt / Sparkle LICENSE missing; use --adb-notice / --sparkle-license")
    validate_binary(adb, args.arch, apple_only=True)
    validate_binary(framework / "Sparkle", args.arch)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", framework)
    if args.host_binary:
        host = args.host_binary.resolve()
    else:
        run("/usr/bin/swift", "build", "--package-path", ROOT / "host", "-c", "release", "--product", "DualScreenHost", "--triple", f"{args.arch}-apple-macosx13.0")
        bin_path = run("/usr/bin/swift", "build", "--package-path", ROOT / "host", "-c", "release", "--triple", f"{args.arch}-apple-macosx13.0", "--show-bin-path", capture=True)
        host = Path(bin_path) / "DualScreenHost"
    deps = validate_binary(host, args.arch)
    if "@rpath/Sparkle.framework/" not in deps:
        parser.error("host executable is not linked to Sparkle; rebuild the integrated host")
    output = args.output.resolve()
    if output == ROOT or ROOT.is_relative_to(output):
        parser.error("output cannot be the repository or its ancestor")
    output.mkdir(parents=True, exist_ok=True)
    stem = f"DualScreen-v{args.version}-macos-{args.arch}"
    # Build in scratch, leaving the last working artifacts intact on failure.
    scratch_root = Path(os.environ.get("BUILD_SCRATCH_ROOT", Path.home() / ".hermes/cache/scratch"))
    scratch_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="dualscreen-packaging-", dir=scratch_root) as directory:
        scratch = Path(directory)
        audio_version = None if args.app_only else validate_audio_component(args.audio_component_pkg.resolve(), scratch, args.arch)
        root = scratch / "payload"
        app = root / "DualScreen.app"
        contents = app / "Contents"
        resources = contents / "Resources"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Frameworks").mkdir()
        (resources / "Licenses").mkdir(parents=True)
        shutil.copy2(host, contents / "MacOS/DualScreenHost")
        shutil.copy2(adb, resources / "adb")
        shutil.copy2(notice, resources / "Licenses/adb-NOTICE.txt")
        shutil.copy2(sparkle_license, resources / "Licenses/Sparkle-LICENSE.txt")
        shutil.copy2(ROOT / "LICENSE", resources / "Licenses/DualScreen-LICENSE.txt")
        # ditto preserves symlinks and vendor code signatures; never modify .build.
        run("/usr/bin/ditto", framework, contents / "Frameworks/Sparkle.framework")
        executable = contents / "MacOS/DualScreenHost"
        loads = run("/usr/bin/otool", "-l", executable, capture=True)
        if "@executable_path/../Frameworks" not in loads:
            run("/usr/bin/install_name_tool", "-add_rpath", "@executable_path/../Frameworks", executable)
        make_icon(ROOT / "assets/branding/dualscreen-icon.png", resources / "AppIcon.icns", scratch)
        info = {"CFBundleIdentifier": "com.oleg.dualscreen.host", "CFBundleName": "DualScreen", "CFBundleDisplayName": "DualScreen", "CFBundleExecutable": "DualScreenHost", "CFBundleIconFile": "AppIcon", "CFBundlePackageType": "APPL", "CFBundleInfoDictionaryVersion": "6.0", "CFBundleShortVersionString": args.version, "CFBundleVersion": args.version, "LSMinimumSystemVersion": "13.0", "LSUIElement": True, "NSHighResolutionCapable": True, "SUFeedURL": FEED, "SUPublicEDKey": public_key, "SUEnableAutomaticChecks": True, "SUAutomaticallyUpdate": False, "SUAllowsAutomaticUpdates": False, "SUVerifyUpdateBeforeExtraction": True, "SURequireSignedFeed": True, "NSLocalNetworkUsageDescription": "DualScreen connects to your tablet on the local network."}
        (contents / "Info.plist").write_bytes(plistlib.dumps(info, sort_keys=True))
        sign_own(resources / "adb", args.codesign_identity)
        # Preserve notarized vendor helpers/framework signatures. Sign only our
        # host and outer bundle, never --deep-sign Sparkle's helper chain.
        sign_own(executable, args.codesign_identity)
        sign_own(app, args.codesign_identity)
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
        component = [{"RootRelativeBundlePath": "DualScreen.app", "BundleIsRelocatable": False, "BundleIsVersionChecked": True, "BundleHasStrictIdentifier": True, "BundleOverwriteAction": "upgrade"}]
        component_file = scratch / "component.plist"
        component_file.write_bytes(plistlib.dumps(component))
        package = scratch / f"{stem}.pkg"
        app_package = package if args.app_only else scratch / "DualScreenApp.pkg"
        pkg_args = ["/usr/bin/pkgbuild", "--root", root, "--component-plist", component_file, "--identifier", "com.oleg.dualscreen.installer", "--version", args.version, "--install-location", "/Applications", "--ownership", "recommended", "--scripts", ROOT / "packaging/macos/installer-scripts"]
        if args.installer_identity and args.app_only:
            pkg_args += ["--sign", args.installer_identity, "--timestamp"]
        run(*pkg_args, app_package)
        if not args.app_only:
            shutil.copy2(args.audio_component_pkg, scratch / "DualScreenAudio.pkg")
            distribution = scratch / "Distribution.xml"
            write_distribution(distribution, args.version, audio_version)
            product_args = ["/usr/bin/productbuild", "--distribution", distribution, "--package-path", scratch]
            if args.installer_identity:
                product_args += ["--sign", args.installer_identity, "--timestamp"]
            run(*product_args, package)
        archive = scratch / f"{stem}.zip"
        run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)
        target = output / "DualScreen.app"
        if target.exists():
            shutil.rmtree(target)
        run("/usr/bin/ditto", app, target)
        for artifact in (package, archive, component_file):
            shutil.copy2(artifact, output / artifact.name)
    print(f"Built {target}\n{output / (stem + '.pkg')}\n{output / (stem + '.zip')}")
    print("Signing: " + ("ad-hoc app, unsigned installer; local testing only, NOT notarized" if args.codesign_identity == "-" else "configured identity; notarization must be performed separately"))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"Packaging failed: {error}")
