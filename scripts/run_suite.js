const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const junitOutput = process.argv[2];
const testFiles = process.argv.slice(3);

if (!junitOutput || testFiles.length === 0) {
  console.error('Usage: run_suite.js <output-junit-path> <test-files...>');
  process.exit(1);
}

fs.mkdirSync(path.dirname(junitOutput), { recursive: true });

const tempJunit = path.join(path.dirname(junitOutput), `raw-${path.basename(junitOutput)}`);

const result = spawnSync(
  process.execPath,
  [
    '--test',
    '--test-reporter=spec',
    '--test-reporter-destination=stdout',
    '--test-reporter=junit',
    `--test-reporter-destination=${tempJunit}`,
    ...testFiles
  ],
  { stdio: ['inherit', 'inherit', 'inherit'] }
);

if (fs.existsSync(tempJunit)) {
  let xml = fs.readFileSync(tempJunit, 'utf8');

  // Strip XML comments
  xml = xml.replace(/<!--[\s\S]*?-->/g, '').trim();

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
  try { fs.unlinkSync(tempJunit); } catch {}
}

process.exit(result.status ?? 0);
