/* global browser */

browser.runtime.onInstalled.addListener(() => {
    browser.contextMenus.create({
        id: "download-siphon",
        title: browser.i18n.getMessage("context_download"),
        contexts: ["link", "video", "page"]
    });

    browser.contextMenus.create({
        id: "fast-download-siphon",
        title: browser.i18n.getMessage("context_fast_download"),
        contexts: ["link", "video"]
    });
});

// Session storage and alarms survive Manifest V3 worker suspension. Each tab
// gets its own record, so concurrent handoffs cannot overwrite another tab.
const DEEP_LINK_TAB_TIMEOUT_MS = 60000;
const DEEP_LINK_TAB_PREFIX = "siphon-deep-link-tab:";

function tabKey(tabId) {
    return DEEP_LINK_TAB_PREFIX + tabId;
}

async function forgetDeepLinkTab(tabId) {
    await browser.storage.session.remove(tabKey(tabId));
    await browser.alarms.clear(tabKey(tabId));
}

async function closeDeepLinkTab(tabId, record) {
    let tab;
    try {
        tab = await browser.tabs.get(tabId);
    } catch {
        await forgetDeepLinkTab(tabId);
        return;
    }
    // A navigated helper tab belongs to the user now. Never close it.
    const isBlankHelper = !tab.pendingUrl && (!tab.url || tab.url === "about:blank");
    if (tab.pendingUrl === record.url || tab.url === record.url || isBlankHelper) {
        await browser.tabs.remove(tabId);
    }
    await forgetDeepLinkTab(tabId);
}

async function reconcileDeepLinkTabs(closeAll = false) {
    try {
        const records = await browser.storage.session.get(null);
        await Promise.all(Object.entries(records).map(async ([key, record]) => {
            if (!key.startsWith(DEEP_LINK_TAB_PREFIX)) return;
            const tabId = Number(key.slice(DEEP_LINK_TAB_PREFIX.length));
            if (!Number.isInteger(tabId) || !Number.isFinite(record.deadline)) return;
            if (closeAll || record.deadline <= Date.now()) {
                await closeDeepLinkTab(tabId, record);
            } else {
                await browser.alarms.create(key, { when: record.deadline });
            }
        }));
    } catch (error) {
        reportCleanupFailure(error);
    }
}

function reportCleanupFailure(error) {
    console.warn("Temporary Siphon tab cleanup failed:", error);
}

browser.alarms.onAlarm.addListener(async (alarm) => {
    if (!alarm.name.startsWith(DEEP_LINK_TAB_PREFIX)) return;
    try {
        const records = await browser.storage.session.get(alarm.name);
        const record = records[alarm.name];
        if (record) await reconcileDeepLinkTabs();
    } catch (error) {
        reportCleanupFailure(error);
    }
});

// Opening siphon:// can move focus to Siphon before a new helper tab's record
// is stored; openDeepLink checks this once the record exists.
let browserFocused = true;

if (browser.windows?.onFocusChanged) {
    browser.windows.onFocusChanged.addListener((windowId) => {
        browserFocused = windowId !== browser.windows.WINDOW_ID_NONE;
        if (!browserFocused) {
            reconcileDeepLinkTabs(true).catch(reportCleanupFailure);
        }
    });
}

browser.tabs.onRemoved.addListener((tabId) => {
    forgetDeepLinkTab(tabId).catch(reportCleanupFailure);
});

async function openDeepLink(deepLink) {
    try {
        const tab = await browser.tabs.create({ url: deepLink, active: true });
        if (!Number.isInteger(tab?.id)) return;
        const record = { url: deepLink, deadline: Date.now() + DEEP_LINK_TAB_TIMEOUT_MS };
        await browser.storage.session.set({ [tabKey(tab.id)]: record });
        await browser.alarms.create(tabKey(tab.id), { when: record.deadline });
        if (!browserFocused) await reconcileDeepLinkTabs(true);
    } catch (error) {
        console.warn("Failed to open Siphon deep link:", error);
    }
}

// Classic extension workers cannot use top-level await. Reconciliation
// handles errors internally and never delays synchronous event registration.
void reconcileDeepLinkTabs(); // NOSONAR

// Players built on Media Source Extensions expose a blob: srcUrl, which Siphon
// cannot fetch. Use the first web address among the link, media and page URLs.
function firstWebURL(...candidates) {
    return candidates.find((url) => typeof url === "string" && /^https?:\/\//i.test(url));
}

async function triggerDownload(url, host = "download") {
    if (!firstWebURL(url)) return;
    await openDeepLink("siphon://" + host + "?url=" + encodeURIComponent(url) + "&browser=safari&ua=" + encodeURIComponent(navigator.userAgent || ""));
}

browser.action.onClicked.addListener(async (tab) => {
    await triggerDownload(tab?.url);
});

browser.contextMenus.onClicked.addListener(async (info, tab) => {
    const url = firstWebURL(info.linkUrl, info.srcUrl, info.pageUrl, tab?.url);
    if (!url) return;

    let host = "";
    if (info.menuItemId === "download-siphon") {
        host = "download";
    } else if (info.menuItemId === "fast-download-siphon") {
        host = "fast-download";
    }

    if (host) {
        await triggerDownload(url, host);
    }
});
