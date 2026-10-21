const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const rawJunitOutput = process.argv[2];
const rawTestFiles = process.argv.slice(3);

if (!rawJunitOutput || rawTestFiles.length === 0) {
  console.error('Usage: run_suite.js <output-junit-path> <test-files...>');
  process.exit(1);
}

function safePath(filePath) {
  const resolved = fs.realpathSync(filePath);
  const baseDir = fs.realpathSync(process.cwd());
  if (resolved !== baseDir && !resolved.startsWith(baseDir + path.sep)) {
    throw new Error(`path '${filePath}' is outside the allowed directory`);
  }
  return resolved;
}

function safeOutputPath(filePath) {
  const dir = path.dirname(filePath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
  const realDir = fs.realpathSync(dir);
  const baseDir = fs.realpathSync(process.cwd());
  if (realDir !== baseDir && !realDir.startsWith(baseDir + path.sep)) {
    throw new Error(`path '${filePath}' is outside the allowed directory`);
  }
  const basename = path.basename(filePath);
  if (!/^[A-Za-z0-9_.-]+$/.test(basename)) {
    throw new Error(`invalid filename: '${basename}'`);
  }
  return path.join(realDir, basename);
}

// Validate output paths against traversal
const junitOutput = safeOutputPath(rawJunitOutput);
const tempJunit = safeOutputPath(path.join(path.dirname(rawJunitOutput), `raw-${path.basename(rawJunitOutput)}`));

// Validate test files against argument injection and traversal
const validatedFiles = rawTestFiles.map((file) => {
  if (!file || !/^[A-Za-z0-9_./-]+$/.test(file) || file.startsWith('-')) {
    throw new Error(`Invalid test file argument: ${file}`);
  }
  return safePath(file);
});

const testRunnerBin = process.env.TEST_RUNNER_BIN || process.execPath;

function stripComments(xml) {
  // Strip XML comments recursively to prevent multi-character sanitization bypass (CodeQL: js/incomplete-multi-character-sanitization)
  let prevXml;
  do {
    prevXml = xml;
    xml = xml.replace(/<!--[\s\S]*?-->/g, '');
  } while (xml !== prevXml);
  return xml;
}

// Run each file in its own process so every result can be attributed to the atom that discover listed:
// older node:test JUnit reporters omit the file attribute, and newer ones report absolute paths.
let exitStatus = 0;
let suites = '';
for (const file of validatedFiles) {
  const relPath = path.relative(process.cwd(), file);
  const result = spawnSync(
    testRunnerBin,
    [
      '--test',
      '--test-reporter=spec',
      '--test-reporter-destination=stdout',
      '--test-reporter=junit',
      `--test-reporter-destination=${tempJunit}`,
      '--',
      file
    ],
    { stdio: ['inherit', 'inherit', 'inherit'] }
  );

  if (fs.existsSync(tempJunit)) {
    const safeTemp = safePath(tempJunit);
    const xml = stripComments(fs.readFileSync(safeTemp, 'utf8'));
    const body = (xml.match(/<testsuites[^>]*>([\s\S]*?)<\/testsuites>/i) || [, ''])[1]
      .replace(/<testcase\b([^>]*?)(\s+file="[^"]*")?(\s*\/?>)/g, `<testcase$1 file="${relPath}"$3`);
    suites += `\t<testsuite name="${relPath}" file="${relPath}">${body}</testsuite>\n`;
    try { fs.unlinkSync(safeTemp); } catch {}
  }

  if (result.error) {
    console.error('Failed to spawn test runner:', result.error.message || result.error);
    exitStatus = 1;
  } else if (result.status === null) {
    console.error(`Test runner terminated unexpectedly by signal: ${result.signal || 'unknown'}`);
    exitStatus = 1;
  } else if (result.status !== 0 && exitStatus === 0) {
    exitStatus = result.status;
  }
}

fs.writeFileSync(junitOutput, `<?xml version="1.0" encoding="utf-8"?>\n<testsuites>\n${suites}</testsuites>\n`, 'utf8');
process.exit(exitStatus);
