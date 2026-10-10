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

// The helper tab only carries the siphon:// link. Close it once Siphon takes
// focus (the browser window loses it), so a first-run "Open Siphon?" prompt stays
// up until the user answers it; the timeout only cleans up a declined prompt.
const DEEP_LINK_TAB_TIMEOUT_MS = 60000;
const deepLinkTabs = new Set();

function closeDeepLinkTab(tabId) {
    if (!deepLinkTabs.delete(tabId)) return;
    chrome.tabs.remove(tabId).catch((error) => {
        console.debug("Failed to close temporary Siphon deep-link tab:", error);
    });
}

if (chrome.windows?.onFocusChanged) {
    chrome.windows.onFocusChanged.addListener((windowId) => {
        if (windowId !== chrome.windows.WINDOW_ID_NONE) return;
        for (const tabId of deepLinkTabs) {
            closeDeepLinkTab(tabId);
        }
    });
}

chrome.tabs.onRemoved.addListener((tabId) => {
    deepLinkTabs.delete(tabId);
});

function openDeepLink(deepLink) {
    chrome.tabs.create({ url: deepLink, active: true }, (createdTab) => {
        if (chrome.runtime.lastError) {
            console.warn("Failed to open Siphon deep link:", chrome.runtime.lastError.message);
            return;
        }
        if (createdTab?.id) {
            deepLinkTabs.add(createdTab.id);
            setTimeout(() => closeDeepLinkTab(createdTab.id), DEEP_LINK_TAB_TIMEOUT_MS);
        }
    });
}

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
    if (!url || typeof url !== "string") return;
    if (!url.startsWith("http://") && !url.startsWith("https://")) return;

    const browserSource = await detectBrowserSource();
    let deepLink = `siphon://${host}?url=${encodeURIComponent(url)}&browser=${encodeURIComponent(browserSource)}`;
    const userAgent = typeof navigator !== "undefined" ? navigator.userAgent : "";
    if (userAgent) {
        deepLink += `&ua=${encodeURIComponent(userAgent)}`;
    }

    // Browser credentials never enter the custom URL. Siphon reads Chrome's
    // cookie database directly after receiving the non-secret browser identifier.
    openDeepLink(deepLink);
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
