'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const MINIMAL_PATH = '/usr/bin:/bin:/usr/sbin:/sbin';
const TARGETS = { 'darwin-arm64': 'aarch64-apple-darwin', 'darwin-x64': 'x86_64-apple-darwin', 'linux-x64': 'x86_64-unknown-linux-gnu' };

function withPackage(fn) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'quotio-npm-'));
  try {
    const pkg = path.join(dir, 'lib/node_modules/quotio');
    fs.mkdirSync(path.join(pkg, 'bin'), { recursive: true });
    fs.copyFileSync(path.join(__dirname, 'npm/bin/quotio'), path.join(pkg, 'bin/quotio'));
    fs.chmodSync(path.join(pkg, 'bin/quotio'), 0o755);
    const native = path.join(pkg, 'native', TARGETS[`${process.platform}-${process.arch}`]);
    fs.mkdirSync(native, { recursive: true });
    fs.writeFileSync(path.join(native, 'quotio'), '#!/bin/sh\nprintf "%s\\n" "$@"\ncat <&3 2>/dev/null || true\nexit 7\n', { mode: 0o755 });
    fs.mkdirSync(path.join(dir, 'bin'));
    fs.symlinkSync('../lib/node_modules/quotio/bin/quotio', path.join(dir, 'bin/quotio'));
    fn(path.join(dir, 'bin/quotio'), dir);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

test('run through a global-install symlink without node on PATH', () => {
  withPackage(launcher => {
    const result = spawnSync(launcher, ['two words', ';literal'], { encoding: 'utf8', env: { PATH: MINIMAL_PATH } });
    assert.equal(result.status, 7);
    assert.equal(result.stdout, 'two words\n;literal\n');
  });
});
test('forward inherited file descriptors to the native binary', () => {
  withPackage((launcher, dir) => {
    fs.writeFileSync(path.join(dir, 'key'), 'secret');
    const fd = fs.openSync(path.join(dir, 'key'), 'r');
    try {
      const result = spawnSync(launcher, [], { encoding: 'utf8', env: { PATH: MINIMAL_PATH }, stdio: ['ignore', 'pipe', 'pipe', fd] });
      assert.equal(result.stdout, '\nsecret');
    } finally { fs.closeSync(fd); }
  });
});
test('reject unsupported platforms', () => {
  withPackage((launcher, dir) => {
    fs.mkdirSync(path.join(dir, 'fake'));
    fs.writeFileSync(path.join(dir, 'fake/uname'), '#!/bin/sh\n[ "$1" = -s ] && echo Linux || echo aarch64\n', { mode: 0o755 });
    const result = spawnSync(launcher, [], { encoding: 'utf8', env: { PATH: `${dir}/fake:${MINIMAL_PATH}` } });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /supports macOS arm64\/x64 and Linux x64/);
  });
});
