const assert = require("node:assert/strict");
const { originalURLs, init } = require("./capture_original_mp4.js");

const original = "https://cdn.example.com/video_source.mp4?Policy=sample&Signature=a%2Bb&u=123";
assert.deepEqual(originalURLs({ files: { source: { url: original } } }), [original]);
assert.deepEqual(originalURLs([original, original]), [original]);
assert.deepEqual(originalURLs([
    "https://cdn.example.com/master.m3u8?Signature=sample",
    "https://cdn.example.com/preview.mp4",
    "https://user:password@cdn.example.com/video_source.mp4",
    "javascript:video_source.mp4",
    "https://cdn.example.com/page?url=video_source.mp4"
]), []);
const cycle = { url: original };
cycle.self = cycle;
assert.deepEqual(originalURLs(cycle), [original]);

function element() {
    return {
        children: [], style: {}, handlers: {},
        append(...items) { this.children.push(...items); },
        addEventListener(type, handler) { this.handlers[type] = handler; },
        remove() { this.removed = true; }
    };
}
const body = element();
const response = {
    headers: { get: () => "application/json" },
    clone: () => ({ json: async () => ({ files: { source: { url: original } } }) })
};
let fetchArgs;
const previousFetch = async (...args) => { fetchArgs = args; return response; };
class FakeXHR {
    constructor() { this.handlers = {}; this.responseType = "json"; }
    addEventListener(type, handler) { this.handlers[type] = handler; }
    getResponseHeader() { return "application/json"; }
    send(value) { return value; }
}
const previousSend = FakeXHR.prototype.send;
const window = { fetch: previousFetch };
const env = {
    window,
    XMLHttpRequest: FakeXHR,
    navigator: { userAgent: "Test Safari" },
    document: { body, createElement: element, querySelectorAll: () => [] },
    performance: { getEntriesByType: () => [] }
};

init(env);
init(env);
assert.equal(body.children.length, 1, "Repeated activation must not duplicate hooks or panels");

// Test Edge browser detection
const edgeBody = element();
class EdgeFakeXHR {
    send(value) { return value; }
}
init({
    window: { fetch: previousFetch },
    XMLHttpRequest: EdgeFakeXHR,
    navigator: { userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0" },
    document: { body: edgeBody, createElement: element, querySelectorAll: () => [] },
    performance: { getEntriesByType: () => [{ name: original }] }
});
const edgeLink = new URL(edgeBody.children[0].children[2].children[0].href);
assert.equal(edgeLink.searchParams.get("browser"), "edge");

async function main() {
    const options = { headers: { "x-example": "unchanged" } };
    assert.equal(await window.fetch("/api/video", options), response);
    await new Promise(resolve => setImmediate(resolve));
    assert.deepEqual(fetchArgs, ["/api/video", options], "Preserve the page's authenticated request");
    const panel = body.children[0];
    const links = panel.children[2];
    assert.equal(links.children.length, 1);
    const handoff = new URL(links.children[0].href);
    assert.equal(handoff.protocol, "siphon:");
    assert.equal(handoff.searchParams.get("url"), original, "Preserve the exact signed source URL");
    assert.equal(handoff.searchParams.get("browser"), "safari");
    assert.equal(handoff.searchParams.get("cookies"), null);
    const xhr = new FakeXHR();
    xhr.response = { source: original.replace("video_source", "second_source") };
    assert.equal(xhr.send("unchanged body"), "unchanged body");
    xhr.handlers.load();
    xhr.handlers.load();
    assert.equal(links.children.length, 2, "XHR originals must be captured without duplicates");
    panel.children[3].handlers.click();
    assert.equal(window.fetch, previousFetch);
    assert.equal(FakeXHR.prototype.send, previousSend);
    assert.equal(panel.removed, true);
    xhr.response = { source: original.replace("video_source", "third_source") };
    xhr.handlers.load();
    assert.equal(links.children.length, 2, "Stopping must disable outstanding capture listeners");
    console.log("Original MP4 capture checks passed.");
}

main().catch(error => {
    console.error(error);
    process.exitCode = 1;
});
