const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");

const source = fs.readFileSync(path.join(__dirname, "../SiphonExtension_Chrome/background.js"), "utf8");
const prefix = "siphon-deep-link-tab:";
const handoff = "siphon://download?url=https%3A%2F%2Fexample.com%2Fvideo";
const flush = async () => {
    for (let i = 0; i < 4; i++) await new Promise(setImmediate);
};

function mockBrowser(extension = "Chrome") {
    const records = {};
    const tabs = new Map();
    const alarms = new Map();
    let nextTab = 1;
    let now = 100000;
    let events;
    const event = () => {
        const listeners = [];
        return { addListener: (fn) => listeners.push(fn), fire: (...args) => Promise.all(listeners.map((fn) => fn(...args))) };
    };
    function startWorker() {
        events = { alarm: event(), focus: event(), removed: event() };
        const chrome = {
            runtime: { onInstalled: event() },
            contextMenus: { create() {}, onClicked: event() },
            action: { onClicked: event() },
            i18n: { getMessage: (key) => key },
            windows: { WINDOW_ID_NONE: -1, onFocusChanged: events.focus },
            storage: { session: {
                async get(key) { return structuredClone(key === null ? records : { [key]: records[key] }); },
                async set(values) { Object.assign(records, structuredClone(values)); },
                async remove(key) { delete records[key]; }
            } },
            alarms: {
                onAlarm: events.alarm,
                async create(name, details) { alarms.set(name, structuredClone(details)); },
                async clear(name) { return alarms.delete(name); }
            },
            tabs: {
                onRemoved: events.removed,
                async create({ url }) {
                    const tab = { id: nextTab++, url };
                    tabs.set(tab.id, tab);
                    return { ...tab };
                },
                async get(id) {
                    if (!tabs.has(id)) throw new Error("Tab no longer exists");
                    return { ...tabs.get(id) };
                },
                async remove(id) { tabs.delete(id); await events.removed.fire(id); }
            }
        };
        const context = vm.createContext({ chrome, browser: chrome, console, navigator: { userAgent: "Chrome" }, Date: class extends Date { static now() { return now; } } });
        const workerSource = extension === "Chrome" ? source : fs.readFileSync(path.join(__dirname, `../SiphonExtension_${extension}/background.js`), "utf8");
        vm.runInContext(workerSource, context);
        context.actionEvent = chrome.action.onClicked;
        context.menuEvent = chrome.contextMenus.onClicked;
        return context;
    }
    return { records, tabs, alarms, startWorker, advance: (ms) => { now += ms; }, fireAlarm: (name) => events.alarm.fire({ name }), loseFocus: () => events.focus.fire(-1), remove: (id) => events.removed.fire(id) };
}

