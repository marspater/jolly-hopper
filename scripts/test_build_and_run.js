const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

for (const shutsDown of [true, false]) {
    test(`launcher ${shutsDown ? "waits for shutdown" : "refuses overlapping instances on timeout"}`, () => {
        const temp = fs.mkdtempSync(path.join(os.tmpdir(), "siphon-launch-test-"));
        try {
            const calls = path.join(temp, "calls");
            const count = path.join(temp, "polls");
            const commands = {
                xcodebuild: "exit 0",
                codesign: "exit 0",
                pkill: `echo terminate >> '${calls}'`,
                pgrep: `counter=0; if [ -f '${count}' ]; then read -r counter < '${count}'; fi
counter=$((counter+1)); echo "$counter" > '${count}'
echo poll >> '${calls}'
${shutsDown ? '[ "$counter" -lt 4 ]' : 'exit 0'}`,
                sleep: "exit 0",
                open: `echo open >> '${calls}'`
            };
            for (const [name, body] of Object.entries(commands)) {
                fs.writeFileSync(path.join(temp, name), "#!/bin/bash\n" + body + "\n", { mode: 0o755 });
            }
            const result = spawnSync("/bin/bash", [path.join(__dirname, "build_and_run.sh"), "--run"], {
                env: { ...process.env, PATH: temp + path.delimiter + process.env.PATH }, encoding: "utf8"
            });
            const events = fs.readFileSync(calls, "utf8").trim().split("\n");
            assert.ok(events.includes("terminate"));
            assert.ok(events.filter(event => event === "poll").length >= 4);
            assert.equal(events.includes("open"), shutsDown);
            assert.equal(result.status, shutsDown ? 0 : 1, result.stderr);
            if (shutsDown) assert.equal(events.at(-1), "open");
        } finally {
            fs.rmSync(temp, { recursive: true, force: true });
        }
    });
}
