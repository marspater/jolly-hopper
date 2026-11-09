import os

/// Intervals for Instruments. Names are static strings: never pass URLs or titles.
public enum Signposts {
    public static let signposter = OSSignposter(subsystem: "com.marspater.siphon", category: "Pipeline")

    public static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    public static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }
}

/// The "Merge" interval of one yt-dlp process. yt-dlp merges inside that process
/// and only reports it on stdout, so the interval follows the output lines.
public final class MergeSignpost: Sendable {
    private struct State: Sendable {
        var interval: OSSignpostIntervalState?
        var finished = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var isOpen: Bool { state.withLock { $0.interval != nil } }

    /// Takes each stdout line in order. Any phase line ends an open merge.
    public func observe(_ line: String) {
        guard line.hasPrefix("[") || line.hasPrefix("SIPHON_") else { return }
        state.withLock { state in
            Self.end(&state)
            if line.hasPrefix("[Merger]"), !state.finished {
                state.interval = Signposts.begin("Merge")
            }
        }
    }

    /// Call when the process is done. A line still in flight after a drain
    /// timeout cannot open an interval that nothing would end.
    public func finish() {
        state.withLock { state in
            Self.end(&state)
            state.finished = true
        }
    }

    private static func end(_ state: inout State) {
        if let interval = state.interval {
            Signposts.end("Merge", interval)
            state.interval = nil
        }
    }
}
