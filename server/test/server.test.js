const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { createServer } = require('../index.js');

async function listen(server) {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return `http://127.0.0.1:${server.address().port}`;
}

const RELEASE_PAYLOAD = {
  tag_name: 'v9.9.9',
  name: 'Siphon 9.9.9',
  published_at: '2026-01-01T00:00:00Z',
  html_url: 'https://github.com/marspater/jolly-hopper/releases/tag/v9.9.9',
  assets: [{ name: 'Siphon.dmg', browser_download_url: 'https://example.com/Siphon.dmg' }],
  body: 'notes'
};

// Stubbed GitHub API: each call consumes the next scripted outcome.
function scriptedFetch(outcomes) {
  const calls = [];
  const fetchImpl = async (url) => {
    calls.push(url);
    const outcome = outcomes.shift();
    if (outcome instanceof Error) throw outcome;
    return new Response(typeof outcome.body === 'string' ? outcome.body : JSON.stringify(outcome.body), {
      status: outcome.status
    });
  };
  return { fetchImpl, calls };
}

describe('Siphon Companion Server', () => {
  let server;
  let baseUrl;

  before(async () => {
    server = createServer({
      fetchImpl: async () => { throw new Error('unexpected upstream request'); }
    });
    baseUrl = await listen(server);
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

  test('responses include standard security headers', async () => {
    const res = await fetch(`${baseUrl}/health`);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('x-content-type-options'), 'nosniff');
    assert.equal(res.headers.get('x-frame-options'), 'DENY');
    assert.equal(res.headers.get('referrer-policy'), 'no-referrer');
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

  test('GET /mock/playlist.m3u8 serves every segment it references', async () => {
    const res = await fetch(`${baseUrl}/mock/playlist.m3u8`);
    assert.equal(res.status, 200);
    assert.match(res.headers.get('content-type'), /mpegurl/i);
    const text = await res.text();
    assert.ok(text.startsWith('#EXTM3U'));
    assert.ok(text.includes('#EXT-X-ENDLIST'));

    const segments = text.split('\n').map((line) => line.trim()).filter((line) => line && !line.startsWith('#'));
    assert.ok(segments.length > 0, 'manifest must reference at least one segment');
    for (const uri of segments) {
      const segment = await fetch(new URL(uri, `${baseUrl}/mock/playlist.m3u8`));
      assert.equal(segment.status, 200, `${uri} must be served`);
      const bytes = Buffer.from(await segment.arrayBuffer());
      assert.equal(bytes.length % 188, 0, `${uri} must be whole MPEG-TS packets`);
      for (let offset = 0; offset < bytes.length; offset += 188) {
        assert.equal(bytes[offset], 0x47, `${uri} packet at ${offset} must start with the TS sync byte`);
      }
    }
  });

  test('GET /mock/video.mp4 returns a playable MP4 with a moov atom', async () => {
    const res = await fetch(`${baseUrl}/mock/video.mp4`);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('content-type'), 'video/mp4');
    const buffer = Buffer.from(await res.arrayBuffer());

    const boxes = [];
    for (let offset = 0; offset < buffer.length;) {
      const size = buffer.readUInt32BE(offset);
      assert.ok(size >= 8 && offset + size <= buffer.length, `box at ${offset} must fit the file`);
      boxes.push(buffer.subarray(offset + 4, offset + 8).toString('latin1'));
      offset += size;
    }
    assert.equal(boxes[0], 'ftyp');
    assert.ok(boxes.includes('moov'), 'MP4 needs a moov atom to be decodable');
    assert.ok(boxes.includes('mdat'), 'MP4 needs media data');
  });

  test('GET /api/latest does not reach the network in tests', async () => {
    const res = await fetch(`${baseUrl}/api/latest`);
    assert.equal(res.status, 503);
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

describe('GET /api/latest', () => {
  const servers = [];

  async function start(outcomes, options = {}) {
    const { fetchImpl, calls } = scriptedFetch(outcomes);
    const server = createServer({ fetchImpl, ...options });
    servers.push(server);
    return { baseUrl: await listen(server), calls };
  }

  after(async () => {
    await Promise.all(servers.map((server) => new Promise((resolve) => server.close(resolve))));
  });

  test('returns release metadata and serves the second request from cache', async () => {
    const { baseUrl, calls } = await start([{ status: 200, body: RELEASE_PAYLOAD }]);

    const first = await fetch(`${baseUrl}/api/latest`);
    assert.equal(first.status, 200);
    assert.equal(first.headers.get('content-type'), 'application/json');
    const data = await first.json();
    assert.equal(data.version, 'v9.9.9');
    assert.equal(data.downloadUrl, 'https://example.com/Siphon.dmg');
    assert.equal(data.cached, false);

    const second = await (await fetch(`${baseUrl}/api/latest`)).json();
    assert.equal(second.cached, true);
    assert.equal(calls.length, 1);
  });

  for (const [label, outcome] of [
    ['rate limiting', { status: 403, body: { message: 'API rate limit exceeded' } }],
    ['a server error', { status: 502, body: 'Bad Gateway' }],
    ['a network failure', new Error('getaddrinfo ENOTFOUND api.github.com')],
    ['malformed JSON', { status: 200, body: '{not json' }],
    ['a payload without tag_name', { status: 200, body: { assets: [] } }]
  ]) {
    test(`returns 503 without cached data on ${label}`, async () => {
      const { baseUrl } = await start([outcome]);
      const res = await fetch(`${baseUrl}/api/latest`);
      assert.equal(res.status, 503);
      assert.deepEqual(await res.json(), { error: 'Release metadata temporarily unavailable' });
    });
  }

  test('falls back to stale cached data when a refresh fails', async () => {
    const { baseUrl } = await start(
      [{ status: 200, body: RELEASE_PAYLOAD }, new Error('upstream down')],
      { cacheTtlMs: 0 }
    );

    assert.equal((await fetch(`${baseUrl}/api/latest`)).status, 200);
    const res = await fetch(`${baseUrl}/api/latest`);
    assert.equal(res.status, 200);
    const data = await res.json();
    assert.equal(data.version, 'v9.9.9');
    assert.equal(data.cached, true);
    assert.equal(data.stale, true);
  });
});
