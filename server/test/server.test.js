const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
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

  test('GET /unknown returns 404', async () => {
    const res = await fetch(`${baseUrl}/unknown-endpoint`);
    assert.equal(res.status, 404);
    const data = await res.json();
    assert.equal(data.error, 'Not Found');
  });
});
