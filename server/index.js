const http = require('node:http');

// Pre-computed minimal valid ISO MP4 header buffer (36 bytes)
const SAMPLE_MP4 = Buffer.from('AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAAAhtZGF0', 'base64');

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
#EXT-X-TARGETDURATION:4
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:4.000000,
segment0.ts
#EXT-X-ENDLIST
`;

// In-memory release cache with 15-minute TTL
let releaseCache = {
  data: null,
  expiresAt: 0
};

async function getLatestRelease() {
  const now = Date.now();
  if (releaseCache.data && now < releaseCache.expiresAt) {
    return { ...releaseCache.data, cached: true };
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10000);

  try {
    const res = await fetch('https://api.github.com/repos/marspater/jolly-hopper/releases/latest', {
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

    const cleanData = {
      version: payload.tag_name || 'v5.3.0',
      name: payload.name || 'Siphon',
      publishedAt: payload.published_at || new Date().toISOString(),
      downloadUrl,
      notes: payload.body || ''
    };

    releaseCache = {
      data: cleanData,
      expiresAt: now + 15 * 60 * 1000
    };

    return { ...cleanData, cached: false };
  } catch (error) {
    console.error('Failed to refresh release metadata:', error instanceof Error ? error.message : String(error));
    if (releaseCache.data) {
      return { ...releaseCache.data, cached: true, stale: true };
    }

    return {
      version: 'v5.3.0',
      name: 'Siphon',
      publishedAt: new Date().toISOString(),
      downloadUrl: 'https://github.com/marspater/jolly-hopper/releases/latest',
      notes: 'Fallback release info (API unavailable)',
      cached: false,
      fallback: true
    };
  } finally {
    clearTimeout(timeout);
  }
}

function sendResponse(res, statusCode, headers, body) {
  res.writeHead(statusCode, headers);
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
      'Content-Length': Buffer.byteLength(SAMPLE_VTT)
    }, SAMPLE_VTT);
    return true;
  }
  if (pathname === '/mock/playlist.m3u8') {
    sendResponse(res, 200, {
      'Content-Type': 'application/vnd.apple.mpegurl',
      'Content-Length': Buffer.byteLength(SAMPLE_M3U8)
    }, SAMPLE_M3U8);
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

async function handleReleaseApi(req, res, pathname) {
  if (req.method !== 'GET' || pathname !== '/api/latest') {
    return false;
  }
  const releaseInfo = await getLatestRelease();
  sendJson(res, 200, releaseInfo);
  return true;
}

function createServer() {
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
      if (await handleReleaseApi(req, res, pathname)) return;

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

if (require.main === module) {
  const configuredPort = Number.parseInt(process.env.PORT ?? '', 10);
  const port = Number.isInteger(configuredPort) && configuredPort >= 1 && configuredPort <= 65535 ? configuredPort : 3000;
  const host = '0.0.0.0';
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
  };

  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
}

module.exports = { createServer };
