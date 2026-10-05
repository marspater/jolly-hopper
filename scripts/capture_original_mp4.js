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

    async function inspectResponse(response, active, collect) {
        if (!active || !(response?.headers?.get?.("content-type") || "").includes("json")) return;
        try {
            const data = await response.clone().json();
            collect(data);
        } catch (_) { /* A consumed response cannot be inspected. */ }
    }

    function init(env) {
        const win = env?.window ?? (typeof window !== "undefined" ? window : undefined);
        const doc = env?.document ?? (typeof document !== "undefined" ? document : undefined);
        const nav = env?.navigator ?? (typeof navigator !== "undefined" ? navigator : undefined);
        const XHR = env?.XMLHttpRequest ?? (typeof XMLHttpRequest !== "undefined" ? XMLHttpRequest : undefined);
        const perf = env?.performance ?? (typeof performance !== "undefined" ? performance : undefined);

        if (!win || !doc || !nav || !XHR) return;
        if (win.__siphonOriginalCapture) return;

        const panel = doc.createElement("aside");
        panel.style.cssText = "position:fixed;right:16px;bottom:16px;z-index:2147483647;background:white;color:black;padding:16px;border:1px solid #888;border-radius:12px;font:14px system-ui;max-width:360px;max-height:50vh;overflow:auto";
        const heading = doc.createElement("strong");
        heading.textContent = "Siphon: original MP4s";
        const status = doc.createElement("p");
        status.textContent = "Capture is active. Open your video from this page. Only originals exposed by the page will appear here.";
        const links = doc.createElement("div");
        const stop = doc.createElement("button");
        stop.textContent = "Stop capture";
        panel.append(heading, status, links, stop);
        doc.body.append(panel);

        let active = true;
        const browser = /Edg\//.test(nav.userAgent || "") ? "edge" : "safari";
        const seen = new Set();
        const collect = (value) => {
            if (!active) return;
            for (const url of originalURLs(value)) {
                if (seen.has(url) || seen.size >= 100) continue;
                seen.add(url);
                const link = doc.createElement("a");
                link.textContent = new URL(url).pathname.split("/").pop();
                link.href = "siphon://download?url=" + encodeURIComponent(url) + "&browser=" + browser + "&ua=" + encodeURIComponent(nav.userAgent || "");
                link.style.cssText = "display:block;margin:12px 0;overflow-wrap:anywhere";
                links.append(link);
                status.textContent = "Choose the original belonging to your video. Siphon will open its download dialog.";
            }
        };

        if (typeof perf?.getEntriesByType === "function") {
            collect(perf.getEntriesByType("resource").map(entry => entry.name));
        }
        if (typeof doc.querySelectorAll === "function") {
            collect(Array.from(doc.querySelectorAll("video,source,a")).flatMap(element => [element.currentSrc, element.src, element.href]));
        }

        const previousFetch = win.fetch;
        const captureFetch = async function (...args) {
            const response = await previousFetch.apply(this, args);
            void inspectResponse(response, active, collect);
            return response;
        };
        win.fetch = captureFetch;

        const previousSend = XHR.prototype.send;
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
        XHR.prototype.send = captureSend;
        win.__siphonOriginalCapture = true;
        stop.addEventListener("click", () => {
            active = false;
            if (win.fetch === captureFetch) win.fetch = previousFetch;
            if (XHR.prototype.send === captureSend) XHR.prototype.send = previousSend;
            delete win.__siphonOriginalCapture;
            panel.remove();
        });
    }

    if (typeof module !== "undefined" && module.exports) {
        module.exports = { originalURLs, init };
    } else {
        init();
    }
})();
