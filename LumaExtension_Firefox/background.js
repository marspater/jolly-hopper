browser.runtime.onInstalled.addListener(() => {
    browser.contextMenus.create({
        id: "download-luma",
        title: browser.i18n.getMessage("context_download"),
        contexts: ["link", "video", "page"]
    });

    browser.contextMenus.create({
        id: "fast-download-luma",
        title: browser.i18n.getMessage("context_fast_download"),
        contexts: ["link", "video"]
    });
});

browser.contextMenus.onClicked.addListener((info, tab) => {
    const url = info.linkUrl || info.srcUrl || info.pageUrl;
    if (!url) return;

    let host = "";
    if (info.menuItemId === "download-luma") {
        host = "download";
    } else if (info.menuItemId === "fast-download-luma") {
        host = "fast-download";
    }

    if (host) {
        let domain = "";
        try {
            domain = new URL(url).hostname.replace(/^www\./, "");
        } catch (e) {}

        const cookieQuery = domain ? { domain: domain } : { url: url };
        browser.cookies.getAll(cookieQuery).then((cookies) => {
            let cookieParam = "";
            if (cookies && cookies.length > 0) {
                const cookieHeader = cookies.map(c => `${c.name}=${c.value}`).join('; ');
                cookieParam = `&cookies=${encodeURIComponent(cookieHeader)}`;
            }
            const deepLink = `luma://${host}?url=${encodeURIComponent(url)}${cookieParam}`;
            browser.tabs.create({ url: deepLink, active: false });
        }).catch(() => {
            const deepLink = `luma://${host}?url=${encodeURIComponent(url)}`;
            browser.tabs.create({ url: deepLink, active: false });
        });
    }
});
