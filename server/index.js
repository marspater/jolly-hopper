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

  try {
    const res = await fetch('https://api.github.com/repos/marspater/jolly-hopper/releases/latest', {
      headers: {
        'User-Agent': 'Siphon-Companion-Service',
        'Accept': 'application/vnd.github.v3+json'
      }
    });

    if (!res.ok) {
      throw new Error(`GitHub API returned status ${res.status}`);
    }

    const payload = await res.json();
    const dmgAsset = (payload.assets || []).find((a) => a.name && a.name.endsWith('.dmg'));
    const downloadUrl = dmgAsset
      ? dmgAsset.browser_download_url
      : payload.html_url || 'https://github.com/marspater/jolly-hopper/releases/latest';

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
  } catch {
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
  }
}

function createServer() {
  return http.createServer(async (req, res) => {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const pathname = url.pathname;

    // Health checks
    if (req.method === 'GET' && (pathname === '/' || pathname === '/health' || pathname === '/healthz')) {
      const payload = JSON.stringify({
        status: 'ok',
        service: 'siphon-companion',
        timestamp: new Date().toISOString()
      });
      res.writeHead(200, {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(payload)
      });
      res.end(payload);
      return;
    }

    // Mock fixtures for video, subtitles, and HLS streaming
    if (req.method === 'GET' && pathname === '/mock/subtitles.vtt') {
      res.writeHead(200, {
        'Content-Type': 'text/vtt; charset=utf-8',
        'Content-Length': Buffer.byteLength(SAMPLE_VTT)
      });
      res.end(SAMPLE_VTT);
      return;
    }

    if (req.method === 'GET' && pathname === '/mock/playlist.m3u8') {
      res.writeHead(200, {
        'Content-Type': 'application/vnd.apple.mpegurl',
        'Content-Length': Buffer.byteLength(SAMPLE_M3U8)
      });
      res.end(SAMPLE_M3U8);
      return;
    }

    if (req.method === 'GET' && pathname === '/mock/video.mp4') {
      res.writeHead(200, {
        'Content-Type': 'video/mp4',
        'Content-Length': SAMPLE_MP4.length
      });
      res.end(SAMPLE_MP4);
      return;
    }

    // Release cache API
    if (req.method === 'GET' && pathname === '/api/latest') {
      const releaseInfo = await getLatestRelease();
      const payload = JSON.stringify(releaseInfo);
      res.writeHead(200, {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(payload)
      });
      res.end(payload);
      return;
    }

    const notFoundPayload = JSON.stringify({ error: 'Not Found' });
    res.writeHead(404, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(notFoundPayload)
    });
    res.end(notFoundPayload);
  });
}

if (require.main === module) {
  const port = parseInt(process.env.PORT, 10) || 3000;
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
