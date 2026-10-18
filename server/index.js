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

// Pre-define standard security headers to avoid recreating header object literals on every HTTP response
const DEFAULT_SECURITY_HEADERS = Object.freeze({
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Referrer-Policy': 'no-referrer',
  'Content-Security-Policy': "default-src 'none'; frame-ancestors 'none'",
  'Cross-Origin-Resource-Policy': 'same-origin',
  'X-Permitted-Cross-Domain-Policies': 'none',
  'Permissions-Policy': 'accelerometer=(), camera=(), geolocation=(), microphone=()'
});

// Bolt Performance Optimization: Pre-compute static response objects with frozen merged headers and pre-serialized payloads
// to eliminate dynamic JSON serialization, byte length calculation, and intermediate header object allocations on every request.
function createStaticResponse(statusCode, contentType, body, extraHeaders = {}) {
  const payload = typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body);
  const contentLength = Buffer.isBuffer(payload) ? payload.length : Buffer.byteLength(payload);
  const headers = Object.freeze({
    ...DEFAULT_SECURITY_HEADERS,
    ...extraHeaders,
    'Content-Type': contentType,
    'Content-Length': contentLength
  });
  return Object.freeze({ statusCode, headers, payload });
}

const STATIC_RESPONSES = Object.freeze({
  BAD_REQUEST: createStaticResponse(400, 'application/json', { error: 'Bad Request' }),
  METHOD_NOT_ALLOWED: createStaticResponse(405, 'application/json', { error: 'Method Not Allowed' }, { 'Allow': 'GET' }),
  NOT_FOUND: createStaticResponse(404, 'application/json', { error: 'Not Found' }),
  INTERNAL_ERROR: createStaticResponse(500, 'application/json', { error: 'Internal Server Error' }),
  SERVICE_UNAVAILABLE: createStaticResponse(503, 'application/json', { error: 'Release metadata temporarily unavailable' }),
  MOCK_VTT: createStaticResponse(200, 'text/vtt; charset=utf-8', SAMPLE_VTT),
  MOCK_M3U8: createStaticResponse(200, 'application/vnd.apple.mpegurl', SAMPLE_M3U8),
  MOCK_TS_SEGMENT: createStaticResponse(200, 'video/mp2t', SAMPLE_TS_SEGMENT),
  MOCK_MP4: createStaticResponse(200, 'video/mp4', SAMPLE_MP4)
});

function sendStaticResponse(res, staticResponse) {
  res.writeHead(staticResponse.statusCode, staticResponse.headers);
  res.end(staticResponse.payload);
}

const RELEASE_CACHE_TTL_MS = 15 * 60 * 1000;
const RELEASE_FAILURE_RETRY_MS = 30 * 1000;
const DEFAULT_RELEASE_URL = 'https://github.com/marspater/jolly-hopper/releases/latest';
const TRUSTED_RELEASE_HOSTS = new Set([
  'github.com',
  'api.github.com',
  'objects.githubusercontent.com'
]);

function isTrustedReleaseUrl(targetUrl) {
  if (typeof targetUrl !== 'string' || !targetUrl.startsWith('https://')) {
    return false;
  }
  try {
    const parsed = new URL(targetUrl);
    return parsed.protocol === 'https:' && TRUSTED_RELEASE_HOSTS.has(parsed.hostname.toLowerCase());
  } catch {
    return false;
  }
}

function extractDownloadUrl(payload) {
  const assets = Array.isArray(payload.assets) ? payload.assets : [];
  const dmgAsset = assets.find((a) => typeof a?.name === 'string' && a.name.endsWith('.dmg'));
  const fallbackUrl = payload.tag_name
    ? `https://github.com/marspater/jolly-hopper/releases/tag/${payload.tag_name}`
    : DEFAULT_RELEASE_URL;
  const candidateUrl = dmgAsset ? dmgAsset.browser_download_url : fallbackUrl;
  return isTrustedReleaseUrl(candidateUrl) ? candidateUrl : DEFAULT_RELEASE_URL;
}

