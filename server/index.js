const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

// 1 s, 16x16 H.264 + AAC fixtures generated with the pinned FFmpeg; both
// decode cleanly with ffprobe.
const SAMPLE_MP4 = fs.readFileSync(path.join(__dirname, 'fixtures', 'video.mp4'));
const SAMPLE_TS_SEGMENT = fs.readFileSync(path.join(__dirname, 'fixtures', 'segment0.ts'));

const SAMPLE_VTT = `WEBVTT

1
00:00:00.000 --> 00:00:02.000
Welcome to Siphon test stream.

2
00:00:02.000 --> 00:00:04.000
Testing subtitle extraction and language mapping.
`;

const SAMPLE_M3U8 = `#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:1
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:1.000000,
segment0.ts
#EXT-X-ENDLIST
`;

// Pre-calculate byte lengths for static sample text fixtures to avoid string encoding scans on every request
const SAMPLE_VTT_LEN = Buffer.byteLength(SAMPLE_VTT);
const SAMPLE_M3U8_LEN = Buffer.byteLength(SAMPLE_M3U8);

// Pre-define standard security headers to avoid recreating header object literals on every HTTP response
const DEFAULT_SECURITY_HEADERS = Object.freeze({
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Referrer-Policy': 'no-referrer',
  'Content-Security-Policy': "default-src 'none'; frame-ancestors 'none'",
  'Cross-Origin-Resource-Policy': 'same-origin',
  'X-Permitted-Cross-Domain-Policies': 'none'
});

const RELEASE_CACHE_TTL_MS = 15 * 60 * 1000;
const RELEASE_FAILURE_RETRY_MS = 30 * 1000;

// Returns a release lookup with its own in-memory cache. `fetchImpl` is
// injectable so tests never depend on the live GitHub API.
function createReleaseFetcher(fetchImpl, cacheTtlMs, failureRetryMs) {
  let releaseCache = {
    data: null,
    expiresAt: 0
  };

  // After a failed refresh, hold off before asking GitHub again so an outage
  // or rate limit is not hammered once per request.
  let retryAfter = 0;

  // Concurrent cache misses share one upstream request instead of each
  // hitting the GitHub API.
  let inFlight = null;

  return function getLatestRelease() {
    if (releaseCache.data && Date.now() < releaseCache.expiresAt) {
      return Promise.resolve({ ...releaseCache.data, cached: true });
    }
    if (!inFlight && Date.now() < retryAfter) {
      return Promise.resolve(staleOrNull());
    }
    if (!inFlight) {
      inFlight = refresh().finally(() => { inFlight = null; });
    }
    return inFlight;
  };

  async function refresh() {
    const now = Date.now();
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 10000);

    try {
      const res = await fetchImpl('https://api.github.com/repos/marspater/jolly-hopper/releases/latest', {
        signal: controller.signal,
        headers: {
          'User-Agent': 'Siphon-Companion-Service',
          'Accept': 'application/vnd.github.v3+json'
        }
      });

      if (!res.ok) {
        throw new Error(`GitHub API returned status ${res.status}`);
      }

      const payload = await res.json();
      const dmgAsset = (payload.assets || []).find((a) => a.name?.endsWith('.dmg'));
      const downloadUrl = dmgAsset ? dmgAsset.browser_download_url : (payload.html_url || 'https://github.com/marspater/jolly-hopper/releases/latest');

      if (!payload.tag_name) {
        throw new Error('GitHub API response missing tag_name');
      }
      const cleanData = {
        version: payload.tag_name,
        name: payload.name || 'Siphon',
        publishedAt: payload.published_at || new Date().toISOString(),
        downloadUrl,
        notes: payload.body || ''
      };

      releaseCache = {
        data: cleanData,
        expiresAt: now + cacheTtlMs
      };

      return { ...cleanData, cached: false };
    } catch (error) {
      console.error('Failed to refresh release metadata:', error instanceof Error ? error.message : String(error));
      retryAfter = Date.now() + failureRetryMs;
      return staleOrNull();
    } finally {
      clearTimeout(timeout);
    }
  }

  function staleOrNull() {
    return releaseCache.data ? { ...releaseCache.data, cached: true, stale: true } : null;
  }
}

function sendResponse(res, statusCode, headers, body) {
  const mergedHeaders = headers ? { ...DEFAULT_SECURITY_HEADERS, ...headers } : DEFAULT_SECURITY_HEADERS;
  res.writeHead(statusCode, mergedHeaders);
  res.end(body);
}

