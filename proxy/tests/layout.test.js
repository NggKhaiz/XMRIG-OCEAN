// The proxy shares code with the pool (`pool/src/target.js` for the maths,
// `pool/src/util.js` for hex, `pool/src/ws.js` for the WebSocket server), and it
// is installed as a *copy* of two directories. That combination has one failure
// mode that no unit test can see: `proxy/src/main.js` starts fine in the
// repository and dies with MODULE_NOT_FOUND in /opt because the copy lost the
// relative path.
//
// This test reads every `require('./…')` and `require('../../…')` in src/ and
// checks it resolves, then repeats the check in a copied layout.

'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const SRC = path.join(__dirname, '..', 'src');
const FACILITY = path.join(__dirname, '..', '..');

function sources(directory = SRC) {
  return fs.readdirSync(directory)
    .filter((name) => name.endsWith('.js'))
    .map((name) => path.join(directory, name));
}

test('every relative require in proxy/src resolves', () => {
  for (const file of sources()) {
    const text = fs.readFileSync(file, 'utf8');

    for (const match of text.matchAll(/require\('(\.[^']+)'\)/g)) {
      const resolved = path.resolve(path.dirname(file), match[1]);

      assert.ok(
        fs.existsSync(resolved) || fs.existsSync(`${resolved}.js`),
        `${path.relative(FACILITY, file)} requires ${match[1]} which does not exist`,
      );
    }
  }
});

test('the installed layout -- two directories copied side by side -- still runs', (t) => {
  const prefix = fs.mkdtempSync(path.join(os.tmpdir(), 'zmrig-proxy-layout-'));
  t.after(() => fs.rmSync(prefix, { recursive: true, force: true }));

  // Exactly what install.sh does, minus the systemd part.
  fs.mkdirSync(path.join(prefix, 'proxy'), { recursive: true });
  fs.mkdirSync(path.join(prefix, 'pool'), { recursive: true });
  fs.cpSync(SRC, path.join(prefix, 'proxy', 'src'), { recursive: true });
  fs.cpSync(path.join(FACILITY, 'pool', 'src'), path.join(prefix, 'pool', 'src'), { recursive: true });

  const output = execFileSync(process.execPath, [path.join(prefix, 'proxy', 'src', 'main.js'), '--version'], { encoding: 'utf8' });
  assert.match(output, /zmrig-proxy \d+\.\d+\.\d+/);

  // And the modules that pull pool code actually load, not just the CLI.
  const loaded = execFileSync(process.execPath, ['-e', `
    require(${JSON.stringify(path.join(prefix, 'proxy', 'src', 'downstream.js'))});
    require(${JSON.stringify(path.join(prefix, 'proxy', 'src', 'server.js'))});
    process.stdout.write('ok');
  `], { encoding: 'utf8' });
  assert.strictEqual(loaded, 'ok');
});

test('install.sh is POSIX sh and refuses to run without a wallet', (t) => {
  const script = path.join(__dirname, '..', 'install.sh');
  assert.ok(fs.existsSync(script), 'install.sh exists');

  // `sh -n` parses without executing: catches a bashism in a #!/bin/sh script.
  execFileSync('sh', ['-n', script]);

  let failed = false;
  try {
    execFileSync('sh', [script, '--dry-run', '--pool=127.0.0.1:3333'], { stdio: 'pipe' });
  } catch (error) {
    failed = true;
    assert.match(String(error.stderr), /--user=<wallet> is required/);
  }

  assert.ok(failed, 'the installer must refuse to install without a wallet');
  assert.ok(fs.statSync(script).mode & 0o111, 'install.sh is executable');
});
