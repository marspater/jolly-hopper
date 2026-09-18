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

chrome.contextMenus.onClicked.addListener((info) => {
    const url = info.linkUrl || info.srcUrl || info.pageUrl;
    if (!url || typeof url !== "string" || !/^https?:\/\//i.test(url)) return;

    let host = "";
    if (info.menuItemId === "download-siphon") {
        host = "download";
    } else if (info.menuItemId === "fast-download-siphon") {
        host = "fast-download";
    }

    if (host) {
        const deepLink = "siphon://" + host + "?url=" + encodeURIComponent(url) + "&browser=safari&ua=" + encodeURIComponent(navigator.userAgent || "");
        chrome.tabs.create({ url: deepLink, active: false }, (createdTab) => {
            if (chrome.runtime.lastError) {
                console.warn("Failed to open Siphon deep link:", chrome.runtime.lastError.message);
                return;
            }
            if (createdTab && createdTab.id) {
                setTimeout(() => {
                    chrome.tabs.remove(createdTab.id).catch((error) => {
                        console.debug("Failed to close temporary Siphon deep-link tab:", error);
                    });
                }, 3500);
            }
        });
    }
});
