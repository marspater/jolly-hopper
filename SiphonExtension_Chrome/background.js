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

async function detectBrowserSource() {
    const ua = typeof navigator !== "undefined" ? (navigator.userAgent || "") : "";
    const brands = typeof navigator !== "undefined" && navigator.userAgentData?.brands
        ? navigator.userAgentData.brands.map((item) => item.brand.toLowerCase()).join(" ")
        : "";

    if (/\bEdg\//.test(ua)) return "edge";
    if (/\bOPR\//.test(ua)) return "opera";
    if (/\bVivaldi\//i.test(ua) || brands.includes("vivaldi")) return "vivaldi";
    if (/\bHelium\//i.test(ua) || brands.includes("helium")) return "helium";

    if (typeof navigator !== "undefined" &&
        typeof navigator.brave?.isBrave === "function") {
        try {
            if (await navigator.brave.isBrave()) return "brave";
        } catch {
            // Fall through to Chromium/Chrome detection.
        }
    }

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
    chrome.tabs.create({ url: deepLink, active: true }, (createdTab) => {
        if (chrome.runtime.lastError) {
            console.warn("Failed to open Siphon deep link:", chrome.runtime.lastError.message);
            return;
        }
        if (createdTab?.id) {
            setTimeout(() => {
                chrome.tabs.remove(createdTab.id).catch((error) => {
                    console.debug("Failed to close temporary Siphon deep-link tab:", error);
                });
            }, 3000);
        }
    });
}

if (chrome.action?.onClicked) {
    chrome.action.onClicked.addListener(async (tab) => {
        if (!tab?.url) return;
        await triggerDownload(tab.url, "download");
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
        await triggerDownload(url, host);
    }
});
