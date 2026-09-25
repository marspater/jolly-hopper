const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { createServer } = require('../index.js');

describe('Siphon Companion Server', () => {
  let server;
  let baseUrl;

  before(async () => {
    server = createServer();
    await new Promise((resolve) => {
      server.listen(0, '127.0.0.1', () => {
        const addr = server.address();
        baseUrl = `http://127.0.0.1:${addr.port}`;
        resolve();
      });
    });
  });

  after(async () => {
    await new Promise((resolve) => server.close(resolve));
  });

  test('GET / returns 200 with service info', async () => {
    const res = await fetch(`${baseUrl}/`);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('content-type'), 'application/json');
    const data = await res.json();
    assert.equal(data.status, 'ok');
    assert.equal(data.service, 'siphon-companion');
    assert.ok(data.timestamp);
  });

  test('GET /health returns 200 with status ok', async () => {
    const res = await fetch(`${baseUrl}/health`);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('content-type'), 'application/json');
    const data = await res.json();
    assert.equal(data.status, 'ok');
  });

  test('GET /healthz returns 200 with status ok', async () => {
    const res = await fetch(`${baseUrl}/healthz`);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('content-type'), 'application/json');
    const data = await res.json();
    assert.equal(data.status, 'ok');
  });

  test('GET /mock/subtitles.vtt returns valid WebVTT content', async () => {
    const res = await fetch(`${baseUrl}/mock/subtitles.vtt`);
    assert.equal(res.status, 200);
    assert.match(res.headers.get('content-type'), /text\/vtt/);
    const text = await res.text();
    assert.ok(text.startsWith('WEBVTT'));
    assert.ok(text.includes('00:00:00.000 --> 00:00:02.000'));
  });

  test('GET /mock/playlist.m3u8 returns valid HLS manifest', async () => {
    const res = await fetch(`${baseUrl}/mock/playlist.m3u8`);
    assert.equal(res.status, 200);
    assert.match(res.headers.get('content-type'), /mpegurl/i);
    const text = await res.text();
    assert.ok(text.startsWith('#EXTM3U'));
    assert.ok(text.includes('#EXT-X-ENDLIST'));
  });

  test('GET /mock/video.mp4 returns valid MP4 binary buffer', async () => {
    const res = await fetch(`${baseUrl}/mock/video.mp4`);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('content-type'), 'video/mp4');
    const buffer = Buffer.from(await res.arrayBuffer());
    assert.ok(buffer.length > 0);
    assert.equal(buffer.subarray(4, 8).toString(), 'ftyp');
  });

  test('GET /api/latest returns release payload with cache status', async () => {
    const res = await fetch(`${baseUrl}/api/latest`);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('content-type'), 'application/json');
    const data = await res.json();
    assert.ok(data.version);
    assert.ok(data.downloadUrl);

    // Verify cache hit on immediate second request
    const res2 = await fetch(`${baseUrl}/api/latest`);
    const data2 = await res2.json();
    assert.equal(data2.cached, true);
  });

  // When the GitHub API is unreachable and no cached data exists, the server
  // should return 503 instead of fabricating fake release metadata.
  // This test cannot easily simulate that scenario without mocking `fetch`,
  // so it verifies the response shape under normal (or cached) conditions
  // and documents the expected 503 contract.
  test('GET /api/latest returns either valid release data or 503', async () => {
    const res = await fetch(`${baseUrl}/api/latest`);
    assert.ok([200, 503].includes(res.status), `expected 200 or 503, got ${res.status}`);
    assert.equal(res.headers.get('content-type'), 'application/json');
    const data = await res.json();
    if (res.status === 200) {
      assert.ok(data.version, 'version must be present');
      assert.ok(data.downloadUrl, 'downloadUrl must be present');
      assert.ok('cached' in data, 'cached flag must be present');
    } else {
      assert.equal(data.error, 'Release metadata temporarily unavailable');
    }
  });

  test('malformed Host header returns 400 without crashing the server', async () => {
    const addr = server.address();
    const result = await new Promise((resolve, reject) => {
      const req = http.request({
        hostname: '127.0.0.1',
        port: addr.port,
        path: '/',
        method: 'GET',
        headers: { Host: '%' }
      }, (res) => {
        let body = '';
        res.setEncoding('utf8');
        res.on('data', (chunk) => { body += chunk; });
        res.on('end', () => resolve({ statusCode: res.statusCode, body }));
      });
      req.on('error', reject);
      req.end();
    });

    assert.equal(result.statusCode, 400);
    assert.deepEqual(JSON.parse(result.body), { error: 'Bad Request' });

    const health = await fetch(`${baseUrl}/health`);
    assert.equal(health.status, 200, 'server must remain healthy after malformed input');
  });

  test('GET /unknown returns 404', async () => {
    const res = await fetch(`${baseUrl}/unknown-endpoint`);
    assert.equal(res.status, 404);
    const data = await res.json();
    assert.equal(data.error, 'Not Found');
  });
});
