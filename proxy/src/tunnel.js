// How rigs in another building reach this proxy.
//
// The four options are not equivalent and the code says so instead of pretending
// they are one thing with a type flag:
//
//   wireguard  the proxy host is a WireGuard server. Every rig is a peer with a
//              fixed private address (10.66.66.x). UDP, kernel-space, no third
//              party, no bandwidth cap, latency is the raw path. This is the
//              default recommendation, and the only one that carries raw
//              stratum *and* the dashboard with no surprises.
//
//   tailscale  WireGuard with a coordination server. No port forwarding, NAT
//              traversal included. Funnel (public ingress) is TLS-only on
//              443/8443/10000 and has an unpublished bandwidth cap -- fine for a
//              stratum JSON stream, wrong for anything chatty. Free plan is
//              non-commercial, so a farm earning money is outside its terms.
//
//   cf-quick   `cloudflared tunnel --url`: a random *.trycloudflare.com name
//              that changes on every restart, 200 concurrent requests, no auth,
//              indexable, explicitly not for production. Useful to prove a path
//              works in two minutes. Never as the only way in.
//
//   cf         a named Cloudflare tunnel with a token. Stable hostname, access
//              control, and the only Cloudflare option worth running daily.
//              Carries WebSocket (--ws) but not raw stratum TCP.
//
// Nothing here installs software. A tunnel that silently pulled a binary from
// the internet into a miner host would be a supply-chain hole in a machine
// holding a wallet.

'use strict';

const { execFileSync, spawn } = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const WG_NET = '10.66.66';
const WG_PORT = 51820;

/** WireGuard server + peer configuration for `rigs` peers. Pure: keys are
 *  arguments, so this is testable without touching the host's networking. */
function wireguardConfig({ rigs = 1, endpoint = '203.0.113.10', port = WG_PORT, serverKeys, peerKeys, net = WG_NET }) {
  if (!Array.isArray(peerKeys) || peerKeys.length < rigs) throw new Error(`peerKeys: need ${rigs} key pairs, got ${Array.isArray(peerKeys) ? peerKeys.length : 0}`);
  if (!serverKeys?.private || !serverKeys?.public) throw new Error('serverKeys.private and .public are required');

  const peers = [];

  for (let index = 0; index < rigs; index++) {
    const address = `${net}.${index + 2}`;      // .1 is the server
    const keys = peerKeys[index];

    peers.push({
      name: `rig-${index + 1}`,
      address,
      publicKey: keys.public,
      privateKey: keys.private,
      // What the operator drops into /etc/wireguard/ocean.conf on the rig.
      client: [
        '[Interface]',
        `PrivateKey = ${keys.private}`,
        `Address = ${address}/32`,
        'DNS = 1.1.1.1',
        '',
        '[Peer]',
        `PublicKey = ${serverKeys.public}`,
        `Endpoint = ${endpoint}:${port}`,
        `AllowedIPs = ${net}.0/24`,
        'PersistentKeepalive = 25',
        '',
      ].join('\n'),
    });
  }

  const server = [
    '[Interface]',
    `Address = ${net}.1/24`,
    `ListenPort = ${port}`,
    `PrivateKey = ${serverKeys.private}`,
    '# NAT so peers can reach the proxy without extra routing on the host.',
    `PostUp = iptables -t nat -A POSTROUTING -s ${net}.0/24 -o %i -j MASQUERADE; sysctl -w net.ipv4.ip_forward=1`,
    'PostDown = iptables -t nat -D POSTROUTING -s ${net}.0/24 -o %i -j MASQUERADE',
    '',
  ].join('\n');

  const peerBlocks = peers.map((peer) => [`# ${peer.name}`, '[Peer]', `PublicKey = ${peer.publicKey}`, `AllowedIPs = ${peer.address}/32`, ''].join('\n'));

  return {
    server: server + peerBlocks.join('\n'),
    peers,
    listen: `${net}.1`,
    port,
  };
}

/** Generates real keys with `wg`, which is the only trustworthy way to do it
 *  (a hand-rolled curve25519 in JavaScript would be a second implementation to
 *  audit). */
