// Run as a bookmarklet on the signed-in page, then open the desired video.
// Only URLs actually returned by the page are used; signatures are never changed.
(() => {
    function originalURLs(value) {
        const urls = new Set();
        const pending = [value];
        const visited = new Set();
        // ponytail: bound large responses; raise the ceiling if real pages exceed it.
        for (let count = 0; pending.length && count < 50000; count++) {
            const item = pending.pop();
            if (typeof item === "string") {
                try {
                    const url = new URL(item);
                    if (["https:", "http:"].includes(url.protocol) &&
                        !url.username && !url.password && /_source\.mp4$/i.test(url.pathname)) {
                        urls.add(item);
                    }
                } catch (_) { /* Response text is usually not a URL. */ }
            } else if (item && typeof item === "object" && !visited.has(item)) {
                visited.add(item);
                pending.push(...Object.values(item));
            }
        }
        return [...urls];
    }

    if (typeof module !== "undefined" && module.exports) {
        module.exports = { originalURLs };
        return;
    }
    if (window.__siphonOriginalCapture) return;

    const panel = document.createElement("aside");
    panel.style.cssText = "position:fixed;right:16px;bottom:16px;z-index:2147483647;background:white;color:black;padding:16px;border:1px solid #888;border-radius:12px;font:14px system-ui;max-width:360px;max-height:50vh;overflow:auto";
    const heading = document.createElement("strong");
    heading.textContent = "Siphon: original MP4s";
    const status = document.createElement("p");
    status.textContent = "Capture is active. Open your video from this page. Only originals exposed by the page will appear here.";
    const links = document.createElement("div");
    const stop = document.createElement("button");
    stop.textContent = "Stop capture";
    panel.append(heading, status, links, stop);
    document.body.append(panel);

    let active = true;
    const seen = new Set();
    const collect = (value) => {
        if (!active) return;
        for (const url of originalURLs(value)) {
            if (seen.has(url) || seen.size >= 100) continue;
            seen.add(url);
            const link = document.createElement("a");
            link.textContent = new URL(url).pathname.split("/").pop();
            link.href = "siphon://download?url=" + encodeURIComponent(url) + "&browser=safari&ua=" + encodeURIComponent(navigator.userAgent);
            link.style.cssText = "display:block;margin:12px 0;overflow-wrap:anywhere";
            links.append(link);
            status.textContent = "Choose the original belonging to your video. Siphon will open its download dialog.";
        }
    };

    collect(performance.getEntriesByType("resource").map(entry => entry.name));
    collect(Array.from(document.querySelectorAll("video,source,a")).flatMap(element => [element.currentSrc, element.src, element.href]));

    const previousFetch = window.fetch;
    const captureFetch = function (...args) {
        return previousFetch.apply(this, args).then(response => {
            if (active && (response.headers.get("content-type") || "").includes("json")) {
                try { response.clone().json().then(collect).catch(() => {}); }
                catch (_) { /* A consumed response cannot be inspected. */ }
            }
            return response;
        });
    };
    window.fetch = captureFetch;

    const previousSend = XMLHttpRequest.prototype.send;
    const observed = new WeakSet();
    const captureSend = function (...args) {
        if (!observed.has(this)) {
            observed.add(this);
            this.addEventListener("load", () => {
                if (!active || !(this.getResponseHeader("content-type") || "").includes("json")) return;
                try {
                    if (this.responseType === "json") collect(this.response);
                    else if (!this.responseType || this.responseType === "text") collect(JSON.parse(this.responseText));
                } catch (_) { /* Ignore non-JSON/error responses; leave the page unchanged. */ }
            });
        }
        return previousSend.apply(this, args);
    };
    XMLHttpRequest.prototype.send = captureSend;
    window.__siphonOriginalCapture = true;
    stop.addEventListener("click", () => {
        active = false;
        if (window.fetch === captureFetch) window.fetch = previousFetch;
        if (XMLHttpRequest.prototype.send === captureSend) XMLHttpRequest.prototype.send = previousSend;
        delete window.__siphonOriginalCapture;
        panel.remove();
    });
})();
