// Reverse proxy in front of the DeepSeek Harness web server.
//
// WHY THIS EXISTS AT ALL
//
// DSH refuses to bind 0.0.0.0, enforced in two independent places:
//
//   1. CLI  -- packages/bundle/web-app/src/startup.ts:95-97
//      `--host 0.0.0.0` is rejected with "unspecified (wildcard) address".
//   2. Config -- packages/host/webserver/src/index.ts:360-364
//      The webserver plugin schema throws for a wildcard host at load time.
//
// Point 2 is the reason this is a proxy and not a patch: patching the CLI flag
// would still hit the schema rejection. Upstream's stated reason is sound --
// the web UI grants remote code execution, so binding every interface would
// expose that to the whole network with no authentication of its own.
//
// So DSH keeps its default loopback bind, and this process is the single
// inbound door.
//
// THE TWO FENCES A NAIVE PROXY FAILS
//
//   A. The /api Host fence -- packages/client/connection/src/api-request-trust.ts:121-176
//      A request is accepted when its Host is loopback, matches `trustedHosts`,
//      or equals the listener's bind address. `sec-fetch-site: cross-site` is
//      refused, and when an Origin is present it must equal the Host.
//
//      Note what that last clause compares: Origin against Host -- NOT against
//      the upstream target. So the correct move is to leave BOTH headers exactly
//      as the browser sent them. `changeOrigin` defaults to false here on
//      purpose: in http-proxy it rewrites only `Host`
//      (node-http-proxy/lib/http-proxy/common.js:99-104) and never touches
//      `Origin`, so turning it on would desynchronise the pair and trip the
//      fence.
//
//   B. The browser session cookie is authority-bound --
//      packages/client/connection/src/browser-auth.ts:78-84,116,173-178
//      The cookie name is a hash of the request authority (host:port) and the
//      payload must carry a matching authority. A session minted for
//      127.0.0.1:3080 is therefore useless at 192.168.1.5:3080. That is why
//      serveIndex() trades the launch token for a per-authority cookie.
//
// TWO BROWSER SHIMS
//
//   - crypto.randomUUID polyfill. The DSH frontend calls it to mint RPC ids,
//     but it only exists in secure contexts. Reaching the UI over a LAN IP is
//     not a secure context, so the API is missing, RPC ids never get created,
//     and the realtime channel stays pending forever.
//   - `isLoopbackHostname(pageLocation.hostname)` forced to true. The frontend
//     hides settings/plugin features when it thinks the page is remote; this
//     proxy is the only way in, so a non-loopback hostname is always expected.
'use strict';

const http = require('http');
const httpProxy = require('http-proxy');
const crypto = require('crypto');

const { serveIndex, injectIntoHead } = require('./upstream-token.js');
const { attachBodyTransform } = require('./compression.js');

const DSH_PORT = Number(process.env.DSH_PORT) || 3079;
const LISTEN_PORT = Number(process.env.PROXY_PORT) || 3080;
const LISTEN_HOST = process.env.PROXY_BIND || '0.0.0.0';
const TARGET_ORIGIN = `http://127.0.0.1:${DSH_PORT}`;
const AUTH_REALM = 'dsh-web';

// Basic Auth is enabled only when BOTH are set; an empty pair means open access.
const AUTH_USER = process.env.PROXY_USERNAME || '';
const AUTH_PASS = process.env.PROXY_PASSWORD || '';
const AUTH_ENABLED = Boolean(AUTH_USER && AUTH_PASS);

// Static PWA assets a browser fetches WITHOUT credentials (a manifest <link>
// has no crossorigin="use-credentials"), so requiring auth there only produces
// console 401 noise. Pages, API routes, and WebSocket upgrades still authenticate.
const PUBLIC_PATHS = new Set(['/manifest.webmanifest', '/favicon.svg', '/favicon.ico']);

// Authorities this proxy serves. Empty means "no host check": DSH's own trust
// fence still guards /api, and the page itself is reachable at any Host.
//
// DSH only applies its trust fence to /api, so the page, the asset bundles and
// the WebSocket upgrades are served to any Host header. That is not an
// authentication hole on its own, but it does mean a hostname pointed at this
// server gets a working UI. When this list is set, every request -- not just
// /api -- must match one of them.
//
// Loopback is always allowed. It cannot be reached by DNS rebinding, and it is
// how the container healthcheck and the smoke test probe the proxy.
const TRUSTED_HOSTS = new Set(
  (process.env.DSH_TRUSTED_HOSTS || '')
    .split(',')
    .map((entry) => entry.trim().toLowerCase())
    // Tolerate a pasted URL, matching entrypoint.sh's behaviour.
    .map((entry) => (entry.includes('://') ? entry.slice(entry.indexOf('://') + 3) : entry))
    .map((entry) => entry.split('/')[0])
    .filter(Boolean),
);

