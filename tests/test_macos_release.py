import importlib.util
import base64
import pathlib
import plistlib
import sys
import tempfile
import unittest
import zipfile

MODULE = pathlib.Path(__file__).resolve().parents[1] / 'scripts' / 'macos_release.py'
spec = importlib.util.spec_from_file_location('macos_release', MODULE)
assert spec is not None and spec.loader is not None
release = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = release
spec.loader.exec_module(release)

class ReleaseValidationTests(unittest.TestCase):
    def test_archive_identity_requires_the_real_app_key_and_feed(self):
        scratch = pathlib.Path.home() / '.hermes/cache/scratch'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            archive = pathlib.Path(directory) / 'update.zip'
            public = base64.b64encode(bytes(32)).decode()
            info = dict(CFBundleIdentifier='com.oleg.dualscreen.host', CFBundleVersion='0.13.0',
                        CFBundleShortVersionString='0.13.0', SUPublicEDKey=public,
                        SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True, SUAllowsAutomaticUpdates=False,
                        SUFeedURL='https://github.com/oproskyrin/DualScreenPOI/releases/download/macos-updates/appcast.xml')
            def write(value):
                with zipfile.ZipFile(archive, 'w') as z:
                    z.writestr('DualScreen.app/Contents/Info.plist', plistlib.dumps(value))
            write(info)
            release.validate_archive(archive, '0.13.0', public)
            for key, value in (('CFBundleVersion', '0.12.0'), ('SUPublicEDKey', 'wrong'), ('SURequireSignedFeed', False), ('SUAllowsAutomaticUpdates', True), ('SUFeedURL', 'http://example.org/update.xml')):
                write(dict(info, **{key: value}))
                with self.assertRaises(ValueError):
                    release.validate_archive(archive, '0.13.0', public)

    def test_version_is_literal_three_component_numeric(self):
        self.assertEqual('0.13.0', release.validate_version('0.13.0'))
        for value in ('v0.13.0', '0.13', '../0.13.0', '0.13.0\n', '0.13.0;open', '00.13.0'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                release.validate_version(value)

    def test_appcast_binds_version_url_length_and_signature(self):
        scratch = pathlib.Path.home() / '.hermes/cache/scratch'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            archive = pathlib.Path(directory) / 'DualScreen-v0.13.0-macos-arm64.zip'
            archive.write_bytes(b'unit-test fixture, not an installable archive')
            signature = base64.b64encode(bytes(64)).decode()
            url = 'https://github.com/oproskyrin/DualScreenPOI/releases/download/v0.13.0/' + archive.name
            def feed(version='0.13.0', download=url, length=archive.stat().st_size, sig=signature):
                return (f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>'
                        f'<sparkle:version>{version}</sparkle:version><enclosure url="{download}" length="{length}" '
                        f'sparkle:edSignature="{sig}" /></item></channel></rss>').encode()
            metadata = release.validate_appcast(feed(), '0.13.0', archive, 'oproskyrin/DualScreenPOI')
            self.assertEqual(url, metadata['url'])
            for invalid in (feed(version='0.12.0'), feed(download='https://example.org/update.zip'), feed(length=1), feed(sig='bad')):
                with self.assertRaises(ValueError):
                    release.validate_appcast(invalid, '0.13.0', archive, 'oproskyrin/DualScreenPOI')

if __name__ == '__main__':
    unittest.main()
