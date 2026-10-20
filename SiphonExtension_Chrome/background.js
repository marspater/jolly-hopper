/* global chrome */

chrome.runtime.onInstalled.addListener(() => {
    chrome.contextMenus.create({
        id: "download-siphon",
        title: chrome.i18n.getMessage("context_download"),
        contexts: ["link", "video", "page"]
    });

    chrome.contextMenus.create({
        id: "fast-download-siphon",
        title: chrome.i18n.getMessage("context_fast_download"),
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
    await chrome.storage.session.remove(tabKey(tabId));
    await chrome.alarms.clear(tabKey(tabId));
}

async function closeDeepLinkTab(tabId, record) {
    let tab;
    try {
        tab = await chrome.tabs.get(tabId);
    } catch {
        await forgetDeepLinkTab(tabId);
        return;
    }
    // A navigated helper tab belongs to the user now. Never close it.
    const isBlankHelper = !tab.pendingUrl && (!tab.url || tab.url === "about:blank");
    if (tab.pendingUrl === record.url || tab.url === record.url || isBlankHelper) {
        await chrome.tabs.remove(tabId);
    }
    await forgetDeepLinkTab(tabId);
}

async function reconcileDeepLinkTabs(closeAll = false) {
    try {
        const records = await chrome.storage.session.get(null);
        await Promise.all(Object.entries(records).map(async ([key, record]) => {
            if (!key.startsWith(DEEP_LINK_TAB_PREFIX)) return;
            const tabId = Number(key.slice(DEEP_LINK_TAB_PREFIX.length));
            if (!Number.isInteger(tabId) || !Number.isFinite(record.deadline)) return;
            if (closeAll || record.deadline <= Date.now()) {
                await closeDeepLinkTab(tabId, record);
            } else {
                await chrome.alarms.create(key, { when: record.deadline });
            }
        }));
    } catch (error) {
        reportCleanupFailure(error);
    }
}

function reportCleanupFailure(error) {
    console.warn("Temporary Siphon tab cleanup failed:", error);
}

chrome.alarms.onAlarm.addListener(async (alarm) => {
    if (!alarm.name.startsWith(DEEP_LINK_TAB_PREFIX)) return;
    try {
        const records = await chrome.storage.session.get(alarm.name);
        const record = records[alarm.name];
        if (record) await reconcileDeepLinkTabs();
    } catch (error) {
        reportCleanupFailure(error);
    }
});

// Opening siphon:// can move focus to Siphon before a new helper tab's record
// is stored; openDeepLink checks this once the record exists.
let browserFocused = true;

if (chrome.windows?.onFocusChanged) {
    chrome.windows.onFocusChanged.addListener((windowId) => {
        browserFocused = windowId !== chrome.windows.WINDOW_ID_NONE;
        if (!browserFocused) {
            reconcileDeepLinkTabs(true).catch(reportCleanupFailure);
        }
    });
}

chrome.tabs.onRemoved.addListener((tabId) => {
    forgetDeepLinkTab(tabId).catch(reportCleanupFailure);
});

async function openDeepLink(deepLink) {
    try {
        const tab = await chrome.tabs.create({ url: deepLink, active: true });
        if (!Number.isInteger(tab?.id)) return;
        const record = { url: deepLink, deadline: Date.now() + DEEP_LINK_TAB_TIMEOUT_MS };
        await chrome.storage.session.set({ [tabKey(tab.id)]: record });
        await chrome.alarms.create(tabKey(tab.id), { when: record.deadline });
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

async function detectBrowserSource() {
    const nav = typeof navigator !== "undefined" ? navigator : null;
    const ua = nav?.userAgent || "";
    const brands = nav?.userAgentData?.brands?.map((item) => item.brand.toLowerCase()).join(" ") || "";

    if (/\bEdg\//.test(ua)) return "edge";
    if (/\bOPR\//.test(ua)) return "opera";
    if (/\bVivaldi\//i.test(ua) || brands.includes("vivaldi")) return "vivaldi";
    if (/\bHelium\//i.test(ua) || brands.includes("helium")) return "helium";
    if (/\bArc\//i.test(ua) || brands.includes("arc")) return "arc";

    try {
        if (typeof nav?.brave?.isBrave === "function" && await nav.brave.isBrave()) {
            return "brave";
        }
    } catch {
        // Fall through to Chromium/Chrome detection.
    }

    // navigator.brave may be missing in the extension service worker; the
    // brand list is not.
    if (brands.includes("brave")) return "brave";

    if (brands.includes("chromium") && !brands.includes("google chrome")) {
        return "chromium";
    }
    return "chrome";
}

async function triggerDownload(url, host = "download") {
    if (!firstWebURL(url)) return;

    const browserSource = await detectBrowserSource();
    let deepLink = `siphon://${host}?url=${encodeURIComponent(url)}&browser=${encodeURIComponent(browserSource)}`;
    const userAgent = typeof navigator !== "undefined" ? navigator.userAgent : "";
    if (userAgent) {
        deepLink += `&ua=${encodeURIComponent(userAgent)}`;
    }

    // Browser credentials never enter the custom URL. Siphon reads Chrome's
    // cookie database directly after receiving the non-secret browser identifier.
    await openDeepLink(deepLink);
}

if (chrome.action?.onClicked) {
    chrome.action.onClicked.addListener(async (tab) => {
        if (!tab?.url) return;
        await triggerDownload(tab.url, "download");
    });
}

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
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
