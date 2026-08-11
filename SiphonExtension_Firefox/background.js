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

browser.contextMenus.onClicked.addListener((info, tab) => {
    const url = info.linkUrl || info.srcUrl || info.pageUrl;
    if (!url) return;

    let host = "";
    if (info.menuItemId === "download-siphon") {
        host = "download";
    } else if (info.menuItemId === "fast-download-siphon") {
        host = "fast-download";
    }

    if (host) {
        const deepLink = `siphon://${host}?url=${encodeURIComponent(url)}`;
        browser.tabs.create({ url: deepLink, active: false });
    }
});
