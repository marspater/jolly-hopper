#!/usr/bin/env node

function commitsMatch(deployed, expected) {
  if (!deployed || !expected) return false;
  const d = String(deployed).trim().toLowerCase();
  const e = String(expected).trim().toLowerCase();
  if (d === e) return true;
  if (d.length >= 7 && e.length >= 7) {
    return d.startsWith(e) || e.startsWith(d);
  }
  return false;
}

function parseCliArgs(args) {
  const options = {
    url: 'https://jolly-hopper.onrender.com/healthz',
    expectedCommit: process.env.EXPECTED_COMMIT || process.env.CIRCLE_SHA1 || '',
    expectedVersion: process.env.EXPECTED_VERSION || process.env.TARGET_VERSION || process.env.APP_VERSION || '',
    timeoutSeconds: Number.parseInt(process.env.DEPLOY_TIMEOUT_SEC || '180', 10),
    intervalSeconds: Number.parseInt(process.env.DEPLOY_INTERVAL_SEC || '10', 10)
  };

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--commit' && i + 1 < args.length) {
      options.expectedCommit = args[++i];
    } else if (arg === '--version' && i + 1 < args.length) {
      options.expectedVersion = args[++i];
    } else if (arg === '--timeout' && i + 1 < args.length) {
      options.timeoutSeconds = Number.parseInt(args[++i], 10);
    } else if (arg === '--interval' && i + 1 < args.length) {
      options.intervalSeconds = Number.parseInt(args[++i], 10);
    } else if (arg === '--url' && i + 1 < args.length) {
      options.url = args[++i];
    } else if (!arg.startsWith('-') && i === 0) {
      options.url = arg;
    }
  }

  return options;
}

async function queryHealthEndpoint(url, fetchImpl) {
  const controller = new AbortController();
  const reqTimeout = setTimeout(() => controller.abort(), 10000);
  try {
    const res = await fetchImpl(url, { signal: controller.signal });
    let payload = null;
    if (res.ok) {
      try {
        payload = await res.json();
      } catch {
        payload = null;
      }
    }
    return { ok: res.ok, status: res.status, payload };
  } finally {
    clearTimeout(reqTimeout);
  }
}

function checkMatch({ payload, expectedCommit, expectedVersion }) {
  const lastSeenCommit = payload?.commit ?? '';
  const lastSeenVersion = payload?.version ?? '';
  const commitMatches = !expectedCommit || commitsMatch(lastSeenCommit, expectedCommit);

  let versionMatches = true;
  if (expectedVersion && expectedVersion !== 'latest') {
    const cleanExpected = expectedVersion.split('-')[0];
    versionMatches = lastSeenVersion === expectedVersion || lastSeenVersion === cleanExpected;
  }

  return { commitMatches, versionMatches, lastSeenCommit, lastSeenVersion };
}

async function verifyDeployment({
  url = 'https://jolly-hopper.onrender.com/healthz',
  expectedCommit = '',
  expectedVersion = '',
  timeoutSeconds = 180,
  intervalSeconds = 10,
  fetchImpl = globalThis.fetch,
  sleepImpl = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  nowImpl = Date.now,
  logger = console
} = {}) {
  const startTime = nowImpl();
  const deadline = startTime + (timeoutSeconds * 1000);
  let attempt = 0;
  let lastSeenCommit = null;
  let lastSeenVersion = null;
  let lastSeenStatus = null;

  logger.log(`Starting deployment verification for ${url}...`);
  if (expectedCommit) logger.log(`Expected commit: ${expectedCommit}`);
  if (expectedVersion) logger.log(`Expected version: ${expectedVersion}`);

  while (nowImpl() <= deadline) {
    attempt++;
    try {
      const probe = await queryHealthEndpoint(url, fetchImpl);
      lastSeenStatus = probe.status;

      if (!probe.ok) {
        logger.log(`[attempt ${attempt}] Health check returned HTTP ${probe.status}`);
      } else if (probe.payload?.status !== 'ok') {
        logger.log(`[attempt ${attempt}] Invalid health check response body`);
      } else {
        const match = checkMatch({
          payload: probe.payload,
          expectedCommit,
          expectedVersion
        });
        lastSeenCommit = match.lastSeenCommit;
        lastSeenVersion = match.lastSeenVersion;

        if (match.commitMatches && match.versionMatches) {
          const elapsed = Math.round((nowImpl() - startTime) / 1000);
          logger.log(`Successfully verified deployment after ${elapsed}s! Service is up and running revision '${lastSeenCommit || 'unversioned'}' (version: ${lastSeenVersion || 'unknown'}).`);
          return {
            ok: true,
            deployedCommit: lastSeenCommit,
            deployedVersion: lastSeenVersion,
            elapsedSeconds: elapsed,
            attempts: attempt
          };
        }

        const reasons = [];
        if (!match.commitMatches) {
          reasons.push(`commit '${lastSeenCommit || 'none'}' does not match expected '${expectedCommit}'`);
        }
        if (!match.versionMatches) {
          reasons.push(`version '${lastSeenVersion || 'none'}' does not match expected '${expectedVersion}'`);
        }
        logger.log(`[attempt ${attempt}] Service is healthy, but running rollout ${reasons.join(' and ')}. Waiting for new deployment...`);
      }
    } catch (err) {
      logger.log(`[attempt ${attempt}] Health check probe failed: ${err?.message || String(err)}`);
    }

    if (nowImpl() + (intervalSeconds * 1000) > deadline) {
      break;
    }
    await sleepImpl(intervalSeconds * 1000);
  }

  const elapsed = Math.round((nowImpl() - startTime) / 1000);
  const errMsg = `Deployment verification timed out after ${elapsed}s: expected commit '${expectedCommit || 'any'}' (last observed commit: '${lastSeenCommit ?? 'none'}', status: ${lastSeenStatus ?? 'none'})`;
  logger.error(errMsg);
  return {
    ok: false,
    error: errMsg,
    lastSeenCommit,
    lastSeenVersion,
    lastSeenStatus,
    elapsedSeconds: elapsed,
    attempts: attempt
  };
}

async function main() {
  const options = parseCliArgs(process.argv.slice(2));
  try {
    const result = await verifyDeployment(options);
    process.exit(result.ok ? 0 : 1);
  } catch (err) {
    console.error('Fatal deployment verification error:', err);
    process.exit(1);
  }
}

if (require.main === module) {
  void main();
}

module.exports = { verifyDeployment, commitsMatch, parseCliArgs };
