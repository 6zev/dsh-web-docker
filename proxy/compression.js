// Response-body pipeline: decompress -> rewrite -> recompress.
//
// Why this exists: the shipped `@deepseek-ai/dsh-web-app` bundle configures
// `compression: gzip` for the webserver (packages/bundle/web-app/cordis.patch.yml,
// `webserver` row). Every HTML/JS response therefore arrives as a gzip byte
// stream, and any string-based rewrite (HTML polyfill injection, the
// `isLoopbackHostname` replacement) can never match the compressed bytes.
//
// The alternative -- stripping Accept-Encoding so upstream returns plaintext --
// relies on the server honouring negotiation, and silently does nothing when it
// does not. Buffering and honouring the real encoding keeps the rewrite working
// regardless of what upstream chose.
//
// Degradation rules (a broken response is worse than an unrewritten one):
//   - unsupported encoding (e.g. zstd) or a decompress failure -> pass the
//     original bytes through untouched, Content-Encoding preserved;
//   - recompress failure after a rewrite -> send plaintext and drop
//     Content-Encoding, so the browser does not try to inflate it;
//   - identity -> rewrite in place, no compression overhead.
'use strict';

const zlib = require('zlib');

// First recognised token of Content-Encoding; empty/absent means identity.
function parseEncoding(contentEncoding) {
  if (!contentEncoding) return 'identity';
  const first = String(contentEncoding).split(',')[0].trim().toLowerCase();
  return first || 'identity';
}

// Buffer -> plaintext Buffer, or null when the encoding is unsupported or the
// payload is not actually valid for it.
function decompress(buffer, encoding) {
  if (!encoding || encoding === 'identity') return buffer;
  try {
    switch (encoding) {
      case 'gzip':
        return zlib.gunzipSync(buffer);
      case 'deflate':
        // Some servers send raw DEFLATE (RFC 1951) rather than the zlib wrapper.
        try {
          return zlib.inflateSync(buffer);
        } catch {
          return zlib.inflateRawSync(buffer);
        }
      case 'br':
        return zlib.brotliDecompressSync(buffer);
      default:
        return null;
    }
  } catch {
    return null;
  }
}

// Plaintext Buffer -> Buffer in the original encoding, or null on failure.
function recompress(buffer, encoding) {
  if (!encoding || encoding === 'identity') return buffer;
  try {
    switch (encoding) {
      case 'gzip':
        return zlib.gzipSync(buffer);
      case 'deflate':
        return zlib.deflateSync(buffer);
      case 'br':
        return zlib.brotliCompressSync(buffer);
      default:
        return null;
    }
  } catch {
    return null;
  }
}

// Attach the pipeline to `res` for one proxied response.
//
// `transform(plainBuffer)` returns the rewritten Buffer, or null for "do not
// rewrite" (pass through untouched).
function attachBodyTransform(res, proxyRes, transform) {
  const encoding = parseEncoding(proxyRes.headers['content-encoding']);
  delete proxyRes.headers['content-length'];
  res.removeHeader('content-length');

  const chunks = [];
  const originalWrite = res.write.bind(res);
  const originalEnd = res.end.bind(res);

  res.write = function (chunk) {
    if (chunk !== undefined && chunk !== null) {
      chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
    }
    return true;
  };

  res.end = function (chunk) {
    if (chunk !== undefined && chunk !== null) {
      chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
    }
    res.write = originalWrite;
    res.end = originalEnd;

    const raw = Buffer.concat(chunks);
    let out = raw;

    const plain = decompress(raw, encoding);
    if (plain !== null) {
      const rewritten = transform(plain);
      if (rewritten !== null) {
        const compressed = recompress(rewritten, encoding);
        if (compressed !== null) {
          out = compressed;
        } else {
          // Rewrite succeeded but recompression did not: send plaintext.
          out = rewritten;
          delete proxyRes.headers['content-encoding'];
        }
      }
    }

    return originalEnd(out);
  };
}

module.exports = {
  parseEncoding,
  decompress,
  recompress,
  attachBodyTransform,
};
