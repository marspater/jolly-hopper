## 2026-03-03 - Non-blocking async thumbnail loading in DownloadManager
**Learning:** Using synchronous `Data(contentsOf:)` inside `Task.detached` blocks cooperative thread pool threads on synchronous disk/network I/O operations.
**Action:** Replace `Data(contentsOf:)` with `URLSession.shared.data(from:)` to leverage non-blocking async I/O.