function generateKeys(count = 1) {
  const pairs = [];

  for (let index = 0; index < count; index++) {
    const priv = execFileSync('wg', ['genkey'], { encoding: 'utf8' }).trim();
    const pub = execFileSync('wg', ['pubkey'], { input: priv, encoding: 'utf8' }).trim();
    pairs.push({ private: priv, public: pub });
  }

  return pairs;
}

function publicEndpoint() {
  // Best effort and clearly labelled: an operator almost always knows their own
  // public address better than a third-party echo service does.
  for (const url of ['https://api.ipify.org', 'https://ifconfig.me/ip']) {
    try {
      const out = execFileSync('curl', ['-fsS', '--max-time', '3', url], { encoding: 'utf8' }).trim();
      if (/^\d+\.\d+\.\d+\.\d+$/.test(out)) return out;
    } catch (_) { /* offline is normal */ }
  }

  return null;
}

/** Writes the server config and one file per rig into `directory`. */
function writeWireguard(directory, options) {
  const conf = wireguardConfig(options);
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });

  const serverPath = path.join(directory, 'ocean-proxy.conf');
  fs.writeFileSync(serverPath, conf.server, { mode: 0o600 });

  for (const peer of conf.peers) {
    fs.writeFileSync(path.join(directory, `${peer.name}.conf`), peer.client, { mode: 0o600 });
  }

  fs.writeFileSync(path.join(directory, 'INSTALL.txt'), [
    'WireGuard setup for the ZMRIG proxy',
    '',
    'On this machine (the proxy):',
    '  sudo apt install wireguard-tools',
    `  sudo cp ${serverPath} /etc/wireguard/ocean-proxy.conf`,
    '  sudo systemctl enable --now wg-quick@ocean-proxy',
    '',
    'On each rig (copy that rig\'s file, one file per rig -- never reuse one):',
    '  sudo cp rig-1.conf /etc/wireguard/ocean.conf',
    '  sudo systemctl enable --now wg-quick@ocean',
    '',
    `Then point the miner at ${conf.listen}:3333 on the proxy.`,
    'Check with: ping 10.66.66.1   (from the rig)',
    '',
  ].join('\n'), { mode: 0o600 });

  return { serverPath, ...conf };
}

// --- runtime orchestration -------------------------------------------------

