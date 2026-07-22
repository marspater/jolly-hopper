## 2024-07-21 - Expensive String Manipulation in Loops
**Learning:** Checking for file extensions in macOS using `.pathExtension` is fast, but extracting the file name without extension using `.deletingPathExtension().lastPathComponent` allocates objects and is slow. When looping through large directories, string manipulation should be deferred until after cheap checks pass.
**Action:** When filtering files in directories, always prioritize cheap checks (`pathExtension`, `hasSuffix`) before executing heavy URL component extraction.
## 2024-07-21 - Optimizing O(N) Array Operations in Swift
**Learning:** In Swift, `insert(at: 0)` on Arrays is highly inefficient (O(N)) because it shifts all subsequent elements. It is often faster to `append()` (O(1)) and reverse the array when displaying or iterating later. Similarly, replacing `removeAll(where:)` with `firstIndex(where:)` and `remove(at:)` avoids full O(N) scans when only a single element is expected to match.
**Action:** When working with Swift arrays, favor appending to the end and retrieving in reverse order if a LIFO or newest-first display order is needed.