function sendJson(res, statusCode, data) {
  const payload = JSON.stringify(data);
  sendResponse(res, statusCode, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(payload)
  }, payload);
}

function handleHealthCheck(req, res, pathname) {
  if (req.method !== 'GET' || (pathname !== '/' && pathname !== '/health' && pathname !== '/healthz')) {
    return false;
  }
  sendJson(res, 200, {
    status: 'ok',
    service: 'siphon-companion',
    timestamp: new Date().toISOString()
  });
  return true;
}

function handleMockFixtures(req, res, pathname) {
  if (req.method !== 'GET') {
    return false;
  }
  if (pathname === '/mock/subtitles.vtt') {
    sendResponse(res, 200, {
      'Content-Type': 'text/vtt; charset=utf-8',
      'Content-Length': SAMPLE_VTT_LEN
    }, SAMPLE_VTT);
    return true;
  }
  if (pathname === '/mock/playlist.m3u8') {
    sendResponse(res, 200, {
      'Content-Type': 'application/vnd.apple.mpegurl',
      'Content-Length': SAMPLE_M3U8_LEN
    }, SAMPLE_M3U8);
    return true;
  }
  if (pathname === '/mock/segment0.ts') {
    sendResponse(res, 200, {
      'Content-Type': 'video/mp2t',
      'Content-Length': SAMPLE_TS_SEGMENT.length
    }, SAMPLE_TS_SEGMENT);
    return true;
  }
  if (pathname === '/mock/video.mp4') {
    sendResponse(res, 200, {
      'Content-Type': 'video/mp4',
      'Content-Length': SAMPLE_MP4.length
    }, SAMPLE_MP4);
    return true;
  }
  return false;
}

async function handleReleaseApi(req, res, pathname, getLatestRelease) {
  if (req.method !== 'GET' || pathname !== '/api/latest') {
    return false;
  }
  const releaseInfo = await getLatestRelease();
  if (!releaseInfo) {
    sendJson(res, 503, { error: 'Release metadata temporarily unavailable' });
    return true;
  }
  sendJson(res, 200, releaseInfo);
  return true;
}

function createServer({
  fetchImpl = globalThis.fetch,
  cacheTtlMs = RELEASE_CACHE_TTL_MS,
  failureRetryMs = RELEASE_FAILURE_RETRY_MS
} = {}) {
  const getLatestRelease = createReleaseFetcher(fetchImpl, cacheTtlMs, failureRetryMs);
  return http.createServer(async (req, res) => {
    try {
      let url;
      try {
        url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
      } catch {
        sendJson(res, 400, { error: 'Bad Request' });
        return;
      }

      const pathname = url.pathname;
      if (handleHealthCheck(req, res, pathname)) return;
      if (handleMockFixtures(req, res, pathname)) return;
      if (await handleReleaseApi(req, res, pathname, getLatestRelease)) return;

      sendJson(res, 404, { error: 'Not Found' });
    } catch (error) {
      console.error('Unhandled companion request error:', error instanceof Error ? error.message : String(error));
      if (!res.headersSent) {
        sendJson(res, 500, { error: 'Internal Server Error' });
      } else if (!res.writableEnded) {
        res.destroy();
      }
    }
  });
}

// Render routes public traffic to the port on every interface and sets
// RENDER=true; bound to loopback there, the service never answers. Anywhere
// else it stays on loopback unless HOST says otherwise.
function listenHost(env = process.env) {
  return env.HOST || (env.RENDER ? '0.0.0.0' : '127.0.0.1');
}

if (require.main === module) {
  const configuredPort = Number.parseInt(process.env.PORT ?? '', 10);
  const port = Number.isInteger(configuredPort) && configuredPort >= 1 && configuredPort <= 65535 ? configuredPort : 3000;
  const host = listenHost();
  const server = createServer();

  server.listen(port, host, () => {
    console.log(`Siphon companion service running on http://${host}:${port}`);
  });

  const shutdown = () => {
    console.log('Received shutdown signal, closing server...');
    server.close(() => {
      console.log('Server closed successfully.');
      process.exit(0);
    });
    // Node 18 keeps idle keep-alive sockets open, which would stall close().
    server.closeIdleConnections?.();
    setTimeout(() => {
      server.closeAllConnections?.();
      process.exit(0);
    }, 10_000).unref();
  };

  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
}

module.exports = { createServer, listenHost };
