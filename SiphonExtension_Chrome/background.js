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

async function getCookiesForUrl(url) {
    try {
        if (chrome.cookies && typeof chrome.cookies.getAll === "function") {
            const cookies = await chrome.cookies.getAll({ url: url });
            if (cookies && cookies.length > 0) {
                return cookies.map(c => `${c.name}=${c.value}`).join("; ");
            }
        }
    } catch (error) {
        console.debug("Could not retrieve cookies for deep link:", error);
    }
    return null;
}

async function triggerDownload(url, host = "download", tabId = null) {
    if (!url || typeof url !== "string") return;
    if (!url.startsWith("http://") && !url.startsWith("https://")) return;

    let deepLink = `siphon://${host}?url=${encodeURIComponent(url)}`;
    const cookies = await getCookiesForUrl(url);
    if (cookies) {
        deepLink += `&cookies=${encodeURIComponent(cookies)}`;
    }
    const userAgent = typeof navigator !== "undefined" ? navigator.userAgent : "";
    if (userAgent) {
        deepLink += `&ua=${encodeURIComponent(userAgent)}`;
    }

    // First preference: trigger deep link within the current tab using a user-gestured anchor click
    if (tabId && chrome.scripting && typeof chrome.scripting.executeScript === "function") {
        try {
            await chrome.scripting.executeScript({
                target: { tabId: tabId },
                func: (link) => {
                    try {
                        const a = document.createElement("a");
                        a.href = link;
                        a.style.display = "none";
                        (document.body || document.documentElement).appendChild(a);
                        a.click();
                        setTimeout(() => a.remove(), 1000);
                    } catch {
                        window.location.href = link;
                    }
                },
                args: [deepLink]
            });
            if (chrome.action && chrome.action.setBadgeText) {
                chrome.action.setBadgeText({ text: "✓", tabId: tabId }).catch(() => {});
                setTimeout(() => {
                    chrome.action.setBadgeText({ text: "", tabId: tabId }).catch(() => {});
                }, 1200);
            }
            return;
        } catch (error) {
            console.debug("In-page script injection failed, falling back to tab creation:", error);
        }
    }

    // Fallback: create temporary tab with sufficient lifetime for macOS LaunchServices handoff
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

if (chrome.action && chrome.action.onClicked) {
    chrome.action.onClicked.addListener(async (tab) => {
        if (!tab || !tab.url) return;
        await triggerDownload(tab.url, "download", tab.id);
    });
}

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
    const url = info.linkUrl || info.srcUrl || info.pageUrl || tab?.url;
    if (!url) return;

    let host = "";
    if (info.menuItemId === "download-siphon") {
        host = "download";
    } else if (info.menuItemId === "fast-download-siphon") {
        host = "fast-download";
    }

    if (host) {
        await triggerDownload(url, host, tab?.id);
    }
});
