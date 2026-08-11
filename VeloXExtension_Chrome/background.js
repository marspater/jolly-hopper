chrome.runtime.onInstalled.addListener(() => {
    chrome.contextMenus.create({
        id: "download-velox",
        title: chrome.i18n.getMessage("context_download"),
        contexts: ["link", "video", "page"]
    });

    chrome.contextMenus.create({
        id: "fast-download-velox",
        title: chrome.i18n.getMessage("context_fast_download"),
        contexts: ["link", "video"]
    });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
    const url = info.linkUrl || info.srcUrl || info.pageUrl;
    if (!url) return;

    let host = "";
    if (info.menuItemId === "download-velox") {
        host = "download";
    } else if (info.menuItemId === "fast-download-velox") {
        host = "fast-download";
    }

    if (host) {
        chrome.cookies.getAll({ url: url }, (cookies) => {
            let cookieParam = "";
            if (cookies && cookies.length > 0) {
                const cookieHeader = cookies.map(c => `${c.name}=${c.value}`).join('; ');
                cookieParam = `&cookies=${encodeURIComponent(cookieHeader)}`;
            }
            const deepLink = `velox://${host}?url=${encodeURIComponent(url)}${cookieParam}`;
            chrome.tabs.create({ url: deepLink, active: false });
        });
    }
});
