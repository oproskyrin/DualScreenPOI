"""Host-owned translations and installed-resource packaging contract."""
import importlib.util
import os
from pathlib import Path
import plistlib
import re
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / 'host/Sources/DualScreenHost/Resources'
SCRATCH = Path(os.environ.get('BUILD_SCRATCH_ROOT', str(Path.home() / '.hermes/cache/scratch')))
SCRATCH.mkdir(parents=True, exist_ok=True)


class HostLocalizationTests(unittest.TestCase):
    def test_catalog_parity_and_format_arguments(self):
        tables = []
        for language in ('en', 'ru'):
            path = RESOURCES / f'{language}.lproj/Localizable.strings'
            self.assertTrue(path.is_file(), f'Missing {language} host catalog')
            import subprocess
            tables.append(plistlib.loads(subprocess.check_output(
                ['plutil', '-convert', 'xml1', '-o', '-', str(path)])))
        self.assertGreaterEqual(len(tables[0]), 35)
        self.assertEqual(tables[0].keys(), tables[1].keys())
        for key in tables[0]:
            self.assertTrue(tables[0][key], key)
            self.assertTrue(tables[1][key], key)
            pattern = r'%(?:\d+\$)?[-+0-9.]*[@dfius]'
            self.assertEqual(re.findall(pattern, tables[0][key]),
                             re.findall(pattern, tables[1][key]), key)
        used = set()
        for source in (ROOT / 'host/Sources/DualScreenHost').glob('*.swift'):
            used.update(re.findall(r'L10n\.(?:text|format)\("([^"\\]+)"', source.read_text()))
        self.assertLessEqual(used, tables[0].keys())

    def test_builder_copies_localizations_without_build_tree(self):
        spec = importlib.util.spec_from_file_location('builder', ROOT / 'scripts/build_macos_app.py')
        assert spec is not None and spec.loader is not None
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
            destination = Path(directory) / 'DualScreen.app/Contents/Resources'
            destination.mkdir(parents=True)
            builder.copy_localizations(destination)
            for language in ('en', 'ru'):
                for filename in ('Localizable.strings', 'InfoPlist.strings'):
                    relative = Path(f'{language}.lproj') / filename
                    self.assertEqual((destination / relative).read_bytes(),
                                     (RESOURCES / relative).read_bytes())

    def test_installer_localized_documents_and_choices(self):
        spec = importlib.util.spec_from_file_location('builder', ROOT / 'scripts/build_macos_app.py')
        assert spec is not None and spec.loader is not None
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        import xml.etree.ElementTree as ET
        with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
            distribution = Path(directory) / 'Distribution.xml'
            builder.write_distribution(distribution, '1.6.1', '1.1.0', '1.1.0')
            tree = ET.parse(distribution).getroot()
            welcome, readme = tree.find('welcome'), tree.find('readme')
            assert welcome is not None and readme is not None
            self.assertEqual(welcome.attrib['file'], 'Welcome.html')
            self.assertEqual(readme.attrib['file'], 'ReadMe.html')
            self.assertEqual({c.attrib['title'] for c in tree.findall('choice')},
                             {'installer.app', 'installer.audio', 'installer.mic'})
        for language in ('en', 'ru'):
            directory = ROOT / f'packaging/macos/installer-resources/{language}.lproj'
            for filename in ('Welcome.html', 'ReadMe.html', 'Localizable.strings'):
                self.assertTrue((directory / filename).is_file(), filename)


if __name__ == '__main__':
    unittest.main()
