#!/usr/bin/env python3
"""Create versioned archives, npm staging and Homebrew formulae without publishing."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import tomllib

ROOT = Path(__file__).resolve().parent.parent
TARGETS = ('aarch64-apple-darwin', 'x86_64-apple-darwin', 'x86_64-unknown-linux-gnu')


def version(value):
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)\.\d+)?', value):
        raise ValueError('Use a release version such as 0.1.0 or 0.1.0-beta.1')
    return value


def archive_name(release, target):
    return f'quotio-{release}-{target}.tar.gz'


def archive(args):
    release = version(args.version)
    if tomllib.loads((ROOT / 'Cargo.toml').read_text())['package']['version'] != release:
        raise ValueError('Cargo.toml version must match the release version')
    args.output.mkdir(parents=True, exist_ok=True)
    dest = args.output / archive_name(release, args.target)
    with tempfile.TemporaryDirectory() as directory:
        staging = Path(directory)
        shutil.copy2(args.binary, staging / 'quotio')
        (staging / 'quotio').chmod(0o755)
        shutil.copy2(ROOT / 'LICENSE', staging / 'LICENSE')
        subprocess.run(['python3', str(ROOT / 'scripts/third-party-notices.py'),
                        '--target', args.target, '--output', str(staging / 'THIRD-PARTY-NOTICES.md')], check=True, cwd=ROOT)
        with tarfile.open(dest, 'x:gz') as tar:
            for file in sorted(staging.iterdir()):
                tar.add(file, arcname=file.name, recursive=False)


def formula(release, repository, hashes):
    beta = '-' in release
    klass = 'QuotioBeta' if beta else 'Quotio'
    def source(target, indent):
        name = archive_name(release, target)
        return f'{indent}url "https://github.com/{repository}/releases/download/cli-v{release}/{name}"\n{indent}sha256 "{hashes[name]}"\n'
    return f'''class {klass} < Formula
  desc "Check AI provider quota and usage"
  homepage "https://github.com/{repository}"
  version "{release}"
  license "MIT"
  on_macos do
    on_arm do
{source(TARGETS[0], '      ')}    end
    on_intel do
{source(TARGETS[1], '      ')}    end
  end
  on_linux do
    depends_on arch: :x86_64
{source(TARGETS[2], '    ')}  end

  def install
    bin.install "quotio"
    doc.install "THIRD-PARTY-NOTICES.md"
  end

  test do
    assert_match "quotio {release}", shell_output("#{{bin}}/quotio --version")
    assert_match "schema_version", shell_output("#{{bin}}/quotio usage --provider mock --no-saved-accounts --format json")
  end
end
'''


def assemble(args):
    release = version(args.version)
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repository):
        raise ValueError('Invalid GitHub repository')
    args.output.mkdir(parents=True, exist_ok=False)
    npm = args.output / 'npm'
    shutil.copytree(ROOT / 'distribution/npm', npm)
    package = json.loads((npm / 'package.json').read_text())
    package['version'] = release
    package.pop('scripts', None)
    package['repository']['url'] = f'git+https://github.com/{args.repository}.git'
    package['homepage'] = f'https://github.com/{args.repository}'
    (npm / 'package.json').write_text(json.dumps(package, indent=2) + '\n')
    shutil.copy2(ROOT / 'LICENSE', npm / 'LICENSE')
    hashes = {}
    notices = []
    for target in TARGETS:
        name = archive_name(release, target)
        source = args.artifacts / name
        hashes[name] = hashlib.sha256(source.read_bytes()).hexdigest()
        shutil.copy2(source, args.output / name)
        native = npm / 'native' / target
        native.mkdir(parents=True)
        with tarfile.open(source, 'r:gz') as tar:
            members = tar.getmembers()
            expected = {'quotio', 'LICENSE', 'THIRD-PARTY-NOTICES.md'}
            if len(members) != 3 or {m.name for m in members} != expected or any(not m.isfile() or m.size > 100 * 1024 * 1024 for m in members):
                raise ValueError(f'Invalid release archive: {name}')
            for member in members:
                contents = tar.extractfile(member).read()
                if member.name == 'quotio':
                    (native / 'quotio').write_bytes(contents)
                    (native / 'quotio').chmod(0o755)
                elif member.name == 'THIRD-PARTY-NOTICES.md':
                    notices.append(f'\n# {target}\n\n' + contents.decode())
    (npm / 'THIRD-PARTY-NOTICES.md').write_text(''.join(notices))
    (npm / 'README.md').write_text('''# Quotio CLI

Install with `npm install -g quotio`, then run `quotio --help`.
This package bundles native binaries; it has no install script or runtime download.
The `quotio` command is a POSIX shell launcher, so it runs without Node.js on PATH.
Supports macOS Apple Silicon/Intel and Linux x64 (glibc 2.39 or newer).
Saved accounts use macOS Keychain or an encrypted Linux vault. Linux requires an
external master key through QUOTIO_VAULT_KEY_FILE or QUOTIO_VAULT_KEY_FD.
''')
    name = 'quotio-beta.rb' if '-' in release else 'quotio.rb'
    (args.output / name).write_text(formula(release, args.repository, hashes))
    subprocess.run(['npm', 'pack', '--ignore-scripts', '--pack-destination', str(args.output.resolve())], cwd=npm, check=True)
    tarball = args.output / f'quotio-{release}.tgz'
    hashes[tarball.name] = hashlib.sha256(tarball.read_bytes()).hexdigest()
    hashes[name] = hashlib.sha256((args.output / name).read_bytes()).hexdigest()
    (args.output / 'SHA256SUMS').write_text(''.join(f'{digest}  {name}\n' for name, digest in sorted(hashes.items())))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    build = commands.add_parser('archive')
    build.add_argument('--target', choices=TARGETS, required=True)
    build.add_argument('--binary', type=Path, required=True)
    build.add_argument('--version', required=True)
    build.add_argument('--output', type=Path, required=True)
    prepare = commands.add_parser('assemble')
    prepare.add_argument('--version', required=True)
    prepare.add_argument('--repository', required=True)
    prepare.add_argument('--artifacts', type=Path, required=True)
    prepare.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    (archive if args.command == 'archive' else assemble)(args)


if __name__ == '__main__':
    main()
