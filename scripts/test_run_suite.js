const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function cleanEnv() {
  const env = { ...process.env };
  delete env.NODE_TEST_CONTEXT;
  delete env.NODE_TEST_WORKER_ID;
  return env;
}

test('run_suite.js exits with status 0 on passing tests', () => {
  const tempDir = fs.mkdtempSync(path.join(process.cwd(), 'scripts', '.test-out-'));
  const testFile = path.join(process.cwd(), 'scripts', 'fixture_pass.js');
  try {
    fs.writeFileSync(testFile, 'const { test } = require("node:test"); test("pass", () => {});\n');
    const junitOut = path.join(tempDir, 'junit.xml');

    const result = spawnSync(process.execPath, [
      path.join(process.cwd(), 'scripts', 'run_suite.js'),
      junitOut,
      'scripts/fixture_pass.js'
    ], { encoding: 'utf8', env: cleanEnv() });

    assert.equal(result.status, 0, result.stderr);
    assert.ok(fs.existsSync(junitOut), 'JUnit output file must be created');
  } finally {
    try { fs.unlinkSync(testFile); } catch {}
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test('run_suite.js exits non-zero when child test process fails normally', () => {
  const tempDir = fs.mkdtempSync(path.join(process.cwd(), 'scripts', '.test-out-'));
  const testFile = path.join(process.cwd(), 'scripts', 'fixture_fail.js');
  try {
    fs.writeFileSync(testFile, 'const { test } = require("node:test"); const assert = require("node:assert"); test("fail", () => { assert.fail("expected failure"); });\n');
    const junitOut = path.join(tempDir, 'junit.xml');

    const result = spawnSync(process.execPath, [
      path.join(process.cwd(), 'scripts', 'run_suite.js'),
      junitOut,
      'scripts/fixture_fail.js'
    ], { encoding: 'utf8', env: cleanEnv() });

    assert.equal(result.status, 1, 'Failing test must yield exit code 1');
  } finally {
    try { fs.unlinkSync(testFile); } catch {}
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test('run_suite.js exits non-zero when child process terminates due to a signal', () => {
  const tempDir = fs.mkdtempSync(path.join(process.cwd(), 'scripts', '.test-out-'));
  const testFile = path.join(process.cwd(), 'scripts', 'fixture_signal.js');
  try {
    // Child test runner is killed via SIGKILL (which cannot be caught by node:test)
    // to simulate abnormal process-level termination where spawnSync returns status: null
    fs.writeFileSync(testFile, 'process.kill(process.ppid, "SIGKILL");\n');
    const junitOut = path.join(tempDir, 'junit.xml');

    const result = spawnSync(process.execPath, [
      path.join(process.cwd(), 'scripts', 'run_suite.js'),
      junitOut,
      'scripts/fixture_signal.js'
    ], { encoding: 'utf8', env: cleanEnv() });

    assert.notEqual(result.status, 0, 'Signal termination must never yield exit code 0');
    assert.equal(result.status, 1, 'Signal termination must yield exit code 1');
    assert.match(result.stderr, /signal|unexpectedly|failed/i, 'Stderr should explain abnormal termination');
  } finally {
    try { fs.unlinkSync(testFile); } catch {}
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});
