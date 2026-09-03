## 2024-07-21 - Expensive String Manipulation in Loops
**Learning:** Checking for file extensions in macOS using `.pathExtension` is fast, but extracting the file name without extension using `.deletingPathExtension().lastPathComponent` allocates objects and is slow. When looping through large directories, string manipulation should be deferred until after cheap checks pass.
**Action:** When filtering files in directories, always prioritize cheap checks (`pathExtension`, `hasSuffix`) before executing heavy URL component extraction.
## 2024-07-21 - Optimizing O(N) Array Operations in Swift
**Learning:** In Swift, `insert(at: 0)` on Arrays is highly inefficient (O(N)) because it shifts all subsequent elements. It is often faster to `append()` (O(1)) and reverse the array when displaying or iterating later. Similarly, replacing `removeAll(where:)` with `firstIndex(where:)` and `remove(at:)` avoids full O(N) scans when only a single element is expected to match.
**Action:** When working with Swift arrays, favor appending to the end and retrieving in reverse order if a LIFO or newest-first display order is needed.
## 2024-07-21 - Optimizing O(N) Iteration for Specific State Filtering
**Learning:** Iterating over a large array to find elements in a specific state (e.g. `.failed`) is O(N) and can be slow. Maintaining a separate dictionary or set for elements in that state reduces iteration to O(K) where K is the number of items in that state.
**Action:** When filtering objects by state frequently, consider maintaining a separate collection (like a dictionary map) specifically for the state, keeping it updated when states change.
## 2025-01-28 - Detached Tasks for Synchronous I/O in SwiftUI
**Learning:** Performing synchronous file I/O operations (`FileManager.default.fileExists`) directly inside SwiftUI views (`@MainActor`) blocks the main thread. When moving these to `Task.detached`, state variables must be extracted locally before entering the detached closure to prevent capturing UI-bound properties asynchronously, avoiding concurrency errors.
**Action:** When offloading synchronous APIs to background threads in Swift, copy necessary values to immutable local variables first, then use `Task.detached` to perform the work, returning the result to the parent MainActor task.
## 2026-07-22 - MainActor Usage for Shared Services
**Learning:** When interacting with an `@MainActor` shared service like `LoggerService`, dispatching from inside an asynchronous API closure (e.g. `requestAuthorization`) requires jumping back to the `MainActor`. A helper function with `Task { @MainActor in }` can seamlessly handle this internally to avoid repetitive dispatch code.
**Action:** Use centralized helper methods to handle repetitive `@MainActor` dispatch when calling UI-bound singletons from background closures.
## 2024-07-21 - Avoiding redundant broadcasts during array mutation
**Learning:** In SwiftUI applications using `ObservableObject`, triggering `objectWillChange.send()` inside a loop that mutates an array causes redundant, performance-killing UI updates for every iteration.
**Action:** When mutating arrays (like clearing or stopping multiple items), pass a `skipBroadcast` flag to bypass the per-item UI update and call `objectWillChange.send()` exactly once after the loop completes.
## 2026-08-15 - Batch Array Modifications to avoid redundant UI broadcasts
**Learning:** Adding multiple objects individually to an `@Published` array causes `objectWillChange.send()` to fire for every single element, leading to severe N+1 performance bottlenecks and laggy UI.
**Action:** When adding multiple elements to an observable array, always map the elements first and insert them all at once using `append(contentsOf:)` to guarantee a single broadcast.
## 2026-08-15 - Avoiding Intermediate String Allocations
**Learning:** `components(separatedBy:)` on `String` allocates multiple intermediate string objects which can be expensive inside heavy parsing loops. Converting to `Data` and using `split(separator:)` with bytes bypasses intermediate String allocations and speeds up execution significantly.
**Action:** When parsing large string outputs line-by-line in Swift, especially before JSON decoding, use `output.data(using: .utf8)?.split(separator: UInt8(ascii: "\n"))` instead of `.components(separatedBy: "\n")`.

## 2026-08-15 - Thread-Safe In-Memory Caching for System Workspace Queries
**Learning:** Querying `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` performs workspace and bundle resolution that can be redundant and slow when called repeatedly. Caching the result thread-safely with `NSLock` avoids unnecessary workspace lookups.
**Action:** Cache static or slowly-changing system workspace lookup results in memory with thread safety (`NSLock`) when invoked from UI views or utility classes.

## 2026-09-03 - Static Pre-Compilation of NSRegularExpression Patterns
**Learning:** Instantiating `NSRegularExpression` objects inside loops or frequently executed method calls compiles regex patterns on every iteration, incurring heavy compilation overhead and unnecessary memory allocations.
**Action:** Always pre-compile static regular expressions into `private static let` properties or constants so they are compiled once at initialization and reused across all function invocations.
