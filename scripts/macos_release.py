#!/usr/bin/env python3
"""Prepare and publish authenticated Sparkle releases using the local Keychain.

No private key is exported or uploaded. CI can build installable bundles, but the
release owner runs this tool on their signing Mac to advance the update channel.
"""
from __future__ import annotations

import base64
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
REPOSITORY = 'oproskyrin/DualScreenPOI'
FEED_URL = f'https://github.com/{REPOSITORY}/releases/download/macos-updates/appcast.xml'
ACCOUNT = 'com.oleg.dualscreen.host'
ROOT = pathlib.Path(__file__).resolve().parents[1]


def validate_version(value: str) -> str:
    component = r'(?:0|[1-9][0-9]*)'
    if not re.fullmatch(rf'{component}\.{component}\.{component}', value):
        raise ValueError('Version must be literal MAJOR.MINOR.PATCH, without v or suffixes')
    return value


def validate_archive(archive: pathlib.Path, version: str, public_key: str) -> None:
    try:
        with zipfile.ZipFile(archive) as zipped:
            for entry in zipped.namelist():
                path = pathlib.PurePosixPath(entry)
                if path.is_absolute() or '..' in path.parts:
                    raise ValueError('Unsafe path in update archive')
            info = plistlib.loads(zipped.read('DualScreen.app/Contents/Info.plist'))
        expected = {'CFBundleIdentifier': 'com.oleg.dualscreen.host', 'CFBundleVersion': version,
                    'CFBundleShortVersionString': version, 'SUPublicEDKey': public_key,
                    'SUFeedURL': FEED_URL, 'SURequireSignedFeed': True, 'SUVerifyUpdateBeforeExtraction': True,
                    'SUAllowsAutomaticUpdates': False}
        for key, value in expected.items():
            if info.get(key) != value:
                raise ValueError(f'Archive metadata mismatch: {key}')
    except (KeyError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        raise ValueError('Not a packaged DualScreen.app update archive') from error


def validate_appcast(data: bytes, version: str, archive: pathlib.Path, repo: str) -> dict:
    if len(data) > 1024 * 1024 or b'<!DOCTYPE' in data.upper():
        raise ValueError('Unexpected appcast XML size or doctype')
    try:
        root = ET.fromstring(data)
        item = root.find('./channel/item')
        if item is None:
            raise ValueError('Missing appcast item')
        enclosure = item.find('enclosure')
        if enclosure is None:
            raise ValueError('Missing appcast enclosure')
        item_version = item.findtext(SPARKLE + 'version') or enclosure.get(SPARKLE + 'version')
        expected_url = f'https://github.com/{repo}/releases/download/v{version}/{archive.name}'
        signature = enclosure.get(SPARKLE + 'edSignature', '')
        if item_version != version or enclosure.get('url') != expected_url:
            raise ValueError('Appcast version or download URL does not match this release')
        if int(enclosure.get('length', '-1')) != archive.stat().st_size:
            raise ValueError('Appcast size does not match archive')
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise ValueError('Invalid Ed25519 signature encoding')
        return {'version': version, 'url': expected_url, 'signature': signature}
    except (ET.ParseError, TypeError) as error:
        raise ValueError('Invalid appcast XML') from error


def run(*arguments: str, capture: bool = False) -> str:
    result = subprocess.run(list(arguments), cwd=ROOT, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else ''


def sha256(path: pathlib.Path) -> str:
    result = hashlib.sha256()
    with path.open('rb') as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def verify_signatures(tools: pathlib.Path, feed: pathlib.Path, archive: pathlib.Path, version: str) -> None:
    # Official Sparkle verifies the signed XML as well as the archive signature.
    # Structural validation alone is never an authenticity check.
    signer = str(tools / 'sign_update')
    run(signer, '--account', ACCOUNT, '--verify', str(feed))
    metadata = validate_appcast(feed.read_bytes(), version, archive, REPOSITORY)
    run(signer, '--account', ACCOUNT, '--verify', str(archive), metadata['signature'])


def prepare(directory: pathlib.Path, version: str, tools: pathlib.Path, verify_only: bool = False) -> tuple:
    archive = directory / f'DualScreen-v{version}-macos-arm64.zip'
    installer = directory / f'DualScreen-v{version}-macos-arm64.pkg'
    for file in (archive, installer):
        if not file.is_file() or file.stat().st_size == 0:
            raise ValueError(f'Missing built artifact: {file}')
    public = (ROOT / 'packaging/macos/sparkle-public-key.txt').read_text().strip()
    if len(base64.b64decode(public, validate=True)) != 32:
        raise ValueError('Invalid committed public key')
    actual = run(str(tools / 'generate_keys'), '--account', ACCOUNT, '-p', capture=True)
    if actual != public:
        raise ValueError('Signing Mac Keychain public key differs; refusing key rotation')
    validate_archive(archive, version, public)
    feed = directory / 'appcast.xml'
    if not verify_only:
        scratch = pathlib.Path.home() / '.hermes/cache/scratch'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='dualscreen-appcast-', dir=scratch) as work:
            stage = pathlib.Path(work)
            shutil.copy2(archive, stage / archive.name)
            run(str(tools / 'generate_appcast'), '--account', ACCOUNT,
                '--maximum-deltas', '0', '--download-url-prefix',
                f'https://github.com/{REPOSITORY}/releases/download/v{version}/', str(stage))
            generated = stage / 'appcast.xml'
            verify_signatures(tools, generated, archive, version)
            shutil.copy2(generated, feed)
    verify_signatures(tools, feed, archive, version)
    return archive, installer, feed


def gh_json(*arguments: str) -> dict:
    return json.loads(run('gh', *arguments, capture=True))


def verify_remote_asset(release: dict, local: pathlib.Path) -> None:
    matches = [asset for asset in release['assets'] if asset['name'] == local.name]
    if len(matches) != 1 or matches[0]['size'] != local.stat().st_size:
        raise ValueError(f'Remote asset missing or wrong size: {local.name}')
    expected = 'sha256:' + sha256(local)
    digest = matches[0].get('digest')
    if digest is not None:
        if digest != expected:
            raise ValueError(f'Remote immutable asset differs: {local.name}')
        return
    scratch = pathlib.Path.home() / '.hermes/cache/scratch'
    with tempfile.TemporaryDirectory(prefix='dualscreen-release-readback-', dir=scratch) as work:
        run('gh', 'release', 'download', release['tag_name'], '--repo', REPOSITORY,
            '--pattern', local.name, '--dir', work)
        if sha256(pathlib.Path(work) / local.name) != expected.removeprefix('sha256:'):
            raise ValueError(f'Remote readback differs: {local.name}')


def publish(archive: pathlib.Path, installer: pathlib.Path, feed: pathlib.Path,
            version: str, tools: pathlib.Path) -> None:
    tag = 'v' + version
    api = f'repos/{REPOSITORY}/releases/tags/'
    release = gh_json('api', api + tag)
    if release['draft'] or release['prerelease']:
        raise ValueError('Only a published stable release may advance the stable update feed')
    # Archives/installers are immutable. Do not clobber an update people may have cached.
    for local in (archive, installer):
        if any(asset['name'] == local.name for asset in release['assets']):
            verify_remote_asset(release, local)
        else:
            run('gh', 'release', 'upload', tag, str(local), '--repo', REPOSITORY)
            release = gh_json('api', api + tag)
            verify_remote_asset(release, local)
    run('gh', 'release', 'upload', tag, str(feed), '--repo', REPOSITORY, '--clobber')
    release = gh_json('api', api + tag)
    verify_remote_asset(release, feed)
    # The fixed prerelease is a feed endpoint only, never Latest. Advance it last.
    result = subprocess.run(['gh', 'api', api + 'macos-updates'], cwd=ROOT,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        # Fail closed on authentication/network errors rather than treating them as absent.
        if '404' not in result.stderr and '404' not in result.stdout:
            raise RuntimeError('Cannot read the macOS update channel: ' + result.stderr.strip())
        run('gh', 'release', 'create', 'macos-updates', '--repo', REPOSITORY,
            '--title', 'Mac update channel', '--notes',
            'Signed Sparkle update feed. Download the complete installer from a versioned release.',
            '--prerelease', '--latest=false')
        channel = gh_json('api', api + 'macos-updates')
    else:
        channel = json.loads(result.stdout)
    if not channel['prerelease'] or channel['draft']:
        raise ValueError('The fixed update channel must be a public prerelease, not Latest')
    run('gh', 'release', 'upload', 'macos-updates', str(feed), '--repo', REPOSITORY, '--clobber')
    channel = gh_json('api', api + 'macos-updates')
    verify_remote_asset(channel, feed)
    scratch = pathlib.Path.home() / '.hermes/cache/scratch'
    with tempfile.TemporaryDirectory(prefix='dualscreen-feed-readback-', dir=scratch) as work:
        run('gh', 'release', 'download', 'macos-updates', '--repo', REPOSITORY,
            '--pattern', 'appcast.xml', '--dir', work)
        downloaded = pathlib.Path(work) / 'appcast.xml'
        if downloaded.read_bytes() != feed.read_bytes():
            raise ValueError('Published feed differs from the locally verified signed feed')
        verify_signatures(tools, downloaded, archive, version)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--artifacts', type=pathlib.Path, default=ROOT / 'dist/macos')
    parser.add_argument('--tools', type=pathlib.Path,
                        default=ROOT / 'host/.build/artifacts/sparkle/Sparkle/bin')
    parser.add_argument('--verify-only', action='store_true')
    parser.add_argument('--publish', action='store_true', help='Upload and advance the signed update channel')
    options = parser.parse_args()
    version = validate_version(options.version)
    archive, installer, feed = prepare(options.artifacts.resolve(), version, options.tools.resolve(), options.verify_only)
    if options.publish:
        publish(archive, installer, feed, version, options.tools.resolve())
    print(json.dumps({'version': version, 'published': options.publish, 'signaturesVerified': True,
                      'archive': archive.name, 'installer': installer.name,
                      'feed': str(feed), 'feedURL': FEED_URL}, indent=2))


if __name__ == '__main__':
    main()
