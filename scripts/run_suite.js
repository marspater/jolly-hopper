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

const result = spawnSync(
  testRunnerBin,
  [
    '--test',
    '--test-reporter=spec',
    '--test-reporter-destination=stdout',
    '--test-reporter=junit',
    `--test-reporter-destination=${tempJunit}`,
    '--',
    ...validatedFiles
  ],
  { stdio: ['inherit', 'inherit', 'inherit'] }
);

if (fs.existsSync(tempJunit)) {
  const safeTemp = safePath(tempJunit);
  let xml = fs.readFileSync(safeTemp, 'utf8');

  // Strip XML comments recursively to prevent multi-character sanitization bypass (CodeQL: js/incomplete-multi-character-sanitization)
  let prevXml;
  do {
    prevXml = xml;
    xml = xml.replace(/<!--[\s\S]*?-->/g, '');
  } while (xml !== prevXml);
  xml = xml.trim();

  // Wrap top-level <testcase> elements in <testsuite> elements
  const match = xml.match(/^([\s\S]*?<testsuites[^>]*>)([\s\S]*?)(<\/testsuites>[\s\S]*)$/i);
  if (match) {
    const [, header, body, footer] = match;
    const lines = body.split('\n');
    let newBody = '';
    let currentOrphanSuite = null;
    let inSuite = false;

    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed.startsWith('<testsuite')) {
        if (currentOrphanSuite) {
          newBody += `\t</testsuite>\n`;
          currentOrphanSuite = null;
        }
        inSuite = true;
        newBody += line + '\n';
      } else if (trimmed.startsWith('</testsuite>')) {
        inSuite = false;
        newBody += line + '\n';
      } else if (!inSuite && trimmed.startsWith('<testcase')) {
        const fileMatch = trimmed.match(/file="([^"]+)"/);
        const fileAttr = fileMatch ? fileMatch[1] : '';
        const relPath = fileAttr ? path.relative(process.cwd(), fileAttr) : 'tests';

        if (currentOrphanSuite !== relPath) {
          if (currentOrphanSuite) {
            newBody += `\t</testsuite>\n`;
          }
          currentOrphanSuite = relPath;
          newBody += `\t<testsuite name="${relPath}" file="${relPath}">\n`;
        }
        newBody += '\t' + line + '\n';
      } else {
        newBody += (currentOrphanSuite ? '\t' : '') + line + '\n';
      }
    }
    if (currentOrphanSuite) {
      newBody += `\t</testsuite>\n`;
    }
    xml = `${header}\n${newBody}${footer}`;
  }

  fs.writeFileSync(junitOutput, xml, 'utf8');
  try { fs.unlinkSync(safeTemp); } catch {}
}

if (result.error) {
  console.error('Failed to spawn test runner:', result.error.message || result.error);
  process.exit(1);
}

if (result.status === null) {
  console.error(`Test runner terminated unexpectedly by signal: ${result.signal || 'unknown'}`);
  process.exit(1);
}

process.exit(result.status);
