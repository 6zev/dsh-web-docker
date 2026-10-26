// Upstream launch-token handling for the DSH web session.
//
// Background (verified in @deepseek-ai/dsh-client-connection/src/browser-auth.ts):
//   - `requestAudience` is built from the request Host, and the browser cookie
//     name is a hash of that audience (`cookieName(authority)`), while the
//     cookie payload must carry a matching `authority`.
//   - The session cookie is therefore bound to host:port. A cookie issued for
//     `127.0.0.1:3080` is not accepted for `192.168.1.5:3080`.
//
// Consequence: users reaching the UI from a different authority than the one
// DSH printed need their own session. The launch token is the currency for
// that: a root GET carrying `?token=<launch-token>` is exchanged for a fresh
// session cookie scoped to whatever authority made the request.
//
// Design constraints:
//   - The token is scraped from the DSH log, not forged. Multiple instances or
//     restarts each print their own; the LAST match wins because later lines are
//     newer.
//   - The token is injected ONLY on a 401 retry of the root document. Attaching
//     it to every request would make upstream mint a new identity per request.
//   - The retry strips the browser's cookie: the exchange creates a brand-new
//     session, and a stale cookie can make upstream reject the retry outright.
'use strict';

const fs = require('fs');
const http = require('http');

const LOG_FILE = process.env.DSH_WEB_LOG || '/root/.dsh-web.log';
const TOKEN_FILE_AUTO = process.env.DSH_TOKEN_FILE_AUTO || '/root/.dsh-launch-token';
const TOKEN_QUERY_KEY = process.env.DSH_TOKEN_QUERY_KEY || 'token';

const HARD_TOKEN = process.env.DSH_TOKEN || '';
const HARD_TOKEN_FILE = process.env.DSH_TOKEN_FILE || '';

let customPattern = null;
if (process.env.DSH_LAUNCH_TOKEN_PATTERN) {
  try {
    customPattern = new RegExp(process.env.DSH_LAUNCH_TOKEN_PATTERN);
  } catch {
    console.warn('[upstream-token] DSH_LAUNCH_TOKEN_PATTERN is not a valid regex; ignoring it');
  }
}