// The allowance covers the listener itself: 127.0.0.1:<port>, localhost:<port>,
// [::1]:<port>. Compared with any port stripped, so an unusual port is fine.
const LOOPBACK_HOSTNAMES = new Set(['127.0.0.1', 'localhost', '[::1]', '::1', '0.0.0.0']);

function hostnameOf(hostHeader) {
  if (!hostHeader) return '';
  // Strip a port, keeping an IPv6 literal's brackets intact.
  if (hostHeader.startsWith('[')) {
    const end = hostHeader.indexOf(']');
    return end === -1 ? hostHeader.toLowerCase() : hostHeader.slice(0, end + 1).toLowerCase();
  }
  return hostHeader.split(':')[0].toLowerCase();
}

// Whether a request's authority may be served at all.
function checkHost(req) {
  if (TRUSTED_HOSTS.size === 0) return true;

  const host = String(req.headers.host || '').toLowerCase();
  if (!host) return false;

  if (LOOPBACK_HOSTNAMES.has(hostnameOf(host))) return true;
  if (TRUSTED_HOSTS.has(host)) return true;

  // A configured entry without a port also matches that host on any port; a
  // browser adds :8080 and would otherwise be refused for it.
  const hostname = hostnameOf(host);
  for (const entry of TRUSTED_HOSTS) {
    if (!entry.includes(':') && entry === hostname) return true;
  }
  return false;
}

