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
