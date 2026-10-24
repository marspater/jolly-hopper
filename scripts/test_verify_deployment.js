const { test } = require('node:test');
const assert = require('node:assert/strict');
const { verifyDeployment, commitsMatch, parseCliArgs } = require('./verify_deployment.js');

test('commitsMatch handles full, short, and mismatched commits', () => {
  const full = 'd161bead70d1f096f3f9e9551dc4f6455ef1241b';
  const short = 'd161bea';
  const other = 'fca6fe3';

  assert.equal(commitsMatch(full, full), true);
  assert.equal(commitsMatch(full, short), true);
  assert.equal(commitsMatch(short, full), true);
  assert.equal(commitsMatch(full, other), false);
  assert.equal(commitsMatch(other, full), false);
  assert.equal(commitsMatch('', full), false);
  assert.equal(commitsMatch(full, ''), false);
  assert.equal(commitsMatch(null, full), false);
});

test('parseCliArgs correctly parses flags and positional arguments', () => {
  const opts = parseCliArgs([
    'https://custom.com/healthz',
    '--commit', 'abcdef1',
    '--version', '1.2.3',
    '--timeout', '60',
    '--interval', '5'
  ]);

  assert.equal(opts.url, 'https://custom.com/healthz');
  assert.equal(opts.expectedCommit, 'abcdef1');
  assert.equal(opts.expectedVersion, '1.2.3');
  assert.equal(opts.timeoutSeconds, 60);
  assert.equal(opts.intervalSeconds, 5);
});

test('verifyDeployment succeeds immediately when target matches expected commit', async () => {
  const logs = [];
  const fakeFetch = async () => new Response(JSON.stringify({
    status: 'ok',
    service: 'siphon-companion',
    version: '1.0.0',
    commit: 'd161bead70d1f096f3f9e9551dc4f6455ef1241b'
  }), { status: 200, headers: { 'Content-Type': 'application/json' } });

  const result = await verifyDeployment({
    url: 'https://example.com/healthz',
    expectedCommit: 'd161bea',
    timeoutSeconds: 5,
    intervalSeconds: 1,
    fetchImpl: fakeFetch,
    sleepImpl: async () => {},
    logger: { log: (msg) => logs.push(msg), error: (msg) => logs.push(msg) }
  });

  assert.equal(result.ok, true);
  assert.equal(result.deployedCommit, 'd161bead70d1f096f3f9e9551dc4f6455ef1241b');
});

test('verifyDeployment retries while old commit is running and succeeds when new commit appears', async () => {
  const logs = [];
  let calls = 0;
  const fakeFetch = async () => {
    calls++;
    if (calls < 3) {
      // Old revision running initially
      return new Response(JSON.stringify({
        status: 'ok',
        version: '1.0.0',
        commit: 'oldcommit111'
      }), { status: 200 });
    }
    // New rollout live on attempt 3
    return new Response(JSON.stringify({
      status: 'ok',
      version: '1.0.0',
      commit: 'newcommit222'
    }), { status: 200 });
  };

  let sleepCount = 0;
  const result = await verifyDeployment({
    url: 'https://example.com/healthz',
    expectedCommit: 'newcommit222',
    timeoutSeconds: 30,
    intervalSeconds: 1,
    fetchImpl: fakeFetch,
    sleepImpl: async () => { sleepCount++; },
    logger: { log: (msg) => logs.push(msg), error: (msg) => logs.push(msg) }
  });

  assert.equal(result.ok, true);
  assert.equal(calls, 3);
  assert.equal(sleepCount, 2);
  assert.ok(logs.some((l) => l.includes('does not match expected')));
});

test('verifyDeployment fails when deployment times out on old revision', async () => {
  const logs = [];
  const fakeFetch = async () => new Response(JSON.stringify({
    status: 'ok',
    version: '1.0.0',
    commit: 'stalecommit000'
  }), { status: 200 });

  let virtualTime = 1000;
  let sleepCount = 0;
  const result = await verifyDeployment({
    url: 'https://example.com/healthz',
    expectedCommit: 'targetcommit999',
    timeoutSeconds: 30,
    intervalSeconds: 10,
    fetchImpl: fakeFetch,
    sleepImpl: async (ms) => {
      sleepCount++;
      virtualTime += ms;
    },
    nowImpl: () => virtualTime,
    logger: { log: (msg) => logs.push(msg), error: (msg) => logs.push(msg) }
  });

  assert.equal(result.ok, false);
  assert.match(result.error, /timed out/i);
  assert.ok(sleepCount >= 3);
});

test('verifyDeployment tolerates intermediate network/500 errors before rollout succeeds', async () => {
  const logs = [];
  let calls = 0;
  const fakeFetch = async () => {
    calls++;
    if (calls === 1) throw new Error('connection refused');
    if (calls === 2) return new Response('Bad Gateway', { status: 502 });
    return new Response(JSON.stringify({
      status: 'ok',
      version: '1.0.0',
      commit: 'targetcommit999'
    }), { status: 200 });
  };

  const result = await verifyDeployment({
    url: 'https://example.com/healthz',
    expectedCommit: 'targetcommit999',
    timeoutSeconds: 30,
    intervalSeconds: 1,
    fetchImpl: fakeFetch,
    sleepImpl: async () => {},
    logger: { log: (msg) => logs.push(msg), error: (msg) => logs.push(msg) }
  });

  assert.equal(result.ok, true);
  assert.equal(calls, 3);
});

test('verifyDeployment retries and fails on version mismatch', async () => {
  const logs = [];
  const fakeFetch = async () => new Response(JSON.stringify({
    status: 'ok',
    version: '1.0.0',
    commit: 'targetcommit999'
  }), { status: 200 });

  let virtualTime = 1000;
  let sleepCount = 0;
  const result = await verifyDeployment({
    url: 'https://example.com/healthz',
    expectedCommit: 'targetcommit999',
    expectedVersion: '2.0.0',
    timeoutSeconds: 30,
    intervalSeconds: 10,
    fetchImpl: fakeFetch,
    sleepImpl: async (ms) => {
      sleepCount++;
      virtualTime += ms;
    },
    nowImpl: () => virtualTime,
    logger: { log: (msg) => logs.push(msg), error: (msg) => logs.push(msg) }
  });

  assert.equal(result.ok, false);
  assert.match(result.error, /timed out/i);
  assert.ok(logs.some((l) => l.includes("version '1.0.0' does not match expected '2.0.0'")));
  assert.ok(sleepCount >= 3);
});

test('verifyDeployment accepts any commit from a comma-separated expected list', async () => {
  const verifyRunning = (commit) => verifyDeployment({
    url: 'https://example.com/healthz',
    expectedCommit: '42a8a6c5b41bd27ff89e496ab53110b0a0de863c,138c181e3e4e1c19dec09f4815fe5fdaf96f7fd0',
    timeoutSeconds: 1,
    intervalSeconds: 1,
    fetchImpl: async () => new Response(JSON.stringify({ status: 'ok', version: '1.0.0', commit }), { status: 200 }),
    sleepImpl: async () => {},
    logger: { log: () => {}, error: () => {} }
  });

  assert.equal((await verifyRunning('138c181e3e4e1c19dec09f4815fe5fdaf96f7fd0')).ok, true);
  const miss = await verifyRunning('fca6fe3');
  assert.equal(miss.ok, false);
  assert.match(miss.error, /\(any of 2 accepted commits\)/);
});
