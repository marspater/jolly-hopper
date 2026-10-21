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

test('run_suite.js converts child signal termination into exit code 1', () => {
  const tempDir = fs.mkdtempSync(path.join(process.cwd(), 'scripts', '.test-out-'));
  const mockRunner = path.join(tempDir, 'mock_runner.js');
  const dummyTest = path.join(process.cwd(), 'scripts', 'fixture_signal_dummy.js');
  try {
    fs.writeFileSync(dummyTest, 'const { test } = require("node:test"); test("dummy", () => {});\n');
    // The child test runner process terminates itself with SIGKILL, so spawnSync returns status: null
    fs.writeFileSync(mockRunner, `process.kill(process.pid, 'SIGKILL');\n`);

    const junitOut = path.join(tempDir, 'junit.xml');
    const env = cleanEnv();
    env.TEST_RUNNER_BIN = process.execPath;

    // Use a wrapper node execution that runs the mock runner script
    const runnerWrapper = path.join(tempDir, 'runner_wrapper.sh');
    fs.writeFileSync(runnerWrapper, `#!/bin/sh\nexec "${process.execPath}" "${mockRunner}" "$@"\n`);
    fs.chmodSync(runnerWrapper, 0o755);
    env.TEST_RUNNER_BIN = runnerWrapper;

    const result = spawnSync(process.execPath, [
      path.join(process.cwd(), 'scripts', 'run_suite.js'),
      junitOut,
      'scripts/fixture_signal_dummy.js'
    ], { encoding: 'utf8', env });

    assert.notEqual(result.status, 0, 'Signal termination must never yield exit code 0');
    assert.equal(result.status, 1, 'Signal termination must yield exit code 1');
    assert.match(result.stderr, /signal|unexpectedly/i, 'Stderr should explain abnormal termination');
  } finally {
    try { fs.unlinkSync(dummyTest); } catch {}
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test('run_suite.js reports spawn errors and exits non-zero', () => {
  const tempDir = fs.mkdtempSync(path.join(process.cwd(), 'scripts', '.test-out-'));
  const dummyTest = path.join(process.cwd(), 'scripts', 'fixture_spawn_err_dummy.js');
  try {
    fs.writeFileSync(dummyTest, 'const { test } = require("node:test"); test("dummy", () => {});\n');
    const junitOut = path.join(tempDir, 'junit.xml');
    const env = cleanEnv();
    env.TEST_RUNNER_BIN = path.join(tempDir, 'nonexistent_test_runner_bin');

    const result = spawnSync(process.execPath, [
      path.join(process.cwd(), 'scripts', 'run_suite.js'),
      junitOut,
      'scripts/fixture_spawn_err_dummy.js'
    ], { encoding: 'utf8', env });

    assert.equal(result.status, 1, 'Spawn error must yield exit code 1');
    assert.match(result.stderr, /failed to spawn/i, 'Stderr should explain spawn failure');
  } finally {
    try { fs.unlinkSync(dummyTest); } catch {}
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test('run_suite.js reports repo-relative file paths so results match discovered atoms', () => {
  const tempDir = fs.mkdtempSync(path.join(process.cwd(), 'scripts', '.test-out-'));
  const testFile = path.join(process.cwd(), 'scripts', 'fixture_relative_paths.js');
  try {
    fs.writeFileSync(testFile, 'const { test, describe } = require("node:test"); test("top", () => {}); describe("group", () => { test("nested", () => {}); });\n');
    const junitOut = path.join(tempDir, 'junit.xml');

    const result = spawnSync(process.execPath, [
      path.join(process.cwd(), 'scripts', 'run_suite.js'),
      junitOut,
      'scripts/fixture_relative_paths.js'
    ], { encoding: 'utf8', env: cleanEnv() });

    assert.equal(result.status, 0, result.stderr);
    const files = [...fs.readFileSync(junitOut, 'utf8').matchAll(/<testcase [^>]*file="([^"]+)"/g)].map((m) => m[1]);
    assert.equal(files.length, 2, 'Both top-level and nested testcases must carry a file attribute');
    assert.deepEqual([...new Set(files)], ['scripts/fixture_relative_paths.js']);
  } finally {
    try { fs.unlinkSync(testFile); } catch {}
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test('run_suite.js attributes results to the atom when the reporter omits file attributes', () => {
  const tempDir = fs.mkdtempSync(path.join(process.cwd(), 'scripts', '.test-out-'));
  const testFile = path.join(process.cwd(), 'scripts', 'fixture_no_file_attr.js');
  try {
    fs.writeFileSync(testFile, '');
    // Mimics older node:test JUnit reporters, which write testcases without a file attribute.
    const mockRunner = path.join(tempDir, 'mock_runner.js');
    fs.writeFileSync(mockRunner, `const dest = process.argv.find((a) => a.startsWith('--test-reporter-destination=') && !a.endsWith('=stdout')).split('=')[1];
require('node:fs').writeFileSync(dest, '<testsuites><testcase name="a" classname="test"/><testsuite name="g"><testcase name="b"></testcase></testsuite></testsuites>');
`);
    const runnerWrapper = path.join(tempDir, 'runner_wrapper.sh');
    fs.writeFileSync(runnerWrapper, `#!/bin/sh\nexec "${process.execPath}" "${mockRunner}" "$@"\n`);
    fs.chmodSync(runnerWrapper, 0o755);
    const env = cleanEnv();
    env.TEST_RUNNER_BIN = runnerWrapper;
    const junitOut = path.join(tempDir, 'junit.xml');

    const result = spawnSync(process.execPath, [
      path.join(process.cwd(), 'scripts', 'run_suite.js'),
      junitOut,
      'scripts/fixture_no_file_attr.js'
    ], { encoding: 'utf8', env });

    assert.equal(result.status, 0, result.stderr);
    const files = [...fs.readFileSync(junitOut, 'utf8').matchAll(/<testcase [^>]*file="([^"]+)"/g)].map((m) => m[1]);
    assert.deepEqual(files, ['scripts/fixture_no_file_attr.js', 'scripts/fixture_no_file_attr.js']);
  } finally {
    try { fs.unlinkSync(testFile); } catch {}
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});