/** Starts whatever the tunnel needs and returns { info, stop }. */
async function startTunnel(config, { logger, log }) {
  if (config.tunnel === 'none') return { info: [], stop: async () => {} };

  if (config.tunnel === 'wireguard') {
    const directory = config.tunnelDir || path.join(process.cwd(), 'wg');

    try {
      const state = execFileSync('wg', ['show', 'interfaces'], { encoding: 'utf8' }).trim();
      const up = state.split(/\s+/).filter(Boolean);
      const ours = up.find((name) => name.startsWith('ocean')) || null;

      if (!ours) {
        return {
          info: [
            'WireGuard keys are needed before the proxy address exists.',
            `Run once:  sudo zmrig-proxy tunnel wireguard --rigs=<how many rigs> --dir=${directory}`,
            'Then start again. Rigs will be reachable at 10.66.66.1:3333.',
          ],
          stop: async () => {},
        };
      }

      const address = execFileSync('wg', ['show', ours, 'addresses'], { encoding: 'utf8' }).trim() || '10.66.66.1';

      return {
        info: [`WireGuard interface ${ours} is up (${address}); rigs connect to ${address.split(/\s+/)[0]}:${config.port}`],
        stop: async () => {},
      };
    } catch (error) {
      return { info: [`WireGuard is not usable here: ${error.message}`], stop: async () => {} };
    }
  }

  if (config.tunnel === 'tailscale') {
    const info = [];

    if (config.tunnelToken) {
      try {
        execFileSync('tailscale', ['up', `--authkey=${config.tunnelToken}`, '--hostname=zmrig-proxy'], { stdio: 'ignore', timeout: 60_000 });
        info.push('tailscale: logged in with --tunnel-token');
      } catch (error) {
        info.push(`tailscale up failed: ${error.message}`);
      }
    }

    let dnsName = null;
    try {
      const status = JSON.parse(execFileSync('tailscale', ['status', '--json'], { encoding: 'utf8' }));
      dnsName = status.Self?.DNSName?.replace(/\.$/, '') || null;
    } catch (_) { /* not logged in */ }

    if (!dnsName) {
      return { info: [...info, 'tailscale is not logged in: run `tailscale up` first'], stop: async () => {} };
    }

    const target = config.ws ? config.wsPort : config.port;

    if (config.ws) {
      try {
        execFileSync('tailscale', ['funnel', '--bg', '443', `http://127.0.0.1:${target}`], { stdio: 'ignore', timeout: 30_000 });
        info.push(`funnel: wss://${dnsName}${config.wsPath}`);
      } catch (error) {
        info.push(`funnel failed (needs the funnel node attribute in the tailnet policy): ${error.message}`);
      }
    } else {
      // Tailscale itself is a private network: rigs in the tailnet reach the
      // raw stratum port with no funnel at all. This is the fast path.
      info.push(`tailnet: rigs on the same tailnet connect to ${dnsName}:${config.port} (no funnel needed)`);
    }

    info.push('funnel is TLS-only on 443/8443/10000 and its bandwidth is capped without publication; use it for the stratum stream, not for polling a dashboard.');
    info.push('the free Tailscale plan is licensed for non-commercial use.');

    return { info, stop: async () => {} };
  }

  // Cloudflare: quick (no account) and named (token).
  const target = config.wsPort || config.port + 1;
  const args = config.tunnel === 'cf-quick'
    ? ['tunnel', '--url', `http://127.0.0.1:${target}`, '--no-autoupdate']
    : ['tunnel', '--no-autoupdate', 'run', ...(config.tunnelToken ? ['--token', config.tunnelToken] : [])];

  const info = [];
  const child = spawn('cloudflared', args, { stdio: ['ignore', 'pipe', 'pipe'] });
  let address = null;

  const capture = (chunk) => {
    const text = chunk.toString('utf8');
    const match = text.match(/https:\/\/[a-z0-9-]+\.trycloudflare\.com/);
    if (match && !address) {
      address = match[0];
      info.push(`quick tunnel: ${address}`);
      log('warn', `quick tunnel ready at ${address} -- hostname dies with this process and has no authentication`);
    }
  };

  child.stdout.on('data', capture);
  child.stderr.on('data', capture);
  child.on('error', (error) => log('error', `cloudflared: ${error.message}`));

  await new Promise((resolve) => setTimeout(resolve, config.tunnel === 'cf-quick' ? 5000 : 3000));

  if (config.tunnel === 'cf' && config.tunnelHost) {
    info.push(`named tunnel: wss://${config.tunnelHost}${config.wsPath} (must be routed to this machine in the Cloudflare dashboard)`);
  }

  const warnings = config.tunnel === 'cf-quick'
    ? [
      'QUICK TUNNEL IS A DEMO, NOT A DEPLOYMENT:',
      '  * the hostname changes every restart, so rigs need editing every restart',
      '  * 200 concurrent requests, then 429',
      '  * no authentication unless you set --token, and this proxy is on the public internet',
      '  * indexed tunnels have appeared in search results',
      '  * Cloudflare states it is not for production use',
      'For a permanent setup run: zmrig-proxy tunnel wireguard   (fixed 10.66.66.x, no third party)',
    ]
    : [];

  return {
    info: [...info, ...warnings],
    stop: async () => {
      try { child.kill('SIGTERM'); } catch (_) {}
    },
  };
}

/** Random-but-stable identifier, useful as a tunnel name and a log prefix. */
function hostTag() {
  return crypto.createHash('sha256').update(require('node:os').hostname()).digest('hex').slice(0, 8);
}

module.exports = {
  WG_NET,
  WG_PORT,
  generateKeys,
  hostTag,
  publicEndpoint,
  startTunnel,
  wireguardConfig,
  writeWireguard,
};
