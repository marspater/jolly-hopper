chrome.runtime.onInstalled.addListener(() => {
    chrome.contextMenus.create({
        id: "download-macabolic",
        title: chrome.i18n.getMessage("context_download"),
        contexts: ["link", "video", "page"]
    });

    chrome.contextMenus.create({
        id: "fast-download-macabolic",
        title: chrome.i18n.getMessage("context_fast_download"),
        contexts: ["link", "video"]
    });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
    const url = info.linkUrl || info.srcUrl || info.pageUrl;
    if (!url) return;

    let host = "";
    if (info.menuItemId === "download-macabolic") {
        host = "download";
    } else if (info.menuItemId === "fast-download-macabolic") {
        host = "fast-download";
    }

    if (host) {
        const deepLink = `macabolic://${host}?url=${encodeURIComponent(url)}`;

        // Daha güvenilir tetikleme: Mevcut sekmeyi güncellemek (sayfa değişmez, protokol tetiklenir)
        chrome.tabs.update(tab.id, { url: deepLink });
    }
});