for (const extension of ["Chrome", "Firefox", "Safari"]) {
    test(`${extension}: alarm closes a helper after worker restart, including a declined blank tab`, async () => {
        const browser = mockBrowser(extension);
        await browser.startWorker().openDeepLink(handoff);
        await flush();
        assert.equal(browser.records[prefix + 1].deadline, 160000);
        browser.tabs.get(1).url = "about:blank";
        browser.startWorker();
        await flush();
        browser.advance(60000);
        await browser.fireAlarm(prefix + 1);
        await flush();
        assert.equal(browser.tabs.size, 0);
        assert.equal(Object.keys(browser.records).length, 0);
        assert.equal(browser.alarms.size, 0);
    });

    test(`${extension}: activation recreates lost alarms without closing tabs before the deadline`, async () => {
        const browser = mockBrowser(extension);
        await browser.startWorker().openDeepLink(handoff);
        browser.alarms.clear();
        browser.startWorker();
        await flush();
        assert.equal(browser.alarms.get(prefix + 1).when, 160000);
        await browser.fireAlarm(prefix + 1);
        await flush();
        assert.equal(browser.tabs.size, 1);
    });

    test(`${extension}: concurrent handoffs survive restart and focus loss cleans both`, async () => {
        const browser = mockBrowser(extension);
        const worker = browser.startWorker();
        await Promise.all([worker.openDeepLink(handoff), worker.openDeepLink(handoff + "2")]);
        assert.equal(Object.keys(browser.records).length, 2);
        browser.startWorker();
        await flush();
        await browser.loseFocus();
        await flush();
        assert.equal(browser.tabs.size, 0);
        assert.equal(Object.keys(browser.records).length, 0);
    });

    test(`${extension}: focus lost before the helper is recorded still closes it`, async () => {
        const browser = mockBrowser(extension);
        const opening = browser.startWorker().openDeepLink(handoff);
        // macOS hands focus to Siphon as soon as the tab opens the link.
        await browser.loseFocus();
        await opening;
        await flush();
        assert.equal(browser.tabs.size, 0);
        assert.equal(Object.keys(browser.records).length, 0);
    });

    test(`${extension}: cleanup never closes a helper that navigated to another page`, async () => {
        const browser = mockBrowser(extension);
        await browser.startWorker().openDeepLink(handoff);
        browser.tabs.get(1).url = "https://example.com/important";
        browser.advance(60000);
        await browser.fireAlarm(prefix + 1);
        await flush();
        assert.equal(browser.tabs.size, 1);
        assert.equal(Object.keys(browser.records).length, 0);
    });

    test(`${extension}: activation reconciles overdue and already-removed tabs`, async () => {
        const browser = mockBrowser(extension);
        const worker = browser.startWorker();
        await worker.openDeepLink(handoff);
        await worker.openDeepLink(handoff + "2");
        browser.tabs.delete(2);
        browser.advance(60000);
        browser.startWorker();
        await flush();
        assert.equal(browser.tabs.size, 0);
        assert.equal(Object.keys(browser.records).length, 0);
        assert.equal(browser.alarms.size, 0);
    });

}

for (const extension of ["Firefox", "Safari"]) {
    test(`${extension}: toolbar handoff is durable and never closes a navigated tab`, async () => {
        const browser = mockBrowser(extension);
        const worker = browser.startWorker();
        await worker.actionEvent.fire({ url: "https://example.com/video" });
        await flush();
        const link = new URL(browser.tabs.get(1).url);
        assert.equal(link.protocol, "siphon:");
        assert.equal(link.searchParams.get("browser"), extension.toLowerCase());
        assert.equal(link.searchParams.get("cookies"), null);
        browser.tabs.get(1).url = "https://example.com/important";
        browser.startWorker();
        await flush();
        browser.advance(60000);
        await browser.fireAlarm(prefix + 1);
        await flush();
        assert.equal(browser.tabs.size, 1);
        assert.equal(Object.keys(browser.records).length, 0);
        const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, `../SiphonExtension_${extension}/manifest.json`)));
        assert.ok(manifest.action);
        for (const size of ["16", "48", "128"]) {
            assert.ok(fs.existsSync(path.join(__dirname, `../SiphonExtension_${extension}`, manifest.icons[size])), `${size} px icon`);
            assert.equal(manifest.action.default_icon[size], manifest.icons[size]);
        }
        assert.ok(manifest.permissions.includes("storage"));
        assert.ok(manifest.permissions.includes("alarms"));
    });
    test(`${extension}: context handoff closes only its own helper after focus loss`, async () => {
        const browser = mockBrowser(extension);
        const worker = browser.startWorker();
        await worker.menuEvent.fire({ menuItemId: "download-siphon", srcUrl: "blob:video", pageUrl: "https://example.com/page" }, {});
        await flush();
        assert.equal(new URL(browser.tabs.get(1).url).searchParams.get("url"), "https://example.com/page");
        browser.startWorker();
        await flush();
        await browser.loseFocus();
        await flush();
        assert.equal(browser.tabs.size, 0);
    });
}
