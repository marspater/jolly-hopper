browser.runtime.onInstalled.addListener(() => {
    browser.contextMenus.create({
        id: "download-velox",
        title: browser.i18n.getMessage("context_download"),
        contexts: ["link", "video", "page"]
    });

    browser.contextMenus.create({
        id: "fast-download-velox",
        title: browser.i18n.getMessage("context_fast_download"),
        contexts: ["link", "video"]
    });
});

browser.contextMenus.onClicked.addListener((info, tab) => {
    const url = info.linkUrl || info.srcUrl || info.pageUrl;
    if (!url) return;

    let host = "";
    if (info.menuItemId === "download-velox") {
        host = "download";
    } else if (info.menuItemId === "fast-download-velox") {
        host = "fast-download";
    }

    if (host) {
        browser.cookies.getAll({ url: url }).then((cookies) => {
            let cookieParam = "";
            if (cookies && cookies.length > 0) {
                const cookieHeader = cookies.map(c => `${c.name}=${c.value}`).join('; ');
                cookieParam = `&cookies=${encodeURIComponent(cookieHeader)}`;
            }
            const deepLink = `velox://${host}?url=${encodeURIComponent(url)}${cookieParam}`;
            browser.tabs.create({ url: deepLink, active: false });
        }).catch(() => {
            const deepLink = `velox://${host}?url=${encodeURIComponent(url)}`;
            browser.tabs.create({ url: deepLink, active: false });
        });
    }
});