// Smallest token shape worth trusting: 16+ URL-safe characters after a
// `token=`/`token:` marker, in a query string, comma list, or start of line.
const DEFAULT_TOKEN_PATTERN = /(?:[?&,]|^)token[=:]\s*["']?([A-Za-z0-9._~-]{16,})/i;

const SCAN_INTERVAL_MS = 2000;
const MAX_SCAN_ATTEMPTS = 30;
const LOG_TAIL_BYTES = 512 * 1024;

const state = {
  token: '',
  source: null,
  scanning: false,
  attempts: 0,
  done: false,
};

function readTail(path, maxBytes) {
  try {
    const stat = fs.statSync(path);
    if (!stat.size) return '';
    const start = Math.max(0, stat.size - maxBytes);
    const fd = fs.openSync(path, 'r');
    const buffer = Buffer.alloc(stat.size - start);
    fs.readSync(fd, buffer, 0, buffer.length, start);
    fs.closeSync(fd);
    return buffer.toString('utf8');
  } catch {
    return '';
  }
}

// Last match in `text`, so a restart's newer token beats an older one.
function lastMatch(text, regex) {
  let scanner;
  try {
    scanner = new RegExp(regex.source, regex.flags.includes('g') ? regex.flags : regex.flags + 'g');
  } catch {
    return null;
  }
  let last = null;
  let match;
  while ((match = scanner.exec(text)) !== null) {
    last = match;
    if (match[0] === '') scanner.lastIndex += 1;
  }
  return last;
}

// Enough to correlate log lines, not enough to be a usable credential.
function maskToken(token) {
  const text = String(token || '');
  if (!text) return '(empty)';
  if (text.length <= 8) return text.slice(0, 1) + '****';
  return text.slice(0, 4) + '****' + text.slice(-4);
}

function extractFromText(text) {
  if (customPattern) {
    const match = lastMatch(text, customPattern);
    if (match) return (match[1] !== undefined ? match[1] : match[0]).trim();
  }
  const match = lastMatch(text, DEFAULT_TOKEN_PATTERN);
  return match ? match[1] : null;
}

function scanLogOnce() {
  const token = extractFromText(readTail(LOG_FILE, LOG_TAIL_BYTES));
  if (!token) return null;
  const trimmed = token.trim();
  try {
    fs.writeFileSync(TOKEN_FILE_AUTO, trimmed);
  } catch {
    // Non-fatal: the token is still held in memory.
  }
  state.token = trimmed;
  state.source = 'auto';
  state.done = true;
  console.log(`[upstream-token] captured launch token from ${LOG_FILE} (${trimmed.length} chars)`);
  return trimmed;
}

function readConfiguredToken() {
  if (HARD_TOKEN) return HARD_TOKEN;
  if (HARD_TOKEN_FILE) {
    try {
      return fs.readFileSync(HARD_TOKEN_FILE, 'utf8').trim();
    } catch {
      return '';
    }
  }
  return '';
}

// Resolve the token, polling the log in the background if it is not there yet
// (DSH may still be starting). Returns '' when nothing is available; callers
// must treat that as "skip the retry", not as an error.
function ensureToken() {
  if (state.done && state.token) return state.token;

  const configured = readConfiguredToken();
  if (configured) {
    state.token = configured;
    state.source = 'manual';
    state.done = true;
    return configured;
  }

  const fromLog = scanLogOnce();
  if (fromLog) return fromLog;

  if (state.scanning) return state.token;
  if (state.attempts >= MAX_SCAN_ATTEMPTS) {
    state.done = true;
    return '';
  }

  state.scanning = true;
  const timer = setInterval(() => {
    const found = scanLogOnce();
    state.attempts += 1;
    if (found || state.attempts >= MAX_SCAN_ATTEMPTS) {
      clearInterval(timer);
      state.scanning = false;
      state.done = true;
    }
  }, SCAN_INTERVAL_MS);
  timer.unref();
  return state.token;
}

// Inject a snippet right after the opening <head>, or at the very start when
// there is no head tag.
function injectIntoHead(content, snippet) {
  const headAt = content.toLowerCase().indexOf('<head');
  if (headAt !== -1) {
    const tagEnd = content.indexOf('>', headAt);
    if (tagEnd !== -1) {
      return content.slice(0, tagEnd + 1) + snippet + content.slice(tagEnd + 1);
    }
    return snippet + content;
  }
  return snippet + content;
}

const FORWARD_HEADERS = [
  'accept',
  'accept-language',
  'user-agent',
  'cookie',
  'referer',
  'sec-fetch-dest',
  'sec-fetch-mode',
  'sec-fetch-site',
  'sec-ch-ua',
  'sec-ch-ua-mobile',
  'sec-ch-ua-platform',
];

// Headers forwarded when re-issuing the root document.
//
// `host` is forwarded deliberately and is the whole reason the session works
// behind this proxy. DSH derives the cookie's audience from the Host it sees
// (`requestAudience` in browser-auth.ts reads only `headers.host`, and the same
// file states that a forwarded header is never consulted). If we handed
// upstream the literal `127.0.0.1:3079`, it would mint a cookie whose
// `authority` is `127.0.0.1:3079`; the browser then uses it against
// `example.com` and DSH rejects it on every request, so the page would
// re-exchange the launch token forever.
//
// Forwarding the client's Host makes the minted cookie carry the authority the
// browser actually uses. The socket still goes to loopback, so this is a header
// change only -- it does not widen what upstream listens on.
function pickIndexHeaders(req, dropCookie) {
  const source = req.headers || {};
  const out = { accept: '*/*', 'accept-encoding': 'identity' };
  for (const name of FORWARD_HEADERS) {
    if (dropCookie && name === 'cookie') continue;
    if (source[name]) out[name] = source[name];
  }
  if (source.host) out.host = source.host;
  return out;
}

// Follow one same-origin redirect from the token exchange, carrying the session
// cookie it just issued. Returns null (caller relays the redirect as-is) when
// the status is not a redirect, the Location is off-origin, or the hop fails.
async function followRedirect(origin, response, baseHeaders) {
  if (response.status < 300 || response.status >= 400) return null;

  const location = response.headers.location;
  if (!location) return null;

  let target;
  try {
    target = new URL(location, origin + '/');
  } catch {
    return null;
  }

  // Only same-origin hops: this proxy must never become an open redirector,
  // and the cookie we hold is scoped to upstream anyway.
  if (target.origin !== origin) return null;

  const headers = { ...baseHeaders };
  const cookies = response.setCookies
    .map((entry) => String(entry).split(';')[0].trim())
    .filter(Boolean);
  if (cookies.length) headers.cookie = cookies.join('; ');

  // Drop the credentials segment of the URL so it is not echoed back.
  headers.referer = origin + '/';

  try {
    const page = await fetchIndex(origin, headers, target.pathname + target.search);
    console.log(`[upstream-token] followed ${response.status} -> ${target.pathname} (${page.status})`);
    if (page.status !== 200) return null;
    return page;
  } catch {
    return null;
  }
}

// Issue a GET to upstream, preserving a caller-supplied `Host` header.
//
// `fetch` cannot be used here: it silently drops a `host` entry from the
// request headers and writes the URL's own authority instead (verified against
// a local listener -- asking for `host: example.com` arrives as the target).
// That matters because DSH mints the session cookie's audience from the Host it
// receives, so a loopback Host produces a cookie the browser can never use.
// `http.request` sends whatever Host it is given, so this path uses it.
function fetchIndex(origin, headers, path) {
  return new Promise((resolve, reject) => {
    const target = new URL(
      path && path !== '/' ? origin + path : origin + '/',
    );

    const request = http.request(
      {
        protocol: target.protocol,
        hostname: target.hostname,
        port: target.port,
        path: target.pathname + target.search,
        method: 'GET',
        headers,
      },
      (response) => {
        const chunks = [];
        response.on('data', (chunk) => chunks.push(chunk));
        response.on('error', reject);
        response.on('end', () => {
          resolve({
            status: response.statusCode || 0,
            headers: response.headers,
            setCookies: response.headers['set-cookie'] || [],
            body: Buffer.concat(chunks).toString('utf8'),
          });
        });
      },
    );

    request.on('error', reject);
    request.end();
  });
}

// Relay an upstream response, preserving Set-Cookie so the browser can
// establish its authority-scoped session.
//
// Upstream headers arrive as Node's plain object (lowercased keys). One entry
// per name is emitted, so a header can never appear twice on the wire -- an
// earlier version appended a second Content-Type after already copying it.
function sendIndex(response, res, transformHtml) {
  const headers = {};

  const skip = new Set([
    'content-length',
    'content-encoding',
    'connection',
    'transfer-encoding',
    'keep-alive',
    'upgrade',
    'set-cookie',
  ]);

  for (const key of Object.keys(response.headers)) {
    const lower = key.toLowerCase();
    if (skip.has(lower)) continue;
    headers[lower === 'content-type' ? 'Content-Type' : key] = response.headers[key];
  }

  headers['Cache-Control'] = headers['Cache-Control'] || 'no-store';
  if (response.setCookies.length) headers['Set-Cookie'] = response.setCookies;

  let body = response.body;
  const contentType = String(response.headers['content-type'] || '').toLowerCase();
  if (contentType.includes('text/html') && transformHtml) body = transformHtml(body);

  // Empty bodies (e.g. a 303) must not claim a text/html type.
  if (body && body.length) {
    headers['Content-Type'] = contentType || 'text/html; charset=utf-8';
  }

  res.writeHead(response.status, headers);
  res.end(body);
}

// Handle a root GET. Normally this is a plain forward; when upstream answers
// 401 the launch token is used once to trade for a session cookie, and the
// resulting Set-Cookie is relayed to the browser.
//
// Returns true when the response was written, false when the caller should fall
// back to the ordinary proxy path.
async function serveIndex(req, res, context) {
  const { origin, transformHtml } = context;
  const requestUrl = req.url || '/';

  let first;
  try {
    first = await fetchIndex(origin, pickIndexHeaders(req), requestUrl);
  } catch {
    return false;
  }

  if (first.status === 401) {
    const token = ensureToken();
    if (token) {
      console.log(
        `[upstream-token] root returned 401; retrying with launch token (${maskToken(token)})`,
      );
      const separator = requestUrl.includes('?') ? '&' : '?';
      const authUrl = `${requestUrl}${separator}${TOKEN_QUERY_KEY}=${encodeURIComponent(token)}`;

      let retry = null;
      try {
        // A fresh session: the browser's old cookie must not participate.
        retry = await fetchIndex(origin, pickIndexHeaders(req, true), authUrl);
      } catch {
        retry = null;
      }

      if (retry) {
        if (retry.status === 401) {
          console.warn(
            `[upstream-token] token exchange failed (still 401); token ${maskToken(token)} may be stale`,
          );
          sendIndex(retry, res, transformHtml);
          return true;
        }

        console.log(
          `[upstream-token] token exchange -> ${retry.status}, ${retry.setCookies.length} cookie(s)`,
        );

        // A successful exchange answers 303 to a clean URL (session is now in
        // the Set-Cookie). Relaying that redirect to the browser works, but it
        // costs a second round trip and makes every "$ curl /" look like a
        // redirect. Follow it here with the cookie we were just handed, so the
        // caller gets the real page and its session in one response.
        const followed = await followRedirect(
          origin,
          retry,
          pickIndexHeaders(req, true),
        );

        if (followed) {
          // Cookie came from the exchange; page came from the follow-up.
          followed.setCookies = retry.setCookies;
          sendIndex(followed, res, transformHtml);
          return true;
        }

        sendIndex(retry, res, transformHtml);
        return true;
      }
      console.warn('[upstream-token] token retry failed upstream; relaying the original 401');
    } else {
      console.log('[upstream-token] no launch token available; relaying the original 401');
    }
  } else if (first.status !== 200) {
    console.log(`[upstream-token] root returned ${first.status}; relaying as-is`);
  }

  sendIndex(first, res, transformHtml);
  return true;
}

module.exports = {
  serveIndex,
  ensureToken,
  injectIntoHead,
};