// The release fields the service publishes, or an error naming what failed.
// A 403/429 without a token is almost always the shared-IP rate limit.
async function parseReleaseResponse(res, hasToken) {
  if (!res.ok) {
    const hint = !hasToken && (res.status === 403 || res.status === 429) ? ' (rate limited; set GITHUB_TOKEN)' : '';
    throw new Error(`GitHub API returned status ${res.status}${hint}`);
  }
  const payload = await res.json();
  if (!payload.tag_name) {
    throw new Error('GitHub API response missing tag_name');
  }
  return {
    version: payload.tag_name,
    name: payload.name || 'Siphon',
    publishedAt: payload.published_at || new Date().toISOString(),
    downloadUrl: extractDownloadUrl(payload),
    notes: payload.body || ''
  };
}

// Returns a release lookup with its own in-memory cache. `fetchImpl` is
// injectable so tests never depend on the live GitHub API. Unauthenticated
// calls share GitHub's 60-per-hour limit with everything else behind the
// host's outbound IP (Render's is shared); a token raises it to 5,000.
function createReleaseFetcher(fetchImpl, cacheTtlMs, failureRetryMs, githubToken) {
  const headers = {
    'User-Agent': 'Siphon-Companion-Service',
    'Accept': 'application/vnd.github.v3+json'
  };
  if (githubToken) {
    headers.Authorization = `Bearer ${githubToken}`;
  }

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
        headers
      });
      const cleanData = await parseReleaseResponse(res, Boolean(githubToken));

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

function sendJson(res, statusCode, data) {
  const payload = JSON.stringify(data);
  // Bolt Performance Optimization: Single-pass header object creation combining default security headers with JSON content headers
  // to avoid intermediate header object allocations and double object spread copies.
  const headers = {
    ...DEFAULT_SECURITY_HEADERS,
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(payload)
  };
  res.writeHead(statusCode, headers);
  res.end(payload);
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
    sendStaticResponse(res, STATIC_RESPONSES.MOCK_VTT);
    return true;
  }
  if (pathname === '/mock/playlist.m3u8') {
    sendStaticResponse(res, STATIC_RESPONSES.MOCK_M3U8);
    return true;
  }
  if (pathname === '/mock/segment0.ts') {
    sendStaticResponse(res, STATIC_RESPONSES.MOCK_TS_SEGMENT);
    return true;
  }
  if (pathname === '/mock/video.mp4') {
    sendStaticResponse(res, STATIC_RESPONSES.MOCK_MP4);
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
    sendStaticResponse(res, STATIC_RESPONSES.SERVICE_UNAVAILABLE);
    return true;
  }
  sendJson(res, 200, releaseInfo);
  return true;
}

const INVALID_HOST_PATTERN = new RegExp('[/@?#\\s]');

function parseRequestUrl(req) {
  const host = req.headers.host;
  if (host && INVALID_HOST_PATTERN.test(host)) {
    return null;
  }
  try {
    return new URL(req.url, `http://${host || 'localhost'}`);
  } catch {
    return null;
  }
}

function createServer({
  fetchImpl = globalThis.fetch,
  cacheTtlMs = RELEASE_CACHE_TTL_MS,
  failureRetryMs = RELEASE_FAILURE_RETRY_MS,
  githubToken = process.env.GITHUB_TOKEN
} = {}) {
  const getLatestRelease = createReleaseFetcher(fetchImpl, cacheTtlMs, failureRetryMs, githubToken);
  return http.createServer(async (req, res) => {
    try {
      if (req.method !== 'GET') {
        sendStaticResponse(res, STATIC_RESPONSES.METHOD_NOT_ALLOWED);
        return;
      }

      const url = parseRequestUrl(req);
      if (!url) {
        sendStaticResponse(res, STATIC_RESPONSES.BAD_REQUEST);
        return;
      }

      const pathname = url.pathname;
      if (handleHealthCheck(req, res, pathname)) return;
      if (handleMockFixtures(req, res, pathname)) return;
      if (await handleReleaseApi(req, res, pathname, getLatestRelease)) return;

      sendStaticResponse(res, STATIC_RESPONSES.NOT_FOUND);
    } catch (error) {
      console.error('Unhandled companion request error:', error instanceof Error ? error.message : String(error));
      if (!res.headersSent) {
        sendStaticResponse(res, STATIC_RESPONSES.INTERNAL_ERROR);
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

  server.listen(port, host);

  const shutdown = () => {
    server.close(() => {
      process.exit(0);
    });
    // Idle keep-alive sockets would otherwise stall close().
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