function rejectHost(res) {
  // 421 Misdirected Request: the request reached a server that does not serve
  // this authority. It leaks less than describing the allowed set.
  res.writeHead(421, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end('421 Misdirected Request');
}

function rejectUpgradeHost(socket) {
  socket.end('HTTP/1.1 421 Misdirected Request\r\nConnection: close\r\n\r\n');
}

function safeEqual(a, b) {
  const left = Buffer.from(String(a));
  const right = Buffer.from(String(b));
  return left.length === right.length && crypto.timingSafeEqual(left, right);
}

function checkAuth(req) {
  if (!AUTH_ENABLED) return true;
  const match = /^Basic\s+(.+)$/i.exec(req.headers.authorization || '');
  if (!match) return false;

  let decoded;
  try {
    decoded = Buffer.from(match[1], 'base64').toString('utf8');
  } catch {
    return false;
  }

  const separator = decoded.indexOf(':');
  if (separator === -1) return false;
  return (
    safeEqual(decoded.slice(0, separator), AUTH_USER) &&
    safeEqual(decoded.slice(separator + 1), AUTH_PASS)
  );
}

function rejectUnauthorized(res) {
  res.writeHead(401, {
    'WWW-Authenticate': `Basic realm="${AUTH_REALM}"`,
    'Content-Type': 'text/plain; charset=utf-8',
  });
  res.end('401 Unauthorized');
}

function rejectUpgrade(socket) {
  socket.end(
    `HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm="${AUTH_REALM}"\r\nConnection: close\r\n\r\n`,
  );
}

// The shim must survive a non-secure context, so it builds ids from
// getRandomValues (available outside secure contexts) rather than randomUUID.
const RANDOM_UUID_POLYFILL =
  '<script>(function(){try{' +
  'if(typeof crypto!=="undefined"&&crypto&&typeof crypto.randomUUID!=="function"){' +
  'crypto.randomUUID=function(){' +
  'var b=crypto.getRandomValues(new Uint8Array(16));' +
  'b[6]=(b[6]&15)|64;b[8]=(b[8]&63)|128;' +
  'var h="";for(var i=0;i<16;i++){h+=b[i].toString(16).padStart(2,"0")}' +
  'return h.slice(0,8)+"-"+h.slice(8,12)+"-"+h.slice(12,16)+"-"+h.slice(16,20)+"-"+h.slice(20)' +
  '}}}catch(e){}})();</script>';

const LOOPBACK_NEEDLE = 'isLoopbackHostname(pageLocation.hostname)';
const LOOPBACK_REPLACEMENT = 'true';

const proxy = httpProxy.createProxyServer({
  target: TARGET_ORIGIN,
  ws: true,
  // Deliberately false -- see the fence notes at the top of this file.
  changeOrigin: false,
  // Keep the browser's Host header for the same reason.
  preserveHeaderKeyCase: true,
});

// Without an error listener, http-proxy throws and takes the whole process
// down whenever upstream is restarting. Answer 502 instead, and fail the
// WebSocket case by destroying the socket.
proxy.on('error', (err, req, res) => {
  console.error(
    `[proxy] upstream ${TARGET_ORIGIN} failed: ${err.code || err.message}`,
  );
  if (res && typeof res.writeHead === 'function') {
    if (res.headersSent) {
      res.end();
    } else {
      res.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('502 Bad Gateway: upstream DSH is unreachable or has exited');
    }
    return;
  }
  if (res && typeof res.destroy === 'function') {
    res.destroy();
  }
});

proxy.on('proxyRes', (proxyRes, req, res) => {
  const contentType = String(proxyRes.headers['content-type'] || '');
  const isHtml = contentType.includes('text/html');
  const isJs = contentType.includes('javascript');
  if (!isHtml && !isJs) return;

  // Upstream compresses (gzip by default), so rewrite through the
  // decompress/recompress pipeline rather than on the raw bytes.
  attachBodyTransform(res, proxyRes, (plain) => {
    const text = plain.toString('utf8');

    if (isHtml) {
      return Buffer.from(injectIntoHead(text, RANDOM_UUID_POLYFILL));
    }

    // JS: rewrite only when the target expression is actually present, so
    // unrelated bundles pass through with no recompression cost.
    if (text.includes(LOOPBACK_NEEDLE)) {
      return Buffer.from(text.split(LOOPBACK_NEEDLE).join(LOOPBACK_REPLACEMENT));
    }
    return null;
  });
});

// Resolve the request path, falling back to '/' rather than throwing: a
// malformed request-target must not take the process down.
function requestPathname(rawUrl) {
  try {
    return new URL(rawUrl || '/', 'http://proxy').pathname;
  } catch {
    return '/';
  }
}

const server = http.createServer((req, res) => {
  const pathname = requestPathname(req.url);

  // Host before auth: an authority this proxy does not serve gets no hint about
  // whether credentials would have helped.
  if (!checkHost(req)) {
    console.warn(`[proxy] refused host ${JSON.stringify(req.headers.host)} for ${pathname}`);
    rejectHost(res);
    return;
  }

  if (!PUBLIC_PATHS.has(pathname) && !checkAuth(req)) {
    rejectUnauthorized(res);
    return;
  }

  // Root GET may need the launch-token exchange; anything else is a plain forward.
  if (req.method === 'GET' && pathname === '/') {
    serveIndex(req, res, {
      origin: TARGET_ORIGIN,
      transformHtml: (html) => injectIntoHead(html, RANDOM_UUID_POLYFILL),
    })
      .then((handled) => {
        if (handled) return;
        proxy.web(req, res);
      })
      .catch((err) => {
        console.error(`[proxy] root handler failed: ${err && err.message}`);
        proxy.web(req, res);
      });
    return;
  }

  proxy.web(req, res);
});

server.on('upgrade', (req, socket, head) => {
  if (!checkHost(req)) {
    console.warn(`[proxy] refused host ${JSON.stringify(req.headers.host)} for upgrade`);
    rejectUpgradeHost(socket);
    return;
  }
  if (!checkAuth(req)) {
    rejectUpgrade(socket);
    return;
  }
  proxy.ws(req, socket, head);
});

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
  console.log(
    `[proxy] listening on ${LISTEN_HOST}:${LISTEN_PORT} -> ${TARGET_ORIGIN}` +
      (AUTH_ENABLED ? ' (Basic Auth enabled)' : ' (auth disabled)'),
  );
  console.log(
    TRUSTED_HOSTS.size
      ? `[proxy] serving hosts: ${[...TRUSTED_HOSTS].join(', ')} (+ loopback)`
      : '[proxy] host check disabled (DSH_TRUSTED_HOSTS empty)',
  );
});

function shutdown(signal) {
  console.log(`[proxy] received ${signal}, closing listener`);
  server.close(() => process.exit(0));
  // Do not let a hung connection block container shutdown.
  setTimeout(() => process.exit(0), 5000).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
