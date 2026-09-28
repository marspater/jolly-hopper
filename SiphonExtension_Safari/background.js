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
        for (const tabId of [...deepLinkTabs]) {
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

chrome.contextMenus.onClicked.addListener((info, tab) => {
    const url = firstWebURL(info.linkUrl, info.srcUrl, info.pageUrl, tab?.url);
    if (!url) return;

    let host = "";
    if (info.menuItemId === "download-siphon") {
        host = "download";
    } else if (info.menuItemId === "fast-download-siphon") {
        host = "fast-download";
    }

    if (host) {
        openDeepLink("siphon://" + host + "?url=" + encodeURIComponent(url) + "&browser=safari&ua=" + encodeURIComponent(navigator.userAgent || ""));
    }
});
