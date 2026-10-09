#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location('release', Path(__file__).with_name('package-release.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def test_versions(self):
        self.assertEqual(release.version('0.1.0-beta.1'), '0.1.0-beta.1')
        for bad in ['v1.0.0', '../outside', '1.0.0;echo', '1.0']:
            with self.assertRaises(ValueError):
                release.version(bad)

    def test_assemble_real_npm_tarball_and_formula(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for target in release.TARGETS:
                staging = root / target
                staging.mkdir()
                for name, contents in [('quotio', '#!/bin/sh\necho quotio 0.1.0\n'), ('LICENSE', 'MIT'), ('THIRD-PARTY-NOTICES.md', 'Copyright fixture')]:
                    (staging / name).write_text(contents)
                with tarfile.open(root / release.archive_name('0.1.0', target), 'w:gz') as tar:
                    for file in staging.iterdir():
                        tar.add(file, arcname=file.name)
            out = root / 'out'
            release.assemble(SimpleNamespace(version='0.1.0', repository='example/quotio', artifacts=root, output=out))
            subprocess.run(['ruby', '-c', str(out / 'quotio.rb')], check=True)
            with tarfile.open(out / 'quotio-0.1.0.tgz') as tar:
                names = tar.getnames()
                for target in release.TARGETS:
                    self.assertIn(f'package/native/{target}/quotio', names)
                readme = tar.extractfile('package/README.md').read().decode()
                self.assertIn('encrypted Linux vault', readme)
                self.assertIn('QUOTIO_VAULT_KEY_FILE', readme)
                self.assertIn('without Node.js on PATH', readme)
                self.assertNotIn('Linux has no saved-account vault', readme)
            self.assertEqual(len((out / 'SHA256SUMS').read_text().splitlines()), 5)
            formula = (out / 'quotio.rb').read_text()
            self.assertIn('/releases/download/cli-v0.1.0/', formula)
            self.assertNotIn('no_check', formula)
            subprocess.run(['npm', 'install', '--prefix', str(root / 'install'), '--ignore-scripts', '--no-audit', '--no-fund', str(out / 'quotio-0.1.0.tgz')], check=True)
            binary = root / 'install/node_modules/.bin/quotio'
            minimal = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'}
            self.assertEqual(subprocess.check_output([str(binary), '--version'], text=True, env=minimal).strip(), 'quotio 0.1.0')


if __name__ == '__main__':
    unittest.main()
